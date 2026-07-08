// SPDX-License-Identifier: GPL-3.0-only OR Commercial
// DCF-Snake shared-memory IPC contract for DeMoD integration
//
// This defines the SPSC ring buffer format for bridging demod-rt (Faust DSP engine)
// with the snake codec layer. Used on both spoke (RISC-V) and hub (x86):
//
// Spoke (RISC-V):
//   - demod-rt writes Faust-processed audio to /demod-snake-tx
//   - snake_source reads from TX ring, encodes via quanta, sends to network
//
// Hub (x86):
//   - snake_mixer receives from network, decodes, writes to /demod-snake-src-{N}
//   - demod-rt reads from source rings, presents as JACK output ports
//
// Cue-mix path (reverse):
//   - demod-rt writes cue audio to /demod-snake-cue-{N}
//   - snake_mixer reads from cue rings, sends raw-L2 returns to spokes

#ifndef SNAKE_IPC_H
#define SNAKE_IPC_H

#include <stdatomic.h>
#include <stdalign.h>
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

// Maximum number of snake sources (spokes in the star topology)
#define SNAKE_IPC_MAX_SRC 8u

// Ring capacity: 65536 samples = 1.36 seconds @ 48kHz (power of 2 for efficient masking)
// This absorbs codec jitter and network latency variations
#define SNAKE_IPC_RING_CAP 65536u

// Shared memory names
#define SNAKE_IPC_TX_SHM_NAME "/demod-snake-tx"
#define SNAKE_IPC_SRC_SHM_PREFIX "/demod-snake-src-"
#define SNAKE_IPC_SRC_SHM_NAME_FMT "/demod-snake-src-%d"
#define SNAKE_IPC_CUE_SHM_PREFIX "/demod-snake-cue-"

// SPSC ring buffer for float32 audio (lock-free, wait-free)
//
// Memory layout:
//   - write_idx: producer writes here (cache line aligned)
//   - read_idx_cached: producer's cache of consumer's read position
//   - read_idx: consumer writes here (cache line aligned)
//   - write_idx_cached: consumer's cache of producer's write position
//   - capacity, mask: immutable after init
//   - data[]: ring buffer (cache line aligned)
//
// On x86 TSO, acquire/release compile to plain MOV — zero fence cost.
// On RISC-V, atomics are native and efficient.
typedef struct SnakeSpsc {
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
} SnakeSpsc;

// Initialize a ring in shared memory
// Called once by the producer (demod-rt on spoke, snake_mixer on hub)
static inline SnakeSpsc *snake_spsc_init(void *mem, uint64_t capacity) {
    if (!mem || capacity < 2)
        return NULL;
    
    // Ensure capacity is power of 2
    if (capacity & (capacity - 1)) {
        // Round up to next power of 2
        capacity--;
        capacity |= capacity >> 1;
        capacity |= capacity >> 2;
        capacity |= capacity >> 4;
        capacity |= capacity >> 8;
        capacity |= capacity >> 16;
        capacity |= capacity >> 32;
        capacity++;
    }
    
    SnakeSpsc *rb = (SnakeSpsc *)mem;
    memset(rb, 0, sizeof(SnakeSpsc) + capacity * sizeof(float));
    rb->capacity = capacity;
    rb->mask = capacity - 1;
    atomic_store_explicit(&rb->write_idx, 0, memory_order_relaxed);
    atomic_store_explicit(&rb->read_idx, 0, memory_order_relaxed);
    rb->read_idx_cached = 0;
    rb->write_idx_cached = 0;
    return rb;
}

// Calculate allocation size for a given capacity
static inline size_t snake_spsc_alloc_size(uint64_t capacity) {
    return sizeof(SnakeSpsc) + capacity * sizeof(float);
}

// Producer: push samples (non-blocking, returns number written)
//
// If the ring is full, returns 0. Caller should handle partial writes.
//
// Memory ordering: release on write_idx ensures samples are visible before the index.
static inline uint64_t snake_spsc_push(SnakeSpsc *rb, const float *data, uint64_t count) {
    const uint64_t w = atomic_load_explicit(&rb->write_idx, memory_order_relaxed);
    uint64_t available = rb->capacity - (w - rb->read_idx_cached);
    
    if (available < count) {
        // Refresh cached read index
        rb->read_idx_cached = atomic_load_explicit(&rb->read_idx, memory_order_acquire);
        available = rb->capacity - (w - rb->read_idx_cached);
        if (available < count)
            return 0;  // genuinely full
    }
    
    // Write data with wrap-around via bitmask
    const uint64_t mask = rb->mask;
    for (uint64_t i = 0; i < count; i++)
        rb->data[(w + i) & mask] = data[i];
    
    // Release: ensure data is visible before index update
    atomic_store_explicit(&rb->write_idx, w + count, memory_order_release);
    return count;
}

// Consumer: pop samples (non-blocking, returns number read)
//
// If the ring is empty, returns 0. Caller should handle underrun.
//
// Memory ordering: acquire on read_idx ensures we see the latest write_idx.
static inline uint64_t snake_spsc_pop(SnakeSpsc *rb, float *buf, uint64_t max_count) {
    const uint64_t r = atomic_load_explicit(&rb->read_idx, memory_order_relaxed);
    uint64_t available = rb->write_idx_cached - r;
    
    if (available == 0) {
        // Refresh cached write index
        rb->write_idx_cached = atomic_load_explicit(&rb->write_idx, memory_order_acquire);
        available = rb->write_idx_cached - r;
        if (available == 0)
            return 0;  // genuinely empty
    }
    
    const uint64_t count = (available < max_count) ? available : max_count;
    const uint64_t mask = rb->mask;
    for (uint64_t i = 0; i < count; i++)
        buf[i] = rb->data[(r + i) & mask];
    
    // Release: ensure reads complete before advancing index
    atomic_store_explicit(&rb->read_idx, r + count, memory_order_release);
    return count;
}

// Query available samples to read
static inline uint64_t snake_spsc_available_read(const SnakeSpsc *rb) {
    const uint64_t w = atomic_load_explicit(&rb->write_idx, memory_order_acquire);
    const uint64_t r = atomic_load_explicit(&rb->read_idx, memory_order_acquire);
    return w - r;
}

// Query available space to write
static inline uint64_t snake_spsc_available_write(const SnakeSpsc *rb) {
    const uint64_t w = atomic_load_explicit(&rb->write_idx, memory_order_acquire);
    const uint64_t r = atomic_load_explicit(&rb->read_idx, memory_order_acquire);
    return rb->capacity - (w - r);
}

#ifdef __cplusplus
}
#endif

#endif // SNAKE_IPC_H
