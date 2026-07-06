/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-DeMoD-Commercial
 * quanta-analyzer — hybrid Gabor matching pursuit, WAV -> QSC (spec §4)
 * Copyright (c) 2026 DeMoD LLC.
 *
 * Offline tool: libm allowed here (spec §12 restricts the *audio path*).
 * Determinism: fixed iteration order — scale-major frame scan, ties broken
 * by lower scale, then lower frame index, then lower bin (§4.3).
 */
#include "../include/qsc.h"

/* ---------- iterative radix-2 complex FFT (double) ---------- */
#include "../include/mp.h"

/* ---------- voice assignment: greedy interval coloring (§4.7) ---------- */
static int cmp_voice_onset(const void *a, const void *b){
    const QscAtom *x=a, *y=b;
    if (x->voice != y->voice) return x->voice < y->voice ? -1 : 1;
    if (x->onset != y->onset) return x->onset < y->onset ? -1 : 1;
    return 0;
}

/* per-channel analysis result */
typedef struct {
    QscAtom  *fa; int m;         /* kept atoms (voice-grouped, onset-sorted) + count */
    uint16_t *gains; uint32_t frames;
    int P, no, dropped;
    double e_res, e_src;
} ChanResult;

/* Matching pursuit + residual model for one channel signal r[0..N) (modified in
   place). This is the original mono path, extracted verbatim so it can be run once
   (mono) or twice (mid + side) for stereo. Caller owns/frees r, result.fa,
   result.gains. */
