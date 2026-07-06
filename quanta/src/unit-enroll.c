/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-DeMoD-Commercial
 * quanta-unit-enroll — WAV(s) -> baked acoustic-unit inventory (.qinv). Analyse each clip,
 * segment into units, resample each to an LSF-trajectory codeword, then either k-means to K
 * codewords (--K, compact) or keep the actual segments (--select, crisper). Voicing subpattern
 * is the per-cluster majority. Ports tools/qunits.py build_inventory.  Copyright (c) 2026 DeMoD LLC.
 */
#include "../include/qunit.h"
#include "../include/qvq.h"
#include "../include/qspu.h"

static double g_wtab[QSC_TAB], g_stab[QSC_TAB];   /* mp.h fft globals */

int main(int argc, char **argv){
    const char *out=NULL; const char *clips[256]; int nclip=0;
    int K=192, order=QUNIT_ORDER, nsub=QUNIT_NSUB, select=0; uint32_t seed=0xC0DE;
    for (int i=1;i<argc;i++){
        if (!strcmp(argv[i],"-o")&&i+1<argc) out=argv[++i];
        else if (!strcmp(argv[i],"--K")&&i+1<argc) K=atoi(argv[++i]);
        else if (!strcmp(argv[i],"--order")&&i+1<argc) order=atoi(argv[++i]);
        else if (!strcmp(argv[i],"--nsub")&&i+1<argc) nsub=atoi(argv[++i]);
        else if (!strcmp(argv[i],"--select")) select=1;
        else if (!strcmp(argv[i],"--seed")&&i+1<argc) seed=(uint32_t)strtoul(argv[++i],NULL,0);
        else if (argv[i][0]!='-' && nclip<256) clips[nclip++]=argv[i];
    }
    if (!out||!nclip){ fprintf(stderr,"usage: quanta-unit-enroll -o inv.qinv clip1.wav [clip2.wav ...] [--K 192] [--order 16] [--nsub 5] [--select]\n"); return 2; }

    int dim=nsub*order, cap=4096, nvec=0;
    double *vecs=malloc((size_t)cap*dim*sizeof(double));
    uint8_t *vpat=malloc((size_t)cap*nsub);
    uint32_t sr0=0;
    int *bounds=NULL; int bcap=0;
    double *Lr=malloc(dim*sizeof(double)); uint8_t *Vr=malloc(nsub);

    for (int c=0;c<nclip;c++){
        uint32_t sr; uint64_t N; double *x=wav_read_mono(clips[c],&sr,&N);
        if (!x){ fprintf(stderr,"read fail: %s\n",clips[c]); return 1; }
        if (!sr0) sr0=sr;
        QAnl A; qunit_analyze(x,N,sr,order,&A); free(x);
        if (A.nf+2>bcap){ bcap=A.nf+2; bounds=realloc(bounds,bcap*sizeof(int)); }
        int nb=qunit_segment(&A,45,140,70,bounds);
        for (int s=0;s<nb-1;s++){
            if (nvec>=cap){ cap*=2; vecs=realloc(vecs,(size_t)cap*dim*sizeof(double)); vpat=realloc(vpat,(size_t)cap*nsub); }
            qunit_traj(&A,bounds[s],bounds[s+1],nsub,Lr,Vr);
            memcpy(vecs+(size_t)nvec*dim,Lr,dim*sizeof(double));
            memcpy(vpat+(size_t)nvec*nsub,Vr,nsub); nvec++;
        }
        qanl_free(&A);
    }
    fprintf(stderr,"enroll: %d clips -> %d unit segments\n",nclip,nvec);
    if (nvec<1){ fprintf(stderr,"no segments\n"); return 1; }

    QInv inv; inv.sr=sr0; inv.order=order; inv.nsub=nsub;
    if (select || K>=nvec){
        inv.K=nvec; inv.cb=malloc((size_t)nvec*dim*sizeof(float)); inv.vpat=malloc((size_t)nvec*nsub);
        for (int i=0;i<nvec*dim;i++) inv.cb[i]=(float)vecs[i];
        memcpy(inv.vpat,vpat,(size_t)nvec*nsub);
        fprintf(stderr,"  inventory = %d actual segments (unit-selection)\n",nvec);
    } else {
        double *cb=malloc((size_t)K*dim*sizeof(double));
        qvq_kmeans(vecs,nvec,dim,K,25,seed,cb);
        inv.K=K; inv.cb=malloc((size_t)K*dim*sizeof(float)); inv.vpat=calloc((size_t)K*nsub,1);
        for (int i=0;i<K*dim;i++) inv.cb[i]=(float)cb[i];
        /* per-cluster voicing majority */
        int *cnt=calloc(K,sizeof(int)); int *vsum=calloc((size_t)K*nsub,sizeof(int));
        for (int i=0;i<nvec;i++){ int k=qvq_nearest(vecs+(size_t)i*dim,cb,K,dim); cnt[k]++;
            for (int j=0;j<nsub;j++) vsum[(size_t)k*nsub+j]+=vpat[(size_t)i*nsub+j]; }
        for (int k=0;k<K;k++) for (int j=0;j<nsub;j++)
            inv.vpat[(size_t)k*nsub+j]= cnt[k] ? (vsum[(size_t)k*nsub+j]*2>cnt[k]) : 1;
        free(cb); free(cnt); free(vsum);
        fprintf(stderr,"  inventory = %d k-means codewords\n",K);
    }
    if (qinv_write(out,&inv)){ fprintf(stderr,"qinv write failed\n"); return 1; }
    fprintf(stderr,"wrote %s  (K=%d order=%d nsub=%d sr=%u)\n",out,inv.K,order,nsub,sr0);
    qinv_free(&inv);
    free(vecs); free(vpat); free(Lr); free(Vr); free(bounds);
    return 0;
}
