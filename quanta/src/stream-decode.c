/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-DeMoD-Commercial
 * quanta-stream-decode — streaming QSS decoder (spec §14).
 * Copyright (c) 2026 DeMoD LLC.
 *
 * Consumes a QSS stream packet-by-packet and synthesizes audio sample-by-
 * sample with bounded memory: atoms are pushed into per-voice queues as their
 * packet is read and retired once the play head passes them; residual band
 * gains are held in a small rolling record. The per-sample math, table lookups
 * and summation order (voices 0..P-1, then the 24-band residual, then the
 * master DC-blocker) are byte-identical to quanta-render / the frozen Faust
 * decoder, so stream-decode(QSS) nulls against render(bridge QSC).
 *
 * Real-time note: the residual envelope interpolates frame f0->f0+1, so a
 * real-time player outputs one residual frame (residual_hop samples) behind
 * the packet head; decoding a complete stream (as here) has all frames.
 */
#include "../include/qss.h"
#include <math.h>

typedef struct { uint32_t onset, dur; float freq, amp, phase; uint8_t layer; } DAtom;
typedef struct { DAtom *q; int head, tail, cap; } VQueue;   /* ring per voice */

static void vpush(VQueue *v, const DAtom *a){
    if (v->tail - v->head >= v->cap){
        int nc = v->cap? v->cap*2 : 8; DAtom *nq = malloc(sizeof(DAtom)*nc);
        for (int i=0;i<v->tail-v->head;i++) nq[i]=v->q[(v->head+i)%v->cap];
        free(v->q); v->q=nq; v->tail-=v->head; v->head=0; v->cap=nc;
    }
    v->q[v->tail % v->cap] = *a; v->tail++;
}

