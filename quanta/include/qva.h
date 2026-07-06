/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-DeMoD-Commercial
 * qva.h — Quanta unit-vocoder SYNTHESIS in C (port of tools/qvoc.py `synth`).
 * Continuous-phase minimum-phase harmonic MQ synthesis + mixed excitation + spectral
 * postfilter + HF-tilted band noise. Given per-frame {log-env, f0, voiced, band-voicing,
 * gain}, renders PCM. Noise is deterministic (Box-Muller on the qsc LCG) so a given
 * input yields the same output. (A6 will swap the FFT-shaped noise for an LCG→SVF bank
 * to make the harmonic path Faust-freezable; the harmonics already are.)
 * Copyright (c) 2026 DeMoD LLC.
 */
#ifndef DEMOD_QVA_H
#define DEMOD_QVA_H
#include "qsc.h"
#include "mp.h"     /* fft() */

#define QVA_NB 5
static const double QVA_BV_EDGES[QVA_NB+1] = {0.0,0.125,0.25,0.5,0.75,1.0};

/* rfft: real x[0..n) -> Re/Im[0..n/2]. irfft: half spectrum -> real out[0..n). */
static inline void qva__rfft(const double *x, int n, double *Re, double *Im){
    double *re=malloc(sizeof(double)*n), *im=malloc(sizeof(double)*n);
    for (int i=0;i<n;i++){ re[i]=x[i]; im[i]=0.0; }
    fft(re,im,n);
    for (int k=0;k<=n/2;k++){ Re[k]=re[k]; Im[k]=im[k]; }
    free(re); free(im);
}
static inline void qva__irfft(const double *Re, const double *Im, int n, double *out){
    double *re=malloc(sizeof(double)*n), *im=malloc(sizeof(double)*n);
    for (int k=0;k<=n/2;k++){ re[k]=Re[k]; im[k]=Im[k]; }
    for (int k=1;k<n/2;k++){ re[n-k]=Re[k]; im[n-k]=-Im[k]; }    /* conj-symmetric */
    for (int k=0;k<n;k++) im[k]=-im[k];                          /* ifft = conj/fft/N */
    fft(re,im,n);
    for (int i=0;i<n;i++) out[i]=re[i]/n;
    free(re); free(im);
}
/* minimum-phase phase from a log-magnitude envelope (cepstral construction) */
static inline void qva__minphase(const double *envlog, int NF, double *theta){
    int half=NF/2;
    double *fr=malloc(sizeof(double)*NF), *fi=malloc(sizeof(double)*NF);
    for (int k=0;k<=half;k++){ fr[k]=envlog[k]; fi[k]=0.0; }
    for (int k=1;k<half;k++){ fr[NF-k]=envlog[k]; fi[NF-k]=0.0; }
    for (int k=0;k<NF;k++) fi[k]=-fi[k]; fft(fr,fi,NF);          /* ifft -> real cepstrum */
    double *cr=malloc(sizeof(double)*NF), *ci=malloc(sizeof(double)*NF);
    for (int k=0;k<NF;k++){ cr[k]=fr[k]/NF; ci[k]=0.0; }
    cr[0]*=1.0; for (int k=1;k<half;k++) cr[k]*=2.0; /* min-phase window: [1,2..2,1,0..0] */
    for (int k=half+1;k<NF;k++) cr[k]=0.0;
    fft(cr,ci,NF);                                              /* fft(min-phase cepstrum) */
    for (int k=0;k<=half;k++) theta[k]=ci[k];                   /* angle(exp(.)) = Im part */
    free(fr); free(fi); free(cr); free(ci);
}
static inline uint32_t qva__u(uint32_t *s){ *s=(*s)*1103515245u+12345u; return *s; }
static inline double qva__gauss(uint32_t *s){    /* Box-Muller on the LCG */
    double u1=(qva__u(s)+1.0)/4294967297.0, u2=(qva__u(s)+1.0)/4294967297.0;
    if (u1<1e-12) u1=1e-12;
    return sqrt(-2.0*log(u1))*cos(2.0*M_PI*u2);
}
/* per-frequency band-voicing strength: linear interp of the QVA_NB band values over
   their centre frequencies, clamped to the first/last band outside the range. */
