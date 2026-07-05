/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-DeMoD-Commercial
 * qbits.h — MSB-first bit I/O + Rice/Exp-Golomb entropy codes.
 * Copyright (c) 2026 DeMoD LLC.
 *
 * Small, allocation-light primitives for the coded QSS packet body (spec
 * Appendix S). Rice(k) is near-optimal for the two-sided-geometric deltas we
 * emit (onset/freq/amp/gain residuals after prediction); k is chosen per block
 * to minimize size. Signed values are zig-zag mapped. Everything is
 * deterministic and byte-losslessly round-trips (self-test: qbits_selftest).
 */
#ifndef DEMOD_QBITS_H
#define DEMOD_QBITS_H
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------ writer ------------------------------ */
typedef struct { uint8_t *buf; size_t cap, byte; int bit; } BitW;
static inline void bw_init(BitW *w){ w->cap=64; w->buf=malloc(w->cap); w->byte=0; w->bit=0; w->buf[0]=0; }
static inline void bw_free(BitW *w){ free(w->buf); w->buf=NULL; }
static inline void bw_put1(BitW *w, int b){
    if (w->byte+1 >= w->cap){ w->cap*=2; w->buf=realloc(w->buf,w->cap); }
    if (b) w->buf[w->byte] |= (uint8_t)(0x80 >> w->bit);
    if (++w->bit==8){ w->bit=0; w->byte++; w->buf[w->byte]=0; }
}
static inline void bw_putn(BitW *w, uint32_t v, int n){        /* n MSB-first bits */
    for (int i=n-1;i>=0;i--) bw_put1(w, (v>>i)&1);
}
static inline size_t bw_bits(const BitW *w){ return w->byte*8 + w->bit; }
static inline size_t bw_bytes(const BitW *w){ return w->byte + (w->bit?1:0); }

/* ------------------------------ reader ------------------------------ */
typedef struct { const uint8_t *buf; size_t cap, byte; int bit; } BitR;
static inline void br_init(BitR *r, const uint8_t *b, size_t n){ r->buf=b; r->cap=n; r->byte=0; r->bit=0; }
static inline int  br_get1(BitR *r){
    if (r->byte >= r->cap) return 0;
    int b = (r->buf[r->byte] >> (7 - r->bit)) & 1;
    if (++r->bit==8){ r->bit=0; r->byte++; }
    return b;
}
static inline uint32_t br_getn(BitR *r, int n){ uint32_t v=0; for (int i=0;i<n;i++) v=(v<<1)|br_get1(r); return v; }

/* --------------------------- zig-zag map ---------------------------- */
static inline uint32_t zz_enc(int32_t v){ return ((uint32_t)v << 1) ^ (uint32_t)(v >> 31); }
static inline int32_t  zz_dec(uint32_t u){ return (int32_t)(u >> 1) ^ -(int32_t)(u & 1); }

/* ----------------------------- Rice(k) ------------------------------ */
static inline void rice_put(BitW *w, uint32_t v, int k){
    uint32_t q = v >> k;
    if (q > 47){                        /* escape: 48 ones, 0, then 32-bit raw */
        for (int i=0;i<48;i++) bw_put1(w,1); bw_put1(w,0); bw_putn(w,v,32); return;
    }
    for (uint32_t i=0;i<q;i++) bw_put1(w,1); bw_put1(w,0);
    if (k) bw_putn(w, v & ((1u<<k)-1), k);
}
static inline uint32_t rice_get(BitR *r, int k){
    uint32_t q=0; while (br_get1(r)){ if (++q>=48){ br_get1(r); return br_getn(r,32); } }
    uint32_t low = k ? br_getn(r,k) : 0;
    return (q<<k) | low;
}
/* pick k minimizing total Rice bits for a block of already-zigzagged values */
static inline int rice_best_k(const uint32_t *v, int n){
    int bk=0; size_t best=(size_t)-1;
    for (int k=0;k<=24;k++){ size_t bits=0;
        for (int i=0;i<n;i++){ uint32_t q=v[i]>>k; bits += (q>47? 48+1+32 : q+1+k); }
        if (bits<best){ best=bits; bk=k; }
    }
    return bk;
}

/* --------------------------- self test ------------------------------ */
static inline int qbits_selftest(void){
    BitW w; bw_init(&w);
    int32_t vals[] = {0,1,-1,7,-13,255,-256,100000,-99999,3,3,3,0,0,-1,
                      0,0,0,0,50000000,0,0,-40000000,1,2}; /* outliers force Rice escape */
    int n=sizeof(vals)/sizeof(vals[0]);
    uint32_t zz[64]; for (int i=0;i<n;i++) zz[i]=zz_enc(vals[i]);
    int k=rice_best_k(zz,n); bw_putn(&w,(uint32_t)k,5);
    for (int i=0;i<n;i++) rice_put(&w,zz[i],k);
    BitR r; br_init(&r,w.buf,bw_bytes(&w));
    int kk=(int)br_getn(&r,5); int ok=(kk==k);
    for (int i=0;i<n;i++){ int32_t g=zz_dec(rice_get(&r,kk)); if (g!=vals[i]) ok=0; }
    bw_free(&w); return ok;
}
#endif /* DEMOD_QBITS_H */
