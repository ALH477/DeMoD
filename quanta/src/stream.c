/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-DeMoD-Commercial
 * quanta-stream — streaming-profile encoder (spec §14).
 * Copyright (c) 2026 DeMoD LLC.
 *
 * Block-causal matching pursuit with a commit horizon. The signal is swept by
 * a write head in hops; a commit point trails the head by L = cap + active.
 * Pursuit runs over the working set [comm, head-cap] with COARSE-TO-FINE
 * maturity (a region is eligible only once all scales <= cap have arrived, so
 * long atoms win first); atoms freeze as comm passes their onset. Scales are
 * capped (--lat-scale) for a bounded latency floor; --active widens the
 * working set (fidelity up, latency up); --rate caps atoms/sec (bitrate).
 *
 * Output is a QSS framed stream (spec §14): a 32-byte header then one packet
 * per commit hop carrying the atoms + residual frames that froze that hop.
 * Voice assignment is online first-fit at commit; the residual uses a causal
 * per-frame trim from the band-coherence matrix C. --qsc also writes a
 * monolithic QSC so the frozen-Faust null test bridges the stream.
 */
#include "../include/mp.h"
#include "../include/qss.h"

static int cmp_vo(const void *a, const void *b){
    const QscAtom *x=a,*y=b;
    if (x->voice != y->voice) return x->voice < y->voice ? -1 : 1;
    if (x->onset != y->onset) return x->onset < y->onset ? -1 : 1;
    return 0;
}
static int cmp_on(const void *a, const void *b){
    const QscAtom *x=a,*y=b; return x->onset<y->onset?-1:(x->onset>y->onset?1:0);
}

typedef struct {
    double *r; uint64_t N; uint32_t sr;
    ScaleCache *sc; int NS;
    double (*Cm)[QSC_BANDS]; double *rho; QscSvf *svf;
    double *acc, eacc; uint64_t rp;
    uint64_t *vfree; int P, dropped; double e_drop;
    QscAtom *atoms; int K; char *emitted;
    QscAtom *fa; int m;
    uint16_t *gains; uint32_t frames;
    FILE *qss; uint32_t hop_index; size_t bytes;
    QssCoder co;
} St;

