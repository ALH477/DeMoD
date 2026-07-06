/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-DeMoD-Commercial
 * demod-quanta — QSC format + shared deterministic DSP core
 * Copyright (c) 2026 DeMoD LLC. See LICENSING.md.
 *
 * Single header shared by quanta-analyzer, quanta-render, quanta-freeze.
 * Everything here is part of the determinism contract (spec §12):
 * the window/sine tables, LCG, and SVF arithmetic defined below are the
 * normative reference; the Faust codegen emits byte-identical table data
 * and operation-order-identical arithmetic.
 */
#ifndef DEMOD_QSC_H
#define DEMOD_QSC_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

/* ---------------- spec constants (§4, §5, §6) ---------------- */
#define QSC_MAGIC        "QSC1"
#define QSC_VERSION      0x0001
#define QSC_HEADER_SIZE  48
#define QSC_ATOM_SIZE    32
#define QSC_SCALES       9        /* 2^6 .. 2^14 */
#define QSC_BANDS        24
#define QSC_RES_HOP      256
#define QSC_PMAX         64
#define QSC_TAB          4096     /* shared window & sine table size   */
#define QSC_WIN_SIGMA    (1.0/6.0)/* normalized Gaussian sigma (s/6)   */
#define QSC_BAND_LO      50.0
#define QSC_BAND_HI      16000.0
#define QSC_BAND_Q       4.0
#define QSC_LCG_A        1103515245
#define QSC_LCG_C        12345
#define QSC_LCG_M        0x7FFFFFFF

typedef struct {
    uint16_t version, flags;
    uint32_t sample_rate;
    uint64_t source_len;
    uint32_t atom_count;
    uint16_t voice_count;
    uint8_t  scale_count, band_count;
    uint16_t residual_hop;
    uint32_t residual_frames;
    uint32_t noise_seed;
    uint8_t  channel_count;    /* offset 38: 1=mono, 2=mid/side stereo. 0 in legacy files ⇒ mono. */
} QscHeader;

typedef struct {
    uint32_t rank, onset, dur;
    float    freq, amp, phase, chirp;
    uint8_t  layer, voice, scale_idx, flags;
} QscAtom;

/* ---- header flags (h.flags) ---- */
/* bit 0 (0x0001) reserved: psy-weighted (spec §4.4); bit 1 (0x0002) reserved: chirp present. */
#define QSC_FLAG_CRES  0x0004   /* bit 2: a coherent residual layer follows the noise gains
                                   (Track B: bit-transparent tier). See qsc_write/qsc_read. */

typedef struct {
    QscHeader h;
    QscAtom  *atoms;            /* grouped by voice, onset-sorted     */
    uint16_t *res_gains;        /* residual_frames * band_count, u16  */
    /* Coherent residual (present iff h.flags & QSC_FLAG_CRES). The true post-atom
       residual r = source - dcblock(atoms), quantized per channel to `cres_bits` and
       scaled by `cres_scale[c]` (stored f32 so encode/decode dequantize identically).
       Layout: channel-major, cres[c*source_len + t]. Decode: out += cres[t]*scale. */
    uint8_t   cres_bits;        /* quantizer precision, e.g. 16                        */
    double    cres_scale[2];    /* per-channel dequant scale (mid, side / or mono)     */
    int16_t  *cres;             /* cc * source_len int16 samples, or NULL              */
} Qsc;

/* ---------------- big-endian primitives (DCF convention) ------ */
static inline void be16w(uint8_t *p, uint16_t v){p[0]=v>>8;p[1]=v;}
static inline void be32w(uint8_t *p, uint32_t v){p[0]=v>>24;p[1]=v>>16;p[2]=v>>8;p[3]=v;}
static inline void be64w(uint8_t *p, uint64_t v){be32w(p,(uint32_t)(v>>32));be32w(p+4,(uint32_t)v);}
static inline uint16_t be16r(const uint8_t*p){return (uint16_t)(p[0]<<8|p[1]);}
static inline uint32_t be32r(const uint8_t*p){return ((uint32_t)p[0]<<24)|((uint32_t)p[1]<<16)|((uint32_t)p[2]<<8)|p[3];}
static inline uint64_t be64r(const uint8_t*p){return ((uint64_t)be32r(p)<<32)|be32r(p+4);}
static inline void bef32w(uint8_t *p, float f){uint32_t u;memcpy(&u,&f,4);be32w(p,u);}
static inline float  bef32r(const uint8_t*p){uint32_t u=be32r(p);float f;memcpy(&f,&u,4);return f;}

