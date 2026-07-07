/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-DeMoD-Commercial
 * quanta-freeze — QSC -> pure static Faust codegen (spec §7)
 * Copyright (c) 2026 DeMoD LLC.
 *
 * Emits a self-contained .dsp: shared f64 tables as waveform literals,
 * per-voice atom tables + branch-free letrec-style index walkers, seeded
 * LCG residual through an inline TPT SVF bank. Arithmetic order mirrors
 * quanta-render exactly so the null test (§7.4) is meaningful. Mono emits a
 * 1-output process; mid/side stereo emits per-channel banks (side residual
 * seeded with noise_seed^QSC_SIDE_SEED_XOR) and process = (M+S, M-S).
 *
 * --verify : emit unity constants instead of UI sliders (golden renders).
 * --k N    : prune atoms with rank >= N before emission (frozen K, §7).
 */
#include "../include/qsc.h"

static void emit_table(FILE *o, const char *name, const double *v, uint32_t n){
    fprintf(o, "%s = waveform{", name);
    for (uint32_t i = 0; i < n; i++)
        fprintf(o, "%s%.17g", i ? "," : "", v[i]);
    if (n == 0) fprintf(o, "0.0");     /* Faust rejects waveform{}; an empty voice reads
                                          this dummy but its act-gate is always false → silence */
    fprintf(o, "};\n");
}

/* Coherent residual (§B): the true post-atom residual as an int16 waveform table read
   by the sample counter, scaled back to linear. Nulls source at the quantizer floor.
   Emitted as integer literals (compact) + a single scale multiply. */
static void emit_cres(FILE *o, const char *name, const int16_t *v, uint64_t n, double scale){
    fprintf(o, "%sT = waveform{", name);
    for (uint64_t i = 0; i < n; i++) fprintf(o, "%s%d", i ? "," : "", (int)v[i]);
    if (n == 0) fprintf(o, "0");
    fprintf(o, "};\n%s = (%sT, int(min(tim,%llu)) : rdtable) * %.17g;\n",
            name, name, (unsigned long long)(n ? n-1 : 0), scale);
}

/* Emit one channel's voice banks + residual, names prefixed by `px` and its own
   LCG `seed`. Defines <px>vsum and <px>res. Shared defs (tables, wlin/slin, tim,
   g0..gm, svf, FR/fpos/ef*) are emitted once by main before this is called.
   `atoms` is that channel's block (voice-grouped, onset-sorted). */
