/*
 * demod_triple_buf.h — Lock-Free Triple Buffer for Parameter Updates
 *
 * Vendored into the cabal package so the orchestrator can be packaged as a
 * self-contained artifact. Keep this in sync with ipc/include/demod_triple_buf.h.
 *
 * Copyright (C) 2025–2026 DeMoD LLC
 * SPDX-License-Identifier: GPL-3.0-only
 */

#ifndef DEMOD_TRIPLE_BUF_H
#define DEMOD_TRIPLE_BUF_H

#include <stdatomic.h>
#include <stdalign.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
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

#ifdef __cplusplus
}
#endif

#endif /* DEMOD_TRIPLE_BUF_H */
