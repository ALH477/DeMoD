/*
 * demod_shm.h — POSIX Shared Memory Setup for DeMoD IPC
 *
 * Copyright (C) 2025–2026 DeMoD LLC
 * SPDX-License-Identifier: GPL-3.0-only
 *
 * The Haskell orchestrator creates shared memory regions before forking
 * the RT child. The C/C++ child opens them by name after exec.
 * All regions live on /dev/shm (tmpfs, zero-copy, no disk I/O).
 */

#ifndef DEMOD_SHM_H
#define DEMOD_SHM_H

#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <stdio.h>

#include "demod_triple_buf.h"
#include "demod_spsc.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ── Named Regions ──────────────────────────────────────────────── */

#define DEMOD_SHM_PARAMS    "/demod-params"     /* Triple buffer: orchestrator → RT */
#define DEMOD_SHM_AUDIO_CMD "/demod-audio-cmd"  /* SPSC: orchestrator → RT commands */
#define DEMOD_SHM_AUDIO_EVT "/demod-audio-evt"  /* SPSC: RT → orchestrator events */
#define DEMOD_SHM_HEARTBEAT "/demod-heartbeat"  /* Watchdog heartbeat */

/* Default SPSC capacity: 4096 floats ≈ 16KB, ~2.67 callbacks of 64-sample stereo */
#define DEMOD_SPSC_DEFAULT_CAPACITY 4096

/* ── Heartbeat Region ──────────────────────────────────────────── */

typedef struct DemodHeartbeat {
    alignas(64) _Atomic uint64_t rt_timestamp_us;
    alignas(64) _Atomic uint64_t rt_callback_count;
    alignas(64) _Atomic uint64_t rt_xrun_count;
    alignas(64) _Atomic uint32_t rt_alive;     /* 1 = running, 0 = stopped */
    float                        rt_cpu_load;  /* 0.0–1.0, updated each callback */
} DemodHeartbeat;

/* ── Creation (Haskell side, before fork) ──────────────────────── */

typedef struct DemodShmRegion {
    void  *addr;
    size_t size;
    int    fd;
    char   name[64];
} DemodShmRegion;

/*
 * Create a named shared memory region. Returns 0 on success, -errno on failure.
 * The region is zeroed and ready for structure init.
 */
static inline int demod_shm_create(DemodShmRegion *region, const char *name, size_t size) {
    int fd = shm_open(name, O_CREAT | O_RDWR | O_TRUNC, 0600);
    if (fd < 0) return -errno;

    if (ftruncate(fd, (off_t)size) < 0) {
        int err = errno;
        close(fd);
        shm_unlink(name);
        return -err;
    }

    void *addr = mmap(NULL, size, PROT_READ | PROT_WRITE,
                       MAP_SHARED | MAP_POPULATE, fd, 0);
    if (addr == MAP_FAILED) {
        int err = errno;
        close(fd);
        shm_unlink(name);
        return -err;
    }

    /* Lock pages to prevent page faults in RT context */
    mlock(addr, size);

    memset(addr, 0, size);
    region->addr = addr;
    region->size = size;
    region->fd   = fd;
    snprintf(region->name, sizeof(region->name), "%s", name);
    return 0;
}

/*
 * Open an existing named shared memory region (child after exec).
 * Returns 0 on success, -errno on failure.
 */
static inline int demod_shm_open(DemodShmRegion *region, const char *name, size_t size) {
    int fd = shm_open(name, O_RDWR, 0600);
    if (fd < 0) return -errno;

    void *addr = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (addr == MAP_FAILED) {
        int err = errno;
        close(fd);
        return -err;
    }

    mlock(addr, size);

    region->addr = addr;
    region->size = size;
    region->fd   = fd;
    snprintf(region->name, sizeof(region->name), "%s", name);
    return 0;
}

/*
 * Unmap and close a region. Does NOT unlink — the creator does that on shutdown.
 */
static inline void demod_shm_close(DemodShmRegion *region) {
    if (region->addr && region->addr != MAP_FAILED) {
        munmap(region->addr, region->size);
    }
    if (region->fd >= 0) close(region->fd);
    region->addr = NULL;
    region->fd = -1;
}

/*
 * Unlink (destroy) a named shared memory region.
 * Only the creator (orchestrator) calls this on clean shutdown.
 */
static inline void demod_shm_unlink(const char *name) {
    shm_unlink(name);
}

/* ── Convenience: Full IPC Setup ────────────────────────────────── */

