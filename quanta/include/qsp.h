/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-DeMoD-Commercial
 * qsp.h — QSP speech container (Harmonic + Noise Model), spec Appendix P.
 * Copyright (c) 2026 DeMoD LLC.
 *
 * A speech score is a sequence of pitch-synchronous frames. Each frame carries:
 *   { onset (pitch mark, samples), f0 (Hz), voiced flag, MVF (Hz, harmonic/noise
 *     crossover), Kf harmonics {amp, phase} at k*f0 < MVF, 24-band noise gains }.
 * Voiced energy = harmonic sinusoids (k*f0); everything above MVF + all unvoiced =
 * the codec's existing 24-band noise residual. Synthesis (speech-render / -freeze)
 * reuses qsc.h's libm-free primitives verbatim (sine table, LCG, SVF bank).
 *
 * Container discipline mirrors QSS/qsz: big-endian header with a CRC-16 over the
 * first 32 bytes, then a Rice-coded body (qbits.h), then a CRC-32 over the body.
 * Harmonic amp/phase use the QSS quant grids; noise gains use qsc_gain_q (0.25 dB).
 */
#ifndef DEMOD_QSP_H
#define DEMOD_QSP_H
#include "qsc.h"
#include "qss.h"      /* qss_crc16, qss_amp_q/dq, qss_phase_q/dq, qss_freq_q/dq, QSS_PHBITS */
#include "qbits.h"    /* BitW/BitR, Rice, zig-zag */
#include <math.h>

#define QSP_MAGIC "QSP1"
#define QSP_HDR   48
#define QSP_KMAX  256                     /* max harmonics per frame (hard cap) */
#define QSP_FLAG_SINES 0x0001             /* frames carry general sinusoidal partials
                                             (freq[] present) instead of k*f0 harmonics */

typedef struct {
    uint32_t sample_rate;
    uint64_t source_len;
    uint32_t frame_count;
    uint16_t kmax;                        /* max harmonics across frames */
    uint16_t band_count;                  /* == QSC_BANDS */
    uint32_t noise_seed;
    uint16_t flags;
} QspHeader;

typedef struct {
    uint32_t onset;                       /* pitch mark, samples */
    float    f0;                          /* Hz (0 => unvoiced) */
    uint8_t  voiced;
    float    mvf;                         /* Hz, harmonic/noise crossover */
    uint16_t na;                          /* number of partials (harmonics or sines) */
    float   *amp;                         /* na amplitudes (linear) */
    float   *phase;                       /* na phases (radians) */
    float   *freq;                         /* na partial freqs (Hz) — SINES mode only */
    uint16_t gain[QSC_BANDS];             /* 24-band noise gains (qsc_gain_q) */
} QspFrame;

typedef struct { QspHeader h; QspFrame *fr; } Qsp;

/* mvf quantized to 20 Hz steps (0..~24 kHz) */
static inline uint32_t qsp_mvf_q(double hz){ long q=lround(hz/20.0); return q<0?0:(uint32_t)q; }
static inline double   qsp_mvf_dq(uint32_t q){ return (double)q*20.0; }

/* ---- McAulay-Quatieri harmonic synthesis (shared by render + analyzer) ----
 * The renderer IS the normative audio path; the analyzer must reconstruct the
 * harmonic layer identically so its noise residual (x - harm) matches what the
 * renderer leaves. Both therefore call qsp_render_harmonics. Phases/frequencies
 * are in TURNS / turns-per-sample so the sine table indexes directly (libm-free
 * hot loop). The cycle-unwrap round() is per-segment, not per-sample. */
static inline void qsp_mq_track(double *out, uint64_t N,
                                int64_t t0, int64_t t1,
                                double A0, double ph0, double nu0,
                                double A1, double ph1, double nu1,
                                const double *stab){
    double T = (double)(t1 - t0);
    if (T < 1.0) return;
    double m = (ph0 + nu0*T - ph1) + 0.5*(nu1 - nu0)*T;
    double M = (double)(int64_t)(m >= 0 ? m + 0.5 : m - 0.5);   /* round */
    double x = ph1 + M - ph0 - nu0*T;
    double z = nu1 - nu0;
    double a = 3.0*x/(T*T)    - z/T;
    double b = -2.0*x/(T*T*T) + z/(T*T);
    double dA = (A1 - A0)/T;
    for (int64_t i = 0; i < (int64_t)T; i++){
        int64_t n = t0 + i; if (n < 0 || n >= (int64_t)N) continue;
        double tt  = (double)i;
        double phi = ph0 + nu0*tt + (a + b*tt)*tt*tt;
        double amp = A0 + dA*tt;
        double frac = phi - (double)(int64_t)phi; if (frac < 0) frac += 1.0;
        out[n] += amp * qsc_slin(stab, frac*QSC_TAB);
    }
}

