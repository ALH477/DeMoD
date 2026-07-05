/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-DeMoD-Commercial
 * quanta-render — QSC reference renderer (spec §6 semantics, exploration player)
 * Copyright (c) 2026 DeMoD LLC.
 *
 * This is the normative audio path: table-based transcendentals only,
 * no libm per-sample, fixed summation order (voices 0..P-1, then bands
 * 0..23, then master). Frozen Faust output must null against this.
 */
#include "../include/qsc.h"

int main(int argc, char **argv){
    const char *inpath=NULL, *wavout=NULL, *rawout=NULL;
    uint32_t K = 0xFFFFFFFF;
    double lg[3] = {1.0,1.0,1.0}, master = 1.0;
    for (int i=1;i<argc;i++){
        if (!strcmp(argv[i],"--k")&&i+1<argc) K=(uint32_t)strtoul(argv[++i],0,0);
        else if (!strcmp(argv[i],"--wav")&&i+1<argc) wavout=argv[++i];
        else if (!strcmp(argv[i],"--raw")&&i+1<argc) rawout=argv[++i];
        else if (!strcmp(argv[i],"--master")&&i+1<argc) master=atof(argv[++i]);
        else if (!strcmp(argv[i],"--g0")&&i+1<argc) lg[0]=atof(argv[++i]);
        else if (!strcmp(argv[i],"--g1")&&i+1<argc) lg[1]=atof(argv[++i]);
        else if (!strcmp(argv[i],"--g2")&&i+1<argc) lg[2]=atof(argv[++i]);
        else inpath=argv[i];
    }
    if (!inpath){ fprintf(stderr,"usage: quanta-render in.qsc [--k N] [--wav o.wav] [--raw o.f64]\n"); return 2; }

    Qsc q;
    int rc = qsc_read(inpath, &q);
    if (rc){ fprintf(stderr,"render: qsc_read failed (%d)\n", rc); return 1; }

    double wtab[QSC_TAB], stab[QSC_TAB];
    qsc_build_tables(wtab, stab);
    uint64_t N = q.h.source_len;
    double sr = (double)q.h.sample_rate;
    double *out = calloc(N, sizeof(double));

    /* per-voice atom ranges (records grouped by voice, onset-sorted) */
    int P = q.h.voice_count;
    uint32_t *voff = calloc(P+1, sizeof(uint32_t));
    for (uint32_t i=0;i<q.h.atom_count;i++) voff[q.atoms[i].voice + 1]++;
    for (int v=0;v<P;v++) voff[v+1]+=voff[v];

    /* ------- voice bank: fixed order v=0..P-1 (§12.4) ------- */
    for (int v=0; v<P; v++){
        uint32_t idx = voff[v], end = voff[v+1];
        for (uint64_t t=0; t<N; t++){
            while (idx+1 < end && t >= q.atoms[idx+1].onset) idx++;
            if (idx >= end) break;
            const QscAtom *a = &q.atoms[idx];
            if (a->rank >= K) continue;
            int64_t tl = (int64_t)t - (int64_t)a->onset;
            if (tl < 0 || tl >= (int64_t)a->dur) continue;
            double x   = (double)tl / (double)a->dur;
            double win = qsc_wlin(wtab, x * QSC_TAB);
            double ph  = (double)a->freq * (double)tl / sr
                       + (double)a->phase * (1.0/(2.0*M_PI));
            double phf = ph - (double)(int64_t)ph;          /* ph >= 0 */
            double sv  = qsc_slin(stab, phf * QSC_TAB);
            out[t] += (double)a->amp * win * sv * lg[a->layer];
        }
    }

    /* ------- residual: seeded LCG -> 24-band SVF, env interp ------- */
    if (q.h.residual_frames){
        QscSvf f[QSC_BANDS];
        for (int b=0;b<QSC_BANDS;b++) qsc_svf_init(&f[b], qsc_band_fc(b), QSC_BAND_Q, sr);
        int32_t st = 0;
        uint32_t FR = q.h.residual_frames, HB = q.h.residual_hop;
        for (uint64_t t=0; t<N; t++){
            st = qsc_lcg_step(st, (int32_t)q.h.noise_seed);
            double nz = qsc_lcg_out(st);
            double fpos = (double)t / (double)HB;
            uint32_t f0 = (uint32_t)fpos; if (f0 > FR-1) f0 = FR-1;
            uint32_t f1 = f0+1 < FR ? f0+1 : FR-1;
            double fr = fpos - (double)f0;
            double acc = 0.0;
            for (int b=0;b<QSC_BANDS;b++){
                double g0 = qsc_gain_dq(q.res_gains[(size_t)f0*QSC_BANDS+b]);
                double g1 = qsc_gain_dq(q.res_gains[(size_t)f1*QSC_BANDS+b]);
                acc += qsc_svf_bp(&f[b], nz) * (g0 + fr*(g1-g0));
            }
            out[t] += acc * lg[2];
        }
    }

    /* ------- master + dc blocker (matches fi.dcblocker: pole 0.995) ------- */
    {
        double x1=0.0, y1=0.0;
        for (uint64_t t=0;t<N;t++){
            double x = out[t]*master;
            double y = x - x1 + 0.995*y1;
            x1 = x; y1 = y; out[t] = y;
        }
    }

    if (wavout) wav_write16(wavout, out, N, q.h.sample_rate);
    if (rawout) raw_write_f64(rawout, out, N);
    double pk=0; for (uint64_t t=0;t<N;t++){ double a=fabs(out[t]); if(a>pk)pk=a; }
    fprintf(stderr,"render: %u atoms (K=%u) P=%d | %llu samples | peak %.3f\n",
            q.h.atom_count, K, P, (unsigned long long)N, pk);
    qsc_free(&q); free(out); free(voff);
    return 0;
}
