/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-DeMoD-Commercial
 * quanta-speech-analyze — WAV -> QSP (Harmonic+Noise Model), spec Appendix P.
 * Copyright (c) 2026 DeMoD LLC.
 *
 * Offline (libm allowed). Pipeline: NCCF f0 track + voicing -> pitch-synchronous
 * frames (~1 frame/period, 2-period Hann window centred on the pitch mark) ->
 * per-harmonic LS projection (amp/phase at k*f0 < MVF) -> harmonic OLA -> noise
 * residual banded to the codec's 24-band envelope (qsc_gain_q). Voiced/unvoiced
 * both frame; unvoiced frames have na=0 (pure noise).
 */
#include "../include/qsc.h"
#include "../include/qsp.h"

/* ---- NCCF f0 estimate for the analysis window [c-W/2, c+W/2) ---- */
static double nccf_f0(const double *x, uint64_t N, int64_t c, int W, uint32_t sr,
                      double fmin, double fmax, double *conf){
    int lo=(int)(sr/fmax), hi=(int)(sr/fmin);
    int64_t s = c - W/2; if (s<0) s=0; if (s+W+hi >= (int64_t)N) { *conf=0; return 0; }
    double e0=0; for (int i=0;i<W;i++) e0 += x[s+i]*x[s+i];
    if (e0 < 1e-9){ *conf=0; return 0; }
    int nlag = hi-lo+1; double *nc = malloc((size_t)nlag*sizeof(double));
    double best=0; int blag=0;
    for (int lag=lo; lag<=hi; lag++){
        double num=0, e1=0;
        for (int i=0;i<W;i++){ double a=x[s+i], b=x[s+i+lag]; num+=a*b; e1+=b*b; }
        double v = num/(sqrt(e0*e1)+1e-12); nc[lag-lo]=v;
        if (v>best){ best=v; blag=lag; }
    }
    *conf = best;
    double lag = blag;
    if (blag>lo && blag<hi){                              /* sub-sample parabolic peak */
        double ym1=nc[blag-lo-1], y0=nc[blag-lo], yp1=nc[blag-lo+1], den=ym1-2*y0+yp1;
        if (fabs(den)>1e-12){ double d=0.5*(ym1-yp1)/den; if (d>-1&&d<1) lag=blag+d; }
    }
    free(nc);
    return lag>0 ? (double)sr/lag : 0.0;
}