/* Reconstruct the full harmonic layer into out[] (accumulates; caller zeroes).
 * A track for harmonic k spans consecutive frames; a harmonic present on only one
 * side (or a whole voiced<->unvoiced transition) is a birth/death that ramps
 * amplitude from/to zero at held frequency. First/last voiced frames get a
 * one-period ramp so onsets/releases start and end at zero. */
static inline void qsp_render_harmonics(double *out, uint64_t N, uint32_t sr,
                                        uint32_t nf, const QspFrame *fr,
                                        const double *stab){
    double inv_sr = 1.0/(double)sr, i2pi = 1.0/(2.0*M_PI);
    for (uint32_t fi=0; fi+1<nf; fi++){
        const QspFrame *A=&fr[fi], *B=&fr[fi+1];
        int naA = A->voiced ? A->na : 0, naB = B->voiced ? B->na : 0;
        if (!naA && !naB) continue;
        int64_t t0=(int64_t)A->onset, t1=(int64_t)B->onset;
        if (t1<=t0) continue;
        double T=(double)(t1-t0);
        int kmax = naA>naB?naA:naB;
        for (int k=1;k<=kmax;k++){
            int inA = k<=naA, inB = k<=naB;
            double nuA=(double)k*A->f0*inv_sr, nuB=(double)k*B->f0*inv_sr;
            double A0,A1,ph0,ph1,f0n,f1n;
            if (inA && inB){
                A0=A->amp[k-1]; ph0=A->phase[k-1]*i2pi; f0n=nuA;
                A1=B->amp[k-1]; ph1=B->phase[k-1]*i2pi; f1n=nuB;
            } else if (inA){
                A0=A->amp[k-1]; ph0=A->phase[k-1]*i2pi; f0n=nuA;
                A1=0.0; f1n=nuA; ph1=ph0+nuA*T;
            } else {
                A1=B->amp[k-1]; ph1=B->phase[k-1]*i2pi; f1n=nuB;
                A0=0.0; f0n=nuB; ph0=ph1-nuB*T;
            }
            qsp_mq_track(out,N,t0,t1,A0,ph0,f0n,A1,ph1,f1n,stab);
        }
    }
    if (nf){
        const QspFrame *F0=&fr[0];
        if (F0->voiced && F0->na){ int p=(int)((double)sr/(F0->f0>1?F0->f0:1)+0.5); if(p<1)p=1;
            for (int k=1;k<=F0->na;k++){ double nu=(double)k*F0->f0*inv_sr, ph=F0->phase[k-1]*i2pi;
                qsp_mq_track(out,N,(int64_t)F0->onset-p,(int64_t)F0->onset,0.0,ph-nu*p,nu,F0->amp[k-1],ph,nu,stab); } }
        const QspFrame *FL=&fr[nf-1];
        if (FL->voiced && FL->na){ int p=(int)((double)sr/(FL->f0>1?FL->f0:1)+0.5); if(p<1)p=1;
            for (int k=1;k<=FL->na;k++){ double nu=(double)k*FL->f0*inv_sr, ph=FL->phase[k-1]*i2pi;
                qsp_mq_track(out,N,(int64_t)FL->onset,(int64_t)FL->onset+p,FL->amp[k-1],ph,nu,0.0,ph+nu*p,nu,stab); } }
    }
}

/* ---- General sinusoidal MQ synthesis (SINES mode) ----
 * Frames carry arbitrary partials (freq[],amp[],phase[]); tracks are formed by
 * greedy nearest-frequency matching between consecutive frames (McAulay-Quatieri
 * 1986 peak matching). Matched pairs are a continuous cubic-phase track; unmatched
 * partials are deaths (ramp to zero, this frame) or births (ramp from zero, next
 * frame) at held frequency. This captures inharmonic/coherent energy the strict
 * k*f0 harmonic model leaves in the residual. Uses the same libm-free qsp_mq_track.
 * `matchcents`: max track-matching interval in cents (e.g. 100 = one semitone). */
