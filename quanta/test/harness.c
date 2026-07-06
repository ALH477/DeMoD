/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-DeMoD-Commercial
 * Offline render harness for faust -lang c output (class name "quanta").
 * Usage: harness N_SAMPLES SR out.f64 out.wav
 * Mono (1 output) writes one channel; stereo (2 outputs) writes interleaved
 * L,R f64 (matching `quanta-render --raw` for a stereo .qsc).
 */
#define FAUSTFLOAT double
#include "../include/qsc.h"
#include "gen.c"

int main(int argc, char **argv){
    if (argc < 5){ fprintf(stderr, "harness N SR out.f64 out.wav\n"); return 2; }
    uint64_t N = strtoull(argv[1], 0, 0);
    int sr = atoi(argv[2]);
    quanta *d = newquanta();
    initquanta(d, sr);
    int nout = getNumOutputsquanta(d);
    double *o0 = calloc(N, sizeof(double));
    double *o1 = (nout > 1) ? calloc(N, sizeof(double)) : NULL;
    for (uint64_t off = 0; off < N; off += 512){
        int cnt = (int)((N - off) < 512 ? (N - off) : 512);
        FAUSTFLOAT *outs[2] = { o0 + off, o1 ? o1 + off : NULL };
        computequanta(d, cnt, NULL, outs);
    }
    if (nout > 1){                                       /* stereo: interleaved L,R f64 */
        double *il = malloc(sizeof(double) * 2 * N);
        for (uint64_t i = 0; i < N; i++){ il[2*i] = o0[i]; il[2*i+1] = o1[i]; }
        raw_write_f64(argv[3], il, 2*N);
        for (uint64_t i = 0; i < N; i++){ double L=o0[i], R=o1[i]; o0[i]=0.5*(L+R); o1[i]=0.5*(L-R); }
        wav_write16_ms(argv[4], o0, o1, N, (uint32_t)sr);
        free(il);
    } else {
        raw_write_f64(argv[3], o0, N);
        wav_write16(argv[4], o0, N, (uint32_t)sr);
    }
    double pk = 0; for (uint64_t i = 0; i < N; i++){ double a = fabs(o0[i]); if (a > pk) pk = a; }
    fprintf(stderr, "harness: %llu samples, %d out, peak %.3f\n", (unsigned long long)N, nout, pk);
    deletequanta(d);
    free(o0); free(o1);
    return 0;
}
