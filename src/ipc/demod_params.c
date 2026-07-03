// SPDX-License-Identifier: MPL-2.0
/*
 * demod_params.c — read the orchestrator param bus (/dev/shm/demod-params).
 *
 * The orchestrator publishes a DemodTripleBuf. We are a passive *display*
 * reader, so rather than acting as the structure's single consumer (which
 * CAS-swaps the reader buffer and would steal frames from rt-audio), we do a
 * non-destructive seqlock read: snapshot the publish sequence, copy the
 * current reader buffer, and retry if a publish landed mid-copy. Worst case we
 * show a frame that is one publish stale — fine for a 60 fps GUI, and it needs
 * only read access to the shm.
 *
 * Copyright (c) 2026 DeMoD LLC. Licensed under the Mozilla Public License, v. 2.0 (see LICENSE).
 */
#include "demod/ipc.h"

#include <stdlib.h>
#include <stdio.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/stat.h>

static DemodTripleBuf *g_tb   = NULL;
static int             g_fd   = -1;
static int             g_tried = 0;   /* don't spam open() failures every frame */

static const char *params_path(void) {
    const char *p = getenv("DEMOD_PARAMS_SHM");
    return (p && *p) ? p : "/dev/shm/demod-params";
}

static int ensure_open(void) {
    if (g_tb) return 1;
    if (g_tried) return 0;          /* already failed once this run; give up quietly */
    g_tried = 1;

    int fd = open(params_path(), O_RDONLY);
    if (fd < 0) return 0;

    struct stat st;
    if (fstat(fd, &st) != 0 || (size_t)st.st_size < sizeof(DemodTripleBuf)) {
        close(fd);
        return 0;
    }
    void *m = mmap(NULL, sizeof(DemodTripleBuf), PROT_READ, MAP_SHARED, fd, 0);
    if (m == MAP_FAILED) { close(fd); return 0; }

    g_fd = fd;
    g_tb = (DemodTripleBuf *)m;
    fprintf(stderr, "[DeMoD] param bus: mapped %s\n", params_path());
    return 1;
}

int demod_params_read(DemodParamSnapshot *out) {
    if (!out || !ensure_open()) return 0;

    for (int attempt = 0; attempt < 4; attempt++) {
        uint64_t s0 = atomic_load_explicit(&g_tb->sequence, memory_order_acquire);
        uint32_t st = atomic_load_explicit(&g_tb->state, memory_order_acquire);
        uint32_t ri = tb_r(st);
        if (ri > 2) ri = 0;
        memcpy(out, &g_tb->buffers[ri], sizeof(*out));
        uint64_t s1 = atomic_load_explicit(&g_tb->sequence, memory_order_acquire);
        if (s0 == s1) return 1;     /* stable: no publish during the copy */
    }
    return 1;                       /* accept a possibly-stale frame after retries */
}

void demod_params_close(void) {
    if (g_tb) { munmap(g_tb, sizeof(DemodTripleBuf)); g_tb = NULL; }
    if (g_fd >= 0) { close(g_fd); g_fd = -1; }
    g_tried = 0;
}
