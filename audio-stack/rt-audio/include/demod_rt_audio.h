/*
 * demod_rt_audio.h — Deterministic RT Audio Engine
 *
 * Copyright (C) 2025–2026 DeMoD LLC
 * SPDX-License-Identifier: GPL-3.0-only
 *
 * The hard-RT audio callback. Runs on an isolated core (SCHED_FIFO 80),
 * reads parameters from triple-buffered shared memory, processes 64 samples
 * per callback at 48kHz (1.33ms budget), writes to JACK output.
 *
 * RULES FOR THIS FILE:
 *   - No malloc/free/new/delete in the callback
 *   - No syscalls (no printf, no file I/O, no mutex)
 *   - No blocking IPC (no pipes, no sockets, no condition variables)
 *   - All memory pre-allocated and mlocked
 *   - All branches deterministic (no data-dependent branching on user input)
 */

#ifndef DEMOD_RT_AUDIO_H
#define DEMOD_RT_AUDIO_H

#include <jack/jack.h>
#include <sched.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <pthread.h>
#include <math.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <time.h>

#include "demod_shm.h"
#include "demod_commands.h"
#include "demod_faust_glue.h"
#include "demod_rt_meters.h"
#include "snake_ipc.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ── Configuration ─────────────────────────────────────────────── */

#define DEMOD_RT_SAMPLE_RATE    48000
#define DEMOD_RT_BUFFER_SIZE    64      /* Target period on hardware: 64 / 48000 = 1.333ms */
#define DEMOD_RT_MAX_JACK_FRAMES 4096   /* Safe upper bound for variable JACK periods */
#define DEMOD_RT_CHANNELS       2
#define DEMOD_RT_MAX_FX_SLOTS   16
#define DEMOD_RT_MAX_FX_PARAMS  16
#define DEMOD_RT_MAX_INSTRUMENT_VOICES 8
#define DEMOD_RT_MAX_PARAM_ZONES (DEMOD_RT_MAX_INSTRUMENT_VOICES * DEMOD_RT_CHANNELS)
#define DEMOD_RT_SCHED_PRIORITY 80      /* Below USB IRQ (90), above JACK (70) */

typedef enum DemodSlotKind {
    DEMOD_SLOT_FX = 0,
    DEMOD_SLOT_INSTRUMENT = 1
} DemodSlotKind;

typedef enum DemodMixMode {
    DEMOD_MIX_SUM = 0,
    DEMOD_MIX_DRY = 1,
    DEMOD_MIX_SYNTH_ONLY = 2
} DemodMixMode;

/* ── Padé [3/3] tanh approximant ────────────────────────────────
 * Standard DeMoD saturator. Used across all DSP: CollabEngine, DeMoDOOM,
 * Vox, SKILL Standard. Accurate to <0.1% for |x| < 3.
 * No branches, no divisions by zero (denominator always > 0 for real x).
 */
static inline float demod_pade_tanh(float x) {
    const float x2 = x * x;
    const float num = x * (135135.0f + x2 * (17325.0f + x2 * (378.0f + x2)));
    const float den = 135135.0f + x2 * (62370.0f + x2 * (3150.0f + x2 * 28.0f));
    return num / den;
}

/* ── DC Blocker (SKILL Standard) ────────────────────────────────
 * y[n] = x[n] - x[n-1] + R * y[n-1], R = 0.995
 */
typedef struct DemodDcBlocker {
    float x_prev;
    float y_prev;
} DemodDcBlocker;

static inline float demod_dc_block(DemodDcBlocker *dc, float x) {
    const float R = 0.995f;
    float y = x - dc->x_prev + R * dc->y_prev;
    dc->x_prev = x;
    dc->y_prev = y;
    return y;
}

/* ── si.smoo one-pole smoother (SKILL Standard) ──────────────── */
static inline float demod_smoo(float *state, float target, float coeff) {
    *state += coeff * (target - *state);
    return *state;
}

static inline float demod_clampf(float x, float lo, float hi) {
    return fminf(hi, fmaxf(lo, x));
}

/* ── FX Slot (Faust-generated compute function pointer) ───────── */

typedef void (*DemodFxComputeFn)(void *dsp, int count,
                                 float **inputs, float **outputs);

typedef struct DemodRtEngine DemodRtEngine;

typedef struct DemodFxParamDesc {
    FAUSTFLOAT *zone[DEMOD_RT_MAX_PARAM_ZONES];
    FAUSTFLOAT  init;
    FAUSTFLOAT  min;
    FAUSTFLOAT  max;
    uint8_t     zone_count;
} DemodFxParamDesc;

typedef struct DemodInstrumentVoiceState {
    uint8_t    active;
    uint8_t    note;
    uint8_t    velocity;
    uint8_t    _pad;
    uint32_t   age;
    FAUSTFLOAT *gate_zone[DEMOD_RT_CHANNELS];
    FAUSTFLOAT *freq_zone[DEMOD_RT_CHANNELS];
    FAUSTFLOAT *gain_zone[DEMOD_RT_CHANNELS];
} DemodInstrumentVoiceState;

