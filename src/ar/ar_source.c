// SPDX-License-Identifier: MPL-2.0
/*
 * DeMoD UI Framework — AR passthrough frame source
 * Out-of-process RGBA frame ingest for dm.ar. Four transports behind one API:
 * file (mtime-polled), mmap (always-fresh), shm (tear-free triple buffer),
 * fifo (streamed frames). Every path converts source RGBA/BGRA to native
 * ARGB8888 once, into a scratch buffer the compositor reads directly. Links
 * libc only — no image codec is pulled into the UI.
 *
 * Copyright (c) 2026 DeMoD LLC.
 * Licensed under the Mozilla Public License, v. 2.0; see LICENSE.
 */
#include "demod/ar.h"
#include "demod/demod_triple_buf.h" /* TB_R_SHIFT / TB_MASK / tb_r — state-word protocol only */

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/mman.h>

typedef enum { SRC_FILE, SRC_MMAP, SRC_SHM, SRC_FIFO } SrcKind;

struct DmArSource {
    SrcKind    kind;
    char      *path;         /* file/fifo path or resolved /dev/shm path */
    int        fd;           /* fifo fd, or mmap/shm backing fd (-1 if none) */
    void      *map;          /* mmap base (mmap/shm) */
    size_t     map_len;
    int        width, height;
    DmArPixFmt format;

    uint8_t   *staging;      /* raw source bytes (file/fifo): width*height*4 */
    size_t     staging_cap;
    size_t     staging_fill; /* fifo assembly progress */

    uint32_t  *scratch;      /* converted ARGB8888: width*height */
    bool       have_frame;

    /* change detection */
    uint64_t   last_seq;     /* shm */
    long       last_mtime_s, last_mtime_ns; /* file */
    long long  last_size;    /* file */
};

/* Convert n RGBA/BGRA source pixels to native ARGB8888 (matches ld_blit). */
static void convert_pixels(uint32_t *dst, const uint8_t *src, int n, DmArPixFmt fmt) {
    if (fmt == DM_AR_FMT_BGRA8888) {
        for (int i = 0; i < n; i++) {
            uint8_t b = src[i * 4], g = src[i * 4 + 1],
                    r = src[i * 4 + 2], a = src[i * 4 + 3];
            dst[i] = ((uint32_t)a << 24) | ((uint32_t)r << 16) |
                     ((uint32_t)g << 8)  |  (uint32_t)b;
        }
    } else {
        for (int i = 0; i < n; i++) {
            uint8_t r = src[i * 4], g = src[i * 4 + 1],
                    b = src[i * 4 + 2], a = src[i * 4 + 3];
            dst[i] = ((uint32_t)a << 24) | ((uint32_t)r << 16) |
                     ((uint32_t)g << 8)  |  (uint32_t)b;
        }
    }
}

/* Split "scheme:rest"; returns rest and sets *kind. Bare path -> SRC_FILE. */
static const char *parse_uri(const char *uri, SrcKind *kind) {
    if      (!strncmp(uri, "file:", 5)) { *kind = SRC_FILE; return uri + 5; }
    else if (!strncmp(uri, "mmap:", 5)) { *kind = SRC_MMAP; return uri + 5; }
    else if (!strncmp(uri, "shm:",  4)) { *kind = SRC_SHM;  return uri + 4; }
    else if (!strncmp(uri, "fifo:", 5)) { *kind = SRC_FIFO; return uri + 5; }
    *kind = SRC_FILE;
    return uri;
}