static inline void qsp_render_sines(double *out, uint64_t N, uint32_t sr,
                                    uint32_t nf, const QspFrame *fr,
                                    const double *stab, double matchcents){
    double inv_sr=1.0/(double)sr, i2pi=1.0/(2.0*M_PI);
    double ratio = matchcents/1200.0;           /* octave fraction for the match gate */
    /* per-partial "used" flags for the next frame, reused each pair */
    uint8_t *usedB=NULL; int capB=0;
    for (uint32_t fi=0; fi+1<nf; fi++){
        const QspFrame *A=&fr[fi], *B=&fr[fi+1];
        int64_t t0=(int64_t)A->onset, t1=(int64_t)B->onset; if (t1<=t0) continue;
        double T=(double)(t1-t0);
        int nb=B->na;
        if (nb>capB){ capB=nb; usedB=(uint8_t*)realloc(usedB,capB); }
        for (int j=0;j<nb;j++) usedB[j]=0;
        /* match each A-partial to the nearest unused B-partial within the gate */
        for (int a=0; a<A->na; a++){
            double fa=A->freq[a]; if (fa<=0) continue;
            int best=-1; double bestd=1e30;
            for (int j=0;j<nb;j++){ if (usedB[j]) continue; double fb=B->freq[j]; if (fb<=0) continue;
                double d=fa>fb?fa/fb:fb/fa;                 /* freq ratio (>=1) */
                double cents=d-1.0;                          /* ~ratio for small intervals */
                if (cents<=ratio && d-1.0<bestd){ bestd=d-1.0; best=j; } }
            double A0=A->amp[a], ph0=A->phase[a]*i2pi, nu0=fa*inv_sr;
            if (best>=0){                                    /* matched track */
                usedB[best]=1;
                double A1=B->amp[best], ph1=B->phase[best]*i2pi, nu1=B->freq[best]*inv_sr;
                qsp_mq_track(out,N,t0,t1,A0,ph0,nu0,A1,ph1,nu1,stab);
            } else {                                         /* death: ramp to zero */
                qsp_mq_track(out,N,t0,t1,A0,ph0,nu0,0.0,ph0+nu0*T,nu0,stab);
            }
        }
        /* unmatched B-partials are births: ramp from zero over this segment */
        for (int j=0;j<nb;j++){ if (usedB[j]) continue; double fb=B->freq[j]; if (fb<=0) continue;
            double A1=B->amp[j], ph1=B->phase[j]*i2pi, nu1=fb*inv_sr;
            qsp_mq_track(out,N,t0,t1,0.0,ph1-nu1*T,nu1,A1,ph1,nu1,stab); }
    }
    free(usedB);
    /* lead-out: last frame's partials ramp to zero over ~one frame hop */
    if (nf>=2){
        const QspFrame *FL=&fr[nf-1]; int64_t hop=(int64_t)FL->onset-(int64_t)fr[nf-2].onset; if(hop<1)hop=1;
        for (int j=0;j<FL->na;j++){ double fb=FL->freq[j]; if(fb<=0)continue;
            double nu=fb*inv_sr, ph=FL->phase[j]*i2pi;
            qsp_mq_track(out,N,(int64_t)FL->onset,(int64_t)FL->onset+hop,FL->amp[j],ph,nu,0.0,ph+nu*hop,nu,stab); }
    }
}

/* ---- Rice column helper (reuses qbits) ---- */
static inline void qsp__putcol(BitW *w, const uint32_t *v, int n){
    int k = rice_best_k(v, n); bw_putn(w, (uint32_t)k, 5);
    for (int i=0;i<n;i++) rice_put(w, v[i], k);
}
static inline void qsp__getcol(BitR *r, uint32_t *v, int n){
    int k=(int)br_getn(r,5); for (int i=0;i<n;i++) v[i]=rice_get(r,k);
}