typedef struct DemodIpc {
    DemodShmRegion   params_region;
    DemodShmRegion   cmd_region;
    DemodShmRegion   evt_region;
    DemodShmRegion   hb_region;

    DemodTripleBuf  *params;     /* → params_region.addr */
    DemodSpsc       *cmd_ring;   /* → cmd_region.addr */
    DemodSpsc       *evt_ring;   /* → evt_region.addr */
    DemodHeartbeat  *heartbeat;  /* → hb_region.addr */
} DemodIpc;

/*
 * Create all IPC regions (orchestrator side).
 * Returns 0 on success, -errno on first failure (partial cleanup done).
 */
static inline int demod_ipc_create(DemodIpc *ipc, uint64_t spsc_capacity) {
    int rc;
    memset(ipc, 0, sizeof(*ipc));

    if (!demod_is_power_of_2(spsc_capacity))
        spsc_capacity = demod_next_power_of_2(spsc_capacity);

    const size_t spsc_size = demod_spsc_alloc_size(spsc_capacity);

    rc = demod_shm_create(&ipc->params_region, DEMOD_SHM_PARAMS, sizeof(DemodTripleBuf));
    if (rc < 0) return rc;
    ipc->params = (DemodTripleBuf *)ipc->params_region.addr;
    demod_triple_buf_init(ipc->params);

    rc = demod_shm_create(&ipc->cmd_region, DEMOD_SHM_AUDIO_CMD, spsc_size);
    if (rc < 0) goto fail_cmd;
    ipc->cmd_ring = demod_spsc_init(ipc->cmd_region.addr, spsc_capacity);

    rc = demod_shm_create(&ipc->evt_region, DEMOD_SHM_AUDIO_EVT, spsc_size);
    if (rc < 0) goto fail_evt;
    ipc->evt_ring = demod_spsc_init(ipc->evt_region.addr, spsc_capacity);

    rc = demod_shm_create(&ipc->hb_region, DEMOD_SHM_HEARTBEAT, sizeof(DemodHeartbeat));
    if (rc < 0) goto fail_hb;
    ipc->heartbeat = (DemodHeartbeat *)ipc->hb_region.addr;

    return 0;

fail_hb:
    demod_shm_close(&ipc->evt_region);
    demod_shm_unlink(DEMOD_SHM_AUDIO_EVT);
fail_evt:
    demod_shm_close(&ipc->cmd_region);
    demod_shm_unlink(DEMOD_SHM_AUDIO_CMD);
fail_cmd:
    demod_shm_close(&ipc->params_region);
    demod_shm_unlink(DEMOD_SHM_PARAMS);
    return rc;
}

/*
 * Open all IPC regions (RT child side, after exec).
 */
static inline int demod_ipc_open(DemodIpc *ipc, uint64_t spsc_capacity) {
    int rc;
    memset(ipc, 0, sizeof(*ipc));

    if (!demod_is_power_of_2(spsc_capacity))
        spsc_capacity = demod_next_power_of_2(spsc_capacity);

    const size_t spsc_size = demod_spsc_alloc_size(spsc_capacity);

    rc = demod_shm_open(&ipc->params_region, DEMOD_SHM_PARAMS, sizeof(DemodTripleBuf));
    if (rc < 0) return rc;
    ipc->params = (DemodTripleBuf *)ipc->params_region.addr;

    rc = demod_shm_open(&ipc->cmd_region, DEMOD_SHM_AUDIO_CMD, spsc_size);
    if (rc < 0) return rc;
    ipc->cmd_ring = (DemodSpsc *)ipc->cmd_region.addr;

    rc = demod_shm_open(&ipc->evt_region, DEMOD_SHM_AUDIO_EVT, spsc_size);
    if (rc < 0) return rc;
    ipc->evt_ring = (DemodSpsc *)ipc->evt_region.addr;

    rc = demod_shm_open(&ipc->hb_region, DEMOD_SHM_HEARTBEAT, sizeof(DemodHeartbeat));
    if (rc < 0) return rc;
    ipc->heartbeat = (DemodHeartbeat *)ipc->hb_region.addr;

    return 0;
}

/*
 * Tear down all IPC (orchestrator shutdown).
 */
static inline void demod_ipc_destroy(DemodIpc *ipc) {
    demod_shm_close(&ipc->hb_region);
    demod_shm_close(&ipc->evt_region);
    demod_shm_close(&ipc->cmd_region);
    demod_shm_close(&ipc->params_region);
    demod_shm_unlink(DEMOD_SHM_HEARTBEAT);
    demod_shm_unlink(DEMOD_SHM_AUDIO_EVT);
    demod_shm_unlink(DEMOD_SHM_AUDIO_CMD);
    demod_shm_unlink(DEMOD_SHM_PARAMS);
}

#ifdef __cplusplus
}
#endif

#endif /* DEMOD_SHM_H */
