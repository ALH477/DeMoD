/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-DeMoD-Commercial
 * quanta-pack — compressed offline container (.qsz).
 *
 * The .qsc score (48-byte header + 32-byte atoms + u16 residual gains) is not
 * entropy-coded. quanta-pack columnar-Rice-codes it (reusing qbits.h + the QSS
 * atom quantizers) into a much smaller .qsz, for a small on-disk footprint "when
 * needed". `compress` quantizes freq/amp/phase to the QSS grids (near-transparent
 * on the well-placed OFFLINE atoms — the streaming distortion was atom placement,
 * not quantization) and delta-codes the residual gains; `decompress` reconstructs
 * a normal .qsc that renders/freezes deterministically. Round-trip is idempotent
 * and gated (test/run.sh gate Z). Copyright (c) 2026 DeMoD LLC.
 */
#include "../include/qsc.h"
#include "../include/qss.h"     /* qss_freq_q/dq (2-cent grid, already fine)   */
#include "../include/qbits.h"   /* BitW/BitR, Rice, zig-zag                    */
#include <stdio.h>
#include <math.h>

#define QSZ_MAGIC "QSZ1"
#define QSZ_HDR   48

/* .qsz-local grids, finer than the streaming QSS ones (this is an archival
 * container, not a low-rate wire): 12-bit phase + 0.25 dB amp cut the quantization
 * distortion for ~a few hundred extra bytes. freq stays on the 2-cent QSS grid. */
#define PACK_PHBITS 12
#define PACK_DBSTEP 0.25
#define PACK_CENT   0.1       /* freq grid, cents — fine enough that phase drift over
                                the longest (0.34 s) atom stays sub-audible; sweet spot
                                (coarser audibly drifts long atoms, finer only adds bytes) */
static uint32_t pk_freq_q(double hz){ if (hz<QSS_FREF) hz=QSS_FREF;
    double c=1200.0/PACK_CENT*log2(hz/QSS_FREF); long q=lround(c); return q<0?0:(uint32_t)q; }
static double   pk_freq_dq(uint32_t q){ return QSS_FREF*pow(2.0,(double)q*PACK_CENT/1200.0); }
static uint32_t pk_phase_q(double ph){ double t=ph/(2.0*M_PI); t-=floor(t);
    long q=lround(t*(1<<PACK_PHBITS)) & ((1<<PACK_PHBITS)-1); return (uint32_t)q; }
static double   pk_phase_dq(uint32_t q){ return (double)q/(double)(1<<PACK_PHBITS)*(2.0*M_PI); }
static uint32_t pk_amp_q(double a){ double db=(a>1e-12)?20.0*log10(a):-144.0;
    long q=lround((db+144.0)/PACK_DBSTEP); if(q<0)q=0; if(q>262143)q=262143; return (uint32_t)q; }
static double   pk_amp_dq(uint32_t q){ return pow(10.0, ((double)q*PACK_DBSTEP-144.0)/20.0); }

static int bits_needed(uint32_t maxv){ int b=1; while (maxv>1){ b++; maxv>>=1; } return b; }

/* emit a length-n column of already-zig-zagged values: 5-bit k, then Rice(k). */
static void put_col(BitW *w, const uint32_t *v, int n){
    int k = rice_best_k(v, n); bw_putn(w, (uint32_t)k, 5);
    for (int i=0;i<n;i++) rice_put(w, v[i], k);
}
static void get_col(BitR *r, uint32_t *v, int n){
    int k = (int)br_getn(r, 5);
    for (int i=0;i<n;i++) v[i] = rice_get(r, k);
}

