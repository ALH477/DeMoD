// SPDX-License-Identifier: MPL-2.0
/*
 * demod_rt_meters.c — read demod-rt's live readback shm (/dev/shm/demod-rt-meters):
 * per-slot RMS levels + a post-chain stereo scope window. demod-rt is the sole
 * writer; we map it read-only and do a single-writer seqlock read (retry while the
 * sequence is odd or changes mid-copy). Unlike the param bus we keep retrying open()
 * until the shm appears, since demod-rt may start/restart after the UI.
 *
 * Copyright (c) 2026 DeMoD LLC. Licensed under the Mozilla Public License, v. 2.0 (see LICENSE).
 */
#include "demod/demod_rt_meters.h"

#ifdef __linux__ /* ── real body: /dev/shm/demod-rt-meters mmap (live readback) ── */

#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>

static DemodRtMeters *g_m  = NULL;
static int            g_fd = -1;

static const char *meters_path(void) {
    const char *p = getenv("DEMOD_RT_METERS_SHM");
    return (p && *p) ? p : "/dev/shm/demod-rt-meters";
}

static int ensure_open(void) {
    if (g_m) return 1;                 /* a demod-rt restart reuses the same shm */
    int fd = open(meters_path(), O_RDONLY);
    if (fd < 0) return 0;              /* not up yet — try again next frame */
    struct stat st;
    if (fstat(fd, &st) != 0 || (size_t)st.st_size < sizeof(DemodRtMeters)) {
        close(fd);
        return 0;
    }
    void *m = mmap(NULL, sizeof(DemodRtMeters), PROT_READ, MAP_SHARED, fd, 0);
    if (m == MAP_FAILED) { close(fd); return 0; }
    g_fd = fd;
    g_m = (DemodRtMeters *)m;
    return 1;
}

/* Returns 1 and fills *out on a stable read, else 0 (engine absent / mid-write). */
int demod_rt_meters_read(DemodRtMeters *out) {
    if (!out || !ensure_open()) return 0;
    for (int attempt = 0; attempt < 8; attempt++) {
        uint32_t s0 = atomic_load_explicit(&g_m->seq, memory_order_acquire);
        if (s0 & 1u) continue;         /* writer mid-publish */
        memcpy(out, g_m, sizeof(*out));
        uint32_t s1 = atomic_load_explicit(&g_m->seq, memory_order_acquire);
        if (s0 == s1) return 1;        /* stable copy */
    }
    return 0;
}

void demod_rt_meters_close(void) {
    if (g_m)  { munmap(g_m, sizeof(DemodRtMeters)); g_m = NULL; }
    if (g_fd >= 0) { close(g_fd); g_fd = -1; }
}

#else /* ── non-Linux stub: no live readback shm; report unavailable ── */

int  demod_rt_meters_read(DemodRtMeters *out) { (void)out; return 0; }
void demod_rt_meters_close(void) {}

#endif /* __linux__ */
