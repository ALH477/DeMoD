/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-DeMoD-Commercial
 * qvq.h — k-means (LBG) vector quantization in C. Used to cluster acoustic-unit
 * LSF-trajectories into an inventory codebook (mirrors qcodec.train_msvq single stage).
 * Deterministic: seeded LCG init so the same corpus yields the same codebook.
 * Copyright (c) 2026 DeMoD LLC.
 */
#ifndef DEMOD_QVQ_H
#define DEMOD_QVQ_H
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static inline uint32_t qvq__lcg(uint32_t *s){ *s = (*s)*1103515245u + 12345u; return *s; }

/* k-means. vecs: n×dim row-major. cb (K×dim) filled by caller-allocated buffer. */
static inline void qvq_kmeans(const double *vecs, int n, int dim, int K,
                              int iters, uint32_t seed, double *cb){
    if (n<=0||K<=0) return;
    uint32_t s = seed ? seed : 1u;
    for (int k=0;k<K;k++){ int idx=(int)(qvq__lcg(&s)>>8)%n; memcpy(cb+(size_t)k*dim, vecs+(size_t)idx*dim, dim*sizeof(double)); }
    int *asg=malloc((size_t)n*sizeof(int));
    double *sum=malloc((size_t)K*dim*sizeof(double)); int *cnt=malloc((size_t)K*sizeof(int));
    for (int it=0; it<iters; it++){
        for (int i=0;i<n;i++){ double best=1e300; int bk=0; const double *v=vecs+(size_t)i*dim;
            for (int k=0;k<K;k++){ const double *c=cb+(size_t)k*dim; double d=0;
                for (int j=0;j<dim;j++){ double e=v[j]-c[j]; d+=e*e; if (d>=best) break; }
                if (d<best){ best=d; bk=k; } }
            asg[i]=bk; }
        memset(sum,0,(size_t)K*dim*sizeof(double)); memset(cnt,0,(size_t)K*sizeof(int));
        for (int i=0;i<n;i++){ int k=asg[i]; cnt[k]++; const double *v=vecs+(size_t)i*dim; double *su=sum+(size_t)k*dim;
            for (int j=0;j<dim;j++) su[j]+=v[j]; }
        for (int k=0;k<K;k++){
            if (cnt[k]){ for (int j=0;j<dim;j++) cb[(size_t)k*dim+j]=sum[(size_t)k*dim+j]/cnt[k]; }
            else { int idx=(int)(qvq__lcg(&s)>>8)%n; memcpy(cb+(size_t)k*dim, vecs+(size_t)idx*dim, dim*sizeof(double)); } }
    }
    free(asg); free(sum); free(cnt);
}

static inline int qvq_nearest(const double *v, const double *cb, int K, int dim){
    double best=1e300; int bk=0;
    for (int k=0;k<K;k++){ const double *c=cb+(size_t)k*dim; double d=0;
        for (int j=0;j<dim;j++){ double e=v[j]-c[j]; d+=e*e; }
        if (d<best){ best=d; bk=k; } }
    return bk;
}
#endif /* DEMOD_QVQ_H */
