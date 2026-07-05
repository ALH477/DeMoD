/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-DeMoD-Commercial
 * mp.h — shared matching-pursuit core (FFT, per-scale caches, onsets).
 * Used by quanta-analyzer (offline) and quanta-stream (streaming profile).
 * Copyright (c) 2026 DeMoD LLC. Extracted verbatim from analyzer.c v0.1.0.
 */
#ifndef DEMOD_MP_H
#define DEMOD_MP_H
#include "qsc.h"

static void fft(double *re, double *im, int n){
    for (int i = 1, j = 0; i < n; i++){
        int bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j |= bit;
        if (i < j){ double t=re[i];re[i]=re[j];re[j]=t; t=im[i];im[i]=im[j];im[j]=t; }
    }
    for (int len = 2; len <= n; len <<= 1){
        double ang = -2.0 * M_PI / len;
        double wr = cos(ang), wi = sin(ang);
        for (int i = 0; i < n; i += len){
            double cr = 1.0, ci = 0.0;
            for (int k = 0; k < len/2; k++){
                int a = i + k, b = i + k + len/2;
                double ur = re[a], ui = im[a];
                double vr = re[b]*cr - im[b]*ci, vi = re[b]*ci + im[b]*cr;
                re[a]=ur+vr; im[a]=ui+vi; re[b]=ur-vr; im[b]=ui-vi;
                double ncr = cr*wr - ci*wi; ci = cr*wi + ci*wr; cr = ncr;
            }
        }
    }
}

/* ---------- per-scale frame cache ---------- */
typedef struct {
    int    scale, hop, nframes;
    double *win;          /* discrete synthesis window, table-sampled  */
    double  e2;           /* sum win^2                                 */
    double *best_score;   /* per frame: max |X_k|^2 / e2               */
    int    *best_bin;
    double *pa, *pb, *pc; /* |X| at bin-1, bin, bin+1 (parabolic)      */
} ScaleCache;

static double g_wtab[QSC_TAB], g_stab[QSC_TAB];

static void frame_analyze(ScaleCache *sc, const double *r, uint64_t N, int f,
                          double *re, double *im, int gated){
    int s = sc->scale; uint32_t u = (uint32_t)f * sc->hop;
    if (gated){ sc->best_score[f] = 0.0; sc->best_bin[f] = 0; return; }
    for (int i = 0; i < s; i++){
        double v = (u + (uint64_t)i < N) ? r[u+i] : 0.0;
        re[i] = v * sc->win[i]; im[i] = 0.0;
    }
    fft(re, im, s);
    double bm = 0.0; int bk = 1;
    for (int k = 1; k < s/2; k++){
        double m = re[k]*re[k] + im[k]*im[k];
        if (m > bm){ bm = m; bk = k; }
    }
    sc->best_score[f] = bm / sc->e2;
    sc->best_bin[f]   = bk;
    int km = bk>1 ? bk-1 : 1, kp = bk<s/2-1 ? bk+1 : s/2-1;
    sc->pa[f] = sqrt(re[km]*re[km]+im[km]*im[km]);
    sc->pb[f] = sqrt(bm);
    sc->pc[f] = sqrt(re[kp]*re[kp]+im[kp]*im[kp]);
}

/* ---------- onset detection: spectral flux, 1024/256 ---------- */
static int detect_onsets(const double *x, uint64_t N, uint32_t sr,
                         uint32_t **out){
    const int W = 1024, H = 256;
    int nf = N > (uint64_t)W ? (int)((N - W)/H) + 1 : 0;
    if (nf < 3){ *out = NULL; return 0; }
    double *re = malloc(sizeof(double)*W), *im = malloc(sizeof(double)*W);
    double *pm = calloc(W/2, sizeof(double));
    double *flux = calloc(nf, sizeof(double));
    for (int f = 0; f < nf; f++){
        for (int i = 0; i < W; i++){
            double h = 0.5 - 0.5*cos(2.0*M_PI*i/(W-1));
            re[i] = x[(uint64_t)f*H + i] * h; im[i] = 0.0;
        }
        fft(re, im, W);
        double fl = 0.0;
        for (int k = 1; k < W/2; k++){
            double m = sqrt(re[k]*re[k]+im[k]*im[k]);
            double d = m - pm[k]; if (d > 0) fl += d;
            pm[k] = m;
        }
        flux[f] = fl;
    }
    double mu=0, sd=0;
    for (int f=0; f<nf; f++) mu += flux[f]; mu /= nf;
    for (int f=0; f<nf; f++){ double d=flux[f]-mu; sd += d*d; } sd = sqrt(sd/nf);
    double thr = mu + 2.0*sd;
    uint32_t *on = malloc(sizeof(uint32_t)*nf); int no = 0;
    int gap = (int)(0.05*sr)/H;                       /* 50 ms min gap */
    for (int f = 1; f < nf-1; f++)
        if (flux[f] > thr && flux[f] >= flux[f-1] && flux[f] >= flux[f+1])
            if (no == 0 || (int)f - (int)(on[no-1]/H) >= gap)
                on[no++] = (uint32_t)f * H + W/2;
    free(re);free(im);free(pm);free(flux);
    *out = on; return no;
}

static int near_onset(uint32_t center, const uint32_t *on, int no, uint32_t win){
    for (int i = 0; i < no; i++){
        uint32_t d = center > on[i] ? center - on[i] : on[i] - center;
        if (d <= win) return 1;
    }
    return 0;
}

#endif /* DEMOD_MP_H */
