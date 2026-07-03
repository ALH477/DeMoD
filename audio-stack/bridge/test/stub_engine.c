/* SPDX-License-Identifier: LGPL-3.0-only */
/*
 * stub_engine.c — loopback fixture standing in for demod-rt + the orchestrator.
 *
 *   1. Creates the meters shm ($DEMOD_RT_METERS_SHM) sized sizeof(DemodRtMeters)
 *      and fills a known snapshot (fx_levels_l[0]=0.5, slot_gain[0]=0.75,
 *      slot_pan[0]=-0.5, slot_mute_mask=0b10) with a valid even seqlock value.
 *   2. Listens on the control socket ($DEMOD_CONTROL_SOCK) and appends every
 *      received line to a log file (argv[1] or $DEMOD_STUB_LOG).
 *
 * Copyright (C) 2025-2026 DeMoD LLC. LGPL-3.0-only; see LICENSE.
 */
#define _GNU_SOURCE 1   /* ftruncate under -std=c11 */
#include "demod_rt_meters.h"

#include <fcntl.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

static const char *env_or(const char *k, const char *dflt) {
    const char *v = getenv(k);
    return (v && *v) ? v : dflt;
}

int main(int argc, char **argv) {
    const char *shm_path  = env_or("DEMOD_RT_METERS_SHM", "/dev/shm/demod-rt-meters");
    const char *sock_path = env_or("DEMOD_CONTROL_SOCK", "/run/demod/control.sock");
    const char *log_path  = (argc > 1) ? argv[1] : env_or("DEMOD_STUB_LOG", "stub_ops.log");

    /* ── 1. meters shm ────────────────────────────────────────────────── */
    int fd = open(shm_path, O_RDWR | O_CREAT, 0666);
    if (fd < 0) { perror("open shm"); return 1; }
    if (ftruncate(fd, sizeof(DemodRtMeters)) != 0) { perror("ftruncate"); return 1; }
    DemodRtMeters *m = mmap(NULL, sizeof(DemodRtMeters), PROT_READ | PROT_WRITE,
                            MAP_SHARED, fd, 0);
    if (m == MAP_FAILED) { perror("mmap"); return 1; }
    memset(m, 0, sizeof(*m));

    atomic_store_explicit(&m->seq, 1u, memory_order_release); /* odd: writing */
    m->fx_levels[0]    = 0.5f;
    m->fx_levels_l[0]  = 0.5f;
    m->fx_levels_r[0]  = 0.5f;
    m->slot_gain[0]    = 0.75f;
    m->slot_pan[0]     = -0.5f;
    m->slot_mute_mask  = 0x2u;   /* 0b10 */
    m->slot_solo_mask  = 0x0u;
    atomic_store_explicit(&m->seq, 2u, memory_order_release); /* even: stable */
    fprintf(stderr, "[stub] meters shm ready at %s\n", shm_path);

    /* ── 2. control socket ────────────────────────────────────────────── */
    unlink(sock_path);
    int ls = socket(AF_UNIX, SOCK_STREAM, 0);
    if (ls < 0) { perror("socket"); return 1; }
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, sock_path, sizeof(addr.sun_path) - 1);
    if (bind(ls, (struct sockaddr *)&addr, sizeof(addr)) != 0) { perror("bind"); return 1; }
    if (listen(ls, 8) != 0) { perror("listen"); return 1; }
    fprintf(stderr, "[stub] control socket listening at %s (log %s)\n", sock_path, log_path);

    for (;;) {
        int cs = accept(ls, NULL, NULL);
        if (cs < 0) continue;
        char buf[1024];
        ssize_t n;
        FILE *log = fopen(log_path, "a");
        while ((n = read(cs, buf, sizeof(buf))) > 0) {
            if (log) { fwrite(buf, 1, (size_t)n, log); fflush(log); }
        }
        if (log) fclose(log);
        close(cs);
    }
    return 0;
}
