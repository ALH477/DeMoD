/*
 * demod_spsc.h — Lock-Free SPSC Ring Buffer for RT Audio IPC
 *
 * Vendored into the cabal package so the orchestrator can be packaged as a
 * self-contained artifact. Keep this in sync with ipc/include/demod_spsc.h.
 *
 * Copyright (C) 2025–2026 DeMoD LLC
 * SPDX-License-Identifier: GPL-3.0-only
 */

#ifndef DEMOD_SPSC_H
#define DEMOD_SPSC_H

#include <stdatomic.h>
#include <stdalign.h>
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

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

#ifdef __cplusplus
}
#endif

#endif /* DEMOD_SPSC_H */
