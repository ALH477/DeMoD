// ─────────────────────────────────────────────────────────────────
//  demod_modal.dsp  —  DeMoD Modal Percussion
//  5-mode parallel resonator bank with real measured bar frequency
//  ratios for marimba and vibraphone.  Vibraphone mode adds an
//  Ornstein-Uhlenbeck-LFO fan-motor tremolo on the output gain.
//
//  Mode frequency ratios (measured, not ideal):
//    Marimba:   [1, 3.932, 9.723, 16.54, 25.57]
//    Vibraphone:[1, 4.08,  10.1,  19.6,  31.7 ]
//  Strike position: gain_m = sin((m+1)·π·x) · baseGain_m
//
//  Reference: Smith & Michon, "mesh2faust" (ICMC-17);
//             pm.modeFilter in physmodels.lib (GRAME/CCRMA)
//
//  DeMoD SKILL compliance:
//    • si.smoo on all continuous knob params
//    • OU LFO (sqrt(3·SR/(π·rate)) pre-scale) for fan tremolo
//    • fi.dcblocker on output
//
//  Compile: faust2jack -poly -nvoices 8 demod_modal.dsp
//  SPDX-License-Identifier: DCSL  ·  © 2025 DeMoD LLC  —  ALH477
// ─────────────────────────────────────────────────────────────────

declare name        "DeMoD Modal Perc";
declare author      "DeMoD LLC";
declare version     "1.0.0";
declare options     "[nvoices:8][midi:on]";

import("stdfaust.lib");
pm = library("physmodels.lib");

// ── DeMoD SKILL: Ornstein-Uhlenbeck LFO ─────────────────────────
// Pre-scale: σ = sqrt(3·SR/(π·rate)) → unit-variance output.
// rate: cut-off / corner frequency in Hz (same as "LFO rate").
ouLFO(rate) =
    no.noise
    : *(sqrt(3.0 * ma.SR / (ma.PI * max(0.01, rate))))
    : fi.lowpass(1, max(0.01, rate));

// ── MIDI voice parameters ─────────────────────────────────────────
freq = hslider("freq [unit:Hz] [hidden:1]", 440,  20, 20000, 0.01);
gain = hslider("gain [hidden:1]",            0.8,   0,     1, 0.01);
gate = button ("gate [hidden:1]");

// ── Instrument controls (all si.smoo'd before use) ────────────────
strikePos  = hslider("Strike Position [unit:%] [style:knob]", 30,  5, 95,  1) / 100 : si.smoo;
decay      = hslider("T60 [unit:s]    [style:knob]",         3.0, 0.3,  8, 0.01) : si.smoo;
fanSpeed   = hslider("Fan Speed [unit:Hz] [style:knob]",     1.5,  0,   7, 0.01) : si.smoo;
isVibes    = checkbox("Vibraphone");

// ── Mode tables ───────────────────────────────────────────────────
// Frequency ratios (relative to fundamental)
mbRatio(0) = 1.000; mbRatio(1) = 3.932; mbRatio(2) = 9.723;
mbRatio(3) = 16.54; mbRatio(4) = 25.57;
vbRatio(0) = 1.000; vbRatio(1) = 4.080; vbRatio(2) = 10.10;
vbRatio(3) = 19.60; vbRatio(4) = 31.70;

// T60 scale per mode (relative to global T60 knob)
modeT60(0) = 1.00; modeT60(1) = 0.55; modeT60(2) = 0.32;
modeT60(3) = 0.20; modeT60(4) = 0.12;

// Base amplitude per mode
modeAmp(0) = 1.00; modeAmp(1) = 0.50; modeAmp(2) = 0.25;
modeAmp(3) = 0.15; modeAmp(4) = 0.08;

// Strike-position–dependent gain: sin((m+1)·π·x)
// Produces the correct nodal pattern for bar vibration modes.
strikeGain(m, x) = sin((m + 1) * ma.PI * x) * modeAmp(m);

// ── Single-mode resonator ─────────────────────────────────────────
// pm.modeFilter(f0, t60, gain): bandpass resonator with specified
// resonant frequency, decay time, and peak gain.  Excitation is
// the input signal.
oneMode(m, f0, t60base, pos) =
    pm.modeFilter(
        min(f0 * modeRatio(m), ma.SR * 0.45),  // clamp below Nyquist
        t60base * modeT60(m),
        strikeGain(m, pos)
    )
with {
    modeRatio(m) = isVibes * vbRatio(m) + (1 - isVibes) * mbRatio(m);
};

// ── 5-mode resonator bank ─────────────────────────────────────────
// All modes share the same impulse excitation.
modalBank(f0, t60base, pos) =
    _ <: par(m, 5, oneMode(m, f0, t60base, pos)) :> / (5.0);

// ── Percussive impulse from gate ──────────────────────────────────
strikeImpulse(g) = g : ba.impulsify : fi.highpass(1, 40);

// ── Vibraphone fan-motor tremolo ──────────────────────────────────
// OU LFO drives amplitude modulation on the output.
// AM range: 0.78 ± 0.20  →  [0.58, 0.98]  (stays positive).
fanTremolo(speed, sig) =
    sig * (0.78 + ouLFO(speed) * 0.20 * isVibes);

// ── Complete modal voice ──────────────────────────────────────────
modalVoice(f, g, gt, pos, t60base) =
    strikeImpulse(gt)
    : modalBank(f, t60base, pos)
    : fanTremolo(fanSpeed)
    : *(g * 0.65)
    : fi.dcblocker;   // DeMoD SKILL: DC block on output (missing ';' broke the def)

process = modalVoice(freq, gain, gate, strikePos, decay) <: (_, _);
