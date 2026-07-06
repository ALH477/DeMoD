/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-DeMoD-Commercial
 * fuzz.c — deterministic fuzzer for the QSS packet reader (spec §S, ROADMAP 4.2).
 * Mutates a valid .qss (flips, truncation, sync injection, band_count fuzzing) and
 * drives qss_read_header + qss2_next_packet. Compile with -fsanitize=address,undefined;
 * any OOB / UB aborts. Malformed streams must degrade to dropped packets, never crash.
 *   usage: fuzz [seed.qss] [iterations]
 */
#include "../include/qss.h"
#include <stdio.h>

static void drive(const uint8_t *b, size_t n){
    QssHeader h; qss_read_header(b, n, &h);          /* header parser robustness */
    /* packet reader: read band directly — CRC-16 is not a security boundary, a
       crafted header can carry any band_count, so the reader must be robust to it. */
    uint16_t band = (n >= 24) ? be16r(b+22) : (uint16_t)QSC_BANDS;
    QssCoder co; memset(&co, 0, sizeof co);
    QssPacket2 pk; size_t off = (n >= QSS_HDR_BYTES) ? QSS_HDR_BYTES : 0;
    for (int guard = 0; guard < 8192; guard++){
        int r = qss2_next_packet(b, n, &off, band, &co, &pk);
        if (r == 1) qss2_free(&pk);
        else if (r == 0) break;
        if (off >= n) break;
    }
}

int main(int argc, char **argv){
    const char *seedp = argc > 1 ? argv[1] : "test/tonal.qss";
    long iters = argc > 2 ? atol(argv[2]) : 200000;
    FILE *f = fopen(seedp, "rb"); if (!f){ fprintf(stderr,"fuzz: no seed %s\n", seedp); return 1; }
    fseek(f,0,SEEK_END); long sl = ftell(f); fseek(f,0,SEEK_SET);
    if (sl < 1){ fclose(f); return 1; }
    uint8_t *seed = malloc(sl);
    if (fread(seed,1,sl,f) != (size_t)sl){ fclose(f); free(seed); return 1; }
    fclose(f);

    uint32_t st = 0xC0FFEEu;
    #define RND (st = st*1103515245u + 12345u, (st>>15) & 0x7fffffffu)
    uint8_t *m = malloc((size_t)sl + 16);
    for (long it = 0; it < iters; it++){
        size_t n = (size_t)sl;
        if (RND % 5 == 0) n = RND % ((size_t)sl + 1);                 /* truncate */
        if (n) memcpy(m, seed, n);
        int flips = RND % 12;
        for (int k=0;k<flips && n;k++) m[RND % n] ^= (uint8_t)(RND & 0xff);   /* flips */
        if (RND % 6  == 0 && n >= 2)  { size_t q = RND % (n-1); m[q]=0xA5; m[q+1]=0x5A; } /* sync */
        if (RND % 20 == 0 && n >= 24) be16w(m+22, (uint16_t)(RND % 4096));    /* fuzz band_count */
        drive(m, n);
    }
    free(m); free(seed);
    printf("fuzz: %ld iterations on %s -> no crash/OOB/UB\n", iters, seedp);
    return 0;
}