DmArSource *dm_ar_source_open(const char *uri, int want_w, int want_h, DmArPixFmt fmt) {
    if (!uri || !*uri) return NULL;
    SrcKind kind;
    const char *rest = parse_uri(uri, &kind);

    DmArSource *s = (DmArSource *)calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->kind = kind;
    s->fd = -1;
    s->format = fmt;
    s->width = want_w;
    s->height = want_h;

    if (kind == SRC_SHM) {
        /* Resolve a POSIX shm name to its /dev/shm path (portable, no -lrt). */
        char devshm[512];
        if (rest[0] == '/')
            snprintf(devshm, sizeof(devshm), "/dev/shm%s", rest);
        else
            snprintf(devshm, sizeof(devshm), "/dev/shm/%s", rest);
        s->path = strdup(devshm);
        s->fd = open(devshm, O_RDONLY);
        if (s->fd < 0) { dm_ar_source_close(s); return NULL; }
        struct stat st;
        if (fstat(s->fd, &st) != 0 || (size_t)st.st_size < sizeof(DmArShmHeader)) {
            dm_ar_source_close(s); return NULL;
        }
        s->map_len = (size_t)st.st_size;
        s->map = mmap(NULL, s->map_len, PROT_READ, MAP_SHARED, s->fd, 0);
        if (s->map == MAP_FAILED) { s->map = NULL; dm_ar_source_close(s); return NULL; }
        const DmArShmHeader *h = (const DmArShmHeader *)s->map;
        if (h->magic != DM_AR_SHM_MAGIC || h->width == 0 || h->height == 0) {
            dm_ar_source_close(s); return NULL;
        }
        s->width  = (int)h->width;
        s->height = (int)h->height;
        s->format = (DmArPixFmt)h->format;
    } else {
        if (want_w <= 0 || want_h <= 0) { free(s); return NULL; }
        s->path = strdup(rest);
        if (kind == SRC_MMAP) {
            s->fd = open(rest, O_RDONLY);
            if (s->fd < 0) { dm_ar_source_close(s); return NULL; }
            s->map_len = (size_t)want_w * want_h * 4;
            struct stat st;
            if (fstat(s->fd, &st) != 0 || (size_t)st.st_size < s->map_len) {
                dm_ar_source_close(s); return NULL;
            }
            s->map = mmap(NULL, s->map_len, PROT_READ, MAP_SHARED, s->fd, 0);
            if (s->map == MAP_FAILED) { s->map = NULL; dm_ar_source_close(s); return NULL; }
        } else if (kind == SRC_FIFO) {
            /* Non-blocking so a missing writer never stalls the UI thread. */
            s->fd = open(rest, O_RDONLY | O_NONBLOCK);
            if (s->fd < 0) { dm_ar_source_close(s); return NULL; }
        }
        s->staging_cap = (size_t)want_w * want_h * 4;
        s->staging = (uint8_t *)malloc(s->staging_cap);
        if (!s->staging) { dm_ar_source_close(s); return NULL; }
    }

    s->scratch = (uint32_t *)calloc((size_t)s->width * s->height, sizeof(uint32_t));
    if (!s->scratch) { dm_ar_source_close(s); return NULL; }
    return s;
}

static bool poll_file(DmArSource *s) {
    size_t needed = (size_t)s->width * s->height * 4;
    struct stat st;
    if (stat(s->path, &st) != 0) return false;
    if ((size_t)st.st_size < needed) return false;

    long mns = 0;
#if defined(__APPLE__)
    long ms = (long)st.st_mtimespec.tv_sec; mns = (long)st.st_mtimespec.tv_nsec;
#elif defined(st_mtime)
    long ms = (long)st.st_mtim.tv_sec; mns = (long)st.st_mtim.tv_nsec;
#else
    long ms = (long)st.st_mtime;
#endif
    if (s->have_frame && ms == s->last_mtime_s && mns == s->last_mtime_ns &&
        (long long)st.st_size == s->last_size)
        return false;

    FILE *f = fopen(s->path, "rb");
    if (!f) return false;
    size_t got = fread(s->staging, 1, needed, f);
    fclose(f);
    if (got < needed) return false;

    convert_pixels(s->scratch, s->staging, s->width * s->height, s->format);
    s->last_mtime_s = ms; s->last_mtime_ns = mns; s->last_size = (long long)st.st_size;
    s->have_frame = true;
    return true;
}

static bool poll_mmap(DmArSource *s) {
    if (!s->map) return false;
    convert_pixels(s->scratch, (const uint8_t *)s->map, s->width * s->height, s->format);
    s->have_frame = true;
    return true;  /* zero-copy source is always considered fresh */
}

static bool poll_shm(DmArSource *s) {
    const DmArShmHeader *h = (const DmArShmHeader *)s->map;
    if (!h || h->magic != DM_AR_SHM_MAGIC) return false;
    uint32_t state = __atomic_load_n((const uint32_t *)&h->state, __ATOMIC_ACQUIRE);
    uint64_t seq   = __atomic_load_n((const uint64_t *)&h->sequence, __ATOMIC_ACQUIRE);
    if (s->have_frame && seq == s->last_seq) return false;

    uint32_t ridx = tb_r(state);
    if (ridx >= DM_AR_SHM_SLOTS) ridx = 0;
    size_t slot_bytes = h->slot_bytes ? h->slot_bytes
                                      : (size_t)s->width * s->height * 4;
    size_t hdr = (sizeof(DmArShmHeader) + 63u) & ~(size_t)63u;
    size_t off = hdr + (size_t)ridx * slot_bytes;
    if (off + (size_t)s->width * s->height * 4 > s->map_len) return false;

    const uint8_t *slot = (const uint8_t *)s->map + off;
    convert_pixels(s->scratch, slot, s->width * s->height, s->format);
    s->last_seq = seq;
    s->have_frame = true;
    return true;
}

