/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-DeMoD-Commercial
 * qlsf.h — LPC <-> LSF (line spectral frequencies) in C, for the unit vocoder's
 * envelope coding. Mirrors tools/lsf.py. LPC->LSF uses the Chebyshev / grid-search
 * method (evaluate the symmetric P(w)/antisymmetric Q(w) on a dense frequency grid,
 * take the interleaved zero-crossings) — robust and codec-standard, no polynomial
 * root-finding. Offline (libm allowed; the render hot path uses precomputed env).
 * Copyright (c) 2026 DeMoD LLC.
 */
#ifndef DEMOD_QLSF_H
#define DEMOD_QLSF_H
#include "qsc.h"
#include "mp.h"          /* fft() for env->autocorrelation */

/* autocorrelation r[0..order] -> LPC a[0..order] (a[0]=1), returns residual energy */
static inline double qlsf_levinson(const double *r, int order, double *a){
    a[0]=1.0; for(int i=1;i<=order;i++) a[i]=0.0;
    double e = r[0] > 0 ? r[0] : 1e-9;
    for (int i=1;i<=order;i++){
        double acc=r[i]; for (int j=1;j<i;j++) acc+=a[j]*r[i-j];
        double k = e>1e-12 ? -acc/e : 0.0;
        if (k<-0.999) k=-0.999; if (k>0.999) k=0.999;   /* stability clamp */
        double tmp[64]; for (int j=0;j<=order;j++) tmp[j]=a[j];
        for (int j=1;j<i;j++) a[j]=tmp[j]+k*tmp[i-j];
        a[i]=k; e*=(1.0-k*k); if (e<=0) e=1e-9;
    }
    return e;
}

/* log-magnitude envelope (NF/2+1) -> LPC (a[0..order], returns gain). Power spectrum
   -> autocorrelation via inverse FFT (reuse mp.h fft with conjugated sign). */
static inline double qlsf_env_to_lpc(const double *env_log, int NF, int order, double *a){
    double *re=malloc(sizeof(double)*NF), *im=malloc(sizeof(double)*NF);
    int half=NF/2;
    for (int k=0;k<=half;k++){ double p=exp(2.0*env_log[k]); re[k]=p; im[k]=0.0; }
    for (int k=1;k<half;k++){ re[NF-k]=re[k]; im[NF-k]=0.0; }   /* symmetric power spectrum */
    /* inverse DFT: conjugate, forward fft, /N -> real autocorrelation */
    for (int k=0;k<NF;k++) im[k]=-im[k];
    fft(re, im, NF);
    double r[64]; for (int i=0;i<=order;i++) r[i]=re[i]/NF;
    r[0]*=1.0001;                                              /* white floor (conditioning) */
    double e=qlsf_levinson(r, order, a);
    free(re); free(im);
    return sqrt(e>1e-12?e:1e-12)/NF;
}

/* LPC (a,gain) -> log-magnitude envelope (NF/2+1). log|H| = log g - log|A(e^jw)| */
static inline void qlsf_lpc_to_env(const double *a, int order, double gain, int NF, double *env_log){
    int half=NF/2;
    for (int k=0;k<=half;k++){
        double w=M_PI*k/half, ar=0, ai=0;
        for (int j=0;j<=order;j++){ ar+=a[j]*cos(-w*j); ai+=a[j]*sin(-w*j); }
        env_log[k]=log(gain+1e-30)-log(sqrt(ar*ar+ai*ai)+1e-12);
    }
}

/* evaluate the (real) value of the symmetric sum polynomial at angle w:
   Ps(w)=Re{ (A(z)+z^-(p+1)A(1/z)) } factored to real cosine sum. We instead evaluate
   P(e^jw) and Q(e^jw) directly (complex) and take their real projections. */
