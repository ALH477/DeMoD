/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-DeMoD-Commercial
 * qss.h — QSS (Quanta Streaming Stream) framed container (spec §14).
 * Copyright (c) 2026 DeMoD LLC.
 *
 * A QSS stream is a fixed 32-byte header followed by a sequence of
 * self-delimiting packets, one per commit hop. Each packet carries only the
 * atoms and residual frames that FROZE during that hop, so the stream can be
 * produced and consumed incrementally with bounded memory and latency.
 *
 * Byte order is big-endian throughout (DCF convention). Every packet ends in
 * a CRC-16/CCITT over its body, so packets are independently verifiable and
 * a corrupt packet can be dropped without desyncing the stream (the sync
 * word re-anchors the reader). Packets map cleanly onto DCF payloads:
 * fragment a packet across 17-byte DeModFrames, or carry one packet per
 * datagram over HydraMesh (UDP 7777).
 *
 * Atoms use a compact 20-byte record (vs QSC's 32): the streaming profile
 * drops rank (packet order is commit order) and chirp (unused). freq/amp/
 * phase stay f32 here so a QSS->QSC bridge reconstructs a byte-exact score
 * for the frozen-Faust null test; entropy/quant coding is a later pass.
 */
#ifndef DEMOD_QSS_H
#define DEMOD_QSS_H
#include "qsc.h"
#include "qbits.h"
#include <math.h>

/* ---- quantization grids (spec Appendix S.4) : lossy for freq/amp/phase ---- */
#define QSS_FREF     20.0     /* Hz, log-freq reference (below band low)      */
#define QSS_CENT     2.0      /* freq grid step, cents                        */
#define QSS_DBSTEP   0.5      /* amp grid step, dB                            */
#define QSS_PHBITS   8        /* phase quantization bits (256 steps)          */

static inline uint32_t qss_freq_q(double hz){
    if (hz < QSS_FREF) hz = QSS_FREF;
    double c = 1200.0/QSS_CENT * log2(hz/QSS_FREF);
    long q = lround(c); return q<0?0:(uint32_t)q;
}
static inline double qss_freq_dq(uint32_t q){ return QSS_FREF * pow(2.0, (double)q*QSS_CENT/1200.0); }
static inline uint32_t qss_amp_q(double a){
    double db = (a>1e-12)? 20.0*log10(a) : -144.0;
    long q = lround((db+144.0)/QSS_DBSTEP); if (q<0)q=0; if (q>65535)q=65535; return (uint32_t)q;
}
static inline double qss_amp_dq(uint32_t q){ return pow(10.0, ((double)q*QSS_DBSTEP-144.0)/20.0); }
static inline uint32_t qss_phase_q(double ph){
    double t = ph/(2.0*M_PI); t -= floor(t);
    long q = lround(t*(1<<QSS_PHBITS)) & ((1<<QSS_PHBITS)-1); return (uint32_t)q;
}
static inline double qss_phase_dq(uint32_t q){ return (double)q/(double)(1<<QSS_PHBITS)*(2.0*M_PI); }


#define QSS_MAGIC        0x51535331u   /* 'QSS1' uncompressed (legacy/debug) */
#define QSS2_MAGIC       0x51535332u   /* 'QSS2' coded (default)             */
#define QSS_SYNC         0xA55Au        /* packet re-anchor word            */
#define QSS_HDR_BYTES    40
#define QSS_ATOM_BYTES   20
#define QSS_FLAG_FLUSH   0x0001u        /* packet is the end-of-stream flush */

/* ---- CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF) : DCF convention ---- */
static inline uint16_t qss_crc16(const uint8_t *d, size_t n){
    uint16_t c = 0xFFFF;
    for (size_t i = 0; i < n; i++){
        c ^= (uint16_t)d[i] << 8;
        for (int k = 0; k < 8; k++) c = (c & 0x8000) ? (uint16_t)((c<<1)^0x1021) : (uint16_t)(c<<1);
    }
    return c;
}

typedef struct {
    uint32_t sample_rate;
    uint64_t source_len;     /* total samples (decoder timeline)            */
    uint16_t cap;            /* latency scale (samples)                     */
    uint16_t hop;            /* commit hop (samples)                        */
    uint16_t active;         /* working-set width (samples)                 */
    uint16_t band_count;
    uint16_t residual_hop;
    uint32_t noise_seed;
    uint16_t flags;
} QssHeader;

/* one committed atom in a packet */
typedef struct {
    uint32_t onset; uint16_t dur; float freq, amp, phase; uint8_t voice, layer;
} QssAtom;

/* ------------------------------- writer ------------------------------- */
static inline void qss_write_header(FILE *f, const QssHeader *h){
    uint8_t b[QSS_HDR_BYTES]; memset(b, 0, sizeof b);
    be32w(b+0,  QSS2_MAGIC);
    be32w(b+4,  h->sample_rate);
    be64w(b+8,  h->source_len);
    be16w(b+16, h->cap);        be16w(b+18, h->hop);
    be16w(b+20, h->active);     be16w(b+22, h->band_count);
    be16w(b+24, h->residual_hop);
    be32w(b+26, h->noise_seed);
    be16w(b+30, h->flags);
    be16w(b+32, qss_crc16(b, 32));   /* header CRC over first 32 bytes */
    fwrite(b, 1, QSS_HDR_BYTES, f);
}

/* Emit one packet: n_atoms committed atoms + n_res residual frames.
 * res_idx[i] is the absolute residual-frame index; res_gains is
 * n_res * band_count u16 values (row-major). Returns bytes written. */
static inline size_t qss_write_packet(FILE *f, uint32_t hop_index, uint16_t pkt_flags,
        const QssAtom *at, uint16_t n_atoms,
        const uint32_t *res_idx, const uint16_t *res_gains,
        uint16_t n_res, uint16_t band_count){
    size_t body = 4 + 2 + 2 + 2 + (size_t)n_atoms*QSS_ATOM_BYTES
                + (size_t)n_res*(4 + (size_t)band_count*2);
    uint8_t *b = (uint8_t*)malloc(2 + body + 2);
    size_t p = 0;
    be16w(b+p, QSS_SYNC); p += 2;
    uint8_t *body0 = b + p;
    be32w(b+p, hop_index);  p += 4;
    be16w(b+p, pkt_flags);  p += 2;
    be16w(b+p, n_atoms);    p += 2;
    be16w(b+p, n_res);      p += 2;
    for (uint16_t i = 0; i < n_atoms; i++){
        be32w(b+p, at[i].onset);          p += 4;
        be16w(b+p, at[i].dur);            p += 2;
        bef32w(b+p, at[i].freq);          p += 4;
        bef32w(b+p, at[i].amp);           p += 4;
        bef32w(b+p, at[i].phase);         p += 4;
        b[p++] = at[i].voice; b[p++] = at[i].layer;
    }
    for (uint16_t i = 0; i < n_res; i++){
        be32w(b+p, res_idx[i]); p += 4;
        for (uint16_t k = 0; k < band_count; k++){ be16w(b+p, res_gains[(size_t)i*band_count+k]); p += 2; }
    }
    uint16_t crc = qss_crc16(body0, body);
    be16w(b+p, crc); p += 2;
    fwrite(b, 1, p, f); free(b);
    return p;
}

/* ------------------------------- reader ------------------------------- */
/* Parse the header from a buffer; returns 0 on success. */
static inline int qss_read_header(const uint8_t *b, size_t n, QssHeader *h){
    if (n < QSS_HDR_BYTES) return -1;
    uint32_t mg=be32r(b); if (mg!=QSS_MAGIC && mg!=QSS2_MAGIC) return -1;
    if (qss_crc16(b, 32) != be16r(b+32)) return -2;
    h->sample_rate = be32r(b+4);
    h->source_len = be64r(b+8);
    h->cap = be16r(b+16);  h->hop = be16r(b+18);
    h->active = be16r(b+20); h->band_count = be16r(b+22);
    h->residual_hop = be16r(b+24);
    h->noise_seed = be32r(b+26);
    h->flags = be16r(b+30);
    return 0;
}

/* Locate the next packet at/after *off (re-anchoring on the sync word),
 * validate CRC, and hand back pointers into the buffer. Advances *off past
 * the packet. Returns 1 on a good packet, 0 at clean end, -1 on CRC error
 * (caller may retry from *off to skip the bad packet). */
typedef struct {
    uint32_t hop_index; uint16_t flags, n_atoms, n_res;
    const uint8_t *atoms;     /* n_atoms * QSS_ATOM_BYTES */
    const uint8_t *res;       /* n_res * (4 + band*2)     */
} QssPacket;

static inline int qss_next_packet(const uint8_t *b, size_t n, size_t *off,
                                  uint16_t band_count, QssPacket *pk){
    size_t p = *off;
    while (p + 2 <= n && be16r(b+p) != QSS_SYNC) p++;   /* re-anchor */
    if (p + 12 > n) { *off = n; return 0; }
    const uint8_t *body0 = b + p + 2;
    uint32_t hop = be32r(b+p+2);
    uint16_t flags = be16r(b+p+6), na = be16r(b+p+8), nr = be16r(b+p+10);
    size_t body = 4+2+2+2 + (size_t)na*QSS_ATOM_BYTES + (size_t)nr*(4+(size_t)band_count*2);
    if (p + 2 + body + 2 > n) { *off = n; return 0; }
    uint16_t crc = be16r(b + p + 2 + body);
    if (qss_crc16(body0, body) != crc){ *off = p + 2; return -1; }  /* skip sync, retry */
    pk->hop_index = hop; pk->flags = flags; pk->n_atoms = na; pk->n_res = nr;
    pk->atoms = body0 + 10;
    pk->res   = pk->atoms + (size_t)na*QSS_ATOM_BYTES;
    *off = p + 2 + body + 2;
    return 1;
}

static inline void qss_unpack_atom(const uint8_t *a, QssAtom *o){
    o->onset = be32r(a); o->dur = be16r(a+4);
    o->freq = bef32r(a+6); o->amp = bef32r(a+10); o->phase = bef32r(a+14);
    o->voice = a[18]; o->layer = a[19];
}

/* ===================== QSS2 coded packets (spec Appendix S.4) ===========
 * Plaintext framing (sync/lengths/CRC) wraps a Rice-coded body. Prediction
 * state (previous onset, residual gain row, frame index) is carried across
 * packets in a QssCoder, so temporal deltas stay small. Voice is NOT stored:
 * the decoder replays the encoder's deterministic first-fit assignment.
 */
typedef struct { uint64_t prev_onset; uint32_t prev_fidx; uint16_t prev_gain[QSC_BANDS]; int primed; } QssCoder;
static inline void qss_coder_init(QssCoder *c){ memset(c,0,sizeof *c); }

/* write one Rice block: 5-bit k then n zig-zagged values */
static inline void qss__wblock(BitW *w, const uint32_t *zz, int n){
    int k = rice_best_k(zz, n); bw_putn(w,(uint32_t)k,5);
    for (int i=0;i<n;i++) rice_put(w, zz[i], k);
}
static inline void qss__rblock(BitR *r, uint32_t *out, int n){
    int k=(int)br_getn(r,5); for (int i=0;i<n;i++) out[i]=rice_get(r,k);
}

/* Emit a coded packet. Integer field arrays are pre-quantized by the encoder.
 * res_gain is n_res*band u16 quantized gains (qsc_gain_q domain). */
static inline size_t qss2_write_packet(FILE *f, QssCoder *co, uint32_t hop_index, uint16_t flags,
        const uint32_t *onset, const uint32_t *scaleidx, const uint32_t *freqq,
        const uint32_t *ampq, const uint32_t *phaseq, uint16_t na,
        const uint32_t *res_idx, const uint16_t *res_gain, uint16_t nr, uint16_t band){
    BitW w; bw_init(&w);
    uint32_t *tmp = malloc(sizeof(uint32_t)*((size_t)(na>nr*band?na:nr*band)+1));
    if (na){
        uint64_t prev=co->prev_onset;
        for (int i=0;i<na;i++){ tmp[i]=zz_enc((int32_t)((int64_t)onset[i]-(int64_t)prev)); prev=onset[i]; }
        qss__wblock(&w,tmp,na); co->prev_onset=prev;
        qss__wblock(&w,scaleidx,na);
        qss__wblock(&w,freqq,na);
        qss__wblock(&w,ampq,na);
        qss__wblock(&w,phaseq,na);
    }
    if (nr){
        uint32_t pf=co->prev_fidx;
        for (int i=0;i<nr;i++){ tmp[i]=zz_enc((int32_t)((int64_t)res_idx[i]-(int64_t)pf)); pf=res_idx[i]; }
        qss__wblock(&w,tmp,nr); co->prev_fidx=pf;
        uint16_t row[QSC_BANDS]; for (int b=0;b<band;b++) row[b]=co->prev_gain[b];
        int gc=0;
        for (int i=0;i<nr;i++){ for (int b=0;b<band;b++){
            tmp[gc++]=zz_enc((int32_t)res_gain[(size_t)i*band+b]-(int32_t)row[b]); row[b]=res_gain[(size_t)i*band+b]; } }
        qss__wblock(&w,tmp,gc);
        for (int b=0;b<band;b++) co->prev_gain[b]=row[b];
    }
    size_t blen = bw_bytes(&w);
    /* frame: sync hop flags na nr body_len [body] crc */
    size_t total = 2+4+2+2+2+2 + blen + 2;
    uint8_t *p = malloc(total); size_t o=0;
    be16w(p+o,QSS_SYNC); o+=2;
    uint8_t *c0=p+o;
    be32w(p+o,hop_index); o+=4; be16w(p+o,flags); o+=2;
    be16w(p+o,na); o+=2; be16w(p+o,nr); o+=2; be16w(p+o,(uint16_t)blen); o+=2;
    memcpy(p+o,w.buf,blen); o+=blen;
    uint16_t crc=qss_crc16(c0,(size_t)(p+o-c0)); be16w(p+o,crc); o+=2;
    fwrite(p,1,o,f);
    free(tmp); bw_free(&w); free(p);
    return o;
}

typedef struct {
    uint32_t hop_index; uint16_t flags, n_atoms, n_res;
    uint32_t *onset,*scaleidx,*freqq,*ampq,*phaseq;   /* n_atoms each */
    uint32_t *res_idx; uint16_t *res_gain;            /* nr, nr*band  */
} QssPacket2;

/* Decode next coded packet at/after *off, re-anchoring on sync + CRC.
 * Fills pk with malloc'd arrays (caller frees via qss2_free). Returns 1 ok,
 * 0 end, -1 CRC error (retry from *off). Updates coder prediction state. */
static inline int qss2_next_packet(const uint8_t *b, size_t n, size_t *off,
                                   uint16_t band, QssCoder *co, QssPacket2 *pk){
    size_t p=*off;
    while (p+2<=n && be16r(b+p)!=QSS_SYNC) p++;
    if (p+14>n){ *off=n; return 0; }
    const uint8_t *c0=b+p+2;
    uint32_t hop=be32r(b+p+2); uint16_t flags=be16r(b+p+6);
    uint16_t na=be16r(b+p+8), nr=be16r(b+p+10), blen=be16r(b+p+12);
    if (p+2+12+blen+2 > n){ *off=n; return 0; }
    uint16_t crc=be16r(b+p+2+12+blen);
    if (qss_crc16(c0,(size_t)12+blen)!=crc){ *off=p+2; return -1; }
    BitR r; br_init(&r, b+p+2+12, blen);
    pk->hop_index=hop; pk->flags=flags; pk->n_atoms=na; pk->n_res=nr;
    pk->onset=pk->scaleidx=pk->freqq=pk->ampq=pk->phaseq=NULL; pk->res_idx=NULL; pk->res_gain=NULL;
    if (na){
        pk->onset=malloc(sizeof(uint32_t)*na); pk->scaleidx=malloc(sizeof(uint32_t)*na);
        pk->freqq=malloc(sizeof(uint32_t)*na); pk->ampq=malloc(sizeof(uint32_t)*na); pk->phaseq=malloc(sizeof(uint32_t)*na);
        uint32_t *d=malloc(sizeof(uint32_t)*na); qss__rblock(&r,d,na);
        uint64_t prev=co->prev_onset; for (int i=0;i<na;i++){ prev=(uint64_t)((int64_t)prev+zz_dec(d[i])); pk->onset[i]=(uint32_t)prev; } co->prev_onset=prev;
        qss__rblock(&r,pk->scaleidx,na); qss__rblock(&r,pk->freqq,na);
        qss__rblock(&r,pk->ampq,na); qss__rblock(&r,pk->phaseq,na); free(d);
    }
    if (nr){
        pk->res_idx=malloc(sizeof(uint32_t)*nr); pk->res_gain=malloc(sizeof(uint16_t)*(size_t)nr*band);
        uint32_t *d=malloc(sizeof(uint32_t)*nr); qss__rblock(&r,d,nr);
        uint32_t pf=co->prev_fidx; for (int i=0;i<nr;i++){ pf=(uint32_t)((int64_t)pf+zz_dec(d[i])); pk->res_idx[i]=pf; } co->prev_fidx=pf;
        uint32_t *g=malloc(sizeof(uint32_t)*(size_t)nr*band); qss__rblock(&r,g,(int)((size_t)nr*band));
        uint16_t row[QSC_BANDS]; for (int bb=0;bb<band;bb++) row[bb]=co->prev_gain[bb];
        int gc=0; for (int i=0;i<nr;i++){ for (int bb=0;bb<band;bb++){
            row[bb]=(uint16_t)((int32_t)row[bb]+zz_dec(g[gc++])); pk->res_gain[(size_t)i*band+bb]=row[bb]; } }
        for (int bb=0;bb<band;bb++) co->prev_gain[bb]=row[bb]; free(d); free(g);
    }
    *off = p+2+12+blen+2;
    return 1;
}
static inline void qss2_free(QssPacket2 *pk){
    free(pk->onset); free(pk->scaleidx); free(pk->freqq); free(pk->ampq); free(pk->phaseq);
    free(pk->res_idx); free(pk->res_gain);
}
#endif /* DEMOD_QSS_H */
