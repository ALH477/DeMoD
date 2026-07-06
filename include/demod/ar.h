// SPDX-License-Identifier: MPL-2.0
/*
 * DeMoD UI Framework — AR passthrough HUD (dm.ar)
 * Composites a live camera/video feed under the flat UI as a background layer,
 * turning any Lua app into an instrument overlay. Decode stays OUT OF PROCESS
 * (an ffmpeg/v4l2/GStreamer producer writes raw RGBA to a file / mmap'd file /
 * POSIX shared memory / FIFO); this layer only ever consumes finished pixels —
 * the same licensing-clean pattern as auto/surfaces/camera.lua, generalized.
 *
 * Optional; compiled only under -DDEMOD_AR (make ARHUD=1). The default build is
 * byte-identical and dm.ar is absent.
 *
 * Copyright (c) 2026 DeMoD LLC.
 * Licensed under the Mozilla Public License, v. 2.0; see LICENSE.
 */
#ifndef DEMOD_AR_H
#define DEMOD_AR_H

#include <stdint.h>
#include <stdbool.h>
#include "demod/framebuffer.h"   /* DmFramebuffer, DmRect, DmFitMode */

#ifdef __cplusplus
extern "C" {
#endif

struct lua_State;

/* ── Frame source ──────────────────────────────────────────────────────
 * A producer writes RGBA (or BGRA) frames; the UI only reads. The URI scheme
 * selects the transport:
 *   "file:/path.rgba"  re-read the whole file each poll; a new frame is detected
 *                      by mtime/size change (idle-friendly; may tear on a
 *                      non-atomic writer — fine for demos/headless).
 *   "mmap:/path.rgba"  mmap a fixed width*height*4 file; always-fresh, zero-copy
 *                      read (may tear).
 *   "shm:/name"        POSIX shared memory (/dev/shm/name) laid out as a
 *                      DmArShmHeader + 3 frame slots; tear-free triple buffer.
 *   "fifo:/path"       named pipe streaming raw back-to-back frames.
 * A bare path with no recognized scheme is treated as "file:".
 */
typedef enum { DM_AR_FMT_RGBA8888 = 0, DM_AR_FMT_BGRA8888 = 1 } DmArPixFmt;

/* Shared-memory frame layout (producer writes, UI reads). Reuses the
 * triple-buffer state-word protocol from demod_triple_buf.h (TB_W/M/R_SHIFT,
 * TB_DIRTY, tb_r), but sized for pixel slots instead of a param struct. Three
 * frame slots of `slot_bytes` each follow this header, 64-byte aligned. */
#define DM_AR_SHM_MAGIC   0x52414D44u  /* "DMAR" little-endian */
#define DM_AR_SHM_VERSION 1u
#define DM_AR_SHM_SLOTS   3
typedef struct {
    uint32_t magic;       /* DM_AR_SHM_MAGIC */
    uint32_t version;     /* DM_AR_SHM_VERSION */
    uint32_t width;
    uint32_t height;
    uint32_t format;      /* DmArPixFmt */
    uint32_t slot_bytes;  /* bytes per slot (>= width*height*4) */
    uint32_t state;       /* triple-buffer state word (atomic on the producer) */
    uint32_t _pad;
    uint64_t sequence;    /* bumped on every committed frame */
    uint32_t _reserved[6];
} DmArShmHeader;

typedef struct DmArSource DmArSource;

DmArSource     *dm_ar_source_open(const char *uri, int want_w, int want_h, DmArPixFmt fmt);
bool            dm_ar_source_poll(DmArSource *s);          /* true iff a NEW frame arrived */
const uint32_t *dm_ar_source_latest(DmArSource *s, int *w, int *h); /* ARGB8888, src-owned */
void            dm_ar_source_close(DmArSource *s);

/* ── Context (source + composite config) ──────────────────────────────── */

typedef struct {
    DmFitMode fit;    /* how the frame fills the framebuffer */
    int       eyes;   /* 1 = mono; 2 = side-by-side stereo (L/R halves) */
    uint8_t   alpha;  /* global alpha of the passthrough layer (255 = opaque) */
    float     k1, k2; /* eyes==2 lens barrel-distortion coeffs (0 = flat SBS) */
} DmArConfig;

typedef struct DmArContext DmArContext;

DmArContext *dm_ar_open(const char *uri, int w, int h, DmArPixFmt fmt, DmArConfig cfg);
bool         dm_ar_active(DmArContext *c);
bool         dm_ar_poll(DmArContext *c);   /* poll source; true iff a new frame arrived */
/* Paint the latest frame as the framebuffer's base layer (replacing the clear).
 * Falls back to a black clear when no frame is available yet. */
void         dm_ar_composite_background(DmArContext *c, DmFramebuffer *fb);
DmArConfig   dm_ar_get_config(DmArContext *c);
void         dm_ar_set_config(DmArContext *c, DmArConfig cfg);
void         dm_ar_status(DmArContext *c, int *w, int *h,
                          uint64_t *seq, uint64_t *frames);
void         dm_ar_close(DmArContext *c);

/* ── Head-tracking pose source (6DOF) ──────────────────────────────────
 * A producer (an IMU/SLAM/OpenXR bridge) writes 7 little-endian float32 —
 * position x,y,z then orientation quaternion qx,qy,qz,qw — to a file/mmap/shm,
 * exactly like the frame source. Polled per frame; a new pose is delivered to
 * the Lua global on_pose(x,y,z, qx,qy,qz,qw). Same URI schemes as the frames. */
typedef struct DmPoseSource DmPoseSource;
#define DM_POSE_FLOATS 7
DmPoseSource *dm_pose_open(const char *uri);
bool          dm_pose_poll(DmPoseSource *s, float out[DM_POSE_FLOATS]); /* true iff new */
void          dm_pose_close(DmPoseSource *s);

/* Register the dm.ar (+ dm.pose) Lua sub-tables onto the dm table on the stack. */
void         dm_ar_register(struct lua_State *L);

#ifdef __cplusplus
}
#endif
#endif /* DEMOD_AR_H */