static ChanResult analyze_channel(double *r, uint64_t N, uint32_t sr,
                                  int Kmax, double snr_db, double floor_amp){
    ChanResult R = {0};
    double e_src = 0.0; for (uint64_t i=0;i<N;i++) e_src += r[i]*r[i];
    double e_stop = e_src * pow(10.0, -snr_db/10.0);

    uint32_t *onsets; int no = detect_onsets(r, N, sr, &onsets);
    uint32_t ogate = (uint32_t)(0.020 * sr);             /* ±20 ms */

    /* build per-scale caches */
    ScaleCache sc[QSC_SCALES]; int maxs = QSC_SCALE_TAB[QSC_SCALES-1];
    double *re = malloc(sizeof(double)*maxs), *im = malloc(sizeof(double)*maxs);
    for (int si = 0; si < QSC_SCALES; si++){
        int s = QSC_SCALE_TAB[si];
        sc[si].scale = s; sc[si].hop = s/4;
        sc[si].nframes = N > (uint64_t)s ? (int)((N - s)/sc[si].hop) + 1 : 0;
        sc[si].win = malloc(sizeof(double)*s);
        sc[si].e2 = 0.0;
        for (int i = 0; i < s; i++){
            sc[si].win[i] = qsc_wlin(g_wtab, (double)i / s * QSC_TAB);
            sc[si].e2 += sc[si].win[i]*sc[si].win[i];
        }
        int nf = sc[si].nframes;
        sc[si].best_score = calloc(nf?nf:1, sizeof(double));
        sc[si].best_bin   = calloc(nf?nf:1, sizeof(int));
        sc[si].pa = calloc(nf?nf:1, sizeof(double));
        sc[si].pb = calloc(nf?nf:1, sizeof(double));
        sc[si].pc = calloc(nf?nf:1, sizeof(double));
        for (int f = 0; f < nf; f++){
            int gated = (s <= 256) &&
                        !near_onset((uint32_t)f*sc[si].hop + s/2, onsets, no, ogate);
            frame_analyze(&sc[si], r, N, f, re, im, gated);
        }
    }

    /* ---------- pursuit loop ---------- */
    QscAtom *atoms = malloc(sizeof(QscAtom)*Kmax);
    int K = 0; double e_res = e_src;
    while (K < Kmax && e_res > e_stop){
        int bsi=-1, bf=-1; double bscore = 0.0;
        for (int si = 0; si < QSC_SCALES; si++)
            for (int f = 0; f < sc[si].nframes; f++)
                if (sc[si].best_score[f] > bscore){
                    bscore = sc[si].best_score[f]; bsi = si; bf = f;
                }
        if (bsi < 0) break;
        ScaleCache *S = &sc[bsi];
        int s = S->scale; uint32_t u = (uint32_t)bf * S->hop;
        /* parabolic bin refinement (magnitude) */
        double pa=S->pa[bf], pb=S->pb[bf], pc=S->pc[bf];
        double den = pa - 2.0*pb + pc;
        double d = (fabs(den) > 1e-12) ? 0.5*(pa - pc)/den : 0.0;
        if (d < -0.5) d = -0.5; if (d > 0.5) d = 0.5;
        double f_hz = ((double)S->best_bin[bf] + d) * (double)sr / s;
        /* exact LS fit of amp*win*sin(theta + phase) at refined f */
        double om = 2.0*M_PI*f_hz/sr;
        double A=0,B=0,C=0,rc=0,rs=0;
        for (int i = 0; i < s; i++){
            double th = om*i, cth = cos(th), sth = sin(th);
            double w = S->win[i], z = (u+(uint64_t)i<N ? r[u+i] : 0.0)*w;
            A += w*w*cth*cth; B += w*w*cth*sth; C += w*w*sth*sth;
            rc += z*cth; rs += z*sth;
        }
        double det = A*C - B*B; if (fabs(det) < 1e-18){ S->best_score[bf]=0; continue; }
        double p = ( C*rc - B*rs)/det, q = (-B*rc + A*rs)/det;
        double amp = sqrt(p*p + q*q);
        if (amp < floor_amp) break;                       /* salience floor */
        double phase = atan2(p, q);                       /* p cos + q sin = a sin(th+psi) */
        if (phase < 0) phase += 2.0*M_PI;
        double de = 0.0;
        for (int i = 0; i < s && u+(uint64_t)i < N; i++){
            double th = om*i;
            double m = (p*cos(th) + q*sin(th)) * S->win[i];
            de += m*(2.0*r[u+i] - m);
            r[u+i] -= m;
        }
        e_res -= de; if (e_res < 0) e_res = 0;
        QscAtom *a = &atoms[K];
        a->rank=(uint32_t)K; a->onset=u; a->dur=(uint32_t)s;
        a->freq=(float)f_hz; a->amp=(float)amp; a->phase=(float)phase; a->chirp=0.f;
        a->layer = (s <= 256) ? 1 : 0; a->voice=0;
        a->scale_idx=(uint8_t)bsi; a->flags=0;
        K++;
        /* dirty-frame recompute across all scales (§4.3 locality) */
        for (int si = 0; si < QSC_SCALES; si++){
            ScaleCache *T = &sc[si];
            long lo = ((long)u - T->scale)/T->hop + 1; if (lo < 0) lo = 0;
            long hi = ((long)u + s)/T->hop;
            if (hi >= T->nframes) hi = T->nframes - 1;
            for (long f = lo; f <= hi; f++){
                int gated = (T->scale <= 256) &&
                    !near_onset((uint32_t)f*T->hop + T->scale/2, onsets, no, ogate);
                frame_analyze(T, r, N, (int)f, re, im, gated);
            }
        }
    }

    /* ---------- voice assignment (§4.7): rank-priority first-fit over
       per-voice interval sets. High-salience atoms always win a voice; when
       P_max overflows, the culled (lowest-salience) atoms have their
       waveforms returned to the residual so the noise layer absorbs them
       and total energy accounting stays closed. ---------------------------- */
    typedef struct { uint32_t s, e; } Iv;
    Iv  *viv[QSC_PMAX]; int vn[QSC_PMAX] = {0}, vcap[QSC_PMAX] = {0};
    int P = 0, dropped = 0, kept = 0;
    double e_drop = 0.0;
    for (int i = 0; i < K; i++){                 /* atoms[] is in rank order */
        uint32_t s0 = atoms[i].onset, e0 = s0 + atoms[i].dur;
        int v = -1;
        for (int j = 0; j < P && v < 0; j++){
            int clash = 0;
            for (int t = 0; t < vn[j]; t++)
                if (s0 < viv[j][t].e && viv[j][t].s < e0){ clash = 1; break; }
            if (!clash) v = j;
        }
        if (v < 0 && P < QSC_PMAX){
            v = P; vcap[v] = 16; viv[v] = malloc(vcap[v]*sizeof(Iv)); P++;
        }
        if (v < 0){                              /* cull: return energy to r */
            atoms[i].voice = 0xFF; dropped++;
            int sd = (int)atoms[i].dur, sidx = atoms[i].scale_idx;
            double om = 2.0*M_PI*(double)atoms[i].freq/sr;
            double a0 = atoms[i].amp, p0 = atoms[i].phase;
            for (int j = 0; j < sd && s0+(uint64_t)j < N; j++){
                double mval = a0 * sin(om*j + p0) * sc[sidx].win[j];
                r[s0+j] += mval; e_drop += mval*mval;
            }
            continue;
        }
        if (vn[v] == vcap[v]){ vcap[v]*=2; viv[v]=realloc(viv[v], vcap[v]*sizeof(Iv)); }
        viv[v][vn[v]].s = s0; viv[v][vn[v]].e = e0; vn[v]++;
        atoms[i].voice = (uint8_t)v; kept++;
    }
    for (int j = 0; j < P; j++) free(viv[j]);
    (void)e_drop;

    /* ---------- residual model (§4.5): unity-peak band envelopes / rho_b, with a
       causal per-frame trim (E_synth ~= gᵀCg) plus a per-frame tonality scale that
       suppresses the noise floor on tonal frames. Encoder-only; freeze/null parity
       untouched. ------------------------------------------------------------- */
    uint32_t frames = (uint32_t)((N + QSC_RES_HOP - 1)/QSC_RES_HOP);
    uint16_t *gains = calloc((size_t)frames*QSC_BANDS, sizeof(uint16_t));
    {
        double C[QSC_BANDS][QSC_BANDS]; qsc_band_coherence(C, sr);
        double rho[QSC_BANDS];
        QscSvf f[QSC_BANDS];
        for (int b = 0; b < QSC_BANDS; b++){
            qsc_svf_init(&f[b], qsc_band_fc(b), QSC_BAND_Q, sr);
            f[b].ic1 = f[b].ic2 = 0.0;
            rho[b] = sqrt(C[b][b]); if (rho[b] < 1e-9) rho[b] = 1e-9;
        }
        double *genv = calloc((size_t)frames*QSC_BANDS, sizeof(double));
        double *ef   = calloc(frames ? frames : 1, sizeof(double));
        double *tsf  = calloc(frames ? frames : 1, sizeof(double));
        double acc[QSC_BANDS] = {0}; double eacc = 0.0;
        for (uint64_t i = 0; i < N; i++){
            eacc += r[i]*r[i];
            for (int b = 0; b < QSC_BANDS; b++){
                double y = qsc_svf_bp(&f[b], r[i]);
                acc[b] += y*y;
            }
            if ((i+1) % QSC_RES_HOP == 0 || i+1 == N){
                uint32_t fr = (uint32_t)(i/QSC_RES_HOP);
                uint64_t cnt = (i % QSC_RES_HOP) + 1;
                for (int b = 0; b < QSC_BANDS; b++)
                    genv[(size_t)fr*QSC_BANDS + b] = sqrt(acc[b]/cnt)/rho[b];
                ef[fr]  = eacc/cnt;
                tsf[fr] = residual_tonal_scale(acc, QSC_BANDS);
                for (int b = 0; b < QSC_BANDS; b++) acc[b] = 0;
                eacc = 0.0;
            }
        }
        for (uint32_t fr = 0; fr < frames; fr++){
            double *g = &genv[(size_t)fr*QSC_BANDS];
            double gCg = 0.0;
            for (int b = 0; b < QSC_BANDS; b++){ double row = 0.0;
                for (int c = 0; c < QSC_BANDS; c++) row += C[b][c]*g[c];
                gCg += g[b]*row; }
            double trim = (gCg > 1e-30) ? sqrt(ef[fr]/gCg) : 1.0;
            for (int b = 0; b < QSC_BANDS; b++)
                gains[(size_t)fr*QSC_BANDS + b] = qsc_gain_q(g[b]*trim*tsf[fr]);
        }
        free(genv); free(ef); free(tsf);
    }

    QscAtom *fa = malloc(sizeof(QscAtom)*(kept?kept:1)); int m = 0;
    for (int i = 0; i < K; i++) if (atoms[i].voice != 0xFF) fa[m++] = atoms[i];
    qsort(fa, m, sizeof(QscAtom), cmp_voice_onset);

    for (int si=0; si<QSC_SCALES; si++){ free(sc[si].win); free(sc[si].best_score);
        free(sc[si].best_bin); free(sc[si].pa); free(sc[si].pb); free(sc[si].pc); }
    free(re); free(im); free(onsets); free(atoms);

    R.fa=fa; R.m=m; R.gains=gains; R.frames=frames;
    R.P=P; R.no=no; R.dropped=dropped; R.e_res=e_res; R.e_src=e_src;
    return R;
}