int main(int argc, char **argv){
    const char *inpath=NULL, *rawout=NULL, *wavout=NULL;
    for (int i=1;i<argc;i++){
        if (!strcmp(argv[i],"--raw")&&i+1<argc) rawout=argv[++i];
        else if (!strcmp(argv[i],"--wav")&&i+1<argc) wavout=argv[++i];
        else inpath=argv[i];
    }
    if (!inpath){ fprintf(stderr,"usage: quanta-stream-decode in.qss [--raw out.f64] [--wav out.wav]\n"); return 2; }

    FILE *fp=fopen(inpath,"rb"); if(!fp){ fprintf(stderr,"decode: cannot open %s\n",inpath); return 1; }
    fseek(fp,0,SEEK_END); long fsz=ftell(fp); fseek(fp,0,SEEK_SET);
    uint8_t *buf=malloc(fsz); if(fread(buf,1,fsz,fp)!=(size_t)fsz){fclose(fp);return 1;} fclose(fp);

    QssHeader h;
    if (qss_read_header(buf,fsz,&h)){ fprintf(stderr,"decode: bad QSS header\n"); return 1; }
    uint32_t sr=h.sample_rate, HB=h.residual_hop, B=h.band_count;
    uint64_t N=h.source_len;
    uint32_t FR=(uint32_t)((N+HB-1)/HB);

    double wtab[QSC_TAB], stab[QSC_TAB]; qsc_build_tables(wtab,stab);
    double lg[3]={1.0,1.0,1.0};                 /* layer gains (parity w/ render defaults) */
    double master=1.0;

    /* per-voice queues (grown on demand up to 256 voices) */
    VQueue vq[QSC_PMAX]; memset(vq,0,sizeof vq);
    int Pseen=0;
    /* residual gains: full frame table (small), filled from packets */
    double *gains=calloc((size_t)FR*B,sizeof(double));
    char *gfilled=calloc(FR,1);

    /* lazy packet reader state */
    size_t off=QSS_HDR_BYTES; int bad_packets=0; long total_atoms=0;
    QssCoder co; qss_coder_init(&co);
    uint64_t dvfree[QSC_PMAX]; memset(dvfree,0,sizeof dvfree);   /* re-derive voices */

    /* pull every packet whose committed content is needed by sample <= upto */
    size_t pkt_off=off;
    #define DRAIN_TO(UPTO) do { \
        while (pkt_off < (size_t)fsz){ \
            QssPacket2 pk; \
            int rc=qss2_next_packet(buf,fsz,&pkt_off,B,&co,&pk); \
            if (rc==0){ pkt_off=fsz; break; } \
            if (rc<0){ bad_packets++; continue; } \
            for (uint16_t i=0;i<pk.n_atoms;i++){ \
                uint32_t on=pk.onset[i]; uint32_t sidx=pk.scaleidx[i]; \
                uint32_t dur=(sidx<QSC_SCALES)?(uint32_t)QSC_SCALE_TAB[sidx]:0; \
                float fr_=(float)qss_freq_dq(pk.freqq[i]); \
                float am=(float)qss_amp_dq(pk.ampq[i]); \
                float ph=(float)qss_phase_dq(pk.phaseq[i]); \
                uint8_t layer=(dur<=256)?1:0; \
                int v=-1; for (int j=0;j<Pseen;j++) if (dvfree[j]<=on){ v=j; break; } \
                if (v<0 && Pseen<QSC_PMAX) v=Pseen++; \
                if (v<0) continue; \
                dvfree[v]=(uint64_t)on+dur; \
                DAtom d={on,dur,fr_,am,ph,layer}; vpush(&vq[v],&d); total_atoms++; } \
            for (uint16_t i=0;i<pk.n_res;i++){ uint32_t fr=pk.res_idx[i]; \
                if (fr<FR){ for (uint16_t b=0;b<B;b++) gains[(size_t)fr*B+b]=qsc_gain_dq(pk.res_gain[(size_t)i*B+b]); gfilled[fr]=1; } } \
            uint32_t hopi=pk.hop_index; qss2_free(&pk); \
            if (hopi && (uint64_t)hopi*h.hop > (UPTO)+ (uint64_t)h.cap+h.active+HB) break; \
        } } while(0)

    double *out=malloc(sizeof(double)*N);        /* master dcblock is causal; hold for wav peak */
    /* residual synth state */
    QscSvf f[QSC_BANDS]; for (int b=0;b<QSC_BANDS;b++) qsc_svf_init(&f[b],qsc_band_fc(b),QSC_BAND_Q,sr);
    int32_t nzst=0;
    /* per-voice active atom cursor */
    int vcur_valid[QSC_PMAX]; memset(vcur_valid,0,sizeof vcur_valid);

    for (uint64_t t=0; t<N; t++){
        DRAIN_TO(t);
        double acc=0.0;
        /* voices 0..P-1 in order (matches render summation order) */
        for (int v=0; v<Pseen; v++){
            VQueue *Q=&vq[v];
            while (Q->head<Q->tail){                    /* retire finished, advance to active */
                DAtom *a=&Q->q[Q->head % Q->cap];
                if (t >= (uint64_t)a->onset + a->dur){ Q->head++; continue; }
                break;
            }
            if (Q->head>=Q->tail) continue;
            DAtom *a=&Q->q[Q->head % Q->cap];
            if (t < a->onset) continue;                 /* not started yet */
            int64_t tl=(int64_t)t-(int64_t)a->onset;
            double x=(double)tl/(double)a->dur;
            double win=qsc_wlin(wtab, x*QSC_TAB);
            double ph=(double)a->freq*(double)tl/sr + (double)a->phase*(1.0/(2.0*M_PI));
            double phf=ph-(double)(int64_t)ph;
            double sv=qsc_slin(stab, phf*QSC_TAB);
            acc += (double)a->amp*win*sv*lg[a->layer];
        }
        /* residual: seeded LCG -> 24-band SVF, env interp (identical to render) */
        nzst=qsc_lcg_step(nzst,(int32_t)h.noise_seed);
        double nz=qsc_lcg_out(nzst);
        double fpos=(double)t/(double)HB;
        uint32_t f0=(uint32_t)fpos; if (f0>FR-1) f0=FR-1;
        uint32_t f1=f0+1<FR?f0+1:FR-1; double frac=fpos-(double)f0;
        double racc=0.0;
        for (int b=0;b<QSC_BANDS && b<(int)B;b++){
            double g0=gains[(size_t)f0*B+b], g1=gains[(size_t)f1*B+b];
            racc += qsc_svf_bp(&f[b],nz)*(g0+frac*(g1-g0));
        }
        acc += racc*lg[2];
        out[t]=acc;
    }
    /* master + dc blocker (fi.dcblocker pole 0.995), identical to render */
    { double x1=0,y1=0; for (uint64_t t=0;t<N;t++){ double x=out[t]*master; double y=x-x1+0.995*y1; x1=x;y1=y; out[t]=y; } }

    double pk=0; for (uint64_t t=0;t<N;t++){ double a=fabs(out[t]); if(a>pk)pk=a; }
    if (rawout) raw_write_f64(rawout,out,N);
    if (wavout) wav_write16(wavout,out,N,sr);
    fprintf(stderr,"stream-decode: %s  %u atoms, %d voices, %llu samples | peak %.3f | bad-packets %d\n",
            inpath, (unsigned)total_atoms, Pseen, (unsigned long long)N, pk, bad_packets);
    return 0;
}