/* ---------------- CRC-32 (IEEE, reflected) -------------------- */
static inline uint32_t qsc_crc32(const uint8_t *d, size_t n){
    uint32_t c = 0xFFFFFFFFu;
    for (size_t i = 0; i < n; i++){
        c ^= d[i];
        for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0xEDB88320u & (0u - (c & 1u)));
    }
    return ~c;
}

/* ---------------- deterministic DSP core (§6, §12) ------------ */
/* Tables are f64. Table *construction* may use libm (data, built once
 * at load/codegen time); the per-sample paths below are libm-free.   */
static inline void qsc_build_tables(double *wtab, double *stab){
    for (int i = 0; i < QSC_TAB; i++){
        double x = (double)i / (double)QSC_TAB;
        double z = (x - 0.5) / QSC_WIN_SIGMA;
        wtab[i] = exp(-0.5 * z * z);
        stab[i] = sin(2.0 * M_PI * x);
    }
}
/* window lookup: pos in [0, QSC_TAB), clamped linear interp */
static inline double qsc_wlin(const double *wtab, double pos){
    if (pos < 0.0) pos = 0.0;
    int    i0 = (int)pos; if (i0 > QSC_TAB - 1) i0 = QSC_TAB - 1;
    int    i1 = i0 + 1;   if (i1 > QSC_TAB - 1) i1 = QSC_TAB - 1;
    double fr = pos - (double)i0;
    return wtab[i0] + fr * (wtab[i1] - wtab[i0]);
}
/* sine lookup: pos in table units, wrapping linear interp (pos >= 0) */
static inline double qsc_slin(const double *stab, double pos){
    int    i0 = (int)pos;
    double fr = pos - (double)i0;
    int    a = i0 & (QSC_TAB - 1), b = (i0 + 1) & (QSC_TAB - 1);
    return stab[a] + fr * (stab[b] - stab[a]);
}
/* Side-channel residual decorrelation: in mid/side stereo the side channel drives
   its noise LCG with (noise_seed ^ this), so its residual is independent of the mid
   channel's. render.c and freeze.c MUST use this identical constant (§12 contract). */
#define QSC_SIDE_SEED_XOR 0x5DEECE66u
/* seeded LCG (§12.3): s0 = 0, s' = (s*A + C + seed) & M, out = s/2^30 - 1 */
static inline int32_t qsc_lcg_step(int32_t s, int32_t seed){
    return (int32_t)((s * QSC_LCG_A + QSC_LCG_C + seed) & QSC_LCG_M);
}
static inline double qsc_lcg_out(int32_t s){ return (double)s / 1073741824.0 - 1.0; }

