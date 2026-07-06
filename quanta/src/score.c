/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-DeMoD-Commercial
 * quanta-score — offline creative transforms on a .qsc score (spec §10, instrument).
 * Copyright (c) 2026 DeMoD LLC.
 *
 * The score is a manipulable object: atoms are Gabor grains (freq/onset/dur/amp).
 * These transforms are pure data edits applied BEFORE render/freeze, so the frozen
 * Faust artifact of a transformed score still nulls against its render — determinism
 * is preserved (the transform just produces a different, still-valid .qsc).
 *
 *   pitch  in.qsc out.qsc <semitones>   scale every atom freq by 2^(s/12).
 *   time   in.qsc out.qsc <factor>      re-space events + stretch the residual by
 *                                        <factor> (grain length held — density shifts).
 *   density in.qsc out.qsc <keep 0..1>  keep the most salient <keep> fraction of atoms.
 *
 * Caveats (honest): pitch does NOT transpose the deterministic-noise residual, and
 * time holds grain length, so both drift from a "perfect" pitch/timestretch — but
 * both stay bit-deterministic and freeze-compatible. Works on mono and stereo scores.
 */
#include "../include/qsc.h"

/* render/freeze want atoms grouped by channel (flag bit0), then voice, then onset. */
static int cmp_import(const void *a, const void *b){
    const QscAtom *x=a,*y=b; int cx=x->flags&1, cy=y->flags&1;
    if (cx!=cy) return cx<cy?-1:1;
    if (x->voice!=y->voice) return x->voice<y->voice?-1:1;
    if (x->onset!=y->onset) return x->onset<y->onset?-1:1;
    return 0;
}

/* export a .qsc's atoms to an editable Lua score (all atom fields, lossless in
   float precision). The residual layer is not exported (it's a noise model, not a
   note score); import produces an atoms-only .qsc. */
static int score_export(const char *inp, const char *outp){
    Qsc q; if (qsc_read(inp,&q)){ fprintf(stderr,"score: cannot read %s\n",inp); return 1; }
    FILE *o=fopen(outp,"w"); if(!o){ fprintf(stderr,"score: cannot write %s\n",outp); qsc_free(&q); return 1; }
    fprintf(o,"-- quanta editable score (round-trip via: quanta-score import)\n"
              "return {\n  sr=%u, len=%llu, voices=%u, seed=0x%08X, channels=%d,\n  atoms={\n",
              q.h.sample_rate,(unsigned long long)q.h.source_len,q.h.voice_count,
              q.h.noise_seed, q.h.channel_count?q.h.channel_count:1);
    for (uint32_t i=0;i<q.h.atom_count;i++){ const QscAtom *a=&q.atoms[i];
        fprintf(o,"    {r=%u,o=%u,d=%u,f=%.9g,a=%.9g,p=%.9g,l=%u,v=%u,s=%u,c=%u},\n",
                a->rank,a->onset,a->dur,(double)a->freq,(double)a->amp,(double)a->phase,
                a->layer,a->voice,a->scale_idx,a->flags&1u);
    }
    fprintf(o,"  }\n}\n"); fclose(o);
    fprintf(stderr,"score: export %u atoms -> %s\n",q.h.atom_count,outp);
    qsc_free(&q); return 0;
}

/* import an (edited) Lua score back to an atoms-only .qsc (residual dropped). */
static int score_import(const char *inp, const char *outp){
    FILE *f=fopen(inp,"rb"); if(!f){ fprintf(stderr,"score: cannot read %s\n",inp); return 1; }
    unsigned int sr=48000, voices=0, cc=1, seed=0xDEC0DE; unsigned long long len=0;
    QscAtom *at=NULL; uint32_t cap=0, n=0; char line[512];
    while (fgets(line,sizeof line,f)){
        char *p;
        if ((p=strstr(line,"sr=")))       sscanf(p,"sr=%u",&sr);
        if ((p=strstr(line,"len=")))      sscanf(p,"len=%llu",&len);
        if ((p=strstr(line,"voices=")))   sscanf(p,"voices=%u",&voices);
        if ((p=strstr(line,"seed=0x")))   sscanf(p,"seed=0x%x",&seed);
        if ((p=strstr(line,"channels="))) sscanf(p,"channels=%u",&cc);
        if ((p=strstr(line,"{r="))){
            unsigned int r,o,d,l,v,s,c; double fr,am,ph;
            if (sscanf(p,"{r=%u,o=%u,d=%u,f=%lg,a=%lg,p=%lg,l=%u,v=%u,s=%u,c=%u}",
                       &r,&o,&d,&fr,&am,&ph,&l,&v,&s,&c)==10){
                if (n==cap){ cap=cap?cap*2:256; at=realloc(at,(size_t)cap*sizeof(QscAtom)); }
                QscAtom *a=&at[n++]; memset(a,0,sizeof *a);
                a->rank=r;a->onset=o;a->dur=d;a->freq=(float)fr;a->amp=(float)am;a->phase=(float)ph;
                a->layer=(uint8_t)l;a->voice=(uint8_t)v;a->scale_idx=(uint8_t)s;a->flags=(uint8_t)(c&1);
            }
        }
    }
    fclose(f);
    if (!len)    for (uint32_t i=0;i<n;i++){ uint64_t e=at[i].onset+at[i].dur; if(e>len)len=e; }
    if (!voices) for (uint32_t i=0;i<n;i++) if ((unsigned)at[i].voice+1>voices) voices=at[i].voice+1;
    qsort(at, n, sizeof(QscAtom), cmp_import);
    Qsc q; memset(&q,0,sizeof q);
    q.h.sample_rate=sr; q.h.source_len=len; q.h.voice_count=(uint16_t)voices; q.h.noise_seed=seed;
    q.h.channel_count=(uint8_t)(cc?cc:1); q.h.scale_count=QSC_SCALES; q.h.band_count=QSC_BANDS;
    q.h.residual_hop=QSC_RES_HOP; q.h.residual_frames=0; q.h.atom_count=n; q.atoms=at; q.res_gains=NULL;
    int rc = qsc_write(outp,&q);
    fprintf(stderr,"score: import %u atoms (residual dropped) -> %s\n", n, outp);
    free(at); return rc;
}