typedef struct DemodFxSlot {
    void              *dsp[DEMOD_RT_CHANNELS];
    void              *voice_dsp[DEMOD_RT_MAX_INSTRUMENT_VOICES][DEMOD_RT_CHANNELS];
    DemodFxComputeFn   compute;
    DemodFxParamDesc   params[DEMOD_RT_MAX_FX_PARAMS];
    DemodInstrumentVoiceState voices[DEMOD_RT_MAX_INSTRUMENT_VOICES];
    float              out_buf[DEMOD_RT_CHANNELS][DEMOD_RT_MAX_JACK_FRAMES];
    float              voice_buf[DEMOD_RT_CHANNELS][DEMOD_RT_MAX_JACK_FRAMES];
    uint32_t           voice_clock;
    DemodSlotKind      kind;
    uint8_t            dsp_count;
    uint8_t            voice_count;
    uint8_t            num_inputs;
    uint8_t            num_outputs;
    uint8_t            param_count;
    uint8_t            active;
    /* per-slot mixer (channel strip): targets set by SLOT_* commands, applied
     * block-rate-smoothed via gain_sm_l/r to avoid zipper noise. gain 0..1.5,
     * pan -1..1 (balance), mute/solo gates (solo = instrument bus only). */
    float              gain;
    float              pan;
    uint8_t            mute;
    uint8_t            solo;
    float              gain_sm_l;
    float              gain_sm_r;
    float              meter_l;   /* per-block post-fader L peak (→ meters shm) */
    float              meter_r;   /* per-block post-fader R peak */
} DemodFxSlot;

static inline void demod_rt_apply_fx_params(const DemodParamSnapshot *snapshot,
                                            DemodFxSlot *slot)
{
    for (int i = 0; i < slot->param_count && i < DEMOD_RT_MAX_FX_PARAMS; i++) {
        DemodFxParamDesc *param = &slot->params[i];
        float value = snapshot->fx_params[i];

        if (param->max > param->min) {
            value = demod_clampf(value, param->min, param->max);
        }

        for (int z = 0; z < param->zone_count && z < DEMOD_RT_MAX_PARAM_ZONES; z++) {
            if (param->zone[z]) {
                *param->zone[z] = value;
            }
        }
    }
}

static inline float demod_rt_midi_to_freq(int note) {
    return 440.0f * powf(2.0f, ((float)note - 69.0f) / 12.0f);
}

static inline void demod_rt_voice_set_zone(FAUSTFLOAT *zone[DEMOD_RT_CHANNELS],
                                           float value)
{
    for (int ch = 0; ch < DEMOD_RT_CHANNELS; ch++) {
        if (zone[ch]) {
            *zone[ch] = value;
        }
    }
}

static inline DemodInstrumentVoiceState *demod_rt_find_voice(DemodFxSlot *slot,
                                                             int note)
{
    for (int i = 0; i < slot->voice_count; i++) {
        DemodInstrumentVoiceState *voice = &slot->voices[i];
        if (voice->active && voice->note == (uint8_t)note) {
            return voice;
        }
    }
    return NULL;
}

static inline DemodInstrumentVoiceState *demod_rt_alloc_voice(DemodFxSlot *slot)
{
    DemodInstrumentVoiceState *oldest = &slot->voices[0];

    for (int i = 0; i < slot->voice_count; i++) {
        DemodInstrumentVoiceState *voice = &slot->voices[i];
        if (!voice->active) {
            return voice;
        }
        if (voice->age < oldest->age) {
            oldest = voice;
        }
    }

    return oldest;
}

static inline void demod_rt_note_on(DemodRtEngine *eng, int slot_idx,
                                    int note, int velocity);
static inline void demod_rt_note_off(DemodRtEngine *eng, int slot_idx, int note);
static inline void demod_rt_all_notes_off(DemodRtEngine *eng, int slot_idx);

/* ── RT Engine State ───────────────────────────────────────────── */

struct DemodRtEngine {
    /* JACK */
    jack_client_t  *jack_client;
    jack_port_t    *port_in_l;
    jack_port_t    *port_in_r;
    jack_port_t    *port_out_l;
    jack_port_t    *port_out_r;

    /* IPC (shared memory, opened by name) */
    DemodIpc        ipc;

    /* Live readback shm (demod-rt is the sole writer; the UI maps it read-only) */
    DemodShmRegion  meters_region;
    DemodRtMeters  *meters;

    /* Snake TX ring (spoke mode: demod-rt → quanta encoder → network) */
    DemodShmRegion  snake_tx_region;
    SnakeSpsc      *snake_tx_ring;

    /* Local snapshot (copied from triple buffer each callback) */
    DemodParamSnapshot params_local;
    uint64_t           params_seq;

    /* FX chain */
    DemodFxSlot     fx_slots[DEMOD_RT_MAX_FX_SLOTS];
    int             fx_slot_count;

    /* DSP state */
    DemodDcBlocker  dc_l, dc_r;
    float           master_gain_target;
    float           smooth_gain;
    float           transport_bpm;
    jack_nframes_t  jack_buffer_size;
    float           tap_mono[DEMOD_RT_MAX_JACK_FRAMES];
    float           zero_buf[DEMOD_RT_CHANNELS][DEMOD_RT_MAX_JACK_FRAMES];
    float           synth_sum[DEMOD_RT_CHANNELS][DEMOD_RT_MAX_JACK_FRAMES];