/* TPT SVF bandpass — arithmetic order is normative (mirrored in Faust) */
typedef struct { double a1, a2, a3, ic1, ic2; } QscSvf;
static inline void qsc_svf_init(QscSvf *f, double fc, double q, double sr){
    double g = tan(M_PI * fc / sr);           /* init-time libm: OK */
    double k = 1.0 / q;
    f->a1 = 1.0 / (1.0 + g * (g + k));
    f->a2 = g * f->a1;
    f->a3 = g * f->a2;
    f->ic1 = f->ic2 = 0.0;
}
static inline double qsc_svf_bp(QscSvf *f, double x){
    double v3 = x - f->ic2;
    double v1 = f->a1 * f->ic1 + f->a2 * v3;
    double v2 = f->ic2 + f->a2 * f->ic1 + f->a3 * v3;
    f->ic1 = 2.0 * v1 - f->ic1;
    f->ic2 = 2.0 * v2 - f->ic2;
    return 0.25 * v1;   /* unity-peak bandpass: k*v1, k = 1/Q (normative) */
}
/* band centers: 24 log-spaced 50 Hz .. 16 kHz */
static inline double qsc_band_fc(int b){
    return QSC_BAND_LO * pow(QSC_BAND_HI / QSC_BAND_LO, (double)b / (QSC_BANDS - 1));
}
/* band-to-band coherence C[b][b'] = E[y_b * y_b'] for the shared calibration
 * noise driving all 24 unity-peak bands. Signal-independent; used for the
 * causal per-frame residual trim: E_synth(frame) ~= g^T C g, so
 * trim = sqrt(E_res_frame / (g^T C g)). diag(C) == rho_b^2. */
static inline void qsc_band_coherence(double C[QSC_BANDS][QSC_BANDS], double sr){
    QscSvf f[QSC_BANDS];
    for (int b = 0; b < QSC_BANDS; b++) qsc_svf_init(&f[b], qsc_band_fc(b), QSC_BAND_Q, sr);
    for (int b = 0; b < QSC_BANDS; b++) for (int c = 0; c < QSC_BANDS; c++) C[b][c] = 0.0;
    int32_t st = 0; double y[QSC_BANDS];
    const int NCAL = 48000;
    for (int i = 0; i < NCAL; i++){
        st = qsc_lcg_step(st, (int32_t)0xC0FFEE);
        double nz = qsc_lcg_out(st);
        for (int b = 0; b < QSC_BANDS; b++) y[b] = qsc_svf_bp(&f[b], nz);
        for (int b = 0; b < QSC_BANDS; b++)
            for (int c = b; c < QSC_BANDS; c++) C[b][c] += y[b]*y[c];
    }
    for (int b = 0; b < QSC_BANDS; b++)
        for (int c = b; c < QSC_BANDS; c++){ C[b][c] /= NCAL; C[c][b] = C[b][c]; }
}
/* residual gain quantization: g_dB = 0.25*q - 144 */
static inline uint16_t qsc_gain_q(double lin){
    double db = (lin > 1e-12) ? 20.0 * log10(lin) : -144.0;
    double q  = (db + 144.0) / 0.25;
    if (q < 0) q = 0; if (q > 65535) q = 65535;
    return (uint16_t)(q + 0.5);
}
static inline double qsc_gain_dq(uint16_t q){
    double db = 0.25 * (double)q - 144.0;
    return pow(10.0, db / 20.0);
}