/* ------------------------------ writer ------------------------------ */
static inline int qsp_write(const char *path, const Qsp *q){
    uint32_t nf = q->h.frame_count, B = q->h.band_count;
    /* total harmonics across frames */
    size_t th = 0; for (uint32_t f=0; f<nf; f++) th += q->fr[f].na;

    BitW w; bw_init(&w);
    uint32_t *col = malloc((size_t)(nf?nf:1)*4);
    int32_t prev;
    /* per-frame columns */
    prev=0; for (uint32_t f=0;f<nf;f++){ col[f]=zz_enc((int32_t)q->fr[f].onset-prev); prev=(int32_t)q->fr[f].onset; }
    qsp__putcol(&w, col, (int)nf);
    for (uint32_t f=0;f<nf;f++){ col[f]=qss_freq_q(q->fr[f].f0>1.0?q->fr[f].f0:20.0); } qsp__putcol(&w,col,(int)nf); /* f0 (cents) */
    for (uint32_t f=0;f<nf;f++) bw_put1(&w, q->fr[f].voiced&1);
    for (uint32_t f=0;f<nf;f++){ col[f]=qsp_mvf_q(q->fr[f].mvf); } qsp__putcol(&w,col,(int)nf);
    for (uint32_t f=0;f<nf;f++){ col[f]=q->fr[f].na; } qsp__putcol(&w,col,(int)nf);
    /* harmonic amps (all frames concatenated), then phases raw */
    uint32_t *ha = malloc((th?th:1)*4); size_t hi=0;
    for (uint32_t f=0;f<nf;f++) for (uint16_t k=0;k<q->fr[f].na;k++) ha[hi++]=qss_amp_q(q->fr[f].amp[k]);
    qsp__putcol(&w, ha, (int)th);
    for (uint32_t f=0;f<nf;f++) for (uint16_t k=0;k<q->fr[f].na;k++) bw_putn(&w, qss_phase_q(q->fr[f].phase[k]), QSS_PHBITS);
    /* SINES mode: per-partial frequencies (cents grid, all frames concatenated) */
    if (q->h.flags & QSP_FLAG_SINES){
        uint32_t *hf = malloc((th?th:1)*4); size_t fi2=0;
        for (uint32_t f=0;f<nf;f++) for (uint16_t k=0;k<q->fr[f].na;k++) hf[fi2++]=qss_freq_q(q->fr[f].freq[k]>1.0?q->fr[f].freq[k]:20.0);
        qsp__putcol(&w, hf, (int)th); free(hf);
    }
    /* noise gains: per band, temporal zig-zag delta */
    uint32_t *gc = malloc((size_t)(nf?nf:1)*4);
    for (uint32_t b=0;b<B;b++){ prev=0; for (uint32_t f=0;f<nf;f++){ int32_t g=q->fr[f].gain[b]; gc[f]=zz_enc(g-prev); prev=g; } qsp__putcol(&w,gc,(int)nf); }
    free(ha); free(col); free(gc);

    size_t body = bw_bytes(&w);
    uint8_t hdr[QSP_HDR]; memset(hdr,0,sizeof hdr);
    memcpy(hdr, QSP_MAGIC, 4);
    be32w(hdr+4, q->h.sample_rate); be64w(hdr+8, q->h.source_len);
    be32w(hdr+16, nf); be16w(hdr+20, q->h.kmax); be16w(hdr+22, (uint16_t)B);
    be32w(hdr+24, q->h.noise_seed); be16w(hdr+28, q->h.flags);
    be16w(hdr+32, qss_crc16(hdr, 32));                    /* header CRC-16 over first 32 */
    uint32_t bcrc = qsc_crc32(w.buf, body);
    FILE *o=fopen(path,"wb"); if(!o){ bw_free(&w); return -1; }
    fwrite(hdr,1,QSP_HDR,o); fwrite(w.buf,1,body,o);
    uint8_t cb[4]; be32w(cb,bcrc); fwrite(cb,1,4,o); fclose(o);
    bw_free(&w);
    return 0;
}

