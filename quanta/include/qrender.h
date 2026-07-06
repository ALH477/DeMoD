/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-DeMoD-Commercial
 * qrender.h — the normative per-channel audio path, shared by src/render.c (the
 * reference player) and src/analyzer.c (so the coherent-residual encoder computes
 * its atoms-only reference with EXACTLY the renderer's arithmetic — zero drift, the
 * §12 determinism contract). freeze.c mirrors this expression-by-expression in Faust.
 * Copyright (c) 2026 DeMoD LLC.
 */
#ifndef QRENDER_H
#define QRENDER_H
#include "qsc.h"

/* Render one channel's voice bank + (optional) 24-band noise residual into out[0..N).
   FR==0 skips the noise layer — that atoms-only output, DC-blocked, is the reference
   the coherent residual is measured against. Identical arithmetic to the historical
   mono path; stereo calls it for M then S (S residual seed decorrelated by caller). */
static inline void render_channel(const QscAtom *at, uint32_t nat, int P, uint32_t K,
                                  const uint16_t *gains, uint32_t FR, uint32_t HB, uint32_t seed,
                                  uint64_t N, double sr, const double *lg,
                                  const double *wtab, const double *stab, double *out){
    for (uint64_t t=0;t<N;t++) out[t]=0.0;
    uint32_t *voff = calloc((size_t)P+1, sizeof(uint32_t));
    for (uint32_t i=0;i<nat;i++) voff[at[i].voice + 1]++;
    for (int v=0;v<P;v++) voff[v+1]+=voff[v];

    for (int v=0; v<P; v++){                              /* fixed order v=0..P-1 (§12.4) */
        uint32_t idx = voff[v], end = voff[v+1];
        for (uint64_t t=0; t<N; t++){
            while (idx+1 < end && t >= at[idx+1].onset) idx++;
            if (idx >= end) break;
            const QscAtom *a = &at[idx];
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
    if (FR){                                              /* seeded LCG -> 24-band SVF */
        QscSvf f[QSC_BANDS];
        for (int b=0;b<QSC_BANDS;b++) qsc_svf_init(&f[b], qsc_band_fc(b), QSC_BAND_Q, sr);
        int32_t st = 0;
        for (uint64_t t=0; t<N; t++){
            st = qsc_lcg_step(st, (int32_t)seed);
            double nz = qsc_lcg_out(st);
            double fpos = (double)t / (double)HB;
            uint32_t f0 = (uint32_t)fpos; if (f0 > FR-1) f0 = FR-1;
            uint32_t f1 = f0+1 < FR ? f0+1 : FR-1;
            double fr = fpos - (double)f0;
            double acc = 0.0;
            for (int b=0;b<QSC_BANDS;b++){
                double g0 = qsc_gain_dq(gains[(size_t)f0*QSC_BANDS+b]);
                double g1 = qsc_gain_dq(gains[(size_t)f1*QSC_BANDS+b]);
                acc += qsc_svf_bp(&f[b], nz) * (g0 + fr*(g1-g0));
            }
            out[t] += acc * lg[2];
        }
    }
    free(voff);
}

/* master gain + DC blocker (fi.dcblocker: pole 0.995), in place. */
static inline void master_dcblock(double *out, uint64_t N, double master){
    double x1=0.0, y1=0.0;
    for (uint64_t t=0;t<N;t++){
        double x = out[t]*master;
        double y = x - x1 + 0.995*y1;
        x1 = x; y1 = y; out[t] = y;
    }
}
#endif
