/*
 * demod_ffi_helpers.c — C FFI Bridge Implementation
 *
 * Copyright (C) 2025–2026 DeMoD LLC
 * SPDX-License-Identifier: GPL-3.0-only
 */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "demod_ffi_helpers.h"

#include <sched.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <time.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>

/* Pull in the header-only IPC implementations */
#include "demod_shm.h"

/* ── POSIX RT Helpers ──────────────────────────────────────────── */

int demod_ffi_set_cpu_affinity(int core) {
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET((unsigned)core, &cpuset);
    if (sched_setaffinity(0, sizeof(cpuset), &cpuset) < 0)
        return -errno;
    return 0;
}

int demod_ffi_set_sched_fifo(int priority) {
    struct sched_param sp;
    memset(&sp, 0, sizeof(sp));
    sp.sched_priority = priority;
    if (sched_setscheduler(0, SCHED_FIFO, &sp) < 0)
        return -errno;
    return 0;
}

int demod_ffi_set_rlimit_memlock_unlimited(void) {
    struct rlimit rl;
    rl.rlim_cur = RLIM_INFINITY;
    rl.rlim_max = RLIM_INFINITY;
    if (setrlimit(RLIMIT_MEMLOCK, &rl) < 0)
        return -errno;
    return 0;
}

int demod_ffi_mlockall(void) {
    if (mlockall(MCL_CURRENT | MCL_FUTURE) < 0)
        return -errno;
    return 0;
}

uint64_t demod_ffi_clock_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
    return (uint64_t)ts.tv_sec * 1000000ULL + (uint64_t)ts.tv_nsec / 1000ULL;
}

/* ── IPC Lifecycle ─────────────────────────────────────────────── */

DemodFfiIpc *demod_ffi_ipc_create(uint64_t spsc_capacity) {
    DemodIpc *ipc = (DemodIpc *)calloc(1, sizeof(DemodIpc));
    if (!ipc) return NULL;

    int rc = demod_ipc_create(ipc, spsc_capacity);
    if (rc < 0) {
        free(ipc);
        return NULL;
    }
    return (DemodFfiIpc *)ipc;
}

DemodFfiIpc *demod_ffi_ipc_open(uint64_t spsc_capacity) {
    DemodIpc *ipc = (DemodIpc *)calloc(1, sizeof(DemodIpc));
    if (!ipc) return NULL;

    int rc = demod_ipc_open(ipc, spsc_capacity);
    if (rc < 0) {
        free(ipc);
        return NULL;
    }
    return (DemodFfiIpc *)ipc;
}

void demod_ffi_ipc_destroy(DemodFfiIpc *ipc) {
    if (!ipc) return;
    demod_ipc_destroy((DemodIpc *)ipc);
    free(ipc);
}

/* ── Triple Buffer ─────────────────────────────────────────────── */

void *demod_ffi_tb_begin_write(DemodFfiIpc *ipc) {
    DemodIpc *real = (DemodIpc *)ipc;
    return (void *)demod_triple_buf_begin_write(real->params);
}

void demod_ffi_tb_publish(DemodFfiIpc *ipc) {
    DemodIpc *real = (DemodIpc *)ipc;
    demod_triple_buf_publish(real->params);
}

uint64_t demod_ffi_tb_read_copy(DemodFfiIpc *ipc, void *dst) {
    DemodIpc *real = (DemodIpc *)ipc;
    return demod_triple_buf_read_copy(real->params, (DemodParamSnapshot *)dst);
}

uint64_t demod_ffi_tb_sequence(const DemodFfiIpc *ipc) {
    const DemodIpc *real = (const DemodIpc *)ipc;
    return demod_triple_buf_sequence(real->params);
}

/* ── SPSC ──────────────────────────────────────────────────────── */

uint64_t demod_ffi_cmd_push(DemodFfiIpc *ipc, const float *data, uint64_t count) {
    DemodIpc *real = (DemodIpc *)ipc;
    return demod_spsc_push(real->cmd_ring, data, count);
}

uint64_t demod_ffi_evt_push(DemodFfiIpc *ipc, const float *data, uint64_t count) {
    DemodIpc *real = (DemodIpc *)ipc;
    return demod_spsc_push(real->evt_ring, data, count);
}

uint64_t demod_ffi_evt_pop(DemodFfiIpc *ipc, float *buf, uint64_t max_count) {
    DemodIpc *real = (DemodIpc *)ipc;
    return demod_spsc_pop(real->evt_ring, buf, max_count);
}

uint64_t demod_ffi_evt_available(const DemodFfiIpc *ipc) {
    const DemodIpc *real = (const DemodIpc *)ipc;
    return demod_spsc_available_read(real->evt_ring);
}

/* ── Heartbeat ─────────────────────────────────────────────────── */