/* ---------------- QSC file I/O -------------------------------- */
static inline int qsc_write(const char *path, const Qsc *q){
    int    cc  = q->h.channel_count ? q->h.channel_count : 1;
    size_t asz = (size_t)q->h.atom_count * QSC_ATOM_SIZE;
    size_t gsz = (size_t)q->h.residual_frames * q->h.band_count * cc * 2;
    int    hasc = (q->h.flags & QSC_FLAG_CRES) && q->cres;
    size_t csz = hasc ? (1 + (size_t)cc*4 + (size_t)cc*q->h.source_len*2) : 0;
    size_t tot = QSC_HEADER_SIZE + asz + gsz + csz + 4;
    uint8_t *buf = calloc(1, tot); if (!buf) return -1;
    uint8_t *p = buf;
    memcpy(p, QSC_MAGIC, 4);
    be16w(p+4,  QSC_VERSION);      be16w(p+6,  q->h.flags);
    be32w(p+8,  q->h.sample_rate); be64w(p+12, q->h.source_len);
    be32w(p+20, q->h.atom_count);  be16w(p+24, q->h.voice_count);
    p[26]=q->h.scale_count; p[27]=q->h.band_count;
    be16w(p+28, q->h.residual_hop);be32w(p+30, q->h.residual_frames);
    be32w(p+34, q->h.noise_seed);
    p[38] = q->h.channel_count ? q->h.channel_count : 1;  /* 38: channels; 39..43 reserved zero */
    p = buf + QSC_HEADER_SIZE;
    for (uint32_t i = 0; i < q->h.atom_count; i++, p += QSC_ATOM_SIZE){
        const QscAtom *a = &q->atoms[i];
        be32w(p, a->rank); be32w(p+4, a->onset); be32w(p+8, a->dur);
        bef32w(p+12, a->freq); bef32w(p+16, a->amp);
        bef32w(p+20, a->phase); bef32w(p+24, a->chirp);
        p[28]=a->layer; p[29]=a->voice; p[30]=a->scale_idx; p[31]=a->flags;
    }
    for (size_t i = 0; i < (size_t)q->h.residual_frames * q->h.band_count * cc; i++, p += 2)
        be16w(p, q->res_gains[i]);
    if (hasc){                                  /* coherent residual layer (QSC_FLAG_CRES) */
        *p++ = q->cres_bits;
        for (int c=0;c<cc;c++){ bef32w(p, (float)q->cres_scale[c]); p += 4; }
        for (size_t i = 0; i < (size_t)cc*q->h.source_len; i++, p += 2)
            be16w(p, (uint16_t)q->cres[i]);
    }
    uint32_t crc = qsc_crc32(buf + QSC_HEADER_SIZE, asz + gsz + csz);
    be32w(buf + 44, crc);                       /* header crc field */
    be32w(p, crc);                              /* trailer copy     */
    FILE *fp = fopen(path, "wb"); if (!fp){ free(buf); return -1; }
    size_t w = fwrite(buf, 1, tot, fp); fclose(fp); free(buf);
    return w == tot ? 0 : -1;
}

static inline int qsc_read(const char *path, Qsc *q){
    FILE *fp = fopen(path, "rb"); if (!fp) return -1;
    fseek(fp, 0, SEEK_END); long sz = ftell(fp); fseek(fp, 0, SEEK_SET);
    if (sz < QSC_HEADER_SIZE + 4){ fclose(fp); return -1; }
    uint8_t *buf = malloc(sz); if (!buf){ fclose(fp); return -1; }
    if (fread(buf, 1, sz, fp) != (size_t)sz){ fclose(fp); free(buf); return -1; }
    fclose(fp);
    if (memcmp(buf, QSC_MAGIC, 4) || be16r(buf+4) != QSC_VERSION){ free(buf); return -2; }
    memset(q, 0, sizeof *q);
    q->h.flags           = be16r(buf+6);
    q->h.sample_rate     = be32r(buf+8);
    q->h.source_len      = be64r(buf+12);
    q->h.atom_count      = be32r(buf+20);
    q->h.voice_count     = be16r(buf+24);
    q->h.scale_count     = buf[26];  q->h.band_count = buf[27];
    q->h.residual_hop    = be16r(buf+28);
    q->h.residual_frames = be32r(buf+30);
    q->h.noise_seed      = be32r(buf+34);
    q->h.channel_count   = buf[38] ? buf[38] : 1;      /* legacy 0 ⇒ mono */
    int cc = q->h.channel_count;
    size_t asz = (size_t)q->h.atom_count * QSC_ATOM_SIZE;
    size_t gsz = (size_t)q->h.residual_frames * q->h.band_count * cc * 2;
    int    hasc = (q->h.flags & QSC_FLAG_CRES) != 0;
    size_t csz = hasc ? (1 + (size_t)cc*4 + (size_t)cc*q->h.source_len*2) : 0;
    if ((size_t)sz < QSC_HEADER_SIZE + asz + gsz + csz + 4){ free(buf); return -2; }
    if (qsc_crc32(buf + QSC_HEADER_SIZE, asz + gsz + csz) != be32r(buf + 44)){ free(buf); return -3; }
    q->atoms = malloc(sizeof(QscAtom) * (q->h.atom_count ? q->h.atom_count : 1));
    const uint8_t *p = buf + QSC_HEADER_SIZE;
    for (uint32_t i = 0; i < q->h.atom_count; i++, p += QSC_ATOM_SIZE){
        QscAtom *a = &q->atoms[i];
        a->rank = be32r(p); a->onset = be32r(p+4); a->dur = be32r(p+8);
        a->freq = bef32r(p+12); a->amp = bef32r(p+16);
        a->phase = bef32r(p+20); a->chirp = bef32r(p+24);
        a->layer = p[28]; a->voice = p[29]; a->scale_idx = p[30]; a->flags = p[31];
    }
    q->res_gains = malloc(gsz ? gsz : 2);
    for (size_t i = 0; i < (size_t)q->h.residual_frames * q->h.band_count * cc; i++, p += 2)
        q->res_gains[i] = be16r(p);
    if (hasc){
        q->cres_bits = *p++;
        for (int c=0;c<cc;c++){ q->cres_scale[c] = (double)bef32r(p); p += 4; }
        size_t ns = (size_t)cc*q->h.source_len;
        q->cres = malloc((ns?ns:1)*sizeof(int16_t));
        for (size_t i=0;i<ns;i++, p+=2) q->cres[i] = (int16_t)be16r(p);
    }
    free(buf);
    return 0;
}
static inline void qsc_free(Qsc *q){ free(q->atoms); free(q->res_gains); free(q->cres); }