static int compress(const char *inp, const char *outp){
    Qsc q; if (qsc_read(inp, &q) != 0){ fprintf(stderr,"pack: cannot read %s\n", inp); return 1; }
    if (q.h.channel_count > 1){                 /* stereo .qsz not yet supported (would drop the channel tag) */
        fprintf(stderr,"pack: stereo .qsc (channel_count=%u) not yet supported by quanta-pack\n", q.h.channel_count);
        free(q.atoms); free(q.res_gains); return 2;
    }
    uint32_t n = q.h.atom_count;
    uint32_t F = q.h.residual_frames, B = q.h.band_count;
    int vbits = bits_needed(q.h.voice_count ? q.h.voice_count : 1);
    int rbits = bits_needed(n ? n : 1);

    BitW w; bw_init(&w);
    uint32_t *col = malloc((size_t)(n?n:1)*4);
    int32_t prev;
    /* onset: zig-zag delta (order is voice-grouped, so deltas can be negative) */
    prev=0; for (uint32_t i=0;i<n;i++){ col[i]=zz_enc((int32_t)q.atoms[i].onset - prev); prev=(int32_t)q.atoms[i].onset; }
    put_col(&w, col, (int)n);
    /* scale_idx (4b), layer (1b), voice (vbits), rank (rbits) — raw */
    for (uint32_t i=0;i<n;i++) bw_putn(&w, q.atoms[i].scale_idx & 0xF, 4);
    for (uint32_t i=0;i<n;i++) bw_put1(&w, q.atoms[i].layer & 1);
    for (uint32_t i=0;i<n;i++) bw_putn(&w, q.atoms[i].voice, vbits);
    for (uint32_t i=0;i<n;i++) bw_putn(&w, q.atoms[i].rank, rbits);
    /* freq / amp: quantize to QSS grids, zig-zag delta Rice */
    prev=0; for (uint32_t i=0;i<n;i++){ int32_t fq=(int32_t)pk_freq_q(q.atoms[i].freq); col[i]=zz_enc(fq-prev); prev=fq; }
    put_col(&w, col, (int)n);
    prev=0; for (uint32_t i=0;i<n;i++){ int32_t aq=(int32_t)pk_amp_q(q.atoms[i].amp);  col[i]=zz_enc(aq-prev); prev=aq; }
    put_col(&w, col, (int)n);
    /* phase: PHBITS raw (≈uniform, incompressible) */
    for (uint32_t i=0;i<n;i++) bw_putn(&w, pk_phase_q(q.atoms[i].phase), PACK_PHBITS);
    /* residual gains: per-band temporal zig-zag delta Rice */
    uint32_t *gc = malloc((size_t)(F?F:1)*4);
    for (uint32_t b=0;b<B;b++){
        prev=0; for (uint32_t f=0;f<F;f++){ int32_t g=(int32_t)q.res_gains[(size_t)f*B+b]; gc[f]=zz_enc(g-prev); prev=g; }
        put_col(&w, gc, (int)F);
    }

    size_t body = bw_bytes(&w);
    uint8_t hdr[QSZ_HDR]; memset(hdr,0,sizeof hdr);
    memcpy(hdr, QSZ_MAGIC, 4);
    be16w(hdr+4, 1); be16w(hdr+6, q.h.flags);
    be32w(hdr+8, q.h.sample_rate); be64w(hdr+12, q.h.source_len);
    be32w(hdr+20, n); be16w(hdr+24, q.h.voice_count);
    hdr[26]=q.h.scale_count; hdr[27]=q.h.band_count;
    be16w(hdr+28, q.h.residual_hop); be32w(hdr+30, F); be32w(hdr+34, q.h.noise_seed);
    uint32_t crc = qsc_crc32(w.buf, body);
    FILE *o=fopen(outp,"wb"); if(!o){ fprintf(stderr,"pack: cannot write %s\n",outp); return 1; }
    fwrite(hdr,1,QSZ_HDR,o); fwrite(w.buf,1,body,o);
    uint8_t cb[4]; be32w(cb,crc); fwrite(cb,1,4,o); fclose(o);

    long qsc_sz; { FILE *f=fopen(inp,"rb"); fseek(f,0,SEEK_END); qsc_sz=ftell(f); fclose(f); }
    long qsz_sz = (long)(QSZ_HDR+body+4);
    fprintf(stderr,"pack: %s (%ld B) -> %s (%ld B)  %.2fx  [%u atoms, %u gain frames]\n",
            inp, qsc_sz, outp, qsz_sz, qsc_sz/(double)qsz_sz, n, F);
    bw_free(&w); free(col); free(gc); free(q.atoms); free(q.res_gains);
    return 0;
}

