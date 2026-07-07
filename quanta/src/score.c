/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-DeMoD-Commercial
 * quanta-score — offline studio transforms on a .qsc score (spec §5.4, instrument).
 * Copyright (c) 2026 DeMoD LLC.
 *
 * The score is a manipulable object: atoms are Gabor grains (freq/onset/dur/amp) over
 * a 24-band noise residual. These are pure ANALYTIC data edits applied BEFORE
 * render/freeze — no phase vocoder, no FFT resynthesis — so the frozen Faust artifact
 * of a transformed score still nulls against its render (determinism preserved: the
 * transform just produces a different, still-valid .qsc).
 *
 *   pitch   in out <semitones> [--formant|--formant-dyn]  scale freq by 2^(s/12);
 *                                            --formant holds the GLOBAL spectral envelope
 *                                            (default — best on stationary timbre, e.g. an
 *                                            instrument); --formant-dyn uses a PER-FRAME
 *                                            envelope for moving formants (voices, evolving
 *                                            mixes). Partials move, formant peaks stay — a
 *                                            phase vocoder only approximates this.
 *   stretch in out <factor> [--keep-transients]  true time-stretch: scale onset+dur
 *                                            (grains ring longer, pitch unchanged).
 *                                            --keep-transients holds layer-1 grain length
 *                                            so transients stay sharp (no smearing).
 *   time    in out <factor>                  legacy re-space: scale onset only, hold dur
 *                                            (density shifts, NOT a true stretch).
 *   density in out <keep 0..1>               keep the most salient <keep> fraction.
 *   eq      in out --lo <Hz> --hi <Hz> --gain <dB>   spectral-region gain on atoms AND
 *                                            the residual bands in [lo,hi].
 *   width   in out <w>                        mid/side stereo width (w<1 narrow, 0 mono,
 *                                            w>1 wide) — scales the side channel.
 *   gain    in out <dB>                        level: scale all atoms + residual by dB.
 *   export  in out  /  import in out           lossless editable-Lua round-trip.
 *
 * Caveats (honest): pitch does NOT transpose the fixed-band noise residual; --formant is a
 * global envelope (measured tighter than per-frame on stationary-timbre music — use
 * --formant-dyn only where formants genuinely move); true stretch sums Gaussian
 * grains whose overlap isn't perfectly constant-energy (mild ripple at large factors,
 * still far cleaner than phase-vocoder phasiness). Editing an atom score changes the
 * signal, so it DROPS the coherent/bit-transparent layer (QSC_FLAG_CRES) down to the
 * analytic atoms+noise tier — reported, not hidden. Works on mono and stereo scores;
 * everything stays bit-deterministic and freeze-compatible.
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

/* true if s is a (possibly signed) numeric literal — so a negative positional amount
   like "-12" is not mistaken for a flag. */
static int is_num(const char *s){
    if (!s || !*s) return 0;
    if (*s=='-' || *s=='+') s++;
    return (*s>='0' && *s<='9') || *s=='.';
}

/* add dB to a residual gain in the quantized domain (0.25 dB/step, g_dB=0.25*q-144). */
static uint16_t res_gain_add_db(uint16_t q, double db){
    double nq = (double)q + db / 0.25;
    if (nq < 0) nq = 0; if (nq > 65535) nq = 65535;
    return (uint16_t)(nq + 0.5);
}

/* editing the atoms/timeline changes the signal, so the stored coherent residual
   (r = source - dcblock(atoms)) is no longer valid — drop it, reverting the score
   from the bit-transparent tier to the analytic atoms+noise tier. */
static void strip_cres(Qsc *q){
    if ((q->h.flags & QSC_FLAG_CRES) || q->cres){
        free(q->cres); q->cres = NULL;
        q->h.flags &= (uint16_t)~QSC_FLAG_CRES;
        q->cres_bits = 0; q->cres_scale[0] = q->cres_scale[1] = 0.0;
        fprintf(stderr,"score: coherent residual dropped (edited score is analytic tier)\n");
    }
}

