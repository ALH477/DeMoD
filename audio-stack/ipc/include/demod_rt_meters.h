/* SPDX-License-Identifier: GPL-3.0-only */
/*
 * demod_rt_meters.h — RT-engine live readback for the UI (writer side, demod-rt).
 *
 * demod-rt is the sole writer of a dedicated shm segment (/dev/shm/demod-rt-meters);
 * the UI maps it read-only and does a single-writer seqlock read. Carries per-slot
 * post-fader levels (mono + L/R), the authoritative per-slot mixer state (gain/pan/
 * mute/solo) for the MIXER screen, and a window of the post-master stereo output for
 * scope/spectrum/lissajous.
 *
 * KEEP BYTE-IDENTICAL with the framework's include/demod/demod_rt_meters.h
 * (same struct layout, different license: the framework copy is MPL-2.0, this
 * engine-side copy is GPL-3.0-only — see LICENSING.md).
 *
 * Copyright (C) 2025-2026 DeMoD LLC. Dual-licensed GPLv3-only OR commercial; see LICENSE.
 */
#ifndef DEMOD_RT_METERS_H
#define DEMOD_RT_METERS_H

#include <stdint.h>
#include <stdatomic.h>

#define DEMOD_SHM_RT_METERS    "/demod-rt-meters"
#define DEMOD_RT_METERS_SLOTS  16
#define DEMOD_RT_METERS_SCOPE_N 256

typedef struct DemodRtMeters {
    _Atomic uint32_t seq;          /* seqlock; odd = write in progress */
    uint32_t         scope_n;      /* valid samples in scope_l/r (== SCOPE_N once filled) */
    float            fx_levels[DEMOD_RT_METERS_SLOTS]; /* per-slot post-fader peak (mono), ~0..1 */
    float            scope_l[DEMOD_RT_METERS_SCOPE_N]; /* post-master output window */
    float            scope_r[DEMOD_RT_METERS_SCOPE_N];
    /* ── per-slot mixer readback (the MIXER screen) ─────────────────────── */
    float            fx_levels_l[DEMOD_RT_METERS_SLOTS]; /* per-slot post-fader L peak, ~0..1 */
    float            fx_levels_r[DEMOD_RT_METERS_SLOTS]; /* per-slot post-fader R peak, ~0..1 */
    float            slot_gain[DEMOD_RT_METERS_SLOTS];   /* authoritative per-slot gain, 0..1.5 */
    float            slot_pan[DEMOD_RT_METERS_SLOTS];    /* authoritative per-slot pan, -1..1 */
    uint32_t         slot_mute_mask;                     /* bit i = slot i muted */
    uint32_t         slot_solo_mask;                     /* bit i = slot i soloed */
} DemodRtMeters;

#endif /* DEMOD_RT_METERS_H */
