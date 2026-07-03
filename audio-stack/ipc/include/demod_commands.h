/*
 * demod_commands.h — IPC Command Protocol
 *
 * Copyright (C) 2025–2026 DeMoD LLC
 * SPDX-License-Identifier: GPL-3.0-only
 *
 * Commands sent from the Haskell orchestrator to the RT audio process
 * via the SPSC command ring. Each command is a sequence of floats
 * where the first float encodes the command type.
 *
 * The RT process reads commands at the start of each callback
 * (non-blocking, O(1) per command). Commands that require I/O
 * (like loading a .so) are deferred to a non-RT helper thread.
 */

#ifndef DEMOD_COMMANDS_H
#define DEMOD_COMMANDS_H

#ifdef __cplusplus
extern "C" {
#endif

/* ── Command codes (encoded as float in SPSC slot 0) ──────────── */

/* FX chain management */
#define DEMOD_CMD_FX_LOAD       1.0f   /* [cmd, slot, path_hash]     */
#define DEMOD_CMD_FX_UNLOAD     2.0f   /* [cmd, slot]                */
#define DEMOD_CMD_FX_BYPASS     3.0f   /* [cmd, slot, 0=off/1=on]    */
#define DEMOD_CMD_FX_PARAM      4.0f   /* [cmd, slot, param_idx, val]*/

/* Transport */
#define DEMOD_CMD_SET_BPM       10.0f  /* [cmd, bpm]                 */
#define DEMOD_CMD_SET_GAIN      11.0f  /* [cmd, gain_linear]         */

/* Per-slot mixer (channel strip). Applied post-node (FX insert trim) or to the
 * instrument bus before the synth sum (synth fader). Pan is an L/R balance.
 * mute/solo are honored for instrument slots (FX-insert mute uses FX_BYPASS). */
#define DEMOD_CMD_SLOT_GAIN     12.0f  /* [cmd, slot, gain_linear 0..1.5] */
#define DEMOD_CMD_SLOT_PAN      13.0f  /* [cmd, slot, pan -1..1]          */
#define DEMOD_CMD_SLOT_MUTE     14.0f  /* [cmd, slot, 0=off/1=on]         */
#define DEMOD_CMD_SLOT_SOLO     15.0f  /* [cmd, slot, 0=off/1=on]         */

/* Instrument note control */
#define DEMOD_CMD_NOTE_ON       20.0f  /* [cmd, slot, note, velocity]*/
#define DEMOD_CMD_NOTE_OFF      21.0f  /* [cmd, slot, note]          */
#define DEMOD_CMD_ALL_NOTES_OFF 22.0f  /* [cmd, slot]                */
#define DEMOD_CMD_SET_MIX_MODE  23.0f  /* [cmd, 0=sum/1=dry/2=synth] */

/* System */
#define DEMOD_CMD_PING          90.0f  /* [cmd] — orchestrator liveness check */
#define DEMOD_CMD_SHUTDOWN      99.0f  /* [cmd] — graceful shutdown request   */

/* ── Event codes (RT → orchestrator, via SPSC event ring) ─────── */

/* Note: audio samples also share the event ring (interleaved).
 * Events are distinguished by a NaN sentinel followed by the event code.
 * Audio samples are never NaN in normal operation. */

#define DEMOD_EVT_SENTINEL      0x7FC00000  /* quiet NaN as uint32 */
#define DEMOD_EVT_XRUN          1.0f   /* [sentinel, evt, xrun_count] */
#define DEMOD_EVT_PONG          90.0f  /* [sentinel, evt] — response to PING */
#define DEMOD_EVT_FX_LOADED     101.0f /* [sentinel, evt, slot]      */
#define DEMOD_EVT_FX_ERROR      102.0f /* [sentinel, evt, slot]      */

/* ── Command sizes (number of floats per command) ──────────────── */

#define DEMOD_CMD_SIZE_FX_LOAD   3
#define DEMOD_CMD_SIZE_FX_UNLOAD 2
#define DEMOD_CMD_SIZE_FX_BYPASS 3
#define DEMOD_CMD_SIZE_FX_PARAM  4
#define DEMOD_CMD_SIZE_SET_BPM   2
#define DEMOD_CMD_SIZE_SET_GAIN  2
#define DEMOD_CMD_SIZE_SLOT_GAIN 3
#define DEMOD_CMD_SIZE_SLOT_PAN  3
#define DEMOD_CMD_SIZE_SLOT_MUTE 3
#define DEMOD_CMD_SIZE_SLOT_SOLO 3
#define DEMOD_CMD_SIZE_NOTE_ON   4
#define DEMOD_CMD_SIZE_NOTE_OFF  3
#define DEMOD_CMD_SIZE_ALL_NOTES_OFF 2
#define DEMOD_CMD_SIZE_SET_MIX_MODE 2
#define DEMOD_CMD_SIZE_PING      1
#define DEMOD_CMD_SIZE_SHUTDOWN  1

#ifdef __cplusplus
}
#endif

#endif /* DEMOD_COMMANDS_H */