uint64_t demod_ffi_heartbeat_timestamp(const DemodFfiIpc *ipc) {
    const DemodIpc *real = (const DemodIpc *)ipc;
    return atomic_load_explicit(&real->heartbeat->rt_timestamp_us, memory_order_acquire);
}

uint64_t demod_ffi_heartbeat_callback_count(const DemodFfiIpc *ipc) {
    const DemodIpc *real = (const DemodIpc *)ipc;
    return atomic_load_explicit(&real->heartbeat->rt_callback_count, memory_order_acquire);
}

uint64_t demod_ffi_heartbeat_xrun_count(const DemodFfiIpc *ipc) {
    const DemodIpc *real = (const DemodIpc *)ipc;
    return atomic_load_explicit(&real->heartbeat->rt_xrun_count, memory_order_acquire);
}

uint32_t demod_ffi_heartbeat_alive(const DemodFfiIpc *ipc) {
    const DemodIpc *real = (const DemodIpc *)ipc;
    return atomic_load_explicit(&real->heartbeat->rt_alive, memory_order_acquire);
}

float demod_ffi_heartbeat_cpu_load(const DemodFfiIpc *ipc) {
    const DemodIpc *real = (const DemodIpc *)ipc;
    return real->heartbeat->rt_cpu_load;
}

/* ── ParamSnapshot Setters ─────────────────────────────────────── */

void demod_ffi_snap_set_pitch(void *snap, float hz, float confidence, int32_t midi_note) {
    DemodParamSnapshot *s = (DemodParamSnapshot *)snap;
    s->detected_pitch_hz = hz;
    s->pitch_confidence  = confidence;
    s->midi_note         = midi_note;
}

void demod_ffi_snap_set_tempo(void *snap, float bpm, uint32_t beat_count) {
    DemodParamSnapshot *s = (DemodParamSnapshot *)snap;
    s->bpm        = bpm;
    s->beat_count = beat_count;
}

void demod_ffi_snap_set_fx_param(void *snap, int slot, float value) {
    DemodParamSnapshot *s = (DemodParamSnapshot *)snap;
    if (slot >= 0 && slot < 16)
        s->fx_params[slot] = value;
}

void demod_ffi_snap_set_fx_bypass(void *snap, uint32_t mask) {
    DemodParamSnapshot *s = (DemodParamSnapshot *)snap;
    s->fx_bypass_mask = mask;
}

void demod_ffi_snap_set_synth(void *snap, uint32_t mix_mode, float gain) {
    DemodParamSnapshot *s = (DemodParamSnapshot *)snap;
    s->synth_mix_mode = mix_mode;
    s->synth_gain = gain;
}

void demod_ffi_snap_set_bt_state(void *snap, uint8_t codec_id, uint8_t connected) {
    DemodParamSnapshot *s = (DemodParamSnapshot *)snap;
    s->bt_codec_id  = codec_id;
    s->bt_connected = connected;
}

void demod_ffi_snap_set_sdr(void *snap, float center_mhz, float bw_khz) {
    DemodParamSnapshot *s = (DemodParamSnapshot *)snap;
    s->sdr_center_freq_mhz = center_mhz;
    s->sdr_bandwidth_khz   = bw_khz;
}

void demod_ffi_snap_set_timestamp(void *snap, uint64_t us) {
    DemodParamSnapshot *s = (DemodParamSnapshot *)snap;
    s->timestamp_us = us;
}

/* ── ParamSnapshot Getters ─────────────────────────────────────── */

float demod_ffi_snap_get_pitch_hz(const void *snap) {
    return ((const DemodParamSnapshot *)snap)->detected_pitch_hz;
}

float demod_ffi_snap_get_pitch_confidence(const void *snap) {
    return ((const DemodParamSnapshot *)snap)->pitch_confidence;
}

int32_t demod_ffi_snap_get_midi_note(const void *snap) {
    return ((const DemodParamSnapshot *)snap)->midi_note;
}

float demod_ffi_snap_get_bpm(const void *snap) {
    return ((const DemodParamSnapshot *)snap)->bpm;
}

uint32_t demod_ffi_snap_get_beat_count(const void *snap) {
    return ((const DemodParamSnapshot *)snap)->beat_count;
}

float demod_ffi_snap_get_fx_param(const void *snap, int slot) {
    if (slot >= 0 && slot < 16)
        return ((const DemodParamSnapshot *)snap)->fx_params[slot];
    return 0.0f;
}

uint32_t demod_ffi_snap_get_fx_bypass(const void *snap) {
    return ((const DemodParamSnapshot *)snap)->fx_bypass_mask;
}

uint32_t demod_ffi_snap_get_synth_mix_mode(const void *snap) {
    return ((const DemodParamSnapshot *)snap)->synth_mix_mode;
}

float demod_ffi_snap_get_synth_gain(const void *snap) {
    return ((const DemodParamSnapshot *)snap)->synth_gain;
}