static inline double qva__vat(const double *bv, const double *bcent, double f){
    if (f<=bcent[0]) return bv[0]; if (f>=bcent[QVA_NB-1]) return bv[QVA_NB-1];
    for (int b=0;b<QVA_NB-1;b++) if (f<bcent[b+1]){
        double t=(f-bcent[b])/(bcent[b+1]-bcent[b]); return bv[b]+t*(bv[b+1]-bv[b]); }
    return bv[QVA_NB-1];
}
/* interpolate log-env + min-phase theta at frequency f (bin = f/(sr/2)*half) */
static inline void qva__envtap(const double *Ei, const double *Ti, int half, uint32_t sr,
                               double f, double *le, double *th){
    double b=f/(sr/2.0)*half; if(b<0)b=0; if(b>half-1e-6)b=half-1e-6;
    int b0=(int)b; double fr=b-b0;
    *le=Ei[b0]+fr*(Ei[b0+1]-Ei[b0]); *th=Ti[b0]+fr*(Ti[b0+1]-Ti[b0]);
}

/* ---------------- analysis (port of qvoc.analyze) ---------------- */
static inline void qva_params(uint32_t sr, int *H, int *NF){
    int h=(int)lround(0.010*sr); if(h<8)h=8; *H=h;
    int n=1; while (n < (int)(0.021*sr)) n<<=1; *NF=n;
}
static inline void qva__lmed(const double *f0, const uint8_t *v, int n, int i, int h, double *med){
    double buf[64]; int c=0;
    for (int j=i-h;j<=i+h;j++) if (j>=0&&j<n&&v[j]) buf[c++]=f0[j];
    if (!c){ *med=0; return; }
    for (int a=1;a<c;a++){ double x=buf[a]; int b=a-1; while(b>=0&&buf[b]>x){buf[b+1]=buf[b];b--;} buf[b+1]=x; }
    *med=buf[c/2];
}
/* NCCF f0 track + voicing + octave/median cleanup */
static inline void qva__f0(const double *x, uint64_t N, uint32_t sr, int H, int NF,
                           double *f0, uint8_t *voiced, int nf){
    double fmin=70,fmax=400,vthr=0.55; int W=NF, lo=(int)(sr/fmax), hi=(int)(sr/fmin);
    for (int idx=0; idx<nf; idx++){ uint64_t i=(uint64_t)idx*H;
        double mean=0; for(int j=0;j<W;j++) mean += (i+j<N)?x[i+j]:0; mean/=W;
        double e0=0; for(int j=0;j<W;j++){ double v=((i+j<N)?x[i+j]:0)-mean; e0+=v*v; }
        f0[idx]=0; voiced[idx]=0;
        if (e0<1e-6) continue;
        double best=0; int blag=0;
        for (int lag=lo; lag<hi; lag++){ double num=0,ea=0,eb=0;
            for (int j=0;j<W-lag;j++){ double a=((i+j<N)?x[i+j]:0)-mean, b=((i+j+lag<N)?x[i+j+lag]:0)-mean; num+=a*b; ea+=a*a; eb+=b*b; }
            double d=ea*eb; if (d>0){ double v=num/sqrt(d); if (v>best){ best=v; blag=lag; } } }
        f0[idx]= blag?(double)sr/blag:0.0;
        voiced[idx]= (best>=vthr && f0[idx]>=fmin && f0[idx]<=fmax);
    }
    double *f0s=malloc(nf*sizeof(double)); memcpy(f0s,f0,nf*sizeof(double));
    double *fc=malloc(nf*sizeof(double)); memcpy(fc,f0s,nf*sizeof(double));
    for (int i=0;i<nf;i++) if (voiced[i]){ double m; qva__lmed(f0s,voiced,nf,i,3,&m);
        if (m>0){ if (f0s[i]>1.6*m) fc[i]=f0s[i]/2; else if (f0s[i]<0.62*m) fc[i]=f0s[i]*2; } }
    for (int i=0;i<nf;i++){ if (voiced[i]){ double m; qva__lmed(fc,voiced,nf,i,3,&m); if(m>0) f0[i]=m; else f0[i]=fc[i]; } else f0[i]=fc[i]; }
    for (int i=1;i<nf-1;i++){
        if (!voiced[i] && voiced[i-1] && voiced[i+1]){ voiced[i]=1; f0[i]=0.5*(f0[i-1]+f0[i+1]); }
        if ( voiced[i] && !voiced[i-1] && !voiced[i+1]){ voiced[i]=0; f0[i]=0; } }
    free(fc); free(f0s);
}

