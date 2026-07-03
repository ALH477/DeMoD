/*
 * demod_ffi_helpers.h — C FFI Bridge for Haskell Orchestrator
 *
 * Copyright (C) 2025–2026 DeMoD LLC
 * SPDX-License-Identifier: GPL-3.0-only
 *
 * Non-inline wrappers around the header-only IPC primitives, plus
 * POSIX RT helpers (sched_setaffinity, sched_setscheduler, mlockall,
 * setrlimit). These are the functions Haskell calls via FFI.
 *
 * All IPC functions are marked for unsafe FFI (~10-20ns overhead).
 */

#ifndef DEMOD_FFI_HELPERS_H
#define DEMOD_FFI_HELPERS_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ── POSIX RT Helpers ──────────────────────────────────────────── */

/* Set CPU affinity to a single core. Returns 0 on success, -errno on failure. */
int demod_ffi_set_cpu_affinity(int core);

/* Set SCHED_FIFO at given priority. Returns 0 on success, -errno on failure. */
int demod_ffi_set_sched_fifo(int priority);

/* Set RLIMIT_MEMLOCK to unlimited. Returns 0 on success, -errno on failure. */
int demod_ffi_set_rlimit_memlock_unlimited(void);

/* mlockall(MCL_CURRENT | MCL_FUTURE). Returns 0 on success, -errno on failure. */
int demod_ffi_mlockall(void);

/* Get monotonic clock in microseconds. */
uint64_t demod_ffi_clock_us(void);

/* ── IPC Lifecycle ─────────────────────────────────────────────── */

/*
 * Opaque handle to the full IPC setup (DemodIpc).
 * Allocated on the C heap, freed by demod_ffi_ipc_destroy.
 */
typedef struct DemodIpc DemodFfiIpc;

/*
 * Create all shared memory IPC regions.
 * Returns heap-allocated DemodIpc*, or NULL on failure.
 * spsc_capacity must be a power of 2 (will be rounded up if not).
 */
DemodFfiIpc *demod_ffi_ipc_create(uint64_t spsc_capacity);

/*
 * Open all shared memory IPC regions (child side, after exec).
 * Returns heap-allocated DemodIpc*, or NULL on failure.
 */
DemodFfiIpc *demod_ffi_ipc_open(uint64_t spsc_capacity);

/*
 * Destroy and unlink all shared memory regions.
 */
void demod_ffi_ipc_destroy(DemodFfiIpc *ipc);

/* ── Triple Buffer ─────────────────────────────────────────────── */

/*
 * Get pointer to the writer's buffer (256 bytes, exclusively owned).
 * Caller fills it, then calls demod_ffi_tb_publish.
 */
void *demod_ffi_tb_begin_write(DemodFfiIpc *ipc);

/* Publish: swap writer ↔ middle, set dirty. */
void demod_ffi_tb_publish(DemodFfiIpc *ipc);

/* Read active snapshot into dst (256 bytes). Returns sequence number. */
uint64_t demod_ffi_tb_read_copy(DemodFfiIpc *ipc, void *dst);

/* Get current sequence number. */
uint64_t demod_ffi_tb_sequence(const DemodFfiIpc *ipc);

/* ── SPSC Ring Buffers ─────────────────────────────────────────── */

/* Push to command ring (orchestrator → RT). Returns count pushed. */
uint64_t demod_ffi_cmd_push(DemodFfiIpc *ipc, const float *data, uint64_t count);

/* Push to event ring (test/debug only). Returns count pushed. */
uint64_t demod_ffi_evt_push(DemodFfiIpc *ipc, const float *data, uint64_t count);

/* Pop from event ring (RT → orchestrator). Returns count popped. */
uint64_t demod_ffi_evt_pop(DemodFfiIpc *ipc, float *buf, uint64_t max_count);

/* Available items in event ring. */
uint64_t demod_ffi_evt_available(const DemodFfiIpc *ipc);

/* ── Heartbeat ─────────────────────────────────────────────────── */

/* Read RT process heartbeat timestamp (microseconds). */
uint64_t demod_ffi_heartbeat_timestamp(const DemodFfiIpc *ipc);

/* Read RT callback count. */
uint64_t demod_ffi_heartbeat_callback_count(const DemodFfiIpc *ipc);

/* Read RT xrun count. */
uint64_t demod_ffi_heartbeat_xrun_count(const DemodFfiIpc *ipc);

/* Read RT alive flag (1 = running, 0 = stopped). */
uint32_t demod_ffi_heartbeat_alive(const DemodFfiIpc *ipc);

/* Read RT CPU load (0.0–1.0). */
float demod_ffi_heartbeat_cpu_load(const DemodFfiIpc *ipc);

/* ── ParamSnapshot Field Setters ───────────────────────────────── */
/* These write directly into the writer's buffer obtained via begin_write. */

void demod_ffi_snap_set_pitch(void *snap, float hz, float confidence, int32_t midi_note);
void demod_ffi_snap_set_tempo(void *snap, float bpm, uint32_t beat_count);
void demod_ffi_snap_set_fx_param(void *snap, int slot, float value);
void demod_ffi_snap_set_fx_bypass(void *snap, uint32_t mask);
void demod_ffi_snap_set_synth(void *snap, uint32_t mix_mode, float gain);
void demod_ffi_snap_set_bt_state(void *snap, uint8_t codec_id, uint8_t connected);
void demod_ffi_snap_set_sdr(void *snap, float center_mhz, float bw_khz);
void demod_ffi_snap_set_timestamp(void *snap, uint64_t us);

/* ── ParamSnapshot Field Getters (for reading copy) ────────────── */

float    demod_ffi_snap_get_pitch_hz(const void *snap);
float    demod_ffi_snap_get_pitch_confidence(const void *snap);
int32_t  demod_ffi_snap_get_midi_note(const void *snap);
float    demod_ffi_snap_get_bpm(const void *snap);
uint32_t demod_ffi_snap_get_beat_count(const void *snap);
float    demod_ffi_snap_get_fx_param(const void *snap, int slot);
uint32_t demod_ffi_snap_get_fx_bypass(const void *snap);
uint32_t demod_ffi_snap_get_synth_mix_mode(const void *snap);
float    demod_ffi_snap_get_synth_gain(const void *snap);

#ifdef __cplusplus
}
#endif

#endif /* DEMOD_FFI_HELPERS_H */