int main(int argc, char **argv){
    const char *inp=NULL, *outp="speech.qsp"; uint32_t seed=0xDEC0DE;
    double fmin=70, fmax=400, vthr=0.35, mvf_cap=5500.0, winp=1.5, aper=0.0;
    for (int i=1;i<argc;i++){
        if (!strcmp(argv[i],"-o")&&i+1<argc) outp=argv[++i];
        else if (!strcmp(argv[i],"--fmin")&&i+1<argc) fmin=atof(argv[++i]);
        else if (!strcmp(argv[i],"--fmax")&&i+1<argc) fmax=atof(argv[++i]);
        else if (!strcmp(argv[i],"--vthr")&&i+1<argc) vthr=atof(argv[++i]);
        else if (!strcmp(argv[i],"--mvf")&&i+1<argc) mvf_cap=atof(argv[++i]);
        else if (!strcmp(argv[i],"--win")&&i+1<argc) winp=atof(argv[++i]);
        else if (!strcmp(argv[i],"--aper")&&i+1<argc) aper=atof(argv[++i]);
        else if (!strcmp(argv[i],"--seed")&&i+1<argc) seed=(uint32_t)strtoul(argv[++i],0,0);
        else inp=argv[i];
    }
    if (!inp){ fprintf(stderr,"usage: quanta-speech-analyze in.wav [-o out.qsp] [--fmin --fmax --vthr --mvf]\n"); return 2; }

    uint32_t sr; uint64_t N;
    double *x = wav_read_mono(inp,&sr,&N);
    if (!x){ fprintf(stderr,"speech-analyze: cannot read %s\n",inp); return 1; }
    double g_wtab[QSC_TAB], g_stab[QSC_TAB]; qsc_build_tables(g_wtab, g_stab);

    /* --- pass 1: place PS frames (onset marks) + f0/voicing --- */
    uint32_t *onset=NULL; double *f0=NULL; uint8_t *vflag=NULL; uint32_t nf=0, cap=0;
    int hopU = (int)(0.010*sr);                         /* unvoiced fixed hop 10 ms */
    int Wf0  = (int)(0.030*sr);                          /* f0 analysis window 30 ms */
    int64_t t=0;
    while (t < (int64_t)N){
        double conf; double f = nccf_f0(x,N,t,Wf0,sr,fmin,fmax,&conf);
        int voiced = (conf>=vthr && f>=fmin && f<=fmax);
        int step = voiced ? (int)(sr/f + 0.5) : hopU;
        if (step<16) step=16;
        if (nf==cap){ cap=cap?cap*2:512; onset=realloc(onset,cap*4); f0=realloc(f0,cap*sizeof(double)); vflag=realloc(vflag,cap); }
        onset[nf]=(uint32_t)t; f0[nf]= voiced?f:0.0; vflag[nf]=(uint8_t)voiced; nf++;
        t += step;
    }

    /* noise-band calibration rho_b (= diag of qsc_band_coherence) */
    double C[QSC_BANDS][QSC_BANDS]; qsc_band_coherence(C, sr);
    double rho[QSC_BANDS]; for (int b=0;b<QSC_BANDS;b++){ rho[b]=sqrt(C[b][b]); if(rho[b]<1e-9)rho[b]=1e-9; }

    /* --- pass 2: harmonic LS per frame + harmonic OLA reconstruction --- */
    Qsp q; memset(&q,0,sizeof q);
    q.h.sample_rate=sr; q.h.source_len=N; q.h.frame_count=nf; q.h.band_count=QSC_BANDS;
    q.h.noise_seed=seed; q.fr=calloc(nf?nf:1,sizeof(QspFrame));
    double *harm = calloc(N,sizeof(double));            /* harmonic reconstruction (MQ) */
    uint16_t kmax=0;

    for (uint32_t fi=0; fi<nf; fi++){
        uint32_t o=onset[fi]; double f=f0[fi]; int voiced=vflag[fi];
        int period = voiced ? (int)(sr/f+0.5) : hopU;
        int hw = (int)(winp*period+0.5); if(hw<1)hw=1;   /* half-window = winp periods */
        double om = voiced ? 2.0*M_PI*f/sr : 0.0;
        int K = 0;
        if (voiced){ double mvf = mvf_cap<0.45*sr?mvf_cap:0.45*sr; K=(int)(mvf/f); if(K<1)K=1; if(K>QSP_KMAX)K=QSP_KMAX; }
        q.fr[fi].onset=o; q.fr[fi].f0=(float)(voiced?f:0.0); q.fr[fi].voiced=(uint8_t)voiced;
        q.fr[fi].mvf=(float)(voiced?K*f:0.0); q.fr[fi].na=(uint16_t)K;
        q.fr[fi].amp=malloc((K?K:1)*sizeof(float)); q.fr[fi].phase=malloc((K?K:1)*sizeof(float));
        if ((uint16_t)K>kmax) kmax=(uint16_t)K;
        /* JOINT LS: fit all harmonics simultaneously (cos_k,sin_k basis) over the
           Hann²-weighted 2-period frame — harmonics overlap in a short window, so an
           independent per-harmonic projection over-counts shared energy. */
        if (K>0){
            int M2=2*K;
            double *MM=calloc((size_t)M2*M2,sizeof(double)), *bb=calloc(M2,sizeof(double));
            double *bas=malloc(M2*sizeof(double));
            for (int i=-hw;i<hw;i++){ int64_t n=(int64_t)o+i; if(n<0||n>=(int64_t)N) continue;
                double hann=0.5-0.5*cos(2.0*M_PI*(i+hw)/(2.0*hw)), w2=hann*hann, z=x[n];
                for (int k=1;k<=K;k++){ double th=k*om*i; bas[2*(k-1)]=cos(th); bas[2*(k-1)+1]=sin(th); }
                for (int a=0;a<M2;a++){ double wa=w2*bas[a]; bb[a]+=wa*z;
                    for (int b2=a;b2<M2;b2++) MM[(size_t)a*M2+b2]+=wa*bas[b2]; } }
            for (int a=0;a<M2;a++){ for (int b2=0;b2<a;b2++) MM[(size_t)a*M2+b2]=MM[(size_t)b2*M2+a]; MM[(size_t)a*M2+a]+=1e-9; }
            for (int col=0;col<M2;col++){                 /* Gauss-Jordan w/ partial pivot */
                int piv=col; double mx=fabs(MM[(size_t)col*M2+col]);
                for (int r=col+1;r<M2;r++){ double v=fabs(MM[(size_t)r*M2+col]); if(v>mx){mx=v;piv=r;} }
                if (piv!=col){ for(int c=0;c<M2;c++){ double t=MM[(size_t)col*M2+c]; MM[(size_t)col*M2+c]=MM[(size_t)piv*M2+c]; MM[(size_t)piv*M2+c]=t; } double t=bb[col]; bb[col]=bb[piv]; bb[piv]=t; }
                double d=MM[(size_t)col*M2+col]; if(fabs(d)<1e-30)d=1e-30;
                for (int r=0;r<M2;r++){ if(r==col) continue; double fct=MM[(size_t)r*M2+col]/d;
                    for (int c=col;c<M2;c++) MM[(size_t)r*M2+c]-=fct*MM[(size_t)col*M2+c]; bb[r]-=fct*bb[col]; } }
            for (int k=1;k<=K;k++){ double p=bb[2*(k-1)]/MM[(size_t)(2*(k-1))*M2+2*(k-1)];
                double qq=bb[2*(k-1)+1]/MM[(size_t)(2*(k-1)+1)*M2+2*(k-1)+1];
                double amp=sqrt(p*p+qq*qq), ph=atan2(p,qq); if(ph<0)ph+=2.0*M_PI;
                q.fr[fi].amp[k-1]=(float)amp; q.fr[fi].phase[k-1]=(float)ph; }
            free(MM); free(bb); free(bas);
        }
    }
    q.h.kmax=kmax;
    /* Reconstruct the harmonic layer EXACTLY as speech-render will (shared MQ
       track synthesis in qsp.h) so the noise residual (x - harm) matches what the
       decoder leaves — the determinism-contract discipline the music path uses. */
    qsp_render_harmonics(harm, N, sr, nf, q.fr, g_stab);

    /* --- pass 3: noise residual (x - harm) banded per frame --- */
    double *res = malloc(N*sizeof(double));
    for (uint64_t n=0;n<N;n++) res[n]=x[n]-harm[n];
    QscSvf f[QSC_BANDS];
    for (uint32_t fi=0; fi<nf; fi++){
        uint32_t o=onset[fi]; int period=vflag[fi]?(int)(sr/f0[fi]+0.5):hopU; int hw=(int)(winp*period+0.5); if(hw<1)hw=1;
        double acc[QSC_BANDS]={0}; int cnt=0;
        for (int b=0;b<QSC_BANDS;b++){ qsc_svf_init(&f[b], qsc_band_fc(b), QSC_BAND_Q, sr); f[b].ic1=f[b].ic2=0; }
        for (int i=-hw;i<hw;i++){ int64_t n=(int64_t)o+i; if(n<0||n>=(int64_t)N) continue;
            for (int b=0;b<QSC_BANDS;b++){ double y=qsc_svf_bp(&f[b], res[n]); acc[b]+=y*y; } cnt++; }
        double gv[QSC_BANDS], gCg=0, ef=0;
        for (int i=-hw;i<hw;i++){ int64_t n=(int64_t)o+i; if(n>=0&&n<(int64_t)N) ef+=res[n]*res[n]; }
        ef = cnt? ef/cnt : 0;
        for (int b=0;b<QSC_BANDS;b++) gv[b]= cnt? sqrt(acc[b]/cnt)/rho[b] : 0;
        /* HNM MVF gate: in voiced frames the harmonics own the spectrum below MVF,
           so residual energy there is harmonic-fit error, not aperiodicity —
           reproducing it as random-phase noise is the dominant source of audible
           hiss. Zero those bands; noise only fills bands above MVF (the aperiodic
           high-frequency breath). Re-apportion the true (time-domain) residual
           energy to the surviving bands by their energy share so the calibration
           trim stays honest. Note: sub-fundamental source energy (< f0) is left
           unmodelled on purpose — it is largely room/handling rumble, and
           resynthesising it as low-frequency random noise (barely masked) is
           perceptually worse than the spectral hole it leaves. */
        double mvf = (vflag[fi] && q.fr[fi].mvf>0) ? (double)q.fr[fi].mvf : 0.0;
        if (mvf>0){
            double e_all=1e-30, e_keep=0;
            for (int b=0;b<QSC_BANDS;b++){ double fc=qsc_band_fc(b); e_all+=acc[b];
                e_keep += (fc>=mvf)? acc[b] : aper*aper*acc[b]; }
            for (int b=0;b<QSC_BANDS;b++) if (qsc_band_fc(b)<mvf) gv[b]*=aper;
            ef *= e_keep/e_all;
        }
        for (int b=0;b<QSC_BANDS;b++){ double row=0; for(int c=0;c<QSC_BANDS;c++) row+=C[b][c]*gv[c]; gCg+=gv[b]*row; }
        double trim = (gCg>1e-30)? sqrt(ef/gCg):1.0;
        for (int b=0;b<QSC_BANDS;b++) q.fr[fi].gain[b]=qsc_gain_q(gv[b]*trim);
    }

    if (qsp_write(outp,&q)){ fprintf(stderr,"speech-analyze: write failed\n"); return 1; }
    uint32_t nv=0; for (uint32_t i=0;i<nf;i++) nv+=vflag[i];
    fprintf(stderr,"speech-analyze: %s\n  %llu samples @ %u Hz | %u frames (%u voiced, %.0f%%) | kmax %u -> %s\n",
            inp,(unsigned long long)N,sr,nf,nv,nf?100.0*nv/nf:0.0,kmax,outp);
    qsp_free(&q); free(x); free(harm); free(res); free(onset); free(f0); free(vflag);
    return 0;
}
