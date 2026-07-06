/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-DeMoD-Commercial
 * qunit.h — shared unit-vocoder analysis: WAV -> per-frame LSF trajectory + f0 +
 * voicing + band-voicing + energy contour, LSF-change segmentation, and fixed-length
 * sub-frame resampling. Ports tools/qunits.py {analyze_lsf, segment, unit_traj, _rs}
 * so quanta-unit-enroll and quanta-unit-encode share one analysis front-end.
 * Copyright (c) 2026 DeMoD LLC.
 */
#ifndef DEMOD_QUNIT_H
#define DEMOD_QUNIT_H
#include "qva.h"
#include "qlsf.h"

#define QUNIT_ORDER 16
#define QUNIT_NSUB  5

typedef struct {
    int nf, H, NF, order; uint32_t sr; uint64_t N;
    double *lsf;      /* nf*order */
    double *f0;       /* nf */
    uint8_t *voiced;  /* nf */
    double *bvoi;     /* nf*QVA_NB */
    double *en;       /* nf frame RMS */
} QAnl;

static inline void qanl_free(QAnl *A){ free(A->lsf); free(A->f0); free(A->voiced); free(A->bvoi); free(A->en); }

/* analysis + per-frame LSF + energy contour (port of qunits.analyze_lsf) */
static inline void qunit_analyze(const double *x, uint64_t N, uint32_t sr, int order, QAnl *A){
    double *env,*f0,*bvoi; uint8_t *voiced; int nf,H,NF;
    qva_analyze(x,N,sr,&env,&f0,&voiced,&bvoi,&nf,&H,&NF);
    int half=NF/2;
    double *lsf=malloc((size_t)nf*order*sizeof(double)), a[68];
    for (int i=0;i<nf;i++){ qlsf_env_to_lpc(env+(size_t)i*(half+1),NF,order,a);
        qlsf_lpc_to_lsf(a,order,lsf+(size_t)i*order); }
    free(env);
    double *en=malloc(nf*sizeof(double));
    for (int i=0;i<nf;i++){ uint64_t s=(uint64_t)i*H; double e=0;
        for (int j=0;j<H;j++){ double v=(s+j<N)?x[s+j]:0.0; e+=v*v; } en[i]=sqrt(e/H); }
    A->nf=nf;A->H=H;A->NF=NF;A->order=order;A->sr=sr;A->N=N;
    A->lsf=lsf;A->f0=f0;A->voiced=voiced;A->bvoi=bvoi;A->en=en;
}

/* numpy-'linear' percentile of an ascending-sorted array */
static inline double qunit__perc(const double *sorted, int n, double p){
    if (n<=0) return 0.0; if (n==1) return sorted[0];
    double idx=(n-1)*p/100.0; int lo=(int)floor(idx); if(lo<0)lo=0; if(lo>=n-1) return sorted[n-1];
    double f=idx-lo; return sorted[lo]*(1-f)+sorted[lo+1]*f;
}
static inline int qunit__dcmp(const void*a,const void*b){ double d=*(const double*)a-*(const double*)b; return d<0?-1:(d>0?1:0); }

/* segment into units at LSF-change peaks + voiced/unvoiced transitions, bounded [min_ms,max_ms].
   Fills bounds[] (caller sized >= nf+2), returns #bounds; #segments = ret-1. (port of qunits.segment) */
static inline int qunit_segment(const QAnl *A, int min_ms, int max_ms, int thr_pctl, int *bounds){
    int nf=A->nf, order=A->order, H=A->H; uint32_t sr=A->sr;
    if (nf<=1){ bounds[0]=0; bounds[1]=nf; return 2; }
    double *d=malloc(nf*sizeof(double)); d[0]=0.0;
    for (int t=1;t<nf;t++){ double s=0; const double *L=A->lsf+(size_t)t*order, *P=A->lsf+(size_t)(t-1)*order;
        for (int c=0;c<order;c++){ double e=L[c]-P[c]; s+=e*e; } d[t]=sqrt(s); }
    double *srt=malloc(nf*sizeof(double)); memcpy(srt,d,nf*sizeof(double));
    qsort(srt,nf,sizeof(double),qunit__dcmp); double thr=qunit__perc(srt,nf,thr_pctl);
    int minf=(int)(min_ms/1000.0*sr/H); if(minf<2)minf=2;
    int maxf=(int)(max_ms/1000.0*sr/H); if(maxf<minf+1)maxf=minf+1;
    int nb=0; bounds[nb++]=0; int last=0;
    for (int t=1;t<nf;t++){ int gap=t-last;
        int vtrans = A->voiced[t]!=A->voiced[t-1];
        int peak = d[t]>=thr && d[t]>=d[t-1] && (t+1>=nf || d[t]>=d[t+1]);
        if ((vtrans&&gap>=minf/2)||(peak&&gap>=minf)||gap>=maxf){ bounds[nb++]=t; last=t; } }
    if (bounds[nb-1]!=nf) bounds[nb++]=nf;
    free(d); free(srt); return nb;
}

/* resample a segment's LSF trajectory + voicing to nsub sub-frames (port of qunits.unit_traj) */
static inline void qunit_traj(const QAnl *A, int s, int e, int nsub, double *Lr, uint8_t *Vr){
    int order=A->order, len=e-s; if (len<1) len=1;
    for (int k=0;k<nsub;k++){
        double t=(nsub>1)?(double)k*(len-1)/(nsub-1):0.0; int ii=(int)lround(t);
        if (ii<0)ii=0; if (ii>=len)ii=len-1; int fi=s+ii; if (fi>=A->nf)fi=A->nf-1;
        for (int c=0;c<order;c++) Lr[k*order+c]=A->lsf[(size_t)fi*order+c];
        Vr[k]=A->voiced[fi];
    }
}

/* resample 1-D array of length len to n points, linear interp (port of qunits._rs) */
static inline void qunit__rs(const double *a, int len, int n, double *out){
    if (len<=0){ for(int i=0;i<n;i++) out[i]=0.0; return; }
    if (len==1){ for(int i=0;i<n;i++) out[i]=a[0]; return; }
    for (int i=0;i<n;i++){ double pos=(double)i*(len-1)/(n-1); int lo=(int)floor(pos);
        if(lo>=len-1){ out[i]=a[len-1]; continue; } double f=pos-lo; out[i]=a[lo]*(1-f)+a[lo+1]*f; }
}
#endif /* DEMOD_QUNIT_H */