static void emit_channel(FILE *o, const char *px, const QscAtom *atoms,
                         const uint32_t *voff, int P, const uint16_t *gains,
                         uint32_t FR, uint32_t sr, uint32_t seed, int verify){
    for (int v = 0; v < P; v++){
        uint32_t a0 = voff[v], n = voff[v+1] - voff[v];
        double *tb = malloc(sizeof(double) * (n + 1));
        char nm[48];
        for (uint32_t i = 0; i < n; i++) tb[i] = (double)atoms[a0+i].onset;
        tb[n] = 1e30;                                    /* sentinel */
        snprintf(nm, 48, "%son%d", px, v);  emit_table(o, nm, tb, n + 1);
        for (uint32_t i = 0; i < n; i++) tb[i] = (double)atoms[a0+i].dur;
        snprintf(nm, 48, "%sdu%d", px, v);  emit_table(o, nm, tb, n);
        for (uint32_t i = 0; i < n; i++) tb[i] = (double)atoms[a0+i].freq;
        snprintf(nm, 48, "%sfq%d", px, v);  emit_table(o, nm, tb, n);
        for (uint32_t i = 0; i < n; i++) tb[i] = (double)atoms[a0+i].amp;
        snprintf(nm, 48, "%sam%d", px, v);  emit_table(o, nm, tb, n);
        for (uint32_t i = 0; i < n; i++) tb[i] = (double)atoms[a0+i].phase * (1.0/(2.0*M_PI));
        snprintf(nm, 48, "%sph%d", px, v);  emit_table(o, nm, tb, n);
        for (uint32_t i = 0; i < n; i++) tb[i] = (double)atoms[a0+i].layer;
        snprintf(nm, 48, "%sly%d", px, v);  emit_table(o, nm, tb, n);
        char rkln[80] = "";
        if (!verify){                                    /* rank table only for the runtime density knob */
            for (uint32_t i = 0; i < n; i++) tb[i] = (double)atoms[a0+i].rank;
            snprintf(nm, 48, "%srk%d", px, v);  emit_table(o, nm, tb, n);
            snprintf(rkln, 80, "  rkv = %srk%d, int(idx) : rdtable;\n", px, v);
        }
        free(tb);

        /* verify keeps the exact static walker (byte-identical null contract); the
           instrument build adds the pitch multiply + rank/density gate. */
        const char *actx = verify ? "(tl >= 0.0) & (tl < d)"
                                   : "(tl >= 0.0) & (tl < d) & (rkv < Kd)";
        const char *phx  = verify ? "fqv * tl / RATE + phv"
                                   : "fqv * PITCH * tl / RATE + phv";
        fprintf(o,
            "%svoice%d = amv*win*sv*act%s with {\n"
            "  n = %u;\n"
            "  onr(i) = %son%d, int(i) : rdtable;\n"
            "  idx = (inc ~ _) with { inc(p) = p + ((p+1 < n) & (tim >= onr(p+1))); };\n"
            "  o = onr(idx);\n"
            "  d = %sdu%d, int(idx) : rdtable;\n"
            "  amv = %sam%d, int(idx) : rdtable;\n"
            "  fqv = %sfq%d, int(idx) : rdtable;\n"
            "  phv = %sph%d, int(idx) : rdtable;\n"
            "  lyv = %sly%d, int(idx) : rdtable;\n"
            "%s"
            "  lg = (lyv < 0.5)*g0 + (lyv > 0.5)*g1;\n"
            "  tl = tim - o;\n"
            "  act = %s;\n"
            "  win = wlin(tl / d * float(NTAB));\n"
            "  ph = %s;\n"
            "  sv = slin((ph - float(int(ph))) * float(NTAB));\n"
            "};\n\n",
            px, v, verify ? "" : "*lg", n + 0u, px, v, px, v, px, v, px, v, px, v, px, v,
            rkln, actx, phx);
    }

    /* residual: per-channel seeded LCG -> inline TPT SVF bank */
    fprintf(o,
        "%slcgs = (step ~ _) with { step(s) = (s*%d + %d + %d) & %d; };\n"
        "%snz = float(%slcgs)/1073741824.0 - 1.0;\n",
        px, QSC_LCG_A, QSC_LCG_C, (int32_t)seed, QSC_LCG_M, px, px);
    double *gt = malloc(sizeof(double) * (FR ? FR : 1));
    for (int b = 0; b < QSC_BANDS; b++){
        char nm[48];
        for (uint32_t f = 0; f < FR; f++)
            gt[f] = qsc_gain_dq(gains[(size_t)f*QSC_BANDS + b]);
        snprintf(nm, 48, "%sgt%d", px, b);
        emit_table(o, nm, gt, FR);
        double fc = qsc_band_fc(b);
        double g  = tan(M_PI * fc / sr);
        double k  = 1.0 / QSC_BAND_Q;
        double a1 = 1.0/(1.0 + g*(g + k)), a2 = g*a1, a3 = g*a2;
        fprintf(o,
            "%senv%d = e0 + efr*(e1 - e0) with { e0 = %sgt%d, int(ef0) : rdtable;"
            " e1 = %sgt%d, int(ef1) : rdtable; };\n"
            "%sres%d = (%snz : svf(%.17g, %.17g, %.17g)) * %senv%d;\n",
            px, b, px, b, px, b, px, b, px, a1, a2, a3, px, b);
    }
    free(gt);

    fprintf(o, "\n%svsum = ", px);
    if (P == 0) fprintf(o, "0.0");
    for (int v = 0; v < P; v++) fprintf(o, "%s%svoice%d", v ? " + " : "", px, v);
    fprintf(o, ";\n%sres = ", px);
    if (FR == 0) fprintf(o, "0.0");
    for (int b = 0; FR && b < QSC_BANDS; b++) fprintf(o, "%s%sres%d", b ? " + " : "", px, b);
    fprintf(o, ";\n\n");
}

