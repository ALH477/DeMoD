/*
 * demod_spsc.h — Lock-Free SPSC Ring Buffer for RT Audio IPC
 *
 * Copyright (C) 2025–2026 DeMoD LLC
 * SPDX-License-Identifier: GPL-3.0-only
 *
 * Rigtorp/Lamport pattern with cached-index optimization.
 * Cache-line aligned for zero false sharing. x86 TSO means
 * acquire/release compile to plain MOV — zero fence cost.
 *
 * Usage:
 *   Producer (Haskell via FFI):  demod_spsc_push(rb, data, count)
 *   Consumer (RT audio callback): demod_spsc_pop(rb, buf, max_count)
 *
 * Capacity MUST be power-of-2. Use demod_spsc_capacity() helper.
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

/* ── Layout ────────────────────────────────────────────────────────────
 * Cache-line separation between producer and consumer indices eliminates
 * false sharing. Rigtorp measured 22× fewer L1 store misses with this
 * layout vs naive. Each side caches the other's index locally, only
 * touching the atomic when the cache says full/empty → 20× throughput.
 * ──────────────────────────────────────────────────────────────────── */

typedef struct DemodSpsc {
    /* Cache line 0: producer-owned */
    alignas(64) _Atomic uint64_t write_idx;
    uint64_t                     read_idx_cached;
    char                         _pad0[64 - sizeof(_Atomic uint64_t) - sizeof(uint64_t)];

    /* Cache line 1: consumer-owned */
    alignas(64) _Atomic uint64_t read_idx;
    uint64_t                     write_idx_cached;
    char                         _pad1[64 - sizeof(_Atomic uint64_t) - sizeof(uint64_t)];

    /* Cache line 2: immutable after init */
    alignas(64) uint64_t capacity;
    uint64_t             mask;   /* capacity - 1, for bitwise AND */

    /* Cache line 3+: data buffer (flexible array member) */
    alignas(64) float data[];
} DemodSpsc;

/* ── Helpers ─────────────────────────────────────────────────────── */

static inline bool demod_is_power_of_2(uint64_t v) {
    return v && !(v & (v - 1));
}

static inline uint64_t demod_next_power_of_2(uint64_t v) {
    v--;
    v |= v >> 1;  v |= v >> 2;  v |= v >> 4;
    v |= v >> 8;  v |= v >> 16; v |= v >> 32;
    return v + 1;
}

/* Returns allocation size in bytes for a given capacity */
static inline size_t demod_spsc_alloc_size(uint64_t capacity) {
    return sizeof(DemodSpsc) + capacity * sizeof(float);
}

/* ── Init ────────────────────────────────────────────────────────── */

/*
 * Initialize an SPSC ring buffer in pre-allocated memory.
 * `mem` must be at least demod_spsc_alloc_size(capacity) bytes,
 * 64-byte aligned (e.g. from mmap on shared memory).
 * `capacity` must be a power of 2.
 * Returns NULL on invalid arguments.
 */
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

/* ── Producer (Haskell side, non-RT) ─────────────────────────────── */

/*
 * Push up to `count` floats. Returns number actually pushed.
 * NEVER BLOCKS. If ring is full, returns 0.
 */
static inline uint64_t demod_spsc_push(DemodSpsc *rb, const float *data, uint64_t count) {
    const uint64_t w = atomic_load_explicit(&rb->write_idx, memory_order_relaxed);
    uint64_t available = rb->capacity - (w - rb->read_idx_cached);

    if (available < count) {
        /* Refresh cached read index */
        rb->read_idx_cached = atomic_load_explicit(&rb->read_idx, memory_order_acquire);
        available = rb->capacity - (w - rb->read_idx_cached);
        if (available < count)
            return 0;  /* genuinely full */
    }

    /* Write data with wrap-around via bitmask */
    const uint64_t mask = rb->mask;
    for (uint64_t i = 0; i < count; i++)
        rb->data[(w + i) & mask] = data[i];

    /* Release: ensure data is visible before index update */
    atomic_store_explicit(&rb->write_idx, w + count, memory_order_release);
    return count;
}

/* ── Consumer (RT audio callback, hard-RT) ────────────────────────── */

/*
 * Pop up to `max_count` floats into `buf`. Returns number actually popped.
 * NEVER BLOCKS. If ring is empty, returns 0.
 *
 * This function is called from SCHED_FIFO context on an isolated core.
 * It must not: allocate, syscall, lock, or access non-local memory
 * beyond the shared region.
 */
static inline uint64_t demod_spsc_pop(DemodSpsc *rb, float *buf, uint64_t max_count) {
    const uint64_t r = atomic_load_explicit(&rb->read_idx, memory_order_relaxed);
    uint64_t available = rb->write_idx_cached - r;

    if (available == 0) {
        /* Refresh cached write index */
        rb->write_idx_cached = atomic_load_explicit(&rb->write_idx, memory_order_acquire);
        available = rb->write_idx_cached - r;
        if (available == 0)
            return 0;  /* genuinely empty */
    }

    const uint64_t count = (available < max_count) ? available : max_count;
    const uint64_t mask = rb->mask;
    for (uint64_t i = 0; i < count; i++)
        buf[i] = rb->data[(r + i) & mask];

    /* Release: ensure reads complete before advancing index */
    atomic_store_explicit(&rb->read_idx, r + count, memory_order_release);
    return count;
}

/* ── Query ───────────────────────────────────────────────────────── */

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