/* --- global log-frequency amplitude envelope, for formant-preserving pitch --- */
#define FENV_LO  20.0     /* Hz, bottom of the envelope grid */
#define FENV_BPO 6.0      /* bins per octave (1/6-oct resolution) */
static void fenv_build(const Qsc *q, double *env, int nb){
    for (int i=0;i<nb;i++) env[i]=0.0;
    for (uint32_t i=0;i<q->h.atom_count;i++){
        double f=q->atoms[i].freq, a=q->atoms[i].amp;
        if (f<=FENV_LO) continue;
        int b=(int)(FENV_BPO*log2(f/FENV_LO)+0.5);
        if (b<0) b=0; if (b>=nb) b=nb-1;
        env[b]+=a*a;                               /* per-bin energy */
    }
    for (int i=0;i<nb;i++) env[i]=sqrt(env[i]);    /* -> envelope amplitude */
    for (int i=0;i<nb;i++) if (env[i]<=0){         /* fill gaps: nearest non-empty */
        double v=0; for (int d=1;d<nb;d++){
            if (i-d>=0 && env[i-d]>0){ v=env[i-d]; break; }
            if (i+d<nb && env[i+d]>0){ v=env[i+d]; break; } }
        env[i]=v;
    }
}
static double fenv_at(const double *env, int nb, double f){
    if (f<=FENV_LO) return env[0];
    double bpos=FENV_BPO*log2(f/FENV_LO);
    int b0=(int)bpos; if (b0<0) b0=0; if (b0>=nb-1) return env[nb-1];
    double fr=bpos-b0;
    return env[b0]*(1.0-fr)+env[b0+1]*fr;          /* linear in log-freq */
}

/* per-FRAME envelope for a time-varying formant hold: env is [nf*nb] row-major by
   frame; each atom lands in the frame of its centre time. To avoid spiky estimates in
   sparse frames, every frame's per-bin energy is regularized by FENV_REG × the global
   per-bin energy (`genv[b]^2`) — a shrinkage toward the global prior. A frame with strong
   local energy resolves the *local* envelope (tight formant hold on dense material); a
   sparse/empty frame collapses to the global shape (safe, no artifacts). */