/* ---------------- minimal WAV I/O ----------------------------- */
static inline double *wav_read_mono(const char *path, uint32_t *sr, uint64_t *n){
    FILE *f = fopen(path, "rb"); if (!f) return NULL;
    uint8_t h[12]; if (fread(h,1,12,f)!=12 || memcmp(h,"RIFF",4) || memcmp(h+8,"WAVE",4)){ fclose(f); return NULL; }
    uint16_t fmt=0, ch=0, bits=0; uint32_t rate=0; double *out=NULL; uint64_t ns=0;
    for (;;){
        uint8_t ck[8]; if (fread(ck,1,8,f)!=8) break;
        uint32_t len = ck[4]|ck[5]<<8|ck[6]<<16|(uint32_t)ck[7]<<24;
        if (!memcmp(ck,"fmt ",4)){
            uint8_t b[40]={0}; uint32_t rd=len<40?len:40; if (fread(b,1,rd,f)!=rd) break;
            fmt = b[0]|b[1]<<8; ch = b[2]|b[3]<<8;
            rate = b[4]|b[5]<<8|b[6]<<16|(uint32_t)b[7]<<24;
            bits = b[14]|b[15]<<8;
            if (fmt==0xFFFE && rd>=26) fmt = b[24]|b[25]<<8;  /* EXTENSIBLE: real code in SubFormat GUID */
            if (len > rd) fseek(f, len-rd, SEEK_CUR);
        } else if (!memcmp(ck,"data",4)){
            uint32_t bytes = (bits/8)*ch; if (!bytes) break;
            ns = len / bytes; out = malloc(sizeof(double)*ns);
            uint8_t *raw = malloc(len);
            if (fread(raw,1,len,f)!=len){ free(raw); free(out); out=NULL; break; }
            for (uint64_t i=0;i<ns;i++){ double acc=0;
                for (int c=0;c<ch;c++){ const uint8_t *s = raw + i*bytes + c*(bits/8); double v=0;
                    if (fmt==1 && bits==16){ int16_t x=(int16_t)(s[0]|s[1]<<8); v=x/32768.0; }
                    else if (fmt==1 && bits==24){ int32_t x=(s[0]|s[1]<<8|s[2]<<16); if (x&0x800000) x|=~0xFFFFFF; v=x/8388608.0; }
                    else if (fmt==1 && bits==32){ int32_t x=(int32_t)(s[0]|s[1]<<8|s[2]<<16|(uint32_t)s[3]<<24); v=x/2147483648.0; }
                    else if (fmt==3 && bits==32){ float fx; memcpy(&fx,s,4); v=fx; }
                    else if (fmt==3 && bits==64){ double dx; memcpy(&dx,s,8); v=dx; }
                    acc += v;
                }
                out[i]=acc/ch;
            }
            free(raw); break;
        } else fseek(f, len + (len&1), SEEK_CUR);
    }
    fclose(f);
    if (out){ *sr = rate; *n = ns; }
    return out;
}
static inline int wav_write16(const char *path, const double *x, uint64_t n, uint32_t sr){
    FILE *f = fopen(path,"wb"); if(!f) return -1;
    uint32_t dlen = (uint32_t)(n*2), rlen = 36+dlen;
    uint8_t h[44]={0}; memcpy(h,"RIFF",4);
    h[4]=rlen;h[5]=rlen>>8;h[6]=rlen>>16;h[7]=rlen>>24; memcpy(h+8,"WAVEfmt ",8);
    h[16]=16; h[20]=1; h[22]=1;
    h[24]=sr;h[25]=sr>>8;h[26]=sr>>16;h[27]=sr>>24;
    uint32_t br=sr*2; h[28]=br;h[29]=br>>8;h[30]=br>>16;h[31]=br>>24;
    h[32]=2; h[34]=16; memcpy(h+36,"data",4);
    h[40]=dlen;h[41]=dlen>>8;h[42]=dlen>>16;h[43]=dlen>>24;
    fwrite(h,1,44,f);
    for (uint64_t i=0;i<n;i++){ double v=x[i]; if(v>1)v=1; if(v<-1)v=-1;
        int16_t s=(int16_t)lrint(v*32767.0); uint8_t b[2]={(uint8_t)s,(uint8_t)(s>>8)}; fwrite(b,1,2,f); }
    fclose(f); return 0;
}
/* Hi-res mono writers (mastering/audiophile path). 24-bit PCM (fmt 1) and 32-bit
   float (fmt 3, exact f64→f32, no quantization). Header mirrors wav_write16;
   bytes-per-sample `bps` and format code parameterised. Any sample rate. */