int main(int argc, char **argv){
    const char *inpath = NULL, *outpath = "score.qsc";
    int Kmax = 2048; double snr_db = 35.0, floor_amp = 1e-4; uint32_t seed = 0xDEC0DE;
    double quality = -1.0; int stereo = 0;
    for (int i = 1; i < argc; i++){
        if (!strcmp(argv[i], "-o") && i+1<argc) outpath = argv[++i];
        else if (!strcmp(argv[i], "--k") && i+1<argc) Kmax = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--snr") && i+1<argc) snr_db = atof(argv[++i]);
        else if (!strcmp(argv[i], "--quality") && i+1<argc) quality = atof(argv[++i]);
        else if (!strcmp(argv[i], "--stereo")) stereo = 1;
        else if (!strcmp(argv[i], "--seed") && i+1<argc) seed = (uint32_t)strtoul(argv[++i],0,0);
        else inpath = argv[i];
    }
    if (quality >= 0.0){
        if (quality > 10.0) quality = 10.0;
        snr_db = 30.0 + 3.0*quality; Kmax = 16384;
        fprintf(stderr, "  --quality %.1f -> snr target %.0f dB, k<=%d\n", quality, snr_db, Kmax);
    }
    if (!inpath){ fprintf(stderr,
        "usage: quanta-analyzer in.wav [-o out.qsc] [--k N] [--snr dB] [--quality 0..10] [--stereo]\n");
        return 2; }

    qsc_build_tables(g_wtab, g_stab);
    uint32_t sr; double *M=NULL, *Sd=NULL;
    uint64_t N = wav_read_ms(inpath, &sr, &M, &Sd);
    if (!N){ fprintf(stderr, "analyzer: cannot read %s\n", inpath); return 1; }
    if (sr != 48000) fprintf(stderr, "analyzer: note: sr=%u (canonical is 48000; proceeding)\n", sr);

    double es = 0.0; for (uint64_t i=0;i<N;i++) es += Sd[i]*Sd[i];
    int do_stereo = stereo && es > 1e-9;                  /* opt-in + non-trivial side */

    ChanResult cm = analyze_channel(M, N, sr, Kmax, snr_db, floor_amp);
    Qsc q = {0};
    q.h.sample_rate=sr; q.h.source_len=N; q.h.scale_count=QSC_SCALES;
    q.h.band_count=QSC_BANDS; q.h.residual_hop=QSC_RES_HOP;
    q.h.residual_frames=cm.frames; q.h.noise_seed=seed;

    if (!do_stereo){
        q.h.channel_count=1; q.h.atom_count=(uint32_t)cm.m; q.h.voice_count=(uint16_t)cm.P;
        q.atoms=cm.fa; q.res_gains=cm.gains;
        if (qsc_write(outpath,&q)){ fprintf(stderr,"analyzer: write failed\n"); return 1; }
        fprintf(stderr,
            "analyzer: %s (mono)\n  %llu samples @ %u Hz | atoms %d (dropped %d) | voices %d\n"
            "  onsets %d | residual %+.2f dB re source | seed 0x%08X -> %s\n",
            inpath, (unsigned long long)N, sr, cm.m, cm.dropped, cm.P, cm.no,
            10.0*log10(cm.e_res/cm.e_src + 1e-30), seed, outpath);
        free(cm.fa); free(cm.gains);
    } else {
        ChanResult cs = analyze_channel(Sd, N, sr, Kmax, snr_db, floor_amp);
        int tot = cm.m + cs.m;
        QscAtom *all = malloc(sizeof(QscAtom)*(tot?tot:1));
        for (int i=0;i<cm.m;i++){ all[i]        = cm.fa[i]; all[i].flags        &= (uint8_t)~1; }   /* mid  = flag bit0 = 0 */
        for (int i=0;i<cs.m;i++){ all[cm.m+i]   = cs.fa[i]; all[cm.m+i].flags   |= 1; }              /* side = flag bit0 = 1 */
        uint32_t fr = cm.frames;                            /* == cs.frames (same N) */
        uint16_t *ag = malloc((size_t)fr*QSC_BANDS*2*sizeof(uint16_t));
        memcpy(ag,                        cm.gains, (size_t)fr*QSC_BANDS*sizeof(uint16_t));
        memcpy(ag+(size_t)fr*QSC_BANDS,   cs.gains, (size_t)fr*QSC_BANDS*sizeof(uint16_t));
        q.h.channel_count=2; q.h.atom_count=(uint32_t)tot;
        q.h.voice_count=(uint16_t)(cm.P>cs.P?cm.P:cs.P);
        q.h.residual_frames=fr; q.atoms=all; q.res_gains=ag;
        if (qsc_write(outpath,&q)){ fprintf(stderr,"analyzer: write failed\n"); return 1; }
        fprintf(stderr,
            "analyzer: %s (mid/side stereo)\n"
            "  %llu samples @ %u Hz | atoms M=%d S=%d (dropped M=%d S=%d) | voices M=%d S=%d\n"
            "  residual M %+.2f dB / S %+.2f dB | seed 0x%08X -> %s\n",
            inpath, (unsigned long long)N, sr, cm.m, cs.m, cm.dropped, cs.dropped, cm.P, cs.P,
            10.0*log10(cm.e_res/cm.e_src + 1e-30),
            10.0*log10(cs.e_res/(cs.e_src + 1e-30) + 1e-30), seed, outpath);
        free(cm.fa); free(cm.gains); free(cs.fa); free(cs.gains); free(all); free(ag);
    }
    free(M); free(Sd);
    return 0;
}