static void flush_to(St *s, uint64_t newcomm, int is_flush){
    QscAtom *cm = malloc(sizeof(QscAtom)*(s->K?s->K:1)); int nc=0;
    for (int i=0;i<s->K;i++)
        if (!s->emitted[i] && s->atoms[i].onset < newcomm){ cm[nc++]=s->atoms[i]; s->emitted[i]=1; }
    qsort(cm, nc, sizeof(QscAtom), cmp_on);
    uint32_t *aon=malloc(sizeof(uint32_t)*(nc?nc:1)), *asi=malloc(sizeof(uint32_t)*(nc?nc:1));
    uint32_t *afq=malloc(sizeof(uint32_t)*(nc?nc:1)), *aap=malloc(sizeof(uint32_t)*(nc?nc:1)), *aph=malloc(sizeof(uint32_t)*(nc?nc:1));
    int nqa=0;
    for (int i=0;i<nc;i++){
        int v=-1;
        for (int j=0;j<s->P;j++) if (s->vfree[j] <= cm[i].onset){ v=j; break; }
        if (v<0 && s->P<QSC_PMAX) v=s->P++;
        if (v<0){ s->dropped++;
            int sc_=cm[i].scale_idx, sd=cm[i].dur; double om=2*M_PI*cm[i].freq/s->sr;
            for (int j=0;j<sd && cm[i].onset+(uint64_t)j<s->N;j++){
                double mm=cm[i].amp*sin(om*j+cm[i].phase)*s->sc[sc_].win[j];
                s->r[cm[i].onset+j]+=mm; s->e_drop+=mm*mm; }
            continue; }
        cm[i].voice=(uint8_t)v; s->vfree[v]=(uint64_t)cm[i].onset+cm[i].dur;
        /* quantize; closed-loop: residual absorbs the quantization error */
        uint32_t fq=qss_freq_q(cm[i].freq), aq=qss_amp_q(cm[i].amp), pq=qss_phase_q(cm[i].phase);
        double dqf=qss_freq_dq(fq), dqa=qss_amp_dq(aq), dqp=qss_phase_dq(pq);
        int sc_=cm[i].scale_idx, sd=cm[i].dur;
        double omu=2*M_PI*cm[i].freq/s->sr, omq=2*M_PI*dqf/s->sr;
        for (int j=0;j<sd && cm[i].onset+(uint64_t)j<s->N;j++){
            double w=s->sc[sc_].win[j];
            double unq=cm[i].amp*sin(omu*j+cm[i].phase)*w;
            double q  =dqa*sin(omq*j+dqp)*w;
            s->r[cm[i].onset+j] += unq - q;          /* undo unquantized, redo quantized */
        }
        cm[i].freq=(float)dqf; cm[i].amp=(float)dqa; cm[i].phase=(float)dqp;  /* bridge = decoder */
        s->fa[s->m++]=cm[i];
        aon[nqa]=cm[i].onset; asi[nqa]=(uint32_t)cm[i].scale_idx;
        afq[nqa]=fq; aap[nqa]=aq; aph[nqa]=pq; nqa++;
    }
    uint32_t *ridx=NULL; uint16_t *rg=NULL; int nr=0, rcap=0;
    while (s->rp < newcomm){
        uint64_t i=s->rp;
        s->eacc += s->r[i]*s->r[i];
        for (int b=0;b<QSC_BANDS;b++){ double y=qsc_svf_bp(&s->svf[b], s->r[i]); s->acc[b]+=y*y; }
        if ((i+1)%QSC_RES_HOP==0 || i+1==s->N){
            uint32_t fr=(uint32_t)(i/QSC_RES_HOP); uint64_t cnt=(i%QSC_RES_HOP)+1;
            double g[QSC_BANDS], gCg=0;
            for (int b=0;b<QSC_BANDS;b++){ g[b]=sqrt(s->acc[b]/cnt)/s->rho[b]; s->acc[b]=0; }
            for (int b=0;b<QSC_BANDS;b++){ double row=0;
                for (int c=0;c<QSC_BANDS;c++) row+=s->Cm[b][c]*g[c]; gCg+=g[b]*row; }
            double ef=s->eacc/cnt; s->eacc=0;
            double trim=(gCg>1e-30)?sqrt(ef/gCg):1.0;
            if (nr>=rcap){ rcap=rcap?rcap*2:64; ridx=realloc(ridx,rcap*sizeof(uint32_t));
                           rg=realloc(rg,(size_t)rcap*QSC_BANDS*sizeof(uint16_t)); }
            ridx[nr]=fr;
            for (int b=0;b<QSC_BANDS;b++){ uint16_t q=qsc_gain_q(g[b]*trim);
                s->gains[(size_t)fr*QSC_BANDS+b]=q; rg[(size_t)nr*QSC_BANDS+b]=q; }
            nr++;
        }
        s->rp++;
    }
    if (nqa || nr || is_flush)
        s->bytes += qss2_write_packet(s->qss, &s->co, s->hop_index, is_flush?QSS_FLAG_FLUSH:0,
                                      aon, asi, afq, aap, aph, (uint16_t)nqa,
                                      ridx, rg, (uint16_t)nr, QSC_BANDS);
    s->hop_index++;
    free(cm); free(aon); free(asi); free(afq); free(aap); free(aph); free(ridx); free(rg);
}