int main(int argc, char **argv){
    const char *inpath = NULL, *outpath = "out.dsp", *luapath = NULL;
    uint32_t K = 0xFFFFFFFF; int verify = 0;
    for (int i = 1; i < argc; i++){
        if (!strcmp(argv[i], "-o") && i+1 < argc) outpath = argv[++i];
        else if (!strcmp(argv[i], "--k") && i+1 < argc) K = (uint32_t)strtoul(argv[++i],0,0);
        else if (!strcmp(argv[i], "--lua") && i+1 < argc) luapath = argv[++i];
        else if (!strcmp(argv[i], "--verify")) verify = 1;
        else inpath = argv[i];
    }
    if (!inpath){ fprintf(stderr,"usage: quanta-freeze in.qsc [-o out.dsp] [--k N] [--verify]\n"); return 2; }

    Qsc q;
    if (qsc_read(inpath, &q)){ fprintf(stderr, "freeze: qsc_read failed\n"); return 1; }
    int cc = q.h.channel_count ? q.h.channel_count : 1;
    int cres_on = (q.h.flags & QSC_FLAG_CRES) && q.cres;   /* bit-transparent tier */
    uint64_t N = q.h.source_len;

    /* K-prune (frozen artifact has no runtime K gate, §7) — per-atom, keeps the
       [mid][side] block order and each atom's channel flag. */
    uint32_t m = 0;
    for (uint32_t i = 0; i < q.h.atom_count; i++)
        if (q.atoms[i].rank < K) q.atoms[m++] = q.atoms[i];
    q.h.atom_count = m;

    if (luapath){                                        /* score sidecar (§10) */
        FILE *lo = fopen(luapath, "w");
        if (lo){
            fprintf(lo, "-- generated by quanta-freeze (demod-quanta score sidecar)\n"
                        "return {\n  sr = %u, len = %llu, voices = %u, seed = \"0x%08X\", channels = %d,\n"
                        "  atoms = {\n",
                    q.h.sample_rate, (unsigned long long)q.h.source_len,
                    q.h.voice_count, q.h.noise_seed, cc);
            for (uint32_t i = 0; i < m; i++){
                const QscAtom *a = &q.atoms[i];
                fprintf(lo, "    {r=%u,o=%u,d=%u,f=%.6g,a=%.6g,l=%u,c=%u},\n",
                        a->rank, a->onset, a->dur, (double)a->freq,
                        (double)a->amp, a->layer, a->flags & 1u);
            }
            fprintf(lo, "  }\n}\n");
            fclose(lo);
            fprintf(stderr, "freeze: score sidecar -> %s\n", luapath);
        }
    }

    int P = q.h.voice_count;
    double wtab[QSC_TAB], stab[QSC_TAB];
    qsc_build_tables(wtab, stab);
    uint32_t FR = q.h.residual_frames;

    FILE *o = fopen(outpath, "w");
    if (!o){ fprintf(stderr, "freeze: cannot open %s\n", outpath); return 1; }

    fprintf(o,
        "// demod-quanta frozen artifact — generated by quanta-freeze\n"
        "// source_len=%llu sr=%u atoms=%u voices=%d seed=0x%08X channels=%d %s\n"
        "// Deterministic static resynthesis (spec §7). Compile: -double -ftz 2.\n"
        "declare name \"demod-quanta-frozen\";\n"
        "declare license \"Generated output — property of the score owner (spec §13)\";\n"
        "import(\"stdfaust.lib\");\n\n"
        "RATE = %.17g;\nNTAB = %d;\n\n",
        (unsigned long long)q.h.source_len, q.h.sample_rate, m, P,
        q.h.noise_seed, cc, verify ? "[verify]" : "", (double)q.h.sample_rate, QSC_TAB);

    /* bake length + rate so a frozen master compiled with arch/player.arch is a fully
       self-contained program (knows its own duration and playback rate — spec §7, B3). */
    fprintf(o, "declare samples \"%llu\";\ndeclare samplerate \"%u\";\n\n",
            (unsigned long long)q.h.source_len, q.h.sample_rate);

    /* shared tables + helpers — byte-identical to the C reference (parity) */
    emit_table(o, "wtab", wtab, QSC_TAB);
    emit_table(o, "stab", stab, QSC_TAB);
    fprintf(o,
        "wt(i) = wtab, int(i) : rdtable;\n"
        "st(i) = stab, int(i) : rdtable;\n"
        "wlin(p) = wt(i0) + fr*(wt(i1) - wt(i0)) with {\n"
        "  pc = max(0.0, p);\n"
        "  i0 = min(int(pc), NTAB-1); i1 = min(i0+1, NTAB-1);\n"
        "  fr = pc - float(i0);\n"
        "};\n"
        "slin(p) = st(a) + fr*(st(b) - st(a)) with {\n"
        "  i0 = int(p); fr = p - float(i0);\n"
        "  a = i0 & (NTAB-1); b = (i0+1) & (NTAB-1);\n"
        "};\n"
        "tim = (+(1) ~ _) - 1;\n"
        "svf(a1,a2,a3) = (rec(a1,a2,a3) ~ (_,_)) : (!,!,_) with {\n"
        "  rec(a1_,a2_,a3_, ic1, ic2, x) = ic1n, ic2n, bp with {\n"
        "    v3 = x - ic2; v1 = a1_*ic1 + a2_*v3; v2 = ic2 + a2_*ic1 + a3_*v3;\n"
        "    bp = 0.25*v1; ic1n = 2.0*v1 - ic1; ic2n = 2.0*v2 - ic2;\n"
        "  };\n"
        "};\n"
        "dcb = _ <: (_, mem : -) : + ~ *(0.995);\n\n");

    uint32_t maxrank = 0;
    for (uint32_t i = 0; i < m; i++) if (q.atoms[i].rank > maxrank) maxrank = q.atoms[i].rank;
    if (verify)
        /* golden/null: all knobs at unity — reduces exactly to the static render. */
        fprintf(o, "g0 = 1.0; g1 = 1.0; g2 = 1.0; gm = 1.0;\nPITCH = 1.0; Kd = 1e30;\n");
    else
        fprintf(o,
        "g0 = ba.db2linear(hslider(\"h:quanta/[0]tonal [unit:dB]\",0,-60,12,0.1)) : si.smoo;\n"
        "g1 = ba.db2linear(hslider(\"h:quanta/[1]transient [unit:dB]\",0,-60,12,0.1)) : si.smoo;\n"
        "g2 = ba.db2linear(hslider(\"h:quanta/[2]residual [unit:dB]\",0,-60,12,0.1)) : si.smoo;\n"
        "gm = ba.db2linear(hslider(\"h:quanta/[3]master [unit:dB]\",0,-60,12,0.1)) : si.smoo;\n"
        /* playable-instrument knobs: pitch (semitone transpose of the tonal atoms;
           residual not transposed) and density (rank gate — how many atoms sound). */
        "PITCH = 2.0 ^ (hslider(\"h:quanta/[4]pitch [unit:st]\",0,-24,24,0.01) / 12.0) : si.smoo;\n"
        "Kd = hslider(\"h:quanta/[5]density [unit:atoms]\",%u,0,%u,1);\n",
        maxrank + 1u, maxrank + 1u);
    fprintf(o, "FR = %u;\nfpos = float(tim)/%.17g;\n"
        "ef0 = min(int(fpos), FR-1);\nef1 = min(ef0+1, FR-1);\nefr = fpos - float(ef0);\n\n",
        FR, (double)q.h.residual_hop);

    if (cc <= 1){
        uint32_t *voff = calloc((size_t)P + 1, sizeof(uint32_t));
        for (uint32_t i = 0; i < m; i++) voff[q.atoms[i].voice + 1]++;
        for (int v = 0; v < P; v++) voff[v+1] += voff[v];
        emit_channel(o, "", q.atoms, voff, P, q.res_gains, FR, q.h.sample_rate, q.h.noise_seed, verify);
        if (cres_on){                                    /* atoms-only + stored true residual */
            emit_cres(o, "cres", q.cres, N, q.cres_scale[0]);
            fprintf(o, "process = (vsum%s : dcb) + cres;\n", verify ? "" : " * gm");
        } else
            fprintf(o, "process = (vsum + res%s)%s : dcb;\n",
                    verify ? "" : "*g2", verify ? "" : " * gm");
        free(voff);
    } else {
        uint32_t split = 0; while (split < m && !(q.atoms[split].flags & 1)) split++;
        const QscAtom *Ma = q.atoms, *Sa = q.atoms + split;
        uint32_t nM = split, nS = m - split;
        size_t gblk = (size_t)FR * QSC_BANDS;
        uint32_t *voffM = calloc((size_t)P + 1, sizeof(uint32_t));
        uint32_t *voffS = calloc((size_t)P + 1, sizeof(uint32_t));
        for (uint32_t i = 0; i < nM; i++) voffM[Ma[i].voice + 1]++;
        for (uint32_t i = 0; i < nS; i++) voffS[Sa[i].voice + 1]++;
        for (int v = 0; v < P; v++){ voffM[v+1] += voffM[v]; voffS[v+1] += voffS[v]; }
        emit_channel(o, "M", Ma, voffM, P, q.res_gains,        FR, q.h.sample_rate, q.h.noise_seed, verify);
        emit_channel(o, "S", Sa, voffS, P, q.res_gains + gblk, FR, q.h.sample_rate,
                     q.h.noise_seed ^ QSC_SIDE_SEED_XOR, verify);
        if (cres_on){
            emit_cres(o, "Mcres", q.cres,   N, q.cres_scale[0]);
            emit_cres(o, "Scres", q.cres+N, N, q.cres_scale[1]);
            fprintf(o,
                "Mout = (Mvsum%s : dcb) + Mcres;\n"
                "Sout = (Svsum%s : dcb) + Scres;\n"
                "process = (Mout + Sout, Mout - Sout);\n",
                verify ? "" : " * gm", verify ? "" : " * gm");
        } else
            fprintf(o,
                "Mout = (Mvsum + Mres%s)%s : dcb;\n"
                "Sout = (Svsum + Sres%s)%s : dcb;\n"
                "process = (Mout + Sout, Mout - Sout);\n",
                verify ? "" : "*g2", verify ? "" : " * gm",
                verify ? "" : "*g2", verify ? "" : " * gm");
        free(voffM); free(voffS);
        (void)nS;
    }

    fclose(o);
    fprintf(stderr, "freeze: %u atoms across %d voices -> %s%s (%s)\n",
            m, P, outpath, verify ? " [verify]" : "", cc >= 2 ? "stereo" : "mono");
    qsc_free(&q);
    return 0;
}
