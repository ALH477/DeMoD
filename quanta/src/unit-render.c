/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-DeMoD-Commercial
 * quanta-unit-render — .qinv + .qspu -> PCM. Reconstructs per-frame envelope (LSF
 * trajectory time-scaled per unit + join-smoothed), pitch/energy/voicing contours,
 * and renders via the C mixed-excitation min-phase synth (qva.h). Mirrors the Python
 * prototype tools/qunits.py `decode`.  Copyright (c) 2026 DeMoD LLC.
 */
#include "../include/qva.h"
#include "../include/qlsf.h"
#include "../include/qspu.h"

static double g_wtab[QSC_TAB], g_stab[QSC_TAB];   /* mp.h fft globals */

static void params(uint32_t sr, int *H, int *NF){
    int h=(int)lround(0.010*sr); if(h<8)h=8; *H=h;
    int nf=1; while (nf < (int)(0.021*sr)) nf<<=1; *NF=nf;
}
static double dq(int i,double lo,double hi,int bits){ int n=(1<<bits)-1; return lo+(double)i/n*(hi-lo); }

int main(int argc, char **argv){
    const char *inv_p=NULL,*str_p=NULL,*wavout=NULL,*rawout=NULL; int wbits=16, det=0;
    for (int i=1;i<argc;i++){
        if (!strcmp(argv[i],"--wav")&&i+1<argc) wavout=argv[++i];
        else if (!strcmp(argv[i],"--raw")&&i+1<argc) rawout=argv[++i];
        else if (!strcmp(argv[i],"--det")) det=1;
        else if (!strcmp(argv[i],"--bits")&&i+1<argc){ const char*b=argv[++i]; wbits=!strcmp(b,"24")?24:(!strcmp(b,"32")||!strcmp(b,"32f"))?32:16; }
        else if (!inv_p) inv_p=argv[i]; else str_p=argv[i];
    }
    if (!inv_p||!str_p){ fprintf(stderr,"usage: quanta-unit-render inv.qinv stream.qspu [--wav o.wav] [--bits 16|24|32f]\n"); return 2; }
    QInv inv; if (qinv_read(inv_p,&inv)){ fprintf(stderr,"qinv read failed\n"); return 1; }
    QStr st; int idb; if (qspu_read(str_p,&st,&idb)){ fprintf(stderr,"qspu read failed\n"); return 1; }
    uint32_t sr=st.sr; int H,NF; params(sr,&H,&NF); int half=NF/2, order=inv.order, ns=inv.nsub;
    double L70=log2(70.0), L400=log2(400.0);

    int nf=0;
    for (uint32_t u=0;u<st.nu;u++){ int fr=(int)lround(dq(st.u[u].dur,20,160,QSPU_DURB)/1000.0*sr/H); if(fr<1)fr=1; nf+=fr; }
    double *lsff=malloc((size_t)nf*order*sizeof(double)), *f0=malloc(nf*sizeof(double));
    double *gain=malloc(nf*sizeof(double)), *bvoi=malloc((size_t)nf*QVA_NB*sizeof(double));
    uint8_t *voiced=malloc(nf);
    double bvdef[QVA_NB]; for(int b=0;b<QVA_NB;b++) bvdef[b]=0.75+(0.2-0.75)*b/(double)(QVA_NB-1);

    int fi=0;
    for (uint32_t u=0;u<st.nu;u++){ QUnit *un=&st.u[u];
        int fr=(int)lround(dq(un->dur,20,160,QSPU_DURB)/1000.0*sr/H); if(fr<1)fr=1;
        double p0=pow(2.0,dq(un->p0,L70,L400,QSPU_PITB)), p1=pow(2.0,dq(un->p1,L70,L400,QSPU_PITB));
        const float *cw=inv.cb+(size_t)un->id*ns*order;
        double econ[64]; for (int j=0;j<ns;j++) econ[j]=pow(10.0,dq(un->econ[j],-4,0,QSPU_ENGB));
        for (int j=0;j<fr;j++,fi++){
            double t=(fr>1)?(double)j/(fr-1):0.0, si=t*(ns-1); int s0=(int)si; double f=si-s0; int s1=(s0+1<ns)?s0+1:s0;
            for (int c=0;c<order;c++) lsff[(size_t)fi*order+c]=cw[s0*order+c]*(1-f)+cw[s1*order+c]*f;
            int sc=(int)lround(t*(ns-1)); int uv=un->vcon[sc];
            f0[fi]=uv?(p0*(1-t)+p1*t):0.0; voiced[fi]=(uint8_t)uv;
            gain[fi]=econ[s0]*(1-f)+econ[s1]*f;
            for (int b=0;b<QVA_NB;b++) bvoi[(size_t)fi*QVA_NB+b]=uv?bvdef[b]:0.0;
        }
    }
    /* smooth the LSF trajectory over time (kills unit-join clicks), then re-sort */
    int sm=3; if (sm>1 && nf>sm){
        double *tmp=malloc((size_t)nf*order*sizeof(double)); int hw=sm/2;
        for (int c=0;c<order;c++) for (int i=0;i<nf;i++){ double s=0; int n=0;
            for (int t=-hw;t<=hw;t++){ int ii=i+t; if(ii>=0&&ii<nf){ s+=lsff[(size_t)ii*order+c]; n++; } }
            tmp[(size_t)i*order+c]=s/n; }
        memcpy(lsff,tmp,(size_t)nf*order*sizeof(double)); free(tmp);
        for (int i=0;i<nf;i++){ double *L=lsff+(size_t)i*order;
            for (int x=1;x<order;x++){ double v=L[x]; int y=x-1; while(y>=0&&L[y]>v){L[y+1]=L[y];y--;} L[y+1]=v; } }
    }
    /* LSF -> LPC -> log-envelope per frame (keep LPC for the deterministic noise filter) */
    double *env=malloc((size_t)nf*(half+1)*sizeof(double));
    double *lpc=malloc((size_t)nf*(order+1)*sizeof(double));
    for (int i=0;i<nf;i++){ double *a=lpc+(size_t)i*(order+1);
        qlsf_lsf_to_lpc(lsff+(size_t)i*order,order,a); qlsf_lpc_to_env(a,order,1.0,NF,env+(size_t)i*(half+1)); }

    double *out=malloc((size_t)nf*H*sizeof(double));
    if (det){ QvaFreeze fz; qva_synth_det(env,f0,voiced,bvoi,gain,lpc,order,nf,sr,H,NF,qva_defaults(),12345,out,&fz); qvafreeze_free(&fz); }
    else qva_synth(env,f0,voiced,bvoi,gain,nf,sr,H,NF,qva_defaults(),12345,out);
    uint64_t N=(uint64_t)nf*H;
    if (wavout) (wbits==24?wav_write24:wbits==32?wav_write_f32:wav_write16)(wavout,out,N,sr);
    if (rawout) raw_write_f64(rawout,out,N);
    fprintf(stderr,"unit-render: %u units -> %d frames -> %llu samples @ %u Hz\n",st.nu,nf,(unsigned long long)N,sr);
    qinv_free(&inv); qspu_free(&st);
    return 0;
}