/* cepstral log-magnitude envelope of one windowed frame (port of qvoc.analyze env) */
static inline void qva__cep_env(const double *fr, int W, const double *win, int NF, int lifter, double *env){
    int half=NF/2;
    double *re=malloc(NF*sizeof(double)), *im=malloc(NF*sizeof(double));
    for (int i=0;i<NF;i++){ re[i]=(i<W)?fr[i]*win[i]:0.0; im[i]=0.0; }
    fft(re,im,NF);
    double mx=0; double *lm=malloc((half+1)*sizeof(double));
    for (int k=0;k<=half;k++){ double m=sqrt(re[k]*re[k]+im[k]*im[k]); lm[k]=m; if(m>mx)mx=m; }
    double flo=mx*1e-4;
    for (int k=0;k<=half;k++){ double m=lm[k]<flo?flo:lm[k]; lm[k]=log(m); }
    for (int k=0;k<=half;k++){ re[k]=lm[k]; im[k]=0.0; }
    for (int k=1;k<half;k++){ re[NF-k]=lm[k]; im[NF-k]=0.0; }
    for (int k=0;k<NF;k++) im[k]=-im[k]; fft(re,im,NF);            /* ifft -> real cepstrum */
    double *cep=malloc(NF*sizeof(double)); for (int k=0;k<NF;k++) cep[k]=re[k]/NF;
    for (int k=lifter;k<=NF-lifter;k++) cep[k]=0.0;                /* liftered: keep low quefrency */
    for (int k=0;k<NF;k++){ re[k]=cep[k]; im[k]=0.0; } fft(re,im,NF);
    for (int k=0;k<=half;k++) env[k]=re[k];
    free(re); free(im); free(lm); free(cep);
}
/* per-band normalized autocorrelation at the pitch lag -> band voicing (MELP mixed-excitation cue) */
static inline void qva__bandvoi(const double *fr, int W, const double *win, int NF, uint32_t sr, double f0, double *v){
    for (int b=0;b<QVA_NB;b++) v[b]=0.0;
    if (f0<1) return;
    int T=(int)lround((double)sr/f0), half=NF/2;
    double *wf=malloc(NF*sizeof(double)), *Re=malloc((half+1)*sizeof(double)), *Im=malloc((half+1)*sizeof(double));
    double *Sr=malloc((half+1)*sizeof(double)), *Si=malloc((half+1)*sizeof(double)), *sb=malloc(NF*sizeof(double));
    for (int i=0;i<NF;i++) wf[i]=(i<W)?fr[i]*win[i]:0.0;
    qva__rfft(wf,NF,Re,Im);
    for (int b=0;b<QVA_NB;b++){
        double e0=QVA_BV_EDGES[b]*(sr/2.0), e1=QVA_BV_EDGES[b+1]*(sr/2.0);
        for (int k=0;k<=half;k++){ double f=(double)k*sr/NF; int m=(f>=e0&&f<e1); Sr[k]=m?Re[k]:0.0; Si[k]=m?Im[k]:0.0; }
        qva__irfft(Sr,Si,NF,sb);
        if (T<NF-8){ double num=0,ea=0,ec=0;
            for (int j=0;j<NF-T;j++){ double a=sb[j],c=sb[j+T]; num+=a*c; ea+=a*a; ec+=c*c; }
            double d=ea*ec; if (d>1e-12){ double vv=num/sqrt(d); v[b]=vv<0?0:(vv>1?1:vv); } }
    }
    free(wf); free(Re); free(Im); free(Sr); free(Si); free(sb);
}
/* full analysis: x -> per-frame log-envelope, f0, voiced, band-voicing. Caller frees env/f0/voiced/bvoi. */
static inline void qva_analyze(const double *x, uint64_t N, uint32_t sr,
        double **env_o, double **f0_o, uint8_t **voiced_o, double **bvoi_o,
        int *nf_o, int *H_o, int *NF_o){
    int H,NF; qva_params(sr,&H,&NF); int half=NF/2, W=NF;
    int lifter=(int)(NF*0.12); if (lifter<20) lifter=20;
    int nf = (N>(uint64_t)W) ? (int)(((N-W)+H-1)/H) : 0;
    double *win=malloc(W*sizeof(double));
    for (int i=0;i<W;i++) win[i]=0.5-0.5*cos(2.0*M_PI*i/(W-1));   /* hanning */
    double *env=malloc((size_t)nf*(half+1)*sizeof(double)), *f0=malloc(nf*sizeof(double));
    double *bvoi=malloc((size_t)nf*QVA_NB*sizeof(double)); uint8_t *voiced=malloc(nf);
    qva__f0(x,N,sr,H,NF,f0,voiced,nf);
    double *fr=malloc(W*sizeof(double));
    for (int idx=0; idx<nf; idx++){ uint64_t i=(uint64_t)idx*H;
        for (int j=0;j<W;j++) fr[j]=(i+j<N)?x[i+j]:0.0;
        qva__cep_env(fr,W,win,NF,lifter,env+(size_t)idx*(half+1));
        qva__bandvoi(fr,W,win,NF,sr, voiced[idx]?f0[idx]:0.0, bvoi+(size_t)idx*QVA_NB);
    }
    free(fr); free(win);
    *env_o=env; *f0_o=f0; *voiced_o=voiced; *bvoi_o=bvoi; *nf_o=nf; *H_o=H; *NF_o=NF;
}

