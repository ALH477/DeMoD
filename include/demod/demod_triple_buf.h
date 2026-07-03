// SPDX-License-Identifier: MPL-2.0
/*
 * demod_triple_buf.h — Lock-free triple buffer for parameter updates.
 * Vendored into demod-ui from the demod5 IPC contract so the framebuffer app
 * can read /dev/shm/demod-params without depending on the demod5 source tree.
 * Keep byte-compatible with demod5/demod/ipc/include/demod_triple_buf.h.
 *
 * Copyright (c) 2026 DeMoD LLC. Licensed under the Mozilla Public License, v. 2.0 (see LICENSE).
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
    float    detected_pitch_hz;
    float    pitch_confidence;
    int32_t  midi_note;
    float    bpm;
    uint32_t beat_count;
    float    fx_params[16];
    uint32_t fx_bypass_mask;
    uint32_t synth_mix_mode;     /* 0=sum, 1=dry, 2=synth-only */
    float    synth_gain;
    uint32_t osc_route_version;
    uint8_t  bt_codec_id;
    uint8_t  bt_connected;
    float    sdr_center_freq_mhz;
    float    sdr_bandwidth_khz;
    uint64_t timestamp_us;
    uint8_t  _reserved[136];
} DemodParamSnapshot;

_Static_assert(sizeof(DemodParamSnapshot) == 256,
               "DemodParamSnapshot must be exactly 256 bytes");

#define TB_W_SHIFT 0
#define TB_M_SHIFT 2
#define TB_R_SHIFT 4
#define TB_DIRTY   (1u << 6)
#define TB_MASK    3u

static inline uint32_t tb_r(uint32_t s) { return (s >> TB_R_SHIFT) & TB_MASK; }

typedef struct DemodTripleBuf {
    alignas(64) _Atomic uint32_t   state;
    alignas(64) _Atomic uint64_t   sequence;
    alignas(64) DemodParamSnapshot buffers[3];
} DemodTripleBuf;

#ifdef __cplusplus
}
#endif
#endif /* DEMOD_TRIPLE_BUF_H */
