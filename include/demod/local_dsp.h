// SPDX-License-Identifier: MPL-2.0
/*
 * local_dsp.h — C ABI over the demodoom_core C++ DSP engine.
 *
 * Implemented by src/dsp/local_dsp_shim.cpp, which wraps demodoom's
 * FXChainProcessor + AudioEngine + ChiptuneSynth. Compiled into demod-ui only
 * when built with LOCAL_DSP=1 (it pulls in PipeWire and optionally libfaust and
 * the demod-dsp-gui source tree). When absent, dm.local_available() is false
 * and the GUI falls back to the orchestrator/stub backend.
 *
 * Slots and param indices here are 0-based (the demodoom convention); the Lua
 * layer presents 1-based slots.
 *
 * Copyright (c) 2026 DeMoD LLC. Licensed under the Mozilla Public License, v. 2.0 (see LICENSE).
 */
#ifndef DEMOD_LOCAL_DSP_H
#define DEMOD_LOCAL_DSP_H

#ifdef __cplusplus
extern "C" {
#endif

int   demod_local_init(int sample_rate, int block_size);
void  demod_local_shutdown(void);

int   demod_local_slot_count(void);
int   demod_local_slot_loaded(int slot);
const char *demod_local_slot_name(int slot);
int   demod_local_slot_bypassed(int slot);
float demod_local_slot_wet(int slot);
int   demod_local_num_params(int slot);

const char *demod_local_param_label(int slot, int idx);
float demod_local_param_min(int slot, int idx);
float demod_local_param_max(int slot, int idx);
float demod_local_param_init(int slot, int idx);
float demod_local_param_step(int slot, int idx);
float demod_local_get_param(int slot, int idx);
void  demod_local_set_param(int slot, int idx, float value);

void  demod_local_set_bypass(int slot, int on);
void  demod_local_set_wet(int slot, float wet);
int   demod_local_load_slot(int slot, const char *path);
void  demod_local_unload_slot(int slot);
void  demod_local_swap(int a, int b);

/* fill L/R with up to max samples of the latest scope; returns count written */
int   demod_local_scope(float *L, float *R, int max);
float demod_local_cpu(void);
int   demod_local_xruns(void);

#ifdef __cplusplus
}
#endif
#endif /* DEMOD_LOCAL_DSP_H */