typedef struct { double pf_alpha, mix, vpow, ntilt, hfmax; } QvaParams;
static inline QvaParams qva_defaults(void){ QvaParams p={0.10,0.15,0.5,0.5,7500.0}; return p; }

/* env: nf×(NF/2+1) log-magnitude; f0/voiced/gain: nf; bvoi: nf×QVA_NB.
   Renders out[0..N) (N=nf*H). Caller applies nothing else (gain already per-frame). */
static inline void qva_synth(const double *env, const double *f0, const uint8_t *voiced,
                             const double *bvoi, const double *gain, int nf, uint32_t sr,
                             int H, int NF, QvaParams pp, uint32_t seed, double *out){
    int half=NF/2; uint64_t N=(uint64_t)nf*H;
    double gscale=0.0; { double *hw=malloc(sizeof(double)*NF);
        for(int i=0;i<NF;i++){hw[i]=0.5-0.5*cos(2.0*M_PI*i/NF); gscale+=hw[i];} free(hw); }
    gscale=2.0/gscale;
    /* postfilter (unsharp-mask the log-env per frame) */
    double *E=malloc(sizeof(double)*nf*(half+1));
    memcpy(E,env,sizeof(double)*nf*(half+1));
    if (pp.pf_alpha>0){ int w=(int)(600.0/(sr/2.0)*half); if(w<3)w=3; w|=1; int hw2=w/2;
        for (int i=0;i<nf;i++){ const double *e=env+(size_t)i*(half+1); double *d=E+(size_t)i*(half+1);
            for (int k=0;k<=half;k++){ double s=0; int c=0;
                for (int t=-hw2;t<=hw2;t++){ int kk=k+t; if(kk>=0&&kk<=half){ s+=e[kk]; c++; } }
                d[k]=e[k]+pp.pf_alpha*(e[k]-s/c); } } }
    /* min-phase per frame */
    double *TH=malloc(sizeof(double)*nf*(half+1));
    for (int i=0;i<nf;i++) qva__minphase(E+(size_t)i*(half+1), NF, TH+(size_t)i*(half+1));
    double bcent[QVA_NB]; for(int b=0;b<QVA_NB;b++) bcent[b]=(QVA_BV_EDGES[b]+QVA_BV_EDGES[b+1])/2.0*(sr/2.0);
    double *nwin=malloc(sizeof(double)*2*H); for(int i=0;i<2*H;i++) nwin[i]=0.5-0.5*cos(2.0*M_PI*i/(2*H));
    double *Snr=malloc(sizeof(double)*(half+1)), *Sni=malloc(sizeof(double)*(half+1));
    /* noise buffers are NF-length: 2H windowed noise zero-padded to NF for the FFT */
    double *nn=calloc(NF,sizeof(double)), *nseg=malloc(sizeof(double)*NF), *nfull=malloc(sizeof(double)*NF);
    for (uint64_t i=0;i<N;i++) out[i]=0.0;
    uint32_t rs=seed?seed:1u; double Phi=0.0;
    for (int idx=0; idx<nf-1; idx++){
        uint64_t i0=(uint64_t)idx*H; int nsg=(int)((i0+H<=N)?H:(N-i0)); if(nsg<=0) break;
        const double *Ei=E+(size_t)idx*(half+1), *Ti=TH+(size_t)idx*(half+1);
        for (int j=0;j<2*H;j++) nn[j]=qva__gauss(&rs)*nwin[j];   /* nn[2H..NF)=0 (calloc) */
        qva__rfft(nn,NF,Snr,Sni);
        for (int k=0;k<=half;k++){ double m=exp(Ei[k]); Snr[k]*=m; Sni[k]*=m; }
        double ncal=1.0; double f0a=f0[idx], f0b=f0[idx+1];
        if (voiced[idx] && f0a>1 && f0b>1){
            int Kh=(int)(fmin(sr*0.45,pp.hfmax)/fmax(fmax(f0a,f0b),1.0)); if(Kh<1)Kh=1;
            double phi=Phi, Ph=0.0;
            for (int j=0;j<nsg;j++){
                double t=(double)j/H, f0i=f0a*(1-t)+f0b*t; phi+=2.0*M_PI*f0i/sr;
                double s=0;
                for (int k=1;k<=Kh;k++){
                    double fk=k*f0i, le,th; qva__envtap(Ei,Ti,half,sr,fk,&le,&th);
                    double V=qva__vat(bvoi+(size_t)idx*QVA_NB,bcent,fk);
                    double amp=exp(le)*gscale*pow(V<0?0:(V>1?1:V),pp.vpow);
                    s+=amp*sin((double)k*phi+th);
                }
                out[i0+j]+=s;
            }
            /* recompute Phi end + full harmonic power for noise calibration */
            { double p2=Phi; for(int j=0;j<nsg;j++){double t=(double)j/H;p2+=2.0*M_PI*(f0a*(1-t)+f0b*t)/sr;} Phi=p2; }
            for (int k=1;k<=Kh;k++){ double fk=k*(f0a+f0b)*0.5, le,th; qva__envtap(Ei,Ti,half,sr,fk,&le,&th);
                double A=exp(le)*gscale; Ph+=0.5*A*A; }
            qva__irfft(Snr,Sni,NF,nfull); double Pn=1e-20; for(int j=0;j<2*H;j++) Pn+=nfull[j]*nfull[j]; Pn/=(2*H);
            ncal=sqrt(Ph/Pn);
            for (int k=0;k<=half;k++){ double f=(double)k*sr/NF; double V=qva__vat(bvoi+(size_t)idx*QVA_NB,bcent,f);
                double tilt=1.0-pp.ntilt*(f/(sr/2.0)); if(tilt<0.25)tilt=0.25;
                double g=sqrt((1.0-V)<0?0:(1.0-V))*tilt; Snr[k]*=g; Sni[k]*=g; }
        }
        qva__irfft(Snr,Sni,NF,nseg);
        double nm=ncal*(voiced[idx]?pp.mix:1.0);
        int64_t b0=(int64_t)i0-H/2;
        for (int j=0;j<2*H;j++){ int64_t p=b0+j; if(p>=0&&p<(int64_t)N) out[p]+=nseg[j]*nm; }
    }
    /* per-frame gain (energy contour) */
    for (int i=0;i<nf;i++){ double e=0; uint64_t i0=(uint64_t)i*H; int c=0;
        for (int j=0;j<H && i0+j<N;j++){ e+=out[i0+j]*out[i0+j]; c++; }
        double cur=sqrt(e/(c?c:1)), g=(cur>1e-6)?gain[i]/cur:1.0; if(g>8)g=8;
        for (int j=0;j<H && i0+j<N;j++) out[i0+j]*=g; }
    free(E); free(TH); free(nwin); free(Snr); free(Sni); free(nn); free(nseg); free(nfull);
}
/* ---------------- deterministic (freezable) synthesis ----------------
   A time-domain synth whose every operation maps to Faust: a piecewise-constant-per-frame
   continuous-phase harmonic bank + white-LCG-through-all-pole(1/A) noise + baked per-frame
   gain. This is the NORMATIVE reference the frozen .dsp nulls against (cf. render.c for the
   music codec). The FFT-noise qva_synth stays as the higher-quality offline reference. */
