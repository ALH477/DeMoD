/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-DeMoD-Commercial
 * quanta-speech-sines — WAV -> QSP (general sinusoidal model), spec Appendix P.
 * Copyright (c) 2026 DeMoD LLC.
 *
 * Offline (libm allowed). A general MQ sinusoidal analyzer: per fixed-hop STFT frame,
 * pick the top-N spectral peaks (parabolic freq/amp/phase refine) and store them as
 * arbitrary partials (freq,amp,phase). Synthesis (speech-render, SINES mode) forms
 * McAulay-Quatieri tracks by nearest-frequency matching and renders them with the
 * shared libm-free cubic-phase engine (qsp_render_sines). This captures the
 * inharmonic/coherent energy the strict k*f0 harmonic model leaves in the residual —
 * the validated path past the harmonic-model NMR wall.
 *
 * A residual noise layer (24-band) is fit against the EXACT MQ resynthesis so the
 * decoder's noise matches what it leaves (determinism-contract discipline).
 */
#include "../include/qsc.h"
#include "../include/qsp.h"

/* iterative radix-2 FFT (copied from mp.h; kept local to avoid its static globals) */
static void s_fft(double *re, double *im, int n){
    for (int i=1,j=0;i<n;i++){ int bit=n>>1; for(;j&bit;bit>>=1) j^=bit; j|=bit;
        if(i<j){ double t=re[i];re[i]=re[j];re[j]=t; t=im[i];im[i]=im[j];im[j]=t; } }
    for (int len=2;len<=n;len<<=1){ double ang=-2.0*M_PI/len, wr=cos(ang), wi=sin(ang);
        for (int i=0;i<n;i+=len){ double cr=1.0,ci=0.0;
            for (int k=0;k<len/2;k++){ int a=i+k,b=i+k+len/2;
                double ur=re[a],ui=im[a], vr=re[b]*cr-im[b]*ci, vi=re[b]*ci+im[b]*cr;
                re[a]=ur+vr;im[a]=ui+vi;re[b]=ur-vr;im[b]=ui-vi;
                double ncr=cr*wr-ci*wi; ci=cr*wi+ci*wr; cr=ncr; } } }
}

typedef struct { double f,a,p; } Peak;