    /* Timing / diagnostics */
    uint64_t        callback_count;
    uint64_t        xrun_count;
    struct timespec  callback_start;
    float           cpu_load;
};

static inline float demod_evt_sentinel_float(void) {
    union {
        uint32_t u;
        float    f;
    } bits = { .u = DEMOD_EVT_SENTINEL };
    return bits.f;
}

static inline void demod_rt_push_event2(DemodRtEngine *eng, float evt_code) {
    float evt[2] = { demod_evt_sentinel_float(), evt_code };
    demod_spsc_push(eng->ipc.evt_ring, evt, 2);
}

static inline void demod_rt_push_event3(DemodRtEngine *eng, float evt_code, float arg0) {
    float evt[3] = { demod_evt_sentinel_float(), evt_code, arg0 };
    demod_spsc_push(eng->ipc.evt_ring, evt, 3);
}

static inline void demod_rt_note_on(DemodRtEngine *eng, int slot_idx,
                                    int note, int velocity)
{
    if (slot_idx < 0 || slot_idx >= DEMOD_RT_MAX_FX_SLOTS
        || note < 0 || note > 127 || velocity <= 0) {
        return;
    }

    DemodFxSlot *slot = &eng->fx_slots[slot_idx];
    if (!slot->active || slot->kind != DEMOD_SLOT_INSTRUMENT || slot->voice_count == 0) {
        return;
    }

    DemodInstrumentVoiceState *voice = demod_rt_find_voice(slot, note);
    if (!voice) {
        voice = demod_rt_alloc_voice(slot);
    }

    voice->active = 1;
    voice->note = (uint8_t)note;
    voice->velocity = (uint8_t)demod_clampf((float)velocity, 1.0f, 127.0f);
    voice->age = ++slot->voice_clock;

    const float freq = demod_rt_midi_to_freq(note);
    const float gain = demod_clampf((float)velocity / 127.0f, 0.0f, 1.0f);

    demod_rt_voice_set_zone(voice->freq_zone, freq);
    demod_rt_voice_set_zone(voice->gain_zone, gain);
    demod_rt_voice_set_zone(voice->gate_zone, 1.0f);
}

static inline void demod_rt_note_off(DemodRtEngine *eng, int slot_idx, int note)
{
    if (slot_idx < 0 || slot_idx >= DEMOD_RT_MAX_FX_SLOTS || note < 0 || note > 127) {
        return;
    }

    DemodFxSlot *slot = &eng->fx_slots[slot_idx];
    if (!slot->active || slot->kind != DEMOD_SLOT_INSTRUMENT) {
        return;
    }

    DemodInstrumentVoiceState *voice = demod_rt_find_voice(slot, note);
    if (!voice) {
        return;
    }

    demod_rt_voice_set_zone(voice->gate_zone, 0.0f);
    voice->active = 0;
}

static inline void demod_rt_all_notes_off(DemodRtEngine *eng, int slot_idx)
{
    if (slot_idx < 0 || slot_idx >= DEMOD_RT_MAX_FX_SLOTS) {
        return;
    }

    DemodFxSlot *slot = &eng->fx_slots[slot_idx];
    if (!slot->active || slot->kind != DEMOD_SLOT_INSTRUMENT) {
        return;
    }

    for (int i = 0; i < slot->voice_count; i++) {
        demod_rt_voice_set_zone(slot->voices[i].gate_zone, 0.0f);
        slot->voices[i].active = 0;
    }
}

/* ── Timing ─────────────────────────────────────────────────────── */

static inline uint64_t demod_clock_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC_RAW, &ts);
    return (uint64_t)ts.tv_sec * 1000000ULL + (uint64_t)ts.tv_nsec / 1000ULL;
}

/* ── JACK Callback (THE CRITICAL PATH) ─────────────────────────── */