int main(int argc, char **argv){
    const char *inpath=NULL, *qsspath="stream.qss", *qscpath=NULL, *mode=NULL;
    int cap=-1, hop=512, active=-1; double rate=-1.0; uint32_t seed=0xDEC0DE;
    double floor_amp=1e-4;
    for (int i=1;i<argc;i++){
        if (!strcmp(argv[i],"-o")&&i+1<argc) qsspath=argv[++i];
        else if (!strcmp(argv[i],"--qsc")&&i+1<argc) qscpath=argv[++i];
        else if (!strcmp(argv[i],"--mode")&&i+1<argc) mode=argv[++i];
        else if (!strcmp(argv[i],"--lat-scale")&&i+1<argc) cap=atoi(argv[++i]);
        else if (!strcmp(argv[i],"--rate")&&i+1<argc) rate=atof(argv[++i]);
        else if (!strcmp(argv[i],"--hop")&&i+1<argc) hop=atoi(argv[++i]);
        else if (!strcmp(argv[i],"--active")&&i+1<argc) active=atoi(argv[++i]);
        else if (!strcmp(argv[i],"--seed")&&i+1<argc) seed=(uint32_t)strtoul(argv[++i],0,0);
        else inpath=argv[i];
    }
    if (mode){
        if      (!strcmp(mode,"live"))    { if(cap<0)cap=1024; if(active<0)active=2048; if(rate<0)rate=1500; }
        else if (!strcmp(mode,"near"))    { if(cap<0)cap=2048; if(active<0)active=4096; if(rate<0)rate=1100; }
        else if (!strcmp(mode,"relaxed")) { if(cap<0)cap=4096; if(active<0)active=8192; if(rate<0)rate=700; }
        else { fprintf(stderr,"stream: unknown --mode '%s' (live|near|relaxed)\n",mode); return 2; }
    }
    if (cap<0) cap=4096;
    if (active<0) active=2*cap;
    if (rate<0) rate=1200;
    if (!inpath){ fprintf(stderr,
        "usage: quanta-stream in.wav [-o out.qss] [--qsc bridge.qsc]\n"
        "       [--mode live|near|relaxed] [--lat-scale N] [--active N] [--rate a/s] [--hop N]\n");
        return 2; }

    uint32_t sr; uint64_t N;
    double *r = wav_read_mono(inpath, &sr, &N);
    if (!r){ fprintf(stderr,"stream: cannot read %s\n", inpath); return 1; }
    qsc_build_tables(g_wtab, g_stab);
    double e_src=0; for (uint64_t i=0;i<N;i++) e_src+=r[i]*r[i];

    int NS=0; while (NS<QSC_SCALES && QSC_SCALE_TAB[NS]<=cap) NS++;
    int L=cap+active;
    uint32_t *onsets; int no=detect_onsets(r,N,sr,&onsets);
    uint32_t ogate=(uint32_t)(0.020*sr);

    ScaleCache sc[QSC_SCALES];
    double *re=malloc(sizeof(double)*cap), *im=malloc(sizeof(double)*cap);
    for (int si=0; si<NS; si++){
        int s=QSC_SCALE_TAB[si]; sc[si].scale=s; sc[si].hop=s/4;
        sc[si].nframes = N>(uint64_t)s ? (int)((N-s)/sc[si].hop)+1 : 0;
        sc[si].win=malloc(sizeof(double)*s); sc[si].e2=0;
        for (int i=0;i<s;i++){ sc[si].win[i]=qsc_wlin(g_wtab,(double)i/s*QSC_TAB); sc[si].e2+=sc[si].win[i]*sc[si].win[i]; }
        int nf=sc[si].nframes?sc[si].nframes:1;
        sc[si].best_score=calloc(nf,sizeof(double)); sc[si].best_bin=calloc(nf,sizeof(int));
        sc[si].pa=calloc(nf,sizeof(double)); sc[si].pb=calloc(nf,sizeof(double)); sc[si].pc=calloc(nf,sizeof(double));
        for (int f=0; f<sc[si].nframes; f++) sc[si].best_score[f]=-1.0;
    }

    int cap_atoms=(int)(rate*(double)N/sr)+8192;
    QscAtom *atoms=malloc(sizeof(QscAtom)*cap_atoms);
    int K=0; uint64_t comm=0; double budget=0, e_track=e_src;
    uint64_t vfree[QSC_PMAX]; int hop_atoms_max=0; long hops=0;

    static double Cm[QSC_BANDS][QSC_BANDS]; qsc_band_coherence(Cm,sr);
    double rho[QSC_BANDS]; for (int b=0;b<QSC_BANDS;b++) rho[b]=sqrt(Cm[b][b]);
    QscSvf svf[QSC_BANDS]; for (int b=0;b<QSC_BANDS;b++) qsc_svf_init(&svf[b],qsc_band_fc(b),QSC_BAND_Q,sr);
    double acc[QSC_BANDS]={0};
    uint32_t frames=(uint32_t)((N+QSC_RES_HOP-1)/QSC_RES_HOP);

    FILE *qf=fopen(qsspath,"wb"); if (!qf){ fprintf(stderr,"stream: cannot write %s\n",qsspath); return 1; }
    QssHeader qh={ .sample_rate=sr, .source_len=N, .cap=(uint16_t)cap, .hop=(uint16_t)hop,
        .active=(uint16_t)(active>65535?65535:active), .band_count=QSC_BANDS,
        .residual_hop=QSC_RES_HOP, .noise_seed=seed, .flags=0 };
    qss_write_header(qf,&qh);

    St st={0};
    st.r=r; st.N=N; st.sr=sr; st.sc=sc; st.NS=NS; st.Cm=Cm; st.rho=rho; st.svf=svf;
    st.acc=acc; st.eacc=0; st.rp=0; st.vfree=vfree; st.P=0;
    st.atoms=atoms; st.emitted=calloc(cap_atoms,1);
    st.fa=malloc(sizeof(QscAtom)*cap_atoms); st.m=0;
    st.gains=calloc((size_t)frames*QSC_BANDS,sizeof(uint16_t)); st.frames=frames;
    st.qss=qf; st.hop_index=0; st.bytes=QSS_HDR_BYTES;

    for (uint64_t head=hop; ; head+=hop){
        if (head>N) head=N;
        int final=(head>=N);
        for (int si=0; si<NS; si++){
            ScaleCache *T=&sc[si]; int s=T->scale;
            long hi=((long)head-(final?s:cap))/T->hop; if (hi>=T->nframes) hi=T->nframes-1;
            for (long f=(long)comm/T->hop; f<=hi; f++){
                uint32_t u=(uint32_t)f*T->hop;
                if (u<comm) continue;
                if (T->best_score[f]>=0.0) continue;
                int gated=(s<=256)&&!near_onset(u+s/2,onsets,no,ogate);
                frame_analyze(T,r,N,(int)f,re,im,gated);
            }
        }
        budget += rate*(double)hop/sr; int this_hop=0;
        while (budget>=1.0){
            int bsi=-1,bf=-1; double bs=0.0;
            for (int si=0; si<NS; si++){ int s=sc[si].scale;
                for (int f=0; f<sc[si].nframes; f++){ uint32_t u=(uint32_t)f*sc[si].hop;
                    if (u<comm || u+(uint32_t)(final?s:cap)>head) continue;
                    if (sc[si].best_score[f]>bs){ bs=sc[si].best_score[f]; bsi=si; bf=f; } } }
            if (bsi<0) break;
            ScaleCache *S=&sc[bsi]; int s=S->scale; uint32_t u=(uint32_t)bf*S->hop;
            double pa=S->pa[bf],pb=S->pb[bf],pc=S->pc[bf];
            double den=pa-2*pb+pc, d=(fabs(den)>1e-12)?0.5*(pa-pc)/den:0.0;
            if (d<-0.5)d=-0.5; if (d>0.5)d=0.5;
            double f_hz=((double)S->best_bin[bf]+d)*(double)sr/s;
            double om=2.0*M_PI*f_hz/sr,A=0,B=0,C2=0,rc=0,rs=0;
            for (int i=0;i<s;i++){ double th=om*i,ct=cos(th),stt=sin(th);
                double w=S->win[i],z=(u+(uint64_t)i<N?r[u+i]:0.0)*w;
                A+=w*w*ct*ct;B+=w*w*ct*stt;C2+=w*w*stt*stt;rc+=z*ct;rs+=z*stt; }
            double det=A*C2-B*B; if (fabs(det)<1e-18){ S->best_score[bf]=0; continue; }
            double p=(C2*rc-B*rs)/det,qy=(-B*rc+A*rs)/det, amp=sqrt(p*p+qy*qy);
            if (amp<floor_amp){ S->best_score[bf]=0; continue; }
            double phase=atan2(p,qy); if (phase<0) phase+=2*M_PI;
            double de=0.0;
            for (int i=0;i<s&&u+(uint64_t)i<N;i++){ double th=om*i, mm=(p*cos(th)+qy*sin(th))*S->win[i];
                de+=mm*(2.0*r[u+i]-mm); r[u+i]-=mm; }
            e_track-=de;
            QscAtom *a=&atoms[K]; a->rank=(uint32_t)K; a->onset=u; a->dur=(uint32_t)s;
            a->freq=(float)f_hz; a->amp=(float)amp; a->phase=(float)phase; a->chirp=0;
            a->layer=(s<=256)?1:0; a->voice=0; a->scale_idx=(uint8_t)bsi; a->flags=0;
            K++; this_hop++; budget-=1.0;
            for (int si=0; si<NS; si++){ ScaleCache *T=&sc[si];
                long lo=((long)u-T->scale)/T->hop+1; if (lo<0)lo=0;
                long hi=((long)u+s)/T->hop; if (hi>=T->nframes) hi=T->nframes-1;
                for (long f=lo; f<=hi; f++){ uint32_t uu=(uint32_t)f*T->hop;
                    if (uu<comm || uu+(uint32_t)(final?T->scale:cap)>head) continue;
                    int gated=(T->scale<=256)&&!near_onset(uu+T->scale/2,onsets,no,ogate);
                    frame_analyze(T,r,N,(int)f,re,im,gated); } }
            if (K>=cap_atoms-1) break;
        }
        if (this_hop>hop_atoms_max) hop_atoms_max=this_hop; hops++;
        st.K=K;
        uint64_t ncomm = head>(uint64_t)L ? head-L : 0;
        if (ncomm>comm){ comm=ncomm; flush_to(&st, comm, 0); }
        if (head>=N) break;
    }
    st.K=K; flush_to(&st, N, 1);
    fclose(qf);

    if (qscpath){
        qsort(st.fa, st.m, sizeof(QscAtom), cmp_vo);
        Qsc q={0};
        q.h.sample_rate=sr; q.h.source_len=N; q.h.atom_count=(uint32_t)st.m;
        q.h.voice_count=(uint16_t)st.P; q.h.scale_count=(uint8_t)NS; q.h.band_count=QSC_BANDS;
        q.h.residual_hop=QSC_RES_HOP; q.h.residual_frames=frames; q.h.noise_seed=seed;
        q.atoms=st.fa; q.res_gains=st.gains;
        if (qsc_write(qscpath,&q)) fprintf(stderr,"stream: QSC bridge write failed\n");
    }

    double e_res=0; for (uint64_t i=0;i<N;i++) e_res+=r[i]*r[i];
    fprintf(stderr,
      "quanta-stream: %s  (streaming profile / QSS)\n"
      "  mode: cap=%d (%.1f ms)  active=%d  latency=%d (%.1f ms)  hop=%d  rate=%.0f/s\n"
      "  atoms %d kept / %d placed (voice-culled %d)  voices %d  onsets %d\n"
      "  QSS: %u packets, %zu bytes (%.1f kbps)  per-hop atom peak %d\n"
      "  pursuit residual %+.2f dB | post-cull %+.2f dB -> %s%s%s\n",
      inpath, cap,(double)cap/sr*1000, active, L,(double)L/sr*1000, hop, rate,
      st.m, K, st.dropped, st.P, no,
      st.hop_index, st.bytes, st.bytes*8.0/((double)N/sr)/1000.0, hop_atoms_max,
      10.0*log10(e_track/e_src+1e-30), 10.0*log10(e_res/e_src+1e-30),
      qsspath, qscpath?" + ":"", qscpath?qscpath:"");
    return 0;
}