static inline int wav_write_hres(const char *path, const double *x, uint64_t n,
                                 uint32_t sr, int bps, int is_float){
    FILE *f=fopen(path,"wb"); if(!f) return -1;
    uint32_t dlen=(uint32_t)(n*bps), rlen=36+dlen, br=sr*(uint32_t)bps;
    uint8_t h[44]={0}; memcpy(h,"RIFF",4);
    h[4]=rlen;h[5]=rlen>>8;h[6]=rlen>>16;h[7]=rlen>>24; memcpy(h+8,"WAVEfmt ",8);
    h[16]=16; h[20]=(uint8_t)(is_float?3:1); h[22]=1;
    h[24]=sr;h[25]=sr>>8;h[26]=sr>>16;h[27]=sr>>24;
    h[28]=br;h[29]=br>>8;h[30]=br>>16;h[31]=br>>24;
    h[32]=(uint8_t)bps; h[34]=(uint8_t)(bps*8); memcpy(h+36,"data",4);
    h[40]=dlen;h[41]=dlen>>8;h[42]=dlen>>16;h[43]=dlen>>24;
    fwrite(h,1,44,f);
    for (uint64_t i=0;i<n;i++){ double v=x[i];
        if (is_float){ float fv=(float)v; fwrite(&fv,4,1,f); }
        else { if(v>1)v=1; if(v<-1)v=-1; int32_t s=(int32_t)lrint(v*8388607.0);
               uint8_t b[3]={(uint8_t)s,(uint8_t)(s>>8),(uint8_t)(s>>16)}; fwrite(b,1,3,f); } }
    fclose(f); return 0;
}
static inline int wav_write24 (const char *p,const double *x,uint64_t n,uint32_t sr){ return wav_write_hres(p,x,n,sr,3,0); }
static inline int wav_write_f32(const char *p,const double *x,uint64_t n,uint32_t sr){ return wav_write_hres(p,x,n,sr,4,1); }