static int decompress(const char *inp, const char *outp){
    FILE *f=fopen(inp,"rb"); if(!f){ fprintf(stderr,"pack: cannot read %s\n",inp); return 1; }
    fseek(f,0,SEEK_END); long sz=ftell(f); fseek(f,0,SEEK_SET);
    uint8_t *buf=malloc(sz); if (fread(buf,1,sz,f)!=(size_t)sz){ fclose(f); return 1; } fclose(f);
    if (sz < QSZ_HDR+4 || memcmp(buf,QSZ_MAGIC,4)){ fprintf(stderr,"pack: bad .qsz\n"); return 2; }
    size_t body = (size_t)sz - QSZ_HDR - 4;
    if (qsc_crc32(buf+QSZ_HDR, body) != be32r(buf+sz-4)){ fprintf(stderr,"pack: crc mismatch\n"); return 3; }

    Qsc q; memset(&q,0,sizeof q);
    q.h.version=1; q.h.flags=be16r(buf+6);
    q.h.sample_rate=be32r(buf+8); q.h.source_len=be64r(buf+12);
    q.h.atom_count=be32r(buf+20); q.h.voice_count=be16r(buf+24);
    q.h.scale_count=buf[26]; q.h.band_count=buf[27];
    q.h.residual_hop=be16r(buf+28); q.h.residual_frames=be32r(buf+30); q.h.noise_seed=be32r(buf+34);
    uint32_t n=q.h.atom_count, F=q.h.residual_frames, B=q.h.band_count;
    int vbits=bits_needed(q.h.voice_count?q.h.voice_count:1), rbits=bits_needed(n?n:1);

    q.atoms = calloc(n?n:1, sizeof(QscAtom));
    q.res_gains = calloc((size_t)(F?F:1)*(B?B:1), sizeof(uint16_t));
    BitR r; br_init(&r, buf+QSZ_HDR, body);
    uint32_t *col=malloc((size_t)(n?n:1)*4);
    int32_t prev;
    get_col(&r, col, (int)n);
    prev=0; for (uint32_t i=0;i<n;i++){ int32_t on=prev+zz_dec(col[i]); q.atoms[i].onset=(uint32_t)on; prev=on; }
    for (uint32_t i=0;i<n;i++){ q.atoms[i].scale_idx=(uint8_t)br_getn(&r,4);
                                q.atoms[i].dur=(uint32_t)QSC_SCALE_TAB[q.atoms[i].scale_idx]; }
    for (uint32_t i=0;i<n;i++) q.atoms[i].layer=(uint8_t)br_get1(&r);
    for (uint32_t i=0;i<n;i++) q.atoms[i].voice=(uint8_t)br_getn(&r,vbits);
    for (uint32_t i=0;i<n;i++) q.atoms[i].rank=br_getn(&r,rbits);
    get_col(&r, col, (int)n);
    prev=0; for (uint32_t i=0;i<n;i++){ int32_t fq=prev+zz_dec(col[i]); q.atoms[i].freq=(float)pk_freq_dq((uint32_t)fq); prev=fq; }
    get_col(&r, col, (int)n);
    prev=0; for (uint32_t i=0;i<n;i++){ int32_t aq=prev+zz_dec(col[i]); q.atoms[i].amp=(float)pk_amp_dq((uint32_t)aq); prev=aq; }
    for (uint32_t i=0;i<n;i++){ q.atoms[i].phase=(float)pk_phase_dq(br_getn(&r,PACK_PHBITS)); q.atoms[i].chirp=0.f; q.atoms[i].flags=0; }
    uint32_t *gc=malloc((size_t)(F?F:1)*4);
    for (uint32_t b=0;b<B;b++){ get_col(&r, gc, (int)F);
        prev=0; for (uint32_t fi=0;fi<F;fi++){ int32_t g=prev+zz_dec(gc[fi]); q.res_gains[(size_t)fi*B+b]=(uint16_t)g; prev=g; } }

    int rc = qsc_write(outp, &q);
    if (rc==0) fprintf(stderr,"pack: %s -> %s  [%u atoms]\n", inp, outp, n);
    free(buf); free(col); free(gc); free(q.atoms); free(q.res_gains);
    return rc;
}

int main(int argc, char **argv){
    if (argc<4 || (strcmp(argv[1],"compress") && strcmp(argv[1],"decompress"))){
        fprintf(stderr,"usage: quanta-pack compress   in.qsc out.qsz\n"
                       "       quanta-pack decompress in.qsz out.qsc\n");
        return 2;
    }
    return strcmp(argv[1],"compress")==0 ? compress(argv[2],argv[3]) : decompress(argv[2],argv[3]);
}