int main(int argc, char **argv){
    if (argc < 4){
        fprintf(stderr,
          "usage: quanta-score <op> in out [amount]\n"
          "  pitch   in.qsc out.qsc <semitones>   time in.qsc out.qsc <factor>\n"
          "  density in.qsc out.qsc <keep 0..1>\n"
          "  export  in.qsc out.lua               (editable text score)\n"
          "  import  in.lua out.qsc               (round-trip edited score; atoms only)\n");
        return 2;
    }
    const char *op=argv[1], *inp=argv[2], *outp=argv[3];
    if (!strcmp(op,"export")) return score_export(inp, outp);
    if (!strcmp(op,"import")) return score_import(inp, outp);
    if (argc < 5){ fprintf(stderr,"score: '%s' needs an <amount>\n", op); return 2; }
    double amt=atof(argv[4]);
    Qsc q; if (qsc_read(inp,&q)){ fprintf(stderr,"score: cannot read %s\n",inp); return 1; }

    if (!strcmp(op,"pitch")){
        double ratio = pow(2.0, amt/12.0);
        for (uint32_t i=0;i<q.h.atom_count;i++) q.atoms[i].freq = (float)(q.atoms[i].freq * ratio);
        fprintf(stderr,"score: pitch %+.2f st (x%.4f) on %u atoms\n", amt, ratio, q.h.atom_count);
    } else if (!strcmp(op,"time")){
        if (amt < 1e-3) amt = 1e-3;
        for (uint32_t i=0;i<q.h.atom_count;i++)
            q.atoms[i].onset = (uint32_t)llround((double)q.atoms[i].onset * amt);   /* re-space; hold dur */
        q.h.source_len = (uint64_t)llround((double)q.h.source_len * amt);
        double nh = (double)q.h.residual_hop * amt;                                  /* stretch residual clock */
        q.h.residual_hop = (uint16_t)(nh > 65535.0 ? 65535.0 : llround(nh));
        fprintf(stderr,"score: time x%.3f -> %llu samples, residual_hop %u on %u atoms\n",
                amt, (unsigned long long)q.h.source_len, q.h.residual_hop, q.h.atom_count);
    } else if (!strcmp(op,"density")){
        if (amt < 0.0) amt=0.0; if (amt > 1.0) amt=1.0;
        uint32_t maxr=0; for (uint32_t i=0;i<q.h.atom_count;i++) if (q.atoms[i].rank>maxr) maxr=q.atoms[i].rank;
        uint32_t thr = (uint32_t)llround(amt * (double)(maxr+1));                     /* keep rank < thr */
        uint32_t k=0;
        for (uint32_t i=0;i<q.h.atom_count;i++) if (q.atoms[i].rank < thr) q.atoms[k++]=q.atoms[i];
        fprintf(stderr,"score: density keep %.0f%% -> %u of %u atoms\n", amt*100.0, k, q.h.atom_count);
        q.h.atom_count = k;
    } else {
        fprintf(stderr,"score: unknown op '%s' (pitch|time|density)\n", op);
        qsc_free(&q); return 2;
    }

    if (qsc_write(outp,&q)){ fprintf(stderr,"score: write failed\n"); qsc_free(&q); return 1; }
    fprintf(stderr,"score: %s -> %s\n", inp, outp);
    qsc_free(&q);
    return 0;
}