static inline int raw_write_f64(const char *path, const double *x, uint64_t n){
    FILE *f=fopen(path,"wb"); if(!f) return -1;
    size_t w=fwrite(x,8,n,f); fclose(f); return w==n?0:-1;
}
/* Stereo WAV reader → mid/side. Parses any channel count (mono ⇒ M=signal,S=0;
   >2 ⇒ first two channels). M=(L+R)/2, S=(L-R)/2. Same chunk parse as
   wav_read_mono; returns #frames (0 on failure), allocates *mid and *side. */
static inline uint64_t wav_read_ms(const char *path, uint32_t *sr, double **mid, double **side){
    FILE *f = fopen(path,"rb"); if(!f) return 0;
    uint8_t h[12]; if (fread(h,1,12,f)!=12 || memcmp(h,"RIFF",4) || memcmp(h+8,"WAVE",4)){ fclose(f); return 0; }
    uint16_t fmt=0,ch=0,bits=0; uint32_t rate=0; uint64_t ns=0; double *M=NULL,*S=NULL;
    for (;;){
        uint8_t ck[8]; if (fread(ck,1,8,f)!=8) break;
        uint32_t len = ck[4]|ck[5]<<8|ck[6]<<16|(uint32_t)ck[7]<<24;
        if (!memcmp(ck,"fmt ",4)){ uint8_t b[40]={0}; uint32_t rd=len<40?len:40; if (fread(b,1,rd,f)!=rd) break;
            fmt=b[0]|b[1]<<8; ch=b[2]|b[3]<<8; rate=b[4]|b[5]<<8|b[6]<<16|(uint32_t)b[7]<<24; bits=b[14]|b[15]<<8;
            if (fmt==0xFFFE && rd>=26) fmt = b[24]|b[25]<<8;  /* EXTENSIBLE: real code in SubFormat GUID */
            if (len>rd) fseek(f,len-rd,SEEK_CUR);
        } else if (!memcmp(ck,"data",4)){
            uint32_t bpf=(bits/8)*ch; if(!bpf) break; ns=len/bpf;
            M=malloc(sizeof(double)*ns); S=malloc(sizeof(double)*ns);
            uint8_t *raw=malloc(len); if (fread(raw,1,len,f)!=len){ free(raw);free(M);free(S);M=S=NULL; break; }
            for (uint64_t i=0;i<ns;i++){ double v[2]={0,0};
                for (int c=0;c<ch;c++){ const uint8_t *s=raw+i*bpf+c*(bits/8); double x=0;
                    if (fmt==1&&bits==16){ int16_t t=(int16_t)(s[0]|s[1]<<8); x=t/32768.0; }
                    else if (fmt==1&&bits==24){ int32_t t=(s[0]|s[1]<<8|s[2]<<16); if(t&0x800000)t|=~0xFFFFFF; x=t/8388608.0; }
                    else if (fmt==1&&bits==32){ int32_t t=(int32_t)(s[0]|s[1]<<8|s[2]<<16|(uint32_t)s[3]<<24); x=t/2147483648.0; }
                    else if (fmt==3&&bits==32){ float fx; memcpy(&fx,s,4); x=fx; }
                    else if (fmt==3&&bits==64){ double dx; memcpy(&dx,s,8); x=dx; }
                    if (c<2) v[c]=x; }
                double L=v[0], R=(ch>=2)?v[1]:v[0];
                M[i]=0.5*(L+R); S[i]=0.5*(L-R);
            }
            free(raw); break;
        } else fseek(f, len+(len&1), SEEK_CUR);
    }
    fclose(f);
    if (M){ *sr=rate; *mid=M; *side=S; return ns; }
    free(M); free(S); return 0;
}
/* Interleaved hi-res stereo writer from mid/side (L=M+S, R=M-S). 24-bit PCM (is_float=0,
   bps=3) or 32-bit float (is_float=1, bps=4). Mirrors wav_write_hres, 2 channels. */