static bool poll_fifo(DmArSource *s) {
    size_t needed = s->staging_cap;   /* one frame */
    ssize_t n = read(s->fd, s->staging + s->staging_fill,
                     needed - s->staging_fill);
    if (n > 0) s->staging_fill += (size_t)n;
    if (s->staging_fill < needed) return false;

    convert_pixels(s->scratch, s->staging, s->width * s->height, s->format);
    s->staging_fill = 0;             /* extra frames wait in the pipe buffer */
    s->have_frame = true;
    return true;
}

bool dm_ar_source_poll(DmArSource *s) {
    if (!s) return false;
    switch (s->kind) {
        case SRC_FILE: return poll_file(s);
        case SRC_MMAP: return poll_mmap(s);
        case SRC_SHM:  return poll_shm(s);
        case SRC_FIFO: return poll_fifo(s);
    }
    return false;
}

const uint32_t *dm_ar_source_latest(DmArSource *s, int *w, int *h) {
    if (!s || !s->have_frame) return NULL;
    if (w) *w = s->width;
    if (h) *h = s->height;
    return s->scratch;
}

void dm_ar_source_close(DmArSource *s) {
    if (!s) return;
    if (s->map && s->map != MAP_FAILED) munmap(s->map, s->map_len);
    if (s->fd >= 0) close(s->fd);
    free(s->path);
    free(s->staging);
    free(s->scratch);
    free(s);
}

/* ── Pose source (7 float32: pos xyz + quat xyzw) ──────────────────────── */

#define POSE_BYTES (DM_POSE_FLOATS * (int)sizeof(float))

struct DmPoseSource {
    char  *path;    /* file/fifo path or resolved /dev/shm path */
    int    fd;      /* mmap/shm backing fd (-1 for plain file re-read) */
    void  *map;     /* mmap base (mmap/shm), NULL for file re-read */
    size_t map_len;
    float  last[DM_POSE_FLOATS];
    bool   have;
};

DmPoseSource *dm_pose_open(const char *uri) {
    if (!uri || !*uri) return NULL;
    SrcKind kind;
    const char *rest = parse_uri(uri, &kind);

    DmPoseSource *s = (DmPoseSource *)calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->fd = -1;

    if (kind == SRC_SHM || kind == SRC_MMAP) {
        char devshm[512];
        if (kind == SRC_SHM) {
            if (rest[0] == '/') snprintf(devshm, sizeof(devshm), "/dev/shm%s", rest);
            else                snprintf(devshm, sizeof(devshm), "/dev/shm/%s", rest);
            s->path = strdup(devshm);
        } else {
            s->path = strdup(rest);
        }
        s->fd = open(s->path, O_RDONLY);
        if (s->fd < 0) { dm_pose_close(s); return NULL; }
        s->map_len = POSE_BYTES;
        s->map = mmap(NULL, s->map_len, PROT_READ, MAP_SHARED, s->fd, 0);
        if (s->map == MAP_FAILED) { s->map = NULL; dm_pose_close(s); return NULL; }
    } else {
        s->path = strdup(rest);  /* file / fifo: re-read each poll */
    }
    return s;
}

bool dm_pose_poll(DmPoseSource *s, float out[DM_POSE_FLOATS]) {
    if (!s) return false;
    float buf[DM_POSE_FLOATS];
    if (s->map) {
        memcpy(buf, s->map, POSE_BYTES);
    } else {
        FILE *f = fopen(s->path, "rb");
        if (!f) return false;
        size_t got = fread(buf, 1, POSE_BYTES, f);
        fclose(f);
        if (got < (size_t)POSE_BYTES) return false;
    }
    if (s->have && memcmp(buf, s->last, POSE_BYTES) == 0) return false;
    memcpy(s->last, buf, POSE_BYTES);
    if (out) memcpy(out, buf, POSE_BYTES);
    s->have = true;
    return true;
}

void dm_pose_close(DmPoseSource *s) {
    if (!s) return;
    if (s->map && s->map != MAP_FAILED) munmap(s->map, s->map_len);
    if (s->fd >= 0) close(s->fd);
    free(s->path);
    free(s);
}