typedef struct {
    int nf, H, Kmax, order; uint32_t sr; double gscale; uint32_t seed;
    double *f0c;   /* nf: per-frame fundamental (0 = unvoiced) */
    double *amp;   /* nf*Kmax harmonic amplitudes */
    double *th;    /* nf*Kmax harmonic phase offsets */
    double *na;    /* nf: white-noise input amplitude (pre-filter) */
    double *lpc;   /* nf*(order+1): all-pole synthesis coeffs (a[0]=1) */
    double *g;     /* nf: final per-frame gain multiplier */
} QvaFreeze;
static inline void qvafreeze_free(QvaFreeze *f){
    free(f->f0c); free(f->amp); free(f->th); free(f->na); free(f->lpc); free(f->g); }

static inline void qva_synth_det(const double *env, const double *f0, const uint8_t *voiced,
        const double *bvoi, const double *gain, const double *lpc, int order,
        int nf, uint32_t sr, int H, int NF, QvaParams pp, uint32_t seed, double *out, QvaFreeze *fz){
    int half=NF/2; uint64_t N=(uint64_t)nf*H;
    double gscale=0.0; for(int i=0;i<NF;i++) gscale+=0.5-0.5*cos(2.0*M_PI*i/NF); gscale=2.0/gscale;
    /* postfilter + min-phase (identical to qva_synth) */
    double *E=malloc(sizeof(double)*nf*(half+1)); memcpy(E,env,sizeof(double)*nf*(half+1));
    if (pp.pf_alpha>0){ int w=(int)(600.0/(sr/2.0)*half); if(w<3)w=3; w|=1; int hw2=w/2;
        for (int i=0;i<nf;i++){ const double *e=env+(size_t)i*(half+1); double *d=E+(size_t)i*(half+1);
            for (int k=0;k<=half;k++){ double s=0; int c=0;
                for (int t=-hw2;t<=hw2;t++){ int kk=k+t; if(kk>=0&&kk<=half){ s+=e[kk]; c++; } }
                d[k]=e[k]+pp.pf_alpha*(e[k]-s/c); } } }
    double *TH=malloc(sizeof(double)*nf*(half+1));
    for (int i=0;i<nf;i++) qva__minphase(E+(size_t)i*(half+1), NF, TH+(size_t)i*(half+1));
    double bcent[QVA_NB]; for(int b=0;b<QVA_NB;b++) bcent[b]=(QVA_BV_EDGES[b]+QVA_BV_EDGES[b+1])/2.0*(sr/2.0);

    int Kmax=1;
    for (int idx=0; idx<nf; idx++) if (voiced[idx] && f0[idx]>1){
        double f0c=f0[idx]; int Kh=(int)(fmin(sr*0.45,pp.hfmax)/fmax(f0c,1.0)); if(Kh>Kmax)Kmax=Kh; }

    fz->nf=nf; fz->H=H; fz->Kmax=Kmax; fz->order=order; fz->sr=sr; fz->gscale=gscale; fz->seed=seed;
    fz->f0c=calloc(nf,sizeof(double)); fz->amp=calloc((size_t)nf*Kmax,sizeof(double));
    fz->th=calloc((size_t)nf*Kmax,sizeof(double)); fz->na=calloc(nf,sizeof(double));
    fz->lpc=malloc((size_t)nf*(order+1)*sizeof(double)); fz->g=malloc(nf*sizeof(double));
    memcpy(fz->lpc,lpc,(size_t)nf*(order+1)*sizeof(double));

    for (uint64_t i=0;i<N;i++) out[i]=0.0;
    /* --- pass 1: harmonic bank + all-pole noise, unnormalized --- */
    uint32_t rs=0; double phi=0.0;                        /* LCG s0=0; seed folds into increment */
    double *yh=calloc(order,sizeof(double)); int yp=0;  /* noise IIR history (ring) */
    for (int idx=0; idx<nf; idx++){
        uint64_t i0=(uint64_t)idx*H; int nsg=(int)((i0+H<=N)?H:(N-i0)); if(nsg<=0) break;
        const double *Ei=E+(size_t)idx*(half+1), *Ti=TH+(size_t)idx*(half+1);
        /* bandwidth-expand the noise all-pole filter to guarantee stability (a[q]*gamma^q),
           then bake the expanded coeffs so the Faust IIR is bit-for-bit identical. */
        double *a=fz->lpc+(size_t)idx*(order+1); { const double *a0=lpc+(size_t)idx*(order+1);
            double gk=1.0; for (int q=0;q<=order;q++){ a[q]=a0[q]*gk; gk*=0.994; } }
        double harmRMS=0, Vsum=0; int Kh=0;
        if (voiced[idx] && f0[idx]>1){
            double f0c=f0[idx]; fz->f0c[idx]=f0c;
            Kh=(int)(fmin(sr*0.45,pp.hfmax)/fmax(f0c,1.0)); if(Kh<1)Kh=1;
            for (int k=1;k<=Kh;k++){ double fk=k*f0c, le,th; qva__envtap(Ei,Ti,half,sr,fk,&le,&th);
                double V=qva__vat(bvoi+(size_t)idx*QVA_NB,bcent,fk); V=V<0?0:(V>1?1:V);
                double amp=exp(le)*gscale*pow(V,pp.vpow);
                fz->amp[(size_t)idx*Kmax+(k-1)]=amp; fz->th[(size_t)idx*Kmax+(k-1)]=th;
                harmRMS+=0.5*amp*amp; Vsum+=V; }
            harmRMS=sqrt(harmRMS);
            for (int j=0;j<nsg;j++){ phi+=2.0*M_PI*f0c/sr; double s=0;
                for (int k=1;k<=Kh;k++) s+=fz->amp[(size_t)idx*Kmax+(k-1)]*sin((double)k*phi+fz->th[(size_t)idx*Kmax+(k-1)]);
                out[i0+j]+=s; }
        }
        /* all-pole filter gain (impulse-response energy) so baked na hits the target RMS */
        double gpow=0; { double hh[256]={0};
            for (int n=0;n<256;n++){ double x=(n==0)?1.0:0.0, y=x;
                for (int q=1;q<=order && q<=n;q++) y-=a[q]*hh[n-q]; hh[n]=y; gpow+=y*y; } }
        double gfilt=sqrt(gpow>1e-20?gpow:1e-20);
#ifdef QVA_DBG
        if (gpow>1e8||!(gpow==gpow)) fprintf(stderr,"[det] unstable frame %d gpow=%g a1=%g a2=%g\n",idx,gpow,a[1],a[2]);
#endif
        double Vmean = Kh?Vsum/Kh:0.0;
        double target = voiced[idx] ? pp.mix*(1.0-Vmean)*harmRMS : 1.0;
        double na = target/gfilt*1.7320508075688772; fz->na[idx]=na;  /* *sqrt(3): uniform var 1/3 */
        for (int j=0;j<nsg;j++){
            rs=(uint32_t)(((uint64_t)rs*QSC_LCG_A + QSC_LCG_C + seed) & QSC_LCG_M);   /* spec §12.3 LCG */
            double e=((double)rs/1073741824.0 - 1.0)*na, y=e;
            for (int q=1;q<=order;q++){ int hp=(yp-q+1+order)%order; y-=a[q]*yh[hp]; }
            yp=(yp+1)%order; yh[yp]=y; out[i0+j]+=y; }
    }
    /* --- pass 2: per-frame gain normalization, baked into fz->g --- */
    for (int idx=0; idx<nf; idx++){ double e=0; uint64_t i0=(uint64_t)idx*H; int c=0;
        for (int j=0;j<H && i0+j<N;j++){ e+=out[i0+j]*out[i0+j]; c++; }
        double cur=sqrt(e/(c?c:1)), g=(cur>1e-6)?gain[idx]/cur:1.0; if(g>8)g=8;
        fz->g[idx]=g; for (int j=0;j<H && i0+j<N;j++) out[i0+j]*=g; }
    free(E); free(TH); free(yh);
}
#endif /* DEMOD_QVA_H */