/* Process commands from orchestrator (non-blocking, max 8 per callback) */
static void demod_rt_process_commands(DemodRtEngine *eng) {
    int processed = 0;

    while (processed < 8) { /* Cap to avoid starving audio */
        uint64_t avail = demod_spsc_available_read(eng->ipc.cmd_ring);
        if (avail == 0) break;

        /* Peek at command type (first float) */
        float cmd_type;
        if (demod_spsc_pop(eng->ipc.cmd_ring, &cmd_type, 1) == 0) break;

        if (cmd_type == DEMOD_CMD_FX_BYPASS) {
            /* FX_BYPASS: [cmd, slot, on/off] — 2 more floats */
            float args[2];
            if (demod_spsc_pop(eng->ipc.cmd_ring, args, 2) == 2) {
                int slot = (int)args[0];
                int on   = (int)args[1];
                if (slot >= 0 && slot < DEMOD_RT_MAX_FX_SLOTS) {
                    if (on)
                        eng->params_local.fx_bypass_mask |= (1u << (unsigned)slot);
                    else
                        eng->params_local.fx_bypass_mask &= ~(1u << (unsigned)slot);
                }
            }
        } else if (cmd_type == DEMOD_CMD_FX_PARAM) {
            /* FX_PARAM: [cmd, slot, param_idx, value] — 3 more floats */
            float args[3];
            if (demod_spsc_pop(eng->ipc.cmd_ring, args, 3) == 3) {
                int slot = (int)args[0];
                int pidx = (int)args[1];
                if (slot >= 0 && slot < DEMOD_RT_MAX_FX_SLOTS
                    && pidx >= 0 && pidx < DEMOD_RT_MAX_FX_PARAMS)
                    eng->params_local.fx_params[pidx] = args[2];
            }
        } else if (cmd_type == DEMOD_CMD_SET_GAIN) {
            /* SET_GAIN: [cmd, gain] — 1 more float */
            float gain;
            if (demod_spsc_pop(eng->ipc.cmd_ring, &gain, 1) == 1)
                eng->master_gain_target = gain < 0.0f ? 0.0f : gain;
        } else if (cmd_type == DEMOD_CMD_SLOT_GAIN) {
            /* SLOT_GAIN: [cmd, slot, gain] — 2 more floats */
            float args[2];
            if (demod_spsc_pop(eng->ipc.cmd_ring, args, 2) == 2) {
                int slot = (int)args[0];
                if (slot >= 0 && slot < DEMOD_RT_MAX_FX_SLOTS)
                    eng->fx_slots[slot].gain = demod_clampf(args[1], 0.0f, 1.5f);
            }
        } else if (cmd_type == DEMOD_CMD_SLOT_PAN) {
            /* SLOT_PAN: [cmd, slot, pan] — 2 more floats */
            float args[2];
            if (demod_spsc_pop(eng->ipc.cmd_ring, args, 2) == 2) {
                int slot = (int)args[0];
                if (slot >= 0 && slot < DEMOD_RT_MAX_FX_SLOTS)
                    eng->fx_slots[slot].pan = demod_clampf(args[1], -1.0f, 1.0f);
            }
        } else if (cmd_type == DEMOD_CMD_SLOT_MUTE) {
            /* SLOT_MUTE: [cmd, slot, on] — 2 more floats */
            float args[2];
            if (demod_spsc_pop(eng->ipc.cmd_ring, args, 2) == 2) {
                int slot = (int)args[0];
                if (slot >= 0 && slot < DEMOD_RT_MAX_FX_SLOTS)
                    eng->fx_slots[slot].mute = (args[1] >= 0.5f) ? 1 : 0;
            }
        } else if (cmd_type == DEMOD_CMD_SLOT_SOLO) {
            /* SLOT_SOLO: [cmd, slot, on] — 2 more floats */
            float args[2];
            if (demod_spsc_pop(eng->ipc.cmd_ring, args, 2) == 2) {
                int slot = (int)args[0];
                if (slot >= 0 && slot < DEMOD_RT_MAX_FX_SLOTS)
                    eng->fx_slots[slot].solo = (args[1] >= 0.5f) ? 1 : 0;
            }
        } else if (cmd_type == DEMOD_CMD_SET_BPM) {
            /* SET_BPM: [cmd, bpm] — 1 more float */
            float bpm;
            if (demod_spsc_pop(eng->ipc.cmd_ring, &bpm, 1) == 1) {
                eng->transport_bpm = bpm;
                eng->params_local.bpm = bpm;
            }
        } else if (cmd_type == DEMOD_CMD_NOTE_ON) {
            /* NOTE_ON: [cmd, slot, note, velocity] — 3 more floats */
            float args[3];
            if (demod_spsc_pop(eng->ipc.cmd_ring, args, 3) == 3) {
                demod_rt_note_on(eng, (int)args[0], (int)args[1], (int)args[2]);
            }
        } else if (cmd_type == DEMOD_CMD_NOTE_OFF) {
            /* NOTE_OFF: [cmd, slot, note] — 2 more floats */
            float args[2];
            if (demod_spsc_pop(eng->ipc.cmd_ring, args, 2) == 2) {
                demod_rt_note_off(eng, (int)args[0], (int)args[1]);
            }
        } else if (cmd_type == DEMOD_CMD_ALL_NOTES_OFF) {
            /* ALL_NOTES_OFF: [cmd, slot] — 1 more float */
            float slot;
            if (demod_spsc_pop(eng->ipc.cmd_ring, &slot, 1) == 1) {
                demod_rt_all_notes_off(eng, (int)slot);
            }
        } else if (cmd_type == DEMOD_CMD_SET_MIX_MODE) {
            /* SET_MIX_MODE: [cmd, mode] — 1 more float */
            float mode;
            if (demod_spsc_pop(eng->ipc.cmd_ring, &mode, 1) == 1) {
                int mix_mode = (int)mode;
                if (mix_mode >= DEMOD_MIX_SUM && mix_mode <= DEMOD_MIX_SYNTH_ONLY) {
                    eng->params_local.synth_mix_mode = (uint32_t)mix_mode;
                }
            }
        } else if (cmd_type == DEMOD_CMD_PING) {
            /* PING — reply on the shared event ring */
            demod_rt_push_event2(eng, DEMOD_EVT_PONG);
        } else if (cmd_type == DEMOD_CMD_SHUTDOWN) {
            /* SHUTDOWN — set flag, main loop checks it */
            eng->params_local.fx_bypass_mask = 0xFFFFFFFF; /* mute all */
        } else {
            /* Unknown command — drain remaining args (max 3) */
            float drain[3];
            demod_spsc_pop(eng->ipc.cmd_ring, drain, 3);
        }

        processed++;
    }
}

