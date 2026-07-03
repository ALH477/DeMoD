// SPDX-License-Identifier: MPL-2.0
/*
 * local_dsp_shim.cpp — C-ABI wrapper around the demodoom_core C++ engine.
 *
 * Built only when LOCAL_DSP=1. Expects the demod-dsp-gui source tree on the
 * include path (DEMODOOM_SRC). It owns one FXChainProcessor + AudioEngine +
 * ChiptuneSynth and routes the same serial-FX + chiptune callback demodoom's
 * Engine uses, so a desktop run gets the real DSP with live audio.
 *
 * NOTE: signatures here mirror demod-dsp-gui src/audio/{fx_chain,audio_engine,
 * chiptune}.hpp as surveyed; reconcile against the actual headers at build time.
 *
 * Copyright (c) 2026 DeMoD LLC. Licensed under the Mozilla Public License, v. 2.0 (see LICENSE).
 */
#include "demod/local_dsp.h"

#include <atomic>
#include <cstring>
#include <string>
#include <vector>

#include "audio/fx_chain.hpp"
#include "audio/audio_engine.hpp"
#include "audio/chiptune.hpp"

using demod::audio::FXChainProcessor;
using demod::audio::AudioEngine;
using demod::audio::ChiptuneSynth;

namespace {

struct LocalDSP {
    FXChainProcessor fx;
    AudioEngine      audio;
    ChiptuneSynth    chip;
    std::atomic<bool> up{false};
    std::string       name_scratch;   // backing store for slot/param name returns
};

LocalDSP *g = nullptr;

} // namespace

extern "C" {

int demod_local_init(int sample_rate, int block_size) {
    if (g) return 1;
    g = new LocalDSP();
    g->fx.set_sample_rate(sample_rate);
    g->chip.init(sample_rate);
    g->chip.set_enabled(false);   // no menu music in the GUI port by default

    g->audio.set_sample_rate(sample_rate);
    g->audio.set_block_size(block_size);
    g->audio.set_channels(2, 2);
    g->audio.set_callback([](const float *const *in, float *const *out,
                             int n_ch, int n_frames) {
        float *buf = out[0];
        if (in) g->fx.process_serial(in, buf, n_ch, n_frames);
        else {
            std::memset(buf, 0, size_t(n_frames) * size_t(n_ch) * sizeof(float));
            g->fx.process_serial(buf, n_ch, n_frames);
        }
        g->chip.process(buf, n_ch, n_frames);
    });

    if (!g->audio.start("demod-dsp-studio")) { delete g; g = nullptr; return 0; }
    g->up.store(true);
    return 1;
}

void demod_local_shutdown(void) {
    if (!g) return;
    g->audio.stop();
    delete g; g = nullptr;
}

int demod_local_slot_count(void) { return g ? FXChainProcessor::MAX_FX_SLOTS : 0; }

int demod_local_slot_loaded(int slot)   { return g ? (g->fx.slot_loaded(slot) ? 1 : 0) : 0; }
int demod_local_slot_bypassed(int slot) { return g ? (g->fx.slot_bypassed(slot) ? 1 : 0) : 1; }
float demod_local_slot_wet(int slot)    { return g ? g->fx.slot_wet_mix(slot) : 0.f; }
int demod_local_num_params(int slot)    { return g ? g->fx.slot_num_params(slot) : 0; }

const char *demod_local_slot_name(int slot) {
    if (!g) return "";
    g->name_scratch = g->fx.slot_dsp_path(slot);
    // strip dir + extension to a short display name
    auto s = g->name_scratch;
    auto sl = s.find_last_of('/'); if (sl != std::string::npos) s = s.substr(sl + 1);
    auto dot = s.find_last_of('.'); if (dot != std::string::npos) s = s.substr(0, dot);
    g->name_scratch = s;
    return g->name_scratch.c_str();
}

const char *demod_local_param_label(int slot, int idx) {
    if (!g) return "";
    const auto &ps = g->fx.slot_params(slot);
    if (idx < 0 || idx >= (int)ps.size()) return "";
    g->name_scratch = ps[idx].label;
    return g->name_scratch.c_str();
}
float demod_local_param_min(int slot, int idx)  { if (!g) return 0; const auto &ps=g->fx.slot_params(slot); return (idx>=0&&idx<(int)ps.size())?ps[idx].min:0; }
float demod_local_param_max(int slot, int idx)  { if (!g) return 1; const auto &ps=g->fx.slot_params(slot); return (idx>=0&&idx<(int)ps.size())?ps[idx].max:1; }
float demod_local_param_init(int slot, int idx) { if (!g) return 0; const auto &ps=g->fx.slot_params(slot); return (idx>=0&&idx<(int)ps.size())?ps[idx].init:0; }
float demod_local_param_step(int slot, int idx) { if (!g) return 0.01f; const auto &ps=g->fx.slot_params(slot); return (idx>=0&&idx<(int)ps.size())?ps[idx].step:0.01f; }

float demod_local_get_param(int slot, int idx)        { return g ? g->fx.get_slot_param(slot, idx) : 0.f; }
void  demod_local_set_param(int slot, int idx, float v){ if (g) g->fx.set_slot_param(slot, idx, v); }
void  demod_local_set_bypass(int slot, int on)        { if (g) g->fx.set_slot_bypassed(slot, on != 0); }
void  demod_local_set_wet(int slot, float wet)        { if (g) g->fx.set_slot_wet_mix(slot, wet); }
int   demod_local_load_slot(int slot, const char *p)  { return g ? (g->fx.load_slot(slot, p ? p : "") ? 1 : 0) : 0; }
void  demod_local_unload_slot(int slot)               { if (g) g->fx.unload_slot(slot); }
void  demod_local_swap(int a, int b)                  { if (g) g->fx.swap_slots(a, b); }

int demod_local_scope(float *L, float *R, int max) {
    if (!g) return 0;
    int n = AudioEngine::SCOPE_BUF_SIZE;
    if (n > max) n = max;
    int pos = g->audio.scope_write_pos.load();
    for (int i = 0; i < n; i++) {
        int idx = (pos - n + i + AudioEngine::SCOPE_BUF_SIZE) % AudioEngine::SCOPE_BUF_SIZE;
        if (L) L[i] = g->audio.scope_buffer[idx];
        if (R) R[i] = g->audio.scope_buffer_R[idx];
    }
    return n;
}
float demod_local_cpu(void)  { return g ? g->audio.cpu_load() : 0.f; }
int   demod_local_xruns(void){ return g ? g->audio.xruns() : 0; }

} // extern "C"