static inline int wav_write_hres_ms(const char *path, const double *mid, const double *side,
                                    uint64_t n, uint32_t sr, int bps, int is_float){
    FILE *f=fopen(path,"wb"); if(!f) return -1;
    uint32_t dlen=(uint32_t)(n*2*bps), rlen=36+dlen, ba=(uint32_t)(2*bps), br=sr*ba;
    uint8_t h[44]={0}; memcpy(h,"RIFF",4);
    h[4]=rlen;h[5]=rlen>>8;h[6]=rlen>>16;h[7]=rlen>>24; memcpy(h+8,"WAVEfmt ",8);
    h[16]=16; h[20]=(uint8_t)(is_float?3:1); h[22]=2;
    h[24]=sr;h[25]=sr>>8;h[26]=sr>>16;h[27]=sr>>24;
    h[28]=br;h[29]=br>>8;h[30]=br>>16;h[31]=br>>24;
    h[32]=(uint8_t)ba; h[34]=(uint8_t)(bps*8); memcpy(h+36,"data",4);
    h[40]=dlen;h[41]=dlen>>8;h[42]=dlen>>16;h[43]=dlen>>24;
    fwrite(h,1,44,f);
    for (uint64_t i=0;i<n;i++){ double s2[2]={mid[i]+side[i], mid[i]-side[i]};
        for (int c=0;c<2;c++){ double v=s2[c];
            if (is_float){ float fv=(float)v; fwrite(&fv,4,1,f); }
            else { if(v>1)v=1; if(v<-1)v=-1; int32_t s=(int32_t)lrint(v*8388607.0);
                   uint8_t b[3]={(uint8_t)s,(uint8_t)(s>>8),(uint8_t)(s>>16)}; fwrite(b,1,3,f); } } }
    fclose(f); return 0;
}
static inline int wav_write24_ms (const char *p,const double *m,const double *s,uint64_t n,uint32_t sr){ return wav_write_hres_ms(p,m,s,n,sr,3,0); }
static inline int wav_write_f32_ms(const char *p,const double *m,const double *s,uint64_t n,uint32_t sr){ return wav_write_hres_ms(p,m,s,n,sr,4,1); }
/* Interleaved 16-bit stereo writer from mid/side (L=M+S, R=M-S). */
static inline int wav_write16_ms(const char *path, const double *mid, const double *side, uint64_t n, uint32_t sr){
    FILE *f=fopen(path,"wb"); if(!f) return -1;
    uint32_t dlen=(uint32_t)(n*4), rlen=36+dlen;
    uint8_t h[44]={0}; memcpy(h,"RIFF",4);
    h[4]=rlen;h[5]=rlen>>8;h[6]=rlen>>16;h[7]=rlen>>24; memcpy(h+8,"WAVEfmt ",8);
    h[16]=16; h[20]=1; h[22]=2;                       /* PCM, 2 channels */
    h[24]=sr;h[25]=sr>>8;h[26]=sr>>16;h[27]=sr>>24;
    uint32_t br=sr*4; h[28]=br;h[29]=br>>8;h[30]=br>>16;h[31]=br>>24;
    h[32]=4; h[34]=16; memcpy(h+36,"data",4);         /* block align 4 */
    h[40]=dlen;h[41]=dlen>>8;h[42]=dlen>>16;h[43]=dlen>>24;
    fwrite(h,1,44,f);
    for (uint64_t i=0;i<n;i++){
        double L=mid[i]+side[i], R=mid[i]-side[i];
        if(L>1)L=1; if(L<-1)L=-1; if(R>1)R=1; if(R<-1)R=-1;
        int16_t l=(int16_t)lrint(L*32767.0), r=(int16_t)lrint(R*32767.0);
        uint8_t b[4]={(uint8_t)l,(uint8_t)(l>>8),(uint8_t)r,(uint8_t)(r>>8)}; fwrite(b,1,4,f);
    }
    fclose(f); return 0;
}

static const int QSC_SCALE_TAB[QSC_SCALES] =
    {64,128,256,512,1024,2048,4096,8192,16384};

#endif /* DEMOD_QSC_H */