int main(int argc, char **argv){
    const char *inp=NULL,*outp="speech.qsp"; uint32_t seed=0xDEC0DE;
    int W=1024, H=256, NPK=60; double matchc=100.0, floordb=-60.0;
    for (int i=1;i<argc;i++){
        if (!strcmp(argv[i],"-o")&&i+1<argc) outp=argv[++i];
        else if (!strcmp(argv[i],"--win")&&i+1<argc) W=atoi(argv[++i]);
        else if (!strcmp(argv[i],"--hop")&&i+1<argc) H=atoi(argv[++i]);
        else if (!strcmp(argv[i],"--peaks")&&i+1<argc) NPK=atoi(argv[++i]);
        else if (!strcmp(argv[i],"--match")&&i+1<argc) matchc=atof(argv[++i]);
        else if (!strcmp(argv[i],"--floor")&&i+1<argc) floordb=atof(argv[++i]);
        else if (!strcmp(argv[i],"--seed")&&i+1<argc) seed=(uint32_t)strtoul(argv[++i],0,0);
        else inp=argv[i];
    }
    if (!inp){ fprintf(stderr,"usage: quanta-speech-sines in.wav [-o out.qsp] [--peaks N] [--win W] [--hop H] [--match cents]\n"); return 2; }
    /* W must be a power of two for s_fft */
    { int p=1; while(p<W)p<<=1; W=p; }

    uint32_t sr; uint64_t N;
    double *x=wav_read_mono(inp,&sr,&N);
    if (!x){ fprintf(stderr,"speech-sines: cannot read %s\n",inp); return 1; }
    double g_wtab[QSC_TAB], g_stab[QSC_TAB]; qsc_build_tables(g_wtab,g_stab);

    double *win=malloc(W*sizeof(double)); double wsum=0;
    for (int i=0;i<W;i++){ win[i]=0.5-0.5*cos(2.0*M_PI*i/W); wsum+=win[i]; }
    double *re=malloc(W*sizeof(double)), *im=malloc(W*sizeof(double));

    uint32_t nf = (N>(uint64_t)W)? (uint32_t)((N-W)/H)+1 : 1;
    Qsp q; memset(&q,0,sizeof q);
    q.h.sample_rate=sr; q.h.source_len=N; q.h.frame_count=nf; q.h.band_count=QSC_BANDS;
    q.h.noise_seed=seed; q.h.flags=QSP_FLAG_SINES; q.fr=calloc(nf?nf:1,sizeof(QspFrame));
    uint16_t kmax=0;
    Peak *pk=malloc((size_t)(W/2+1)*sizeof(Peak));

    for (uint32_t fi=0; fi<nf; fi++){
        uint64_t o=(uint64_t)fi*H;
        /* zero-phase (fftshift) windowing: rotate the windowed frame by W/2 so the
           analysis window is symmetric about sample 0 -> the DFT phase at a peak bin
           is the partial's phase at the frame CENTRE (o+W/2), free of the fractional-
           bin leakage error that contaminates a sample-0 reference. */
        for (int i=0;i<W;i++){ double v=(o+(uint64_t)i<N)? x[o+i]:0.0; double wv=v*win[i];
            int j=(i+W/2)&(W-1); re[j]=wv; im[j]=0.0; }
        s_fft(re,im,W);
        /* magnitudes; global peak for the per-frame floor */
        double gmax=0;
        for (int k=1;k<W/2;k++){ double m=sqrt(re[k]*re[k]+im[k]*im[k]); if(m>gmax)gmax=m; }
        double fl = gmax*pow(10.0, floordb/20.0);
        /* local maxima above floor */
        int npk=0;
        for (int k=2;k<W/2-1;k++){
            double m0=sqrt(re[k-1]*re[k-1]+im[k-1]*im[k-1]);
            double m1=sqrt(re[k]*re[k]+im[k]*im[k]);
            double m2=sqrt(re[k+1]*re[k+1]+im[k+1]*im[k+1]);
            if (m1>m0 && m1>=m2 && m1>fl){
                /* QIFFT: parabolic interpolation on LOG magnitude (accurate for the
                   window mainlobe) for sub-bin frequency + true peak amplitude. */
                double l0=log(m0+1e-30), l1=log(m1+1e-30), l2=log(m2+1e-30);
                double den=l0-2*l1+l2, d=(fabs(den)>1e-30)? 0.5*(l0-l2)/den:0.0;
                if (d>0.5)d=0.5; if(d<-0.5)d=-0.5;
                double lpk=l1-0.25*(l0-l2)*d, amp=exp(lpk);   /* interpolated peak mag */
                double freq=(k+d)*(double)sr/W;
                /* phase at the frame centre. The W/2 fftshift multiplies bin k by
                   (-1)^k, so add pi*k to undo it; +pi/2 converts cos-phase to the
                   sine convention the synth uses. */
                double ph=atan2(im[k],re[k]) + M_PI*k + 0.5*M_PI;
                pk[npk].f=freq; pk[npk].a=2.0*amp/wsum; pk[npk].p=ph; npk++;
            }
        }
        /* keep the NPK strongest (simple partial selection by amplitude) */
        for (int a=0;a<npk;a++) for (int b=a+1;b<npk;b++) if (pk[b].a>pk[a].a){ Peak t=pk[a];pk[a]=pk[b];pk[b]=t; }
        int na = npk<NPK?npk:NPK;
        q.fr[fi].onset=(uint32_t)(o+W/2); q.fr[fi].voiced=1; q.fr[fi].f0=0; q.fr[fi].mvf=0; q.fr[fi].na=(uint16_t)na;
        q.fr[fi].amp=malloc((na?na:1)*sizeof(float));
        q.fr[fi].phase=malloc((na?na:1)*sizeof(float));
        q.fr[fi].freq=malloc((na?na:1)*sizeof(float));
        for (int a=0;a<na;a++){ double p=pk[a].p; p=p-2.0*M_PI*floor(p/(2.0*M_PI));
            q.fr[fi].amp[a]=(float)pk[a].a; q.fr[fi].phase[a]=(float)p; q.fr[fi].freq[a]=(float)pk[a].f; }
        if ((uint16_t)na>kmax) kmax=(uint16_t)na;
    }
    q.h.kmax=kmax;

    /* --- residual noise layer: MQ-resynthesize, subtract, band to 24 gains ---
       Matches the decoder (qsp_render_sines) so the noise is what it actually leaves. */
    double *harm=calloc(N,sizeof(double));
    qsp_render_sines(harm,N,sr,nf,q.fr,g_stab,matchc);
    double *res=malloc(N*sizeof(double)); for (uint64_t n=0;n<N;n++) res[n]=x[n]-harm[n];
    double C[QSC_BANDS][QSC_BANDS]; qsc_band_coherence(C,sr);
    double rho[QSC_BANDS]; for(int b=0;b<QSC_BANDS;b++){ rho[b]=sqrt(C[b][b]); if(rho[b]<1e-9)rho[b]=1e-9; }
    QscSvf f[QSC_BANDS];
    for (uint32_t fi=0; fi<nf; fi++){
        int64_t o=(int64_t)q.fr[fi].onset; int hw=H;
        double acc[QSC_BANDS]={0}; int cnt=0, ef=0; double efe=0;
        for (int b=0;b<QSC_BANDS;b++){ qsc_svf_init(&f[b],qsc_band_fc(b),QSC_BAND_Q,sr); f[b].ic1=f[b].ic2=0; }
        for (int i=-hw;i<hw;i++){ int64_t n=o+i; if(n<0||n>=(int64_t)N) continue;
            for (int b=0;b<QSC_BANDS;b++){ double y=qsc_svf_bp(&f[b],res[n]); acc[b]+=y*y; } efe+=res[n]*res[n]; cnt++; (void)ef; }
        double gv[QSC_BANDS], gCg=0; double efm = cnt? efe/cnt : 0;
        for (int b=0;b<QSC_BANDS;b++) gv[b]= cnt? sqrt(acc[b]/cnt)/rho[b] : 0;
        for (int b=0;b<QSC_BANDS;b++){ double row=0; for(int c=0;c<QSC_BANDS;c++) row+=C[b][c]*gv[c]; gCg+=gv[b]*row; }
        double trim=(gCg>1e-30)? sqrt(efm/gCg):1.0;
        for (int b=0;b<QSC_BANDS;b++) q.fr[fi].gain[b]=qsc_gain_q(gv[b]*trim);
    }

    if (qsp_write(outp,&q)){ fprintf(stderr,"speech-sines: write failed\n"); return 1; }
    fprintf(stderr,"speech-sines: %s\n  %llu samples @ %u Hz | %u frames (hop %d, win %d) | peaks<=%d kmax %u -> %s\n",
            inp,(unsigned long long)N,sr,nf,H,W,NPK,kmax,outp);
    qsp_free(&q); free(x); free(win); free(re); free(im); free(pk); free(harm); free(res);
    return 0;
}
