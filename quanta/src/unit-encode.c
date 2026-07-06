/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-DeMoD-Commercial
 * quanta-unit-encode — WAV + baked inventory (.qinv) -> quantized unit stream (.qspu).
 * Analyse, segment, match each unit's LSF trajectory to the nearest inventory codeword,
 * extract + quantize prosody (duration, pitch contour, energy contour, voicing contour).
 * Ports tools/qunits.py encode; reports measured bitrate.  Copyright (c) 2026 DeMoD LLC.
 */
#include "../include/qunit.h"
#include "../include/qvq.h"
#include "../include/qspu.h"

static double g_wtab[QSC_TAB], g_stab[QSC_TAB];   /* mp.h fft globals */

static int qz(double v,double lo,double hi,int bits){ int n=(1<<bits)-1;
    if(v<lo)v=lo; if(v>hi)v=hi; int q=(int)lround((v-lo)/(hi-lo)*n); return q<0?0:(q>n?n:q); }

int main(int argc, char **argv){
    const char *inv_p=NULL,*wav_p=NULL,*out=NULL;
    for (int i=1;i<argc;i++){
        if (!strcmp(argv[i],"-o")&&i+1<argc) out=argv[++i];
        else if (!inv_p) inv_p=argv[i]; else if (!wav_p) wav_p=argv[i];
    }
    if (!inv_p||!wav_p||!out){ fprintf(stderr,"usage: quanta-unit-encode inv.qinv in.wav -o out.qspu\n"); return 2; }

    QInv inv; if (qinv_read(inv_p,&inv)){ fprintf(stderr,"qinv read failed\n"); return 1; }
    int order=inv.order, nsub=inv.nsub, dim=nsub*order, K=inv.K;
    double *cbd=malloc((size_t)K*dim*sizeof(double));
    for (int i=0;i<K*dim;i++) cbd[i]=inv.cb[i];

    uint32_t sr; uint64_t N; double *x=wav_read_mono(wav_p,&sr,&N);
    if (!x){ fprintf(stderr,"read fail: %s\n",wav_p); return 1; }
    QAnl A; qunit_analyze(x,N,sr,order,&A); free(x);

    int *bounds=malloc((A.nf+2)*sizeof(int)); int nb=qunit_segment(&A,45,140,70,bounds);
    int nu=nb-1;
    double L70=log2(70.0), L400=log2(400.0);
    double *Lr=malloc(dim*sizeof(double)); uint8_t *Vr=malloc(nsub);
    double *envseg=malloc(A.nf*sizeof(double)), *econ=malloc(nsub*sizeof(double));
    double *vf=malloc(A.nf*sizeof(double)), *vcf=malloc(A.nf*sizeof(double)), *vout=malloc(nsub*sizeof(double));

    QStr st; st.sr=sr; st.source_len=N; st.nu=nu; st.nsub=nsub;
    st.u=calloc(nu?nu:1,sizeof(QUnit));

    for (int s=0;s<nu;s++){ int a=bounds[s], e=bounds[s+1]; QUnit *u=&st.u[s];
        qunit_traj(&A,a,e,nsub,Lr,Vr);
        u->id=(uint32_t)qvq_nearest(Lr,cbd,K,dim);
        double dur=(double)(e-a)*A.H/sr*1000.0;
        u->dur=(uint8_t)qz(dur,20,160,QSPU_DURB);
        /* pitch contour: first/last voiced f0 in the segment (fallback 120) */
        int nv=0; for (int t=a;t<e;t++) if (A.voiced[t]) vf[nv++]=A.f0[t];
        double p0=nv?vf[0]:120.0, p1=nv?vf[nv-1]:120.0;
        u->p0=(uint8_t)qz(log2(p0<70?70:(p0>400?400:p0)),L70,L400,QSPU_PITB);
        u->p1=(uint8_t)qz(log2(p1<70?70:(p1>400?400:p1)),L70,L400,QSPU_PITB);
        /* energy contour */
        int len=e-a; for (int t=0;t<len;t++) envseg[t]=A.en[a+t];
        qunit__rs(envseg,len,nsub,econ);
        u->econ=malloc(nsub); for (int j=0;j<nsub;j++) u->econ[j]=(uint8_t)qz(log10(econ[j]+1e-9),-4,0,QSPU_ENGB);
        /* voicing contour */
        for (int t=0;t<len;t++) vcf[t]=A.voiced[a+t]?1.0:0.0;
        qunit__rs(vcf,len,nsub,vout);
        u->vcon=malloc(nsub); for (int j=0;j<nsub;j++) u->vcon[j]=(vout[j]>0.5)?1:0;
    }
    int idb=qspu_idbits(K);
    if (qspu_write(out,&st,idb)){ fprintf(stderr,"qspu write failed\n"); return 1; }
    /* measured bitrate */
    double secs=(double)N/sr; long bits=(long)nu*(idb+QSPU_DURB+2*QSPU_PITB+nsub*QSPU_ENGB+nsub);
    fprintf(stderr,"encode: %d units, %d frames, %.2fs -> %s\n",nu,A.nf,secs,out);
    fprintf(stderr,"  idbits=%d  payload=%ld bits = %.0f bps  (%.1f units/s)\n",idb,bits,bits/secs,nu/secs);

    qspu_free(&st); qinv_free(&inv); qanl_free(&A);
    free(cbd); free(bounds); free(Lr); free(Vr); free(envseg); free(econ); free(vf); free(vcf); free(vout);
    return 0;
}