static int demod_rt_process(jack_nframes_t nframes, void *arg) {
    DemodRtEngine *eng = (DemodRtEngine *)arg;

    /* Timestamp for CPU load and heartbeat */
    clock_gettime(CLOCK_MONOTONIC_RAW, &eng->callback_start);

    /* Process commands from orchestrator (~50ns per command) */
    demod_rt_process_commands(eng);

    /* Read latest params from triple buffer via safe copy (~50ns for 256B) */
    uint64_t seq = demod_triple_buf_sequence(eng->ipc.params);
    if (seq != eng->params_seq) {
        demod_triple_buf_read_copy(eng->ipc.params, &eng->params_local);
        eng->params_seq = seq;
        eng->params_local.bpm = eng->transport_bpm;
    }

    /* Get JACK buffers */
    float *in_l  = (float *)jack_port_get_buffer(eng->port_in_l,  nframes);
    float *in_r  = (float *)jack_port_get_buffer(eng->port_in_r,  nframes);
    float *out_l = (float *)jack_port_get_buffer(eng->port_out_l, nframes);
    float *out_r = (float *)jack_port_get_buffer(eng->port_out_r, nframes);

    /* Copy input to output as starting point */
    memcpy(out_l, in_l, nframes * sizeof(float));
    memcpy(out_r, in_r, nframes * sizeof(float));

    /* Audio tap: write mono input to SPSC event ring for Ulation Engine.
     * Sum L+R to mono, push to ring. If ring is full, samples are dropped
     * (acceptable — pitch detection tolerates gaps). This push takes ~50ns
     * for 64 samples, well within budget. */
    {
        if (nframes <= DEMOD_RT_MAX_JACK_FRAMES) {
            for (jack_nframes_t i = 0; i < nframes; i++) {
                eng->tap_mono[i] = (in_l[i] + in_r[i]) * 0.5f;
            }
            demod_spsc_push(eng->ipc.evt_ring, eng->tap_mono, nframes);
        }
        /* Non-blocking: if Haskell is slow (GC pause), we just drop frames */
    }

    if (nframes <= DEMOD_RT_MAX_JACK_FRAMES) {
        memset(eng->synth_sum[0], 0, nframes * sizeof(float));
        memset(eng->synth_sum[1], 0, nframes * sizeof(float));
    }

    /* Run FX chain and render instrument buses. Instruments do not feed the
     * serial guitar path; they are summed in the mixer below. */
    const uint32_t bypass = eng->params_local.fx_bypass_mask;
    /* per-slot mixer: block-rate one-pole smoothing (~10 ms) toward each slot's
     * gain*pan*gate target; solo (when any instrument is soloed) mutes the other
     * instrument buses. Pan is an L/R balance (centre = unity, no 3 dB dip). */
    const float slot_coeff =
        1.0f - expf(-(float)nframes / (0.01f * (float)DEMOD_RT_SAMPLE_RATE));
    int any_solo = 0;
    for (int s = 0; s < eng->fx_slot_count; s++) {
        if (eng->fx_slots[s].kind == DEMOD_SLOT_INSTRUMENT && eng->fx_slots[s].solo) {
            any_solo = 1;
            break;
        }
    }
    /* reset per-slot meters so bypassed/inactive slots report silence this block */
    for (int s = 0; s < DEMOD_RT_MAX_FX_SLOTS; s++) {
        eng->fx_slots[s].meter_l = 0.0f;
        eng->fx_slots[s].meter_r = 0.0f;
    }
    for (int i = 0; i < eng->fx_slot_count; i++) {
        DemodFxSlot *slot = &eng->fx_slots[i];
        if (!slot->active || !slot->compute || !slot->dsp[0]
            || (bypass & (1u << (unsigned)i)))
            continue;

        demod_rt_apply_fx_params(&eng->params_local, slot);

        /* advance this slot's smoothed L/R channel gains toward its mixer target */
        {
            float gate = slot->mute ? 0.0f : 1.0f;
            if (slot->kind == DEMOD_SLOT_INSTRUMENT && any_solo && !slot->solo)
                gate = 0.0f;
            float tl = slot->gain * gate * (slot->pan > 0.0f ? (1.0f - slot->pan) : 1.0f);
            float tr = slot->gain * gate * (slot->pan < 0.0f ? (1.0f + slot->pan) : 1.0f);
            slot->gain_sm_l += slot_coeff * (tl - slot->gain_sm_l);
            slot->gain_sm_r += slot_coeff * (tr - slot->gain_sm_r);
        }

        if (slot->kind == DEMOD_SLOT_INSTRUMENT) {
            if (nframes > DEMOD_RT_MAX_JACK_FRAMES) {
                continue;
            }

            memset(slot->out_buf[0], 0, nframes * sizeof(float));
            memset(slot->out_buf[1], 0, nframes * sizeof(float));

            float *zero_in[DEMOD_RT_CHANNELS] = {
                eng->zero_buf[0],
                eng->zero_buf[1]
            };

            for (int voice = 0; voice < slot->voice_count; voice++) {
                if (slot->num_outputs == 1 && slot->dsp_count >= 2) {
                    for (int ch = 0; ch < DEMOD_RT_CHANNELS; ch++) {
                        float *outs[1] = { slot->voice_buf[ch] };
                        slot->compute(slot->voice_dsp[voice][ch], (int)nframes,
                                      zero_in, outs);
                        for (jack_nframes_t frame = 0; frame < nframes; frame++) {
                            slot->out_buf[ch][frame] += slot->voice_buf[ch][frame];
                        }
                    }
                } else if (slot->num_outputs == 2 && slot->dsp_count >= 1) {
                    float *outs[DEMOD_RT_CHANNELS] = {
                        slot->voice_buf[0],
                        slot->voice_buf[1]
                    };
                    slot->compute(slot->voice_dsp[voice][0], (int)nframes,
                                  zero_in, outs);
                    for (jack_nframes_t frame = 0; frame < nframes; frame++) {
                        slot->out_buf[0][frame] += slot->voice_buf[0][frame];
                        slot->out_buf[1][frame] += slot->voice_buf[1][frame];
                    }
                }
            }

            /* instrument bus → synth sum, scaled by the slot's smoothed fader/pan;
             * capture the post-fader L/R peak for the meters shm. */
            {
                float ml = 0.0f, mr = 0.0f;
                for (jack_nframes_t frame = 0; frame < nframes; frame++) {
                    float l = slot->gain_sm_l * slot->out_buf[0][frame];
                    float r = slot->gain_sm_r * slot->out_buf[1][frame];
                    eng->synth_sum[0][frame] += l;
                    eng->synth_sum[1][frame] += r;
                    float al = fabsf(l), ar = fabsf(r);
                    if (al > ml) ml = al;
                    if (ar > mr) mr = ar;
                }
                slot->meter_l = ml;
                slot->meter_r = mr;
            }
        } else if (slot->num_inputs == 1 && slot->num_outputs == 1 && slot->dsp_count >= 2) {
            float *mono_in[1];
            float *mono_out[1];

            mono_in[0] = out_l;
            mono_out[0] = out_l;
            slot->compute(slot->dsp[0], (int)nframes, mono_in, mono_out);

            mono_in[0] = out_r;
            mono_out[0] = out_r;
            slot->compute(slot->dsp[1], (int)nframes, mono_in, mono_out);
        } else if (slot->num_inputs == 2 && slot->num_outputs == 2) {
            float *ins[2]  = { out_l, out_r };
            float *outs[2] = { out_l, out_r };
            slot->compute(slot->dsp[0], (int)nframes, ins, outs);
        }

        /* FX insert: apply this slot's smoothed gain/pan as a post-node trim on the
         * serial bus (instruments were already scaled into the synth sum); capture
         * the post-node bus L/R peak as this slot's meter. */
        if (slot->kind != DEMOD_SLOT_INSTRUMENT) {
            float ml = 0.0f, mr = 0.0f;
            for (jack_nframes_t frame = 0; frame < nframes; frame++) {
                out_l[frame] *= slot->gain_sm_l;
                out_r[frame] *= slot->gain_sm_r;
                float al = fabsf(out_l[frame]), ar = fabsf(out_r[frame]);
                if (al > ml) ml = al;
                if (ar > mr) mr = ar;
            }
            slot->meter_l = ml;
            slot->meter_r = mr;
        }
    }

    if (nframes <= DEMOD_RT_MAX_JACK_FRAMES) {
        const uint32_t mix_mode = eng->params_local.synth_mix_mode;
        const float synth_gain = demod_clampf(eng->params_local.synth_gain, 0.0f, 1.0f);
        float fx_gain = 1.0f;
        float synth_mix_gain = synth_gain;

        if (mix_mode == DEMOD_MIX_DRY) {
            synth_mix_gain = 0.0f;
        } else if (mix_mode == DEMOD_MIX_SYNTH_ONLY) {
            fx_gain = 0.0f;
        }

        for (jack_nframes_t i = 0; i < nframes; i++) {
            out_l[i] = fx_gain * out_l[i] + synth_mix_gain * eng->synth_sum[0][i];
            out_r[i] = fx_gain * out_r[i] + synth_mix_gain * eng->synth_sum[1][i];
        }
    }

    /* Master: DC block + soft saturation + gain smoothing */
    const float target_gain = eng->master_gain_target;
    const float smoo_coeff = 1.0f - expf(-1.0f / (0.01f * (float)DEMOD_RT_SAMPLE_RATE));

    for (jack_nframes_t i = 0; i < nframes; i++) {
        float gain = demod_smoo(&eng->smooth_gain, target_gain, smoo_coeff);

        float l = out_l[i] * gain;
        float r = out_r[i] * gain;

        /* Padé tanh saturation (prevents clipping, adds warmth) */
        l = demod_pade_tanh(l);
        r = demod_pade_tanh(r);

        /* DC blocking */
        out_l[i] = demod_dc_block(&eng->dc_l, l);
        out_r[i] = demod_dc_block(&eng->dc_r, r);
    }

    /* Snake TX ring: push processed stereo output (summed to mono) for network transmission.
     * This is the spoke's contribution to the cluster. The ring feeds the quanta encoder
     * which compresses and sends via raw-L2 to the hub. Non-blocking: if ring is full,
     * samples are dropped (acceptable — network layer handles gaps via PLC). */
    if (eng->snake_tx_ring && nframes <= DEMOD_RT_MAX_JACK_FRAMES) {
        float snake_mono[DEMOD_RT_MAX_JACK_FRAMES];
        for (jack_nframes_t i = 0; i < nframes; i++) {
            snake_mono[i] = (out_l[i] + out_r[i]) * 0.5f;
        }
        snake_spsc_push(eng->snake_tx_ring, snake_mono, nframes);
    }

    /* Publish live readback (seqlock: odd = writing, even = stable). RT-safe — plain
     * stores between release fences; the UI maps read-only and retries on odd/changed
     * seq. Per-slot post-fader levels + authoritative mixer state + post-master scope. */
    if (eng->meters) {
        DemodRtMeters *mt = eng->meters;
        uint32_t sq = atomic_load_explicit(&mt->seq, memory_order_relaxed);
        atomic_store_explicit(&mt->seq, sq + 1u, memory_order_relaxed); /* odd */
        atomic_thread_fence(memory_order_release);

        uint32_t mute_mask = 0u, solo_mask = 0u;
        for (int i = 0; i < DEMOD_RT_METERS_SLOTS; i++) {
            DemodFxSlot *sl = &eng->fx_slots[i];
            float ml = sl->meter_l > 1.0f ? 1.0f : sl->meter_l;
            float mr = sl->meter_r > 1.0f ? 1.0f : sl->meter_r;
            mt->fx_levels_l[i] = ml;
            mt->fx_levels_r[i] = mr;
            mt->fx_levels[i]   = ml > mr ? ml : mr;
            mt->slot_gain[i]   = sl->gain;
            mt->slot_pan[i]    = sl->pan;
            if (sl->mute) mute_mask |= (1u << (unsigned)i);
            if (sl->solo) solo_mask |= (1u << (unsigned)i);
        }
        mt->slot_mute_mask = mute_mask;
        mt->slot_solo_mask = solo_mask;

        uint32_t sn = (uint32_t)nframes;
        if (sn > (uint32_t)DEMOD_RT_METERS_SCOPE_N) sn = (uint32_t)DEMOD_RT_METERS_SCOPE_N;
        for (uint32_t i = 0; i < sn; i++) {
            mt->scope_l[i] = out_l[i];
            mt->scope_r[i] = out_r[i];
        }
        mt->scope_n = sn;

        atomic_thread_fence(memory_order_release);
        atomic_store_explicit(&mt->seq, sq + 2u, memory_order_release); /* even */
    }

    /* Update heartbeat (single atomic store, ~5ns) */
    struct timespec end;
    clock_gettime(CLOCK_MONOTONIC_RAW, &end);
    uint64_t elapsed_ns = (uint64_t)(end.tv_sec - eng->callback_start.tv_sec) * 1000000000ULL
                        + (uint64_t)(end.tv_nsec - eng->callback_start.tv_nsec);
    eng->cpu_load = (float)elapsed_ns / (float)((uint64_t)nframes * 1000000000ULL / DEMOD_RT_SAMPLE_RATE);

    eng->callback_count++;
    atomic_store_explicit(&eng->ipc.heartbeat->rt_timestamp_us,
                          demod_clock_us(), memory_order_release);
    atomic_store_explicit(&eng->ipc.heartbeat->rt_callback_count,
                          eng->callback_count, memory_order_release);
    atomic_store_explicit(&eng->ipc.heartbeat->rt_alive, 1, memory_order_release);
    eng->ipc.heartbeat->rt_cpu_load = eng->cpu_load;

    return 0;
}

