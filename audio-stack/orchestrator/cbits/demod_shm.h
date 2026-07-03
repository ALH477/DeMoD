/*
 * demod_shm.h — POSIX Shared Memory Setup for DeMoD IPC
 *
 * Vendored into the cabal package so the orchestrator can be packaged as a
 * self-contained artifact. Keep this in sync with ipc/include/demod_shm.h.
 *
 * Copyright (C) 2025–2026 DeMoD LLC
 * SPDX-License-Identifier: GPL-3.0-only
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
#include <stdatomic.h>
#include <stdalign.h>
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DemodParamSnapshot {
    float detected_pitch_hz;
    float pitch_confidence;
    int32_t midi_note;
    float bpm;
    uint32_t beat_count;
    float fx_params[16];
    uint32_t fx_bypass_mask;
    uint32_t synth_mix_mode;
    float synth_gain;
    uint32_t osc_route_version;
    uint8_t bt_codec_id;
    uint8_t bt_connected;
    float sdr_center_freq_mhz;
    float sdr_bandwidth_khz;
    uint64_t timestamp_us;
    uint8_t _reserved[136];
} DemodParamSnapshot;

_Static_assert(sizeof(DemodParamSnapshot) == 256,
               "DemodParamSnapshot must be exactly 256 bytes");

#define TB_W_SHIFT  0
#define TB_M_SHIFT  2
#define TB_R_SHIFT  4
#define TB_DIRTY    (1u << 6)
#define TB_MASK     3u

static inline uint32_t tb_pack(uint32_t w, uint32_t m, uint32_t r, bool d) {
    return (w << TB_W_SHIFT) | (m << TB_M_SHIFT) | (r << TB_R_SHIFT) | (d ? TB_DIRTY : 0);
}
static inline uint32_t tb_w(uint32_t s) { return (s >> TB_W_SHIFT) & TB_MASK; }
static inline uint32_t tb_m(uint32_t s) { return (s >> TB_M_SHIFT) & TB_MASK; }
static inline uint32_t tb_r(uint32_t s) { return (s >> TB_R_SHIFT) & TB_MASK; }
static inline bool     tb_dirty(uint32_t s) { return (s & TB_DIRTY) != 0; }

typedef struct DemodTripleBuf {
    alignas(64) _Atomic uint32_t state;
    alignas(64) _Atomic uint64_t sequence;
    alignas(64) DemodParamSnapshot buffers[3];
} DemodTripleBuf;

static inline void demod_triple_buf_init(DemodTripleBuf *tb) {
    memset(tb, 0, sizeof(*tb));
    atomic_store_explicit(&tb->state, tb_pack(0, 1, 2, false), memory_order_relaxed);
    atomic_store_explicit(&tb->sequence, 0, memory_order_relaxed);
}

static inline DemodParamSnapshot *demod_triple_buf_begin_write(DemodTripleBuf *tb) {
    uint32_t s = atomic_load_explicit(&tb->state, memory_order_relaxed);
    return &tb->buffers[tb_w(s)];
}

static inline void demod_triple_buf_publish(DemodTripleBuf *tb) {
    uint32_t old_s = atomic_load_explicit(&tb->state, memory_order_relaxed);
    uint32_t new_s;
    do {
        new_s = tb_pack(tb_m(old_s), tb_w(old_s), tb_r(old_s), true);
    } while (!atomic_compare_exchange_weak_explicit(
                &tb->state, &old_s, new_s,
                memory_order_acq_rel, memory_order_relaxed));
    atomic_fetch_add_explicit(&tb->sequence, 1, memory_order_release);
}

static inline const DemodParamSnapshot *demod_triple_buf_read_active(
    DemodTripleBuf *tb)
{
    uint32_t old_s = atomic_load_explicit(&tb->state, memory_order_acquire);
    if (tb_dirty(old_s)) {
        uint32_t new_s;
        do {
            new_s = tb_pack(tb_w(old_s), tb_r(old_s), tb_m(old_s), false);
        } while (!atomic_compare_exchange_weak_explicit(
                    &tb->state, &old_s, new_s,
                    memory_order_acq_rel, memory_order_relaxed));
        return &tb->buffers[tb_r(new_s)];
    }
    return &tb->buffers[tb_r(old_s)];
}

static inline uint64_t demod_triple_buf_read_copy(
    DemodTripleBuf *tb, DemodParamSnapshot *dst)
{
    const DemodParamSnapshot *src = demod_triple_buf_read_active(tb);
    memcpy(dst, src, sizeof(DemodParamSnapshot));
    return atomic_load_explicit(&tb->sequence, memory_order_acquire);
}

static inline uint64_t demod_triple_buf_sequence(const DemodTripleBuf *tb) {
    return atomic_load_explicit(&tb->sequence, memory_order_acquire);
}

typedef struct DemodSpsc {
    alignas(64) _Atomic uint64_t write_idx;
    uint64_t                     read_idx_cached;
    char                         _pad0[64 - sizeof(_Atomic uint64_t) - sizeof(uint64_t)];

    alignas(64) _Atomic uint64_t read_idx;
    uint64_t                     write_idx_cached;
    char                         _pad1[64 - sizeof(_Atomic uint64_t) - sizeof(uint64_t)];

    alignas(64) uint64_t capacity;
    uint64_t             mask;

    alignas(64) float data[];
} DemodSpsc;

static inline bool demod_is_power_of_2(uint64_t v) {
    return v && !(v & (v - 1));
}

static inline uint64_t demod_next_power_of_2(uint64_t v) {
    v--;
    v |= v >> 1;  v |= v >> 2;  v |= v >> 4;
    v |= v >> 8;  v |= v >> 16; v |= v >> 32;
    return v + 1;
}

static inline size_t demod_spsc_alloc_size(uint64_t capacity) {
    return sizeof(DemodSpsc) + capacity * sizeof(float);
}

static inline DemodSpsc *demod_spsc_init(void *mem, uint64_t capacity) {
    if (!mem || !demod_is_power_of_2(capacity) || capacity < 2)
        return NULL;

    DemodSpsc *rb = (DemodSpsc *)mem;
    memset(rb, 0, demod_spsc_alloc_size(capacity));
    rb->capacity = capacity;
    rb->mask = capacity - 1;
    atomic_store_explicit(&rb->write_idx, 0, memory_order_relaxed);
    atomic_store_explicit(&rb->read_idx, 0, memory_order_relaxed);
    rb->read_idx_cached = 0;
    rb->write_idx_cached = 0;
    return rb;
}

static inline uint64_t demod_spsc_push(DemodSpsc *rb, const float *data, uint64_t count) {
    const uint64_t w = atomic_load_explicit(&rb->write_idx, memory_order_relaxed);
    uint64_t available = rb->capacity - (w - rb->read_idx_cached);

    if (available < count) {
        rb->read_idx_cached = atomic_load_explicit(&rb->read_idx, memory_order_acquire);
        available = rb->capacity - (w - rb->read_idx_cached);
        if (available < count)
            return 0;
    }

    const uint64_t mask = rb->mask;
    for (uint64_t i = 0; i < count; i++)
        rb->data[(w + i) & mask] = data[i];

    atomic_store_explicit(&rb->write_idx, w + count, memory_order_release);
    return count;
}

static inline uint64_t demod_spsc_pop(DemodSpsc *rb, float *buf, uint64_t max_count) {
    const uint64_t r = atomic_load_explicit(&rb->read_idx, memory_order_relaxed);
    uint64_t available = rb->write_idx_cached - r;

    if (available == 0) {
        rb->write_idx_cached = atomic_load_explicit(&rb->write_idx, memory_order_acquire);
        available = rb->write_idx_cached - r;
        if (available == 0)
            return 0;
    }

    const uint64_t count = (available < max_count) ? available : max_count;
    const uint64_t mask = rb->mask;
    for (uint64_t i = 0; i < count; i++)
        buf[i] = rb->data[(r + i) & mask];

    atomic_store_explicit(&rb->read_idx, r + count, memory_order_release);
    return count;
}

static inline uint64_t demod_spsc_available_read(const DemodSpsc *rb) {
    const uint64_t w = atomic_load_explicit(&rb->write_idx, memory_order_acquire);
    const uint64_t r = atomic_load_explicit(&rb->read_idx, memory_order_acquire);
    return w - r;
}

static inline uint64_t demod_spsc_available_write(const DemodSpsc *rb) {
    const uint64_t w = atomic_load_explicit(&rb->write_idx, memory_order_acquire);
    const uint64_t r = atomic_load_explicit(&rb->read_idx, memory_order_acquire);
    return rb->capacity - (w - r);
}

#define DEMOD_SHM_PARAMS    "/demod-params"
#define DEMOD_SHM_AUDIO_CMD "/demod-audio-cmd"
#define DEMOD_SHM_AUDIO_EVT "/demod-audio-evt"
#define DEMOD_SHM_HEARTBEAT "/demod-heartbeat"

#define DEMOD_SPSC_DEFAULT_CAPACITY 4096

typedef struct DemodHeartbeat {
    alignas(64) _Atomic uint64_t rt_timestamp_us;
    alignas(64) _Atomic uint64_t rt_callback_count;
    alignas(64) _Atomic uint64_t rt_xrun_count;
    alignas(64) _Atomic uint32_t rt_alive;
    float                        rt_cpu_load;
} DemodHeartbeat;

typedef struct DemodShmRegion {
    void  *addr;
    size_t size;
    int    fd;
    char   name[64];
} DemodShmRegion;

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

    mlock(addr, size);

    memset(addr, 0, size);
    region->addr = addr;
    region->size = size;
    region->fd   = fd;
    snprintf(region->name, sizeof(region->name), "%s", name);
    return 0;
}

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

static inline void demod_shm_close(DemodShmRegion *region) {
    if (region->addr && region->addr != MAP_FAILED) {
        munmap(region->addr, region->size);
    }
    if (region->fd >= 0) close(region->fd);
    region->addr = NULL;
    region->fd = -1;
}

static inline void demod_shm_unlink(const char *name) {
    shm_unlink(name);
}

typedef struct DemodIpc {
    DemodShmRegion   params_region;
    DemodShmRegion   cmd_region;
    DemodShmRegion   evt_region;
    DemodShmRegion   hb_region;

    DemodTripleBuf  *params;
    DemodSpsc       *cmd_ring;
    DemodSpsc       *evt_ring;
    DemodHeartbeat  *heartbeat;
} DemodIpc;

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