#define FENV_FRAME 4096.0     /* samples per envelope frame (~85 ms @ 48k) */
#define FENV_REG   0.35       /* global-prior shrinkage weight */
static void fenv_build_frames(const Qsc *q, double *env, int nf, int nb, const double *genv){
    for (size_t i=0;i<(size_t)nf*nb;i++) env[i]=0.0;
    for (uint32_t i=0;i<q->h.atom_count;i++){
        double f=q->atoms[i].freq, a=q->atoms[i].amp;
        if (f<=FENV_LO) continue;
        int b=(int)(FENV_BPO*log2(f/FENV_LO)+0.5); if (b<0) b=0; if (b>=nb) b=nb-1;
        double ctr=(double)q->atoms[i].onset + 0.5*(double)q->atoms[i].dur;
        int fr=(int)(ctr/FENV_FRAME); if (fr<0) fr=0; if (fr>=nf) fr=nf-1;
        env[(size_t)fr*nb+b]+=a*a;                              /* local energy */
    }
    for (int fr=0;fr<nf;fr++){
        double *row=env+(size_t)fr*nb;
        for (int b=0;b<nb;b++) row[b]=sqrt(row[b] + FENV_REG*genv[b]*genv[b]);
    }
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
          "usage: quanta-score <op> in out [amount] [flags]\n"
          "  pitch   in.qsc out.qsc <semitones> [--formant|--formant-dyn]  transpose (formant-preserving)\n"
          "  stretch in.qsc out.qsc <factor> [--keep-transients] true time-stretch\n"
          "  time    in.qsc out.qsc <factor>                     legacy re-space (holds dur)\n"
          "  density in.qsc out.qsc <keep 0..1>                  keep most-salient fraction\n"
          "  eq      in.qsc out.qsc --lo <Hz> --hi <Hz> --gain <dB>   spectral-region gain\n"
          "  width   in.qsc out.qsc <w>                          mid/side width (0..2)\n"
          "  gain    in.qsc out.qsc <dB>                         master level\n"
          "  export  in.qsc out.lua   /   import in.lua out.qsc  editable-Lua round-trip\n");
        return 2;
    }
    const char *op=argv[1], *inp=argv[2], *outp=argv[3];
    if (!strcmp(op,"export")) return score_export(inp, outp);
    if (!strcmp(op,"import")) return score_import(inp, outp);

    /* scan argv[4..] for a (possibly negative) positional amount + flags */
    int formant=0, dyn=0, keeptr=0, have_amt=0, have_lo=0, have_hi=0, have_gain=0;
    double amt=0, lo=0, hi=0, eqdb=0;
    for (int i=4;i<argc;i++){
        if      (!strcmp(argv[i],"--formant"))                    formant=1;
        else if (!strcmp(argv[i],"--formant-dyn"))             { formant=1; dyn=1; }
        else if (!strcmp(argv[i],"--keep-transients"))            keeptr=1;
        else if (!strcmp(argv[i],"--lo")   && i+1<argc){ lo=atof(argv[++i]);   have_lo=1;   }
        else if (!strcmp(argv[i],"--hi")   && i+1<argc){ hi=atof(argv[++i]);   have_hi=1;   }
        else if (!strcmp(argv[i],"--gain") && i+1<argc){ eqdb=atof(argv[++i]); have_gain=1; }
        else if (is_num(argv[i]))                       { amt=atof(argv[i]);   have_amt=1;  }
        else fprintf(stderr,"score: ignoring unknown arg '%s'\n", argv[i]);
    }

    Qsc q; if (qsc_read(inp,&q)){ fprintf(stderr,"score: cannot read %s\n",inp); return 1; }
    strip_cres(&q);                              /* any edit invalidates a coherent residual */
    int cc = q.h.channel_count ? q.h.channel_count : 1;

    if (!strcmp(op,"pitch")){
        if (!have_amt){ fprintf(stderr,"score: pitch needs <semitones>\n"); qsc_free(&q); return 2; }
        double ratio = pow(2.0, amt/12.0);
        if (formant){
            int nb=(int)(FENV_BPO*log2((q.h.sample_rate*0.5)/FENV_LO))+2; if (nb<8) nb=8;
            double *genv=malloc(sizeof(double)*(size_t)nb);          /* global envelope */
            fenv_build(&q, genv, nb);
            /* --formant (default): one global envelope — best on stationary-timbre material
               (an instrument), objectively tighter than per-frame there. --formant-dyn: a
               per-frame envelope for material with moving formants (voices, evolving mixes). */
            int nf = dyn ? (int)((double)q.h.source_len/FENV_FRAME)+1 : 1; if (nf<1) nf=1;
            double *fenv=NULL;
            if (dyn){ fenv=malloc(sizeof(double)*(size_t)nf*nb); fenv_build_frames(&q, fenv, nf, nb, genv); }
            for (uint32_t i=0;i<q.h.atom_count;i++){
                double f0=q.atoms[i].freq; if (f0<=0) continue;
                double f1=f0*ratio;
                const double *e=genv;
                if (dyn){
                    double ctr=(double)q.atoms[i].onset + 0.5*(double)q.atoms[i].dur;
                    int fr=(int)(ctr/FENV_FRAME); if (fr<0) fr=0; if (fr>=nf) fr=nf-1;
                    e=fenv+(size_t)fr*nb;
                }
                double g=fenv_at(e,nb,f1)/(fenv_at(e,nb,f0)+1e-12);
                q.atoms[i].freq=(float)f1;
                q.atoms[i].amp =(float)(q.atoms[i].amp*g);
            }
            free(fenv); free(genv);
            fprintf(stderr,"score: pitch %+.2f st (x%.4f) formant-preserving (%s) on %u atoms\n",
                    amt, ratio, dyn?"per-frame":"global", q.h.atom_count);
        } else {
            for (uint32_t i=0;i<q.h.atom_count;i++) q.atoms[i].freq=(float)(q.atoms[i].freq*ratio);
            fprintf(stderr,"score: pitch %+.2f st (x%.4f) on %u atoms\n", amt, ratio, q.h.atom_count);
        }
    } else if (!strcmp(op,"stretch")){
        if (!have_amt){ fprintf(stderr,"score: stretch needs <factor>\n"); qsc_free(&q); return 2; }
        if (amt < 1e-3) amt = 1e-3;
        for (uint32_t i=0;i<q.h.atom_count;i++){
            q.atoms[i].onset = (uint32_t)llround((double)q.atoms[i].onset * amt);
            if (!(keeptr && q.atoms[i].layer==1))                    /* hold transient grain length */
                q.atoms[i].dur = (uint32_t)llround((double)q.atoms[i].dur * amt);
        }
        q.h.source_len = (uint64_t)llround((double)q.h.source_len * amt);
        double nh = (double)q.h.residual_hop * amt;
        q.h.residual_hop = (uint16_t)(nh > 65535.0 ? 65535.0 : llround(nh));
        fprintf(stderr,"score: stretch x%.3f%s -> %llu samples on %u atoms\n",
                amt, keeptr?" (transients held)":"", (unsigned long long)q.h.source_len, q.h.atom_count);
    } else if (!strcmp(op,"time")){
        if (!have_amt){ fprintf(stderr,"score: time needs <factor>\n"); qsc_free(&q); return 2; }
        if (amt < 1e-3) amt = 1e-3;
        for (uint32_t i=0;i<q.h.atom_count;i++)
            q.atoms[i].onset = (uint32_t)llround((double)q.atoms[i].onset * amt);   /* re-space; hold dur */
        q.h.source_len = (uint64_t)llround((double)q.h.source_len * amt);
        double nh = (double)q.h.residual_hop * amt;                                  /* stretch residual clock */
        q.h.residual_hop = (uint16_t)(nh > 65535.0 ? 65535.0 : llround(nh));
        fprintf(stderr,"score: time x%.3f -> %llu samples, residual_hop %u on %u atoms\n",
                amt, (unsigned long long)q.h.source_len, q.h.residual_hop, q.h.atom_count);
    } else if (!strcmp(op,"density")){
        if (!have_amt){ fprintf(stderr,"score: density needs <keep 0..1>\n"); qsc_free(&q); return 2; }
        if (amt < 0.0) amt=0.0; if (amt > 1.0) amt=1.0;
        uint32_t maxr=0; for (uint32_t i=0;i<q.h.atom_count;i++) if (q.atoms[i].rank>maxr) maxr=q.atoms[i].rank;
        uint32_t thr = (uint32_t)llround(amt * (double)(maxr+1));                     /* keep rank < thr */
        uint32_t k=0;
        for (uint32_t i=0;i<q.h.atom_count;i++) if (q.atoms[i].rank < thr) q.atoms[k++]=q.atoms[i];
        fprintf(stderr,"score: density keep %.0f%% -> %u of %u atoms\n", amt*100.0, k, q.h.atom_count);
        q.h.atom_count = k;
    } else if (!strcmp(op,"eq")){
        if (!(have_lo && have_hi && have_gain)){
            fprintf(stderr,"score: eq needs --lo <Hz> --hi <Hz> --gain <dB>\n"); qsc_free(&q); return 2; }
        double glin = pow(10.0, eqdb/20.0); uint32_t na=0;
        for (uint32_t i=0;i<q.h.atom_count;i++)
            if (q.atoms[i].freq>=lo && q.atoms[i].freq<=hi){ q.atoms[i].amp=(float)(q.atoms[i].amp*glin); na++; }
        int nbands=0;
        if (q.res_gains) for (int b=0;b<QSC_BANDS;b++){
            double fc=qsc_band_fc(b); if (fc<lo||fc>hi) continue; nbands++;
            for (int c=0;c<cc;c++){
                size_t base=(size_t)c*q.h.residual_frames*QSC_BANDS;
                for (uint32_t fr=0;fr<q.h.residual_frames;fr++){
                    size_t idx=base+(size_t)fr*QSC_BANDS+b;
                    q.res_gains[idx]=res_gain_add_db(q.res_gains[idx], eqdb);
                }
            }
        }
        fprintf(stderr,"score: eq %.0f-%.0f Hz %+.1f dB -> %u atoms, %d residual bands\n", lo,hi,eqdb,na,nbands);
    } else if (!strcmp(op,"width")){
        if (!have_amt){ fprintf(stderr,"score: width needs <w>\n"); qsc_free(&q); return 2; }
        if (cc < 2){
            fprintf(stderr,"score: width: mono score, no side channel (no-op)\n");
        } else {
            double w = amt<0?0:amt; uint32_t ns=0;
            for (uint32_t i=0;i<q.h.atom_count;i++)
                if (q.atoms[i].flags & 1){ q.atoms[i].amp=(float)(q.atoms[i].amp*w); ns++; }
            double wdb = (w>1e-6)? 20.0*log10(w) : -144.0;
            if (q.res_gains){
                size_t base=(size_t)q.h.residual_frames*QSC_BANDS;                    /* side = channel 1 */
                for (size_t k=0;k<(size_t)q.h.residual_frames*QSC_BANDS;k++)
                    q.res_gains[base+k]=res_gain_add_db(q.res_gains[base+k], wdb);
            }
            fprintf(stderr,"score: width x%.3f on %u side atoms\n", w, ns);
        }
    } else if (!strcmp(op,"gain")){
        if (!have_amt){ fprintf(stderr,"score: gain needs <dB>\n"); qsc_free(&q); return 2; }
        double glin=pow(10.0, amt/20.0);
        for (uint32_t i=0;i<q.h.atom_count;i++) q.atoms[i].amp=(float)(q.atoms[i].amp*glin);
        if (q.res_gains) for (size_t k=0;k<(size_t)q.h.residual_frames*QSC_BANDS*cc;k++)
            q.res_gains[k]=res_gain_add_db(q.res_gains[k], amt);
        fprintf(stderr,"score: gain %+.2f dB (x%.4f) on %u atoms\n", amt, glin, q.h.atom_count);
    } else {
        fprintf(stderr,"score: unknown op '%s' (pitch|stretch|time|density|eq|width|gain|export|import)\n", op);
        qsc_free(&q); return 2;
    }

    if (qsc_write(outp,&q)){ fprintf(stderr,"score: write failed\n"); qsc_free(&q); return 1; }
    fprintf(stderr,"score: %s -> %s\n", inp, outp);
    qsc_free(&q);
    return 0;
}
