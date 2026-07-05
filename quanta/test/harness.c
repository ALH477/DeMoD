/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-DeMoD-Commercial
 * Offline render harness for faust -lang c output (class name "quanta").
 * Usage: harness N_SAMPLES SR out.f64 out.wav
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
    double *out = calloc(N, sizeof(double));
    for (uint64_t off = 0; off < N; off += 512){
        int cnt = (int)((N - off) < 512 ? (N - off) : 512);
        FAUSTFLOAT *outs[1] = { out + off };
        computequanta(d, cnt, NULL, outs);
    }
    raw_write_f64(argv[3], out, N);
    wav_write16(argv[4], out, N, (uint32_t)sr);
    double pk = 0; for (uint64_t i = 0; i < N; i++){ double a = fabs(out[i]); if (a > pk) pk = a; }
    fprintf(stderr, "harness: %llu samples, peak %.3f\n", (unsigned long long)N, pk);
    deletequanta(d);
    free(out);
    return 0;
}