/* ── XRUN callback ──────────────────────────────────────────────── */

static int demod_rt_xrun(void *arg) {
    DemodRtEngine *eng = (DemodRtEngine *)arg;
    eng->xrun_count++;
    atomic_store_explicit(&eng->ipc.heartbeat->rt_xrun_count,
                          eng->xrun_count, memory_order_release);
    demod_rt_push_event3(eng, DEMOD_EVT_XRUN, (float)eng->xrun_count);
    return 0;
}

/* ── RT Setup (called in child before JACK activation) ──────────── */

static inline int demod_rt_pin_core(int core) {
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET((unsigned)core, &cpuset);
    return pthread_setaffinity_np(pthread_self(), sizeof(cpuset), &cpuset);
}

static inline int demod_rt_set_fifo(int priority) {
    struct sched_param sp = { .sched_priority = priority };
    return sched_setscheduler(0, SCHED_FIFO, &sp);
}

static inline int demod_rt_lock_memory(void) {
    /* Raise memlock limit first */
    struct rlimit rl = { .rlim_cur = RLIM_INFINITY, .rlim_max = RLIM_INFINITY };
    setrlimit(RLIMIT_MEMLOCK, &rl);
    return mlockall(MCL_CURRENT | MCL_FUTURE);
}

/* ── Engine Init ──────────────────────────────────────────────── */