/* ------------------------------ reader ------------------------------ */
static inline int qsp_read(const char *path, Qsp *q){
    FILE *f=fopen(path,"rb"); if(!f) return -1;
    fseek(f,0,SEEK_END); long sz=ftell(f); fseek(f,0,SEEK_SET);
    if (sz < QSP_HDR+4){ fclose(f); return -1; }
    uint8_t *buf=malloc(sz); if (fread(buf,1,sz,f)!=(size_t)sz){ fclose(f); free(buf); return -1; } fclose(f);
    if (memcmp(buf,QSP_MAGIC,4)){ free(buf); return -2; }
    if (qss_crc16(buf,32)!=be16r(buf+32)){ free(buf); return -3; }
    memset(q,0,sizeof *q);
    q->h.sample_rate=be32r(buf+4); q->h.source_len=be64r(buf+8);
    q->h.frame_count=be32r(buf+16); q->h.kmax=be16r(buf+20); q->h.band_count=be16r(buf+22);
    q->h.noise_seed=be32r(buf+24); q->h.flags=be16r(buf+28);
    uint32_t nf=q->h.frame_count, B=q->h.band_count;
    if (B>QSC_BANDS){ free(buf); return -4; }
    size_t body=(size_t)sz-QSP_HDR-4;
    if (qsc_crc32(buf+QSP_HDR, body)!=be32r(buf+sz-4)){ free(buf); return -5; }

    q->fr = calloc(nf?nf:1, sizeof(QspFrame));
    BitR r; br_init(&r, buf+QSP_HDR, body);
    uint32_t *col=malloc((size_t)(nf?nf:1)*4); int32_t prev;
    qsp__getcol(&r,col,(int)nf); prev=0; for (uint32_t i=0;i<nf;i++){ int32_t o=prev+zz_dec(col[i]); q->fr[i].onset=(uint32_t)o; prev=o; }
    qsp__getcol(&r,col,(int)nf); for (uint32_t i=0;i<nf;i++) q->fr[i].f0=(float)qss_freq_dq(col[i]);
    for (uint32_t i=0;i<nf;i++) q->fr[i].voiced=(uint8_t)br_get1(&r);
    qsp__getcol(&r,col,(int)nf); for (uint32_t i=0;i<nf;i++) q->fr[i].mvf=(float)qsp_mvf_dq(col[i]);
    qsp__getcol(&r,col,(int)nf); size_t th=0; for (uint32_t i=0;i<nf;i++){ q->fr[i].na=(uint16_t)col[i]; th+=col[i]; }
    uint32_t *ha=malloc((th?th:1)*4); qsp__getcol(&r,ha,(int)th);
    size_t hi=0;
    for (uint32_t i=0;i<nf;i++){ uint16_t na=q->fr[i].na;
        q->fr[i].amp=malloc((na?na:1)*sizeof(float)); q->fr[i].phase=malloc((na?na:1)*sizeof(float));
        for (uint16_t k=0;k<na;k++) q->fr[i].amp[k]=(float)qss_amp_dq(ha[hi++]); }
    for (uint32_t i=0;i<nf;i++) for (uint16_t k=0;k<q->fr[i].na;k++) q->fr[i].phase[k]=(float)qss_phase_dq(br_getn(&r,QSS_PHBITS));
    if (q->h.flags & QSP_FLAG_SINES){                     /* per-partial frequencies */
        uint32_t *hf=malloc((th?th:1)*4); qsp__getcol(&r,hf,(int)th); size_t fj=0;
        for (uint32_t i=0;i<nf;i++){ uint16_t na=q->fr[i].na; q->fr[i].freq=malloc((na?na:1)*sizeof(float));
            for (uint16_t k=0;k<na;k++) q->fr[i].freq[k]=(float)qss_freq_dq(hf[fj++]); }
        free(hf);
    }
    for (uint32_t b=0;b<B;b++){ qsp__getcol(&r,col,(int)nf); prev=0; for (uint32_t i=0;i<nf;i++){ int32_t g=prev+zz_dec(col[i]); q->fr[i].gain[b]=(uint16_t)g; prev=g; } }
    free(buf); free(col); free(ha);
    return 0;
}
static inline void qsp_free(Qsp *q){
    if (q->fr){ for (uint32_t i=0;i<q->h.frame_count;i++){ free(q->fr[i].amp); free(q->fr[i].phase); free(q->fr[i].freq); } free(q->fr); q->fr=NULL; }
}
#endif /* DEMOD_QSP_H */
