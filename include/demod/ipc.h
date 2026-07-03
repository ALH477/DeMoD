// SPDX-License-Identifier: MPL-2.0
/*
 * ipc.h — demod-ui ↔ demod5 orchestrator IPC client.
 *   • param bus:     read /dev/shm/demod-params (lock-free seqlock snapshot read)
 *   • control socket: write /run/demod/control.sock (JSON-lines commands)
 * Both are optional; on a host without the orchestrator the reads report
 * unavailable and the sends are no-ops, so the same binary runs anywhere.
 *
 * Paths can be overridden with $DEMOD_PARAMS_SHM and $DEMOD_CONTROL_SOCK.
 * Copyright (c) 2026 DeMoD LLC. Licensed under the Mozilla Public License, v. 2.0 (see LICENSE).
 */
#ifndef DEMOD_IPC_H
#define DEMOD_IPC_H

#include "demod/demod_triple_buf.h"
#include "demod/demod_rt_meters.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Non-destructive seqlock read of the current param snapshot.
 * Returns 1 and fills *out on success, 0 if the shm is unavailable. */
int  demod_params_read(DemodParamSnapshot *out);
void demod_params_close(void);

/* Read demod-rt's live readback shm (per-slot RMS + post-chain scope window).
 * Returns 1 and fills *out on a stable read, 0 if demod-rt isn't publishing. */
int  demod_rt_meters_read(DemodRtMeters *out);
void demod_rt_meters_close(void);

/* Send a single JSON command line to the control socket (connect/send/close).
 * Returns 0 on success, -1 if the socket is unavailable or the write failed. */
int  demod_control_send_raw(const char *json_line);

/* Typed convenience wrappers matching the orchestrator's Control.hs ops. */
int  demod_control_set_param(int slot, int idx, float value);
int  demod_control_bypass(int slot, int on);
int  demod_control_set_bpm(float bpm);
int  demod_control_set_gain(float gain);

#ifdef __cplusplus
}
#endif
#endif /* DEMOD_IPC_H */