static inline int demod_rt_engine_init(DemodRtEngine *eng, int rt_core) {
    memset(eng, 0, sizeof(*eng));
    eng->master_gain_target = 1.0f;
    eng->smooth_gain = 1.0f;
    eng->transport_bpm = 120.0f;
    eng->params_local.bpm = 120.0f;
    eng->params_local.synth_mix_mode = DEMOD_MIX_SUM;
    eng->params_local.synth_gain = 1.0f;
    /* per-slot mixer defaults: unity gain, centre pan, unmuted (memset zeroed them) */
    for (int s = 0; s < DEMOD_RT_MAX_FX_SLOTS; s++) {
        eng->fx_slots[s].gain = 1.0f;
        eng->fx_slots[s].pan = 0.0f;
        eng->fx_slots[s].gain_sm_l = 1.0f;
        eng->fx_slots[s].gain_sm_r = 1.0f;
    }

    /* RT setup */
    demod_rt_lock_memory();
    demod_rt_pin_core(rt_core);
    demod_rt_set_fifo(DEMOD_RT_SCHED_PRIORITY);

    /* Open shared memory IPC */
    int rc = demod_ipc_open(&eng->ipc, DEMOD_SPSC_DEFAULT_CAPACITY);
    if (rc < 0) {
        fprintf(stderr, "[demod-rt] failed to open IPC: %s\n", strerror(-rc));
        return rc;
    }

    /* Live readback shm — demod-rt is the sole writer. Non-fatal if it can't be
     * created (the UI just shows no meters); never block audio on it. */
    if (demod_shm_create(&eng->meters_region, DEMOD_SHM_RT_METERS,
                         sizeof(DemodRtMeters)) == 0) {
        eng->meters = (DemodRtMeters *)eng->meters_region.addr;
        memset(eng->meters, 0, sizeof(*eng->meters));
        for (int s = 0; s < DEMOD_RT_METERS_SLOTS; s++) {
            eng->meters->slot_gain[s] = 1.0f;
        }
    } else {
        eng->meters = NULL;
        fprintf(stderr, "[demod-rt] meters shm unavailable (UI meters disabled)\n");
    }

    /* Snake TX ring (spoke mode: demod-rt → quanta encoder → network).
     * Create the shared memory region for the quanta encoder to read from.
     * Non-fatal if it can't be created (standalone mode without snake network). */
    eng->snake_tx_ring = NULL;
    size_t snake_tx_size = snake_spsc_alloc_size(SNAKE_IPC_RING_CAP);
    if (demod_shm_create(&eng->snake_tx_region, SNAKE_IPC_TX_SHM_NAME, snake_tx_size) == 0) {
        eng->snake_tx_ring = snake_spsc_init(eng->snake_tx_region.addr, SNAKE_IPC_RING_CAP);
        if (!eng->snake_tx_ring) {
            demod_shm_close(&eng->snake_tx_region);
        } else {
            fprintf(stderr, "[demod-rt] snake TX ring created: %s (%zu samples)\n",
                    SNAKE_IPC_TX_SHM_NAME, SNAKE_IPC_RING_CAP);
        }
    } else {
        fprintf(stderr, "[demod-rt] snake TX ring unavailable (standalone mode)\n");
    }

    /* Connect to JACK */
    jack_status_t status;
    eng->jack_client = jack_client_open("demod-rt", JackNoStartServer, &status);
    if (!eng->jack_client) {
        fprintf(stderr, "[demod-rt] JACK open failed: 0x%x\n", (unsigned)status);
        return -1;
    }

    jack_set_process_callback(eng->jack_client, demod_rt_process, eng);
    jack_set_xrun_callback(eng->jack_client, demod_rt_xrun, eng);
    eng->jack_buffer_size = jack_get_buffer_size(eng->jack_client);

    /* Register ports */
    eng->port_in_l  = jack_port_register(eng->jack_client, "in_L",
                        JACK_DEFAULT_AUDIO_TYPE, JackPortIsInput, 0);
    eng->port_in_r  = jack_port_register(eng->jack_client, "in_R",
                        JACK_DEFAULT_AUDIO_TYPE, JackPortIsInput, 0);
    eng->port_out_l = jack_port_register(eng->jack_client, "out_L",
                        JACK_DEFAULT_AUDIO_TYPE, JackPortIsOutput, 0);
    eng->port_out_r = jack_port_register(eng->jack_client, "out_R",
                        JACK_DEFAULT_AUDIO_TYPE, JackPortIsOutput, 0);

    if (!eng->port_in_l || !eng->port_in_r || !eng->port_out_l || !eng->port_out_r) {
        fprintf(stderr, "[demod-rt] port registration failed\n");
        jack_client_close(eng->jack_client);
        return -1;
    }

    return 0;
}

static inline int demod_rt_engine_activate(DemodRtEngine *eng) {
    return jack_activate(eng->jack_client);
}

static inline void demod_rt_engine_shutdown(DemodRtEngine *eng) {
    if (eng->jack_client) {
        jack_deactivate(eng->jack_client);
        jack_client_close(eng->jack_client);
        eng->jack_client = NULL;
    }
    demod_shm_close(&eng->ipc.params_region);
    demod_shm_close(&eng->ipc.cmd_region);
    demod_shm_close(&eng->ipc.evt_region);
    demod_shm_close(&eng->ipc.hb_region);
    demod_shm_close(&eng->snake_tx_region);
}

#ifdef __cplusplus
}
#endif

#endif /* DEMOD_RT_AUDIO_H */
