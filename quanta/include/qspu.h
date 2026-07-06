/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-DeMoD-Commercial
 * qspu.h — Quanta unit-vocoder containers. Two parts:
 *   .qinv  baked INVENTORY (shipped both ends, not part of bitrate): K acoustic-unit
 *          LSF-trajectory codewords (nsub×order f32) + per-unit voicing subpattern.
 *   .qspu  transmitted UNIT STREAM: per unit { id, duration, pitch start/end, energy
 *          contour, voicing contour }, bit-packed (qbits). This is the coded bitrate.
 * Mirrors the Python prototype tools/qunits.py so the C and Python codecs interoperate.
 * Copyright (c) 2026 DeMoD LLC.
 */
#ifndef DEMOD_QSPU_H
#define DEMOD_QSPU_H
#include "qsc.h"       /* big-endian helpers + crc32 */
#include "qbits.h"     /* bit I/O */

#define QSPU_INV_MAGIC "QINV"
#define QSPU_STR_MAGIC "QSPU"
#define QSPU_DURB 4
#define QSPU_PITB 6
#define QSPU_ENGB 3      /* per sub-frame energy */

typedef struct { uint32_t sr; int K, order, nsub; float *cb; uint8_t *vpat; } QInv;
/* one quantized unit: id + dur + pitch(start,end) + energy[nsub] + voicing[nsub] */
typedef struct { uint32_t id; uint8_t dur,p0,p1; uint8_t *econ; uint8_t *vcon; } QUnit;
typedef struct { uint32_t sr; uint64_t source_len; uint32_t nu; int nsub; QUnit *u; } QStr;

static inline int qspu_idbits(int K){ int b=0; while ((1<<b)<K) b++; return b<1?1:b; }

/* -------- inventory -------- */
static inline int qinv_write(const char *path, const QInv *v){
    FILE *f=fopen(path,"wb"); if(!f) return -1;
    uint8_t h[24]={0}; memcpy(h,QSPU_INV_MAGIC,4); be32w(h+4,v->sr);
    be32w(h+8,(uint32_t)v->K); be32w(h+12,(uint32_t)v->order); be32w(h+16,(uint32_t)v->nsub);
    be32w(h+20, qsc_crc32(h,20));
    fwrite(h,1,24,f);
    fwrite(v->cb,sizeof(float),(size_t)v->K*v->nsub*v->order,f);
    fwrite(v->vpat,1,(size_t)v->K*v->nsub,f);
    fclose(f); return 0;
}
static inline int qinv_read(const char *path, QInv *v){
    FILE *f=fopen(path,"rb"); if(!f) return -1;
    uint8_t h[24]; if(fread(h,1,24,f)!=24||memcmp(h,QSPU_INV_MAGIC,4)){fclose(f);return -2;}
    if (qsc_crc32(h,20)!=be32r(h+20)){ fclose(f); return -3; }
    v->sr=be32r(h+4); v->K=(int)be32r(h+8); v->order=(int)be32r(h+12); v->nsub=(int)be32r(h+16);
    size_t nc=(size_t)v->K*v->nsub*v->order, np=(size_t)v->K*v->nsub;
    v->cb=malloc(nc*sizeof(float)); v->vpat=malloc(np);
    if(fread(v->cb,sizeof(float),nc,f)!=nc||fread(v->vpat,1,np,f)!=np){fclose(f);return -4;}
    fclose(f); return 0;
}
static inline void qinv_free(QInv *v){ free(v->cb); free(v->vpat); v->cb=NULL; v->vpat=NULL; }

/* -------- unit stream -------- */
static inline int qspu_write(const char *path, const QStr *st, int idbits){
    BitW w; bw_init(&w);
    for (uint32_t i=0;i<st->nu;i++){ const QUnit *u=&st->u[i];
        bw_putn(&w,u->id,idbits); bw_putn(&w,u->dur,QSPU_DURB);
        bw_putn(&w,u->p0,QSPU_PITB); bw_putn(&w,u->p1,QSPU_PITB);
        for (int j=0;j<st->nsub;j++) bw_putn(&w,u->econ[j],QSPU_ENGB);
        for (int j=0;j<st->nsub;j++) bw_put1(&w,u->vcon[j]&1);
    }
    size_t body=bw_bytes(&w);
    uint8_t h[32]={0}; memcpy(h,QSPU_STR_MAGIC,4); be32w(h+4,st->sr);
    be64w(h+8,st->source_len); be32w(h+16,st->nu); be32w(h+20,(uint32_t)st->nsub);
    be32w(h+24,(uint32_t)idbits); be32w(h+28,qsc_crc32(h,28));
    FILE *f=fopen(path,"wb"); if(!f){bw_free(&w);return -1;}
    fwrite(h,1,32,f); fwrite(w.buf,1,body,f); uint8_t cb[4]; be32w(cb,qsc_crc32(w.buf,body)); fwrite(cb,1,4,f);
    fclose(f); bw_free(&w); return 0;
}
static inline int qspu_read(const char *path, QStr *st, int *idbits){
    FILE *f=fopen(path,"rb"); if(!f) return -1;
    fseek(f,0,SEEK_END); long sz=ftell(f); fseek(f,0,SEEK_SET);
    if (sz<36){ fclose(f); return -1; }
    uint8_t *buf=malloc(sz); if(fread(buf,1,sz,f)!=(size_t)sz){fclose(f);free(buf);return -1;} fclose(f);
    if (memcmp(buf,QSPU_STR_MAGIC,4)||qsc_crc32(buf,28)!=be32r(buf+28)){ free(buf); return -2; }
    st->sr=be32r(buf+4); st->source_len=be64r(buf+8); st->nu=be32r(buf+16);
    st->nsub=(int)be32r(buf+20); *idbits=(int)be32r(buf+24);
    size_t body=(size_t)sz-32-4;
    if (qsc_crc32(buf+32,body)!=be32r(buf+sz-4)){ free(buf); return -3; }
    BitR r; br_init(&r,buf+32,body);
    st->u=calloc(st->nu?st->nu:1,sizeof(QUnit));
    for (uint32_t i=0;i<st->nu;i++){ QUnit *u=&st->u[i];
        u->id=br_getn(&r,*idbits); u->dur=(uint8_t)br_getn(&r,QSPU_DURB);
        u->p0=(uint8_t)br_getn(&r,QSPU_PITB); u->p1=(uint8_t)br_getn(&r,QSPU_PITB);
        u->econ=malloc(st->nsub); u->vcon=malloc(st->nsub);
        for (int j=0;j<st->nsub;j++) u->econ[j]=(uint8_t)br_getn(&r,QSPU_ENGB);
        for (int j=0;j<st->nsub;j++) u->vcon[j]=(uint8_t)br_get1(&r);
    }
    free(buf); return 0;
}
static inline void qspu_free(QStr *st){ if(st->u){ for(uint32_t i=0;i<st->nu;i++){free(st->u[i].econ);free(st->u[i].vcon);} free(st->u); st->u=NULL; } }
#endif /* DEMOD_QSPU_H */