static inline void qlsf__pq(const double *a, int p, double w, double *Pr, double *Qr){
    /* P = A(z)+z^-(p+1)A(1/z), Q = A(z)-z^-(p+1)A(1/z), z=e^{jw}. Both have real value
       after multiplying by e^{j(p+1)w/2}: standard reduction to cosine series. Simpler:
       evaluate the length-(p+2) coefficient arrays directly. */
    double Pc[66], Qc[66];
    for (int i=0;i<=p+1;i++){
        double ai = (i<=p)?a[i]:0.0, ar = (i>=1)?a[p+1-i]:0.0;  /* z^-(p+1)A(1/z) coeff */
        Pc[i]=ai+ar; Qc[i]=ai-ar;
    }
    double pr=0,pi=0,qr=0,qi=0;
    for (int i=0;i<=p+1;i++){ double c=cos(-w*i), s=sin(-w*i); pr+=Pc[i]*c; pi+=Pc[i]*s; qr+=Qc[i]*c; qi+=Qc[i]*s; }
    /* rotate by e^{j(p+1)w/2}. P is palindromic -> rotated value is REAL (take Re);
       Q is anti-palindromic -> rotated value is pure IMAGINARY (take Im). */
    double rc=cos((p+1)*w/2.0), rs=sin((p+1)*w/2.0);
    *Pr = pr*rc - pi*rs;               /* Re{ P e^{j(p+1)w/2} } */
    *Qr = qr*rs + qi*rc;               /* Im{ Q e^{j(p+1)w/2} } */
}

/* LPC a[0..p] -> p LSFs (ascending, radians in (0,pi)). Grid zero-crossing search. */
static inline int qlsf_lpc_to_lsf(const double *a, int p, double *lsf){
    int G=512, nf=0; double wprev=0, Pp=0, Qp=0; qlsf__pq(a,p,0.0,&Pp,&Qp);
    /* P and Q zero-crossings interleave; collect all in (0,pi) */
    for (int g=1; g<=G && nf<p; g++){
        double w=M_PI*g/G, Pv,Qv; qlsf__pq(a,p,w,&Pv,&Qv);
        if (Pp*Pv<0){ double t=Pp/(Pp-Pv); lsf[nf++]=wprev+(w-wprev)*t; }
        if (nf<p && Qp*Qv<0){ double t=Qp/(Qp-Qv); lsf[nf++]=wprev+(w-wprev)*t; }
        wprev=w; Pp=Pv; Qp=Qv;
    }
    for (int i=0;i<p;i++) if (nf<=i) lsf[i]=M_PI*(i+1)/(p+1);   /* pad if under-found */
    /* insertion sort (p is small) */
    for (int i=1;i<p;i++){ double v=lsf[i]; int j=i-1; while(j>=0&&lsf[j]>v){lsf[j+1]=lsf[j];j--;} lsf[j+1]=v; }
    return p;
}

/* p LSFs -> LPC a[0..p] (a[0]=1). Rebuild P,Q from unit-circle roots; A=(P+Q)/2. */
static inline void qlsf_lsf_to_lpc(const double *lsf, int p, double *a){
    /* P(z)=(z+1) prod(z^2-2cos(w_even)z+1); Q(z)=(z-1) prod(z^2-2cos(w_odd)z+1) */
    double P[68]={0}, Q[68]={0}; P[0]=1; Q[0]=1; int pl=0, ql=0;
    /* start P with (1 - z^-1)?  Use polynomial convolution building deg up. */
    double Pp[68]={1.0}, Qp[68]={1.0}; int dp=0, dq=0;
    for (int i=0;i<p;i++){
        double c=-2.0*cos(lsf[i]); double f[3]={1.0,c,1.0};
        double *dst = (i%2==0)?Pp:Qp; int *dd=(i%2==0)?&dp:&dq;
        double out[68]={0}; for(int j=0;j<=*dd;j++) for(int k=0;k<3;k++) out[j+k]+=dst[j]*f[k];
        for(int j=0;j<=*dd+2;j++) dst[j]=out[j]; *dd+=2;
    }
    /* multiply P-part by (z+1) i.e. {1,1}; Q-part by (z-1) i.e. {1,-1} */
    for (int j=0;j<=dp+1;j++) P[j]=(j<=dp?Pp[j]:0)+(j>=1?Pp[j-1]:0);
    for (int j=0;j<=dq+1;j++) Q[j]=(j<=dq?Qp[j]:0)-(j>=1?Qp[j-1]:0);
    for (int j=0;j<=p;j++) a[j]=0.5*(P[j]+Q[j]);
    a[0]=1.0;
}
#endif /* DEMOD_QLSF_H */
