// ─────────────────────────────────────────────────────────────────
//  demod_ks.dsp  —  DeMoD Karplus-Strong Plucked String
//  Extended Karplus-Strong (EKS) with pick-position comb filter.
//  Reference: Smith III, "Making Virtual Electric Guitars Using Faust"
//
//  DeMoD SKILL compliance:
//    • si.smoo on all continuous knob params (upstream of conversions)
//    • Padé [3,2] rational-tanh on the body saturation stage
//    • fi.dcblocker on output
//    • OU LFO for modulation (not used in KS but available via import)
//
//  Compile (poly JACK):   faust2jack -poly -nvoices 16 demod_ks.dsp
//  Compile (ALSA):        faust2alsa -poly -nvoices 16 demod_ks.dsp
//  Compile (C++):         faust -lang cpp -o demod_ks.cpp demod_ks.dsp
//
//  SPDX-License-Identifier: DCSL
//  © 2025 DeMoD LLC  —  ALH477
// ─────────────────────────────────────────────────────────────────

declare name        "DeMoD KS String";
declare author      "DeMoD LLC";
declare version     "1.0.0";
declare options     "[nvoices:16][midi:on]";

import("stdfaust.lib");

// ── DeMoD SKILL: Padé [3,2] rational-tanh ────────────────────────
// Accurate for |x| ≤ 3; apply after drive-scaled input.
// Use with pre-gain ≤ 3 to stay in the accurate region.
pade32(x) = x*(27.0 + x*x) / (27.0 + 9.0*x*x);

// ── MIDI voice parameters (auto-routed by [nvoices:N][midi:on]) ───
freq  = hslider("freq [unit:Hz] [hidden:1]",  440,  20, 20000, 0.01);
gain  = hslider("gain [hidden:1]",             0.8,   0,     1, 0.01);
gate  = button ("gate [hidden:1]");

// ── Instrument controls ───────────────────────────────────────────
// si.smoo applied here, before any nonlinear conversion.
pickPos  = hslider("Pick Position [unit:%] [style:knob]",  33,   5,  95, 1)   / 100 : si.smoo;
damping  = hslider("Damping       [style:knob]",         0.995, 0.88, 0.9998, 0.0001) : si.smoo;
bodyAmt  = hslider("Body          [style:knob]",           0.5,   0,     1, 0.01)    : si.smoo;
driveAmt = hslider("Drive         [style:knob]",           0.0,   0,     1, 0.01)    : si.smoo;
bassMode = checkbox("Bass Mode");

// ── Internal constants ────────────────────────────────────────────
maxLen  = 8192;       // max delay-line length (samples); covers ~5.8 Hz @ 48 kHz
D(f)    = ma.SR / max(20, f) - 1.0;  // delay in samples (–1 for the loop-filter 1-sample delay)

// ── Pick-position FIR comb filter ────────────────────────────────
// H(z) = 1 – z^(–floor(β·N + 0.5))
// Creates zeros at harmonics n·f0/β, shaping the initial excitation.
// single input feeds both legs (the bare `_ - _@K` was a 2-input block).
pickComb(D, beta) = _ <: _ - 0.45 * (_ @ int(D * min(0.95, max(0.05, beta)) + 0.5));

// ── KS two-point average loop filter ─────────────────────────────
// H(z) = damp · (1 + z^–1) / 2  — one sample of additional delay included.
loopFilt(damp) = _ <: (_, _') :> *(0.5 * damp);

// ── Noise excitation burst ────────────────────────────────────────
// Bandlimited by a lowpass at 1.5× the fundamental, gated by a short AR envelope.
noiseBurst(f, g) =
    no.noise
    : fi.lowpass(1, min(f * 1.5, 8000))
    : *(en.ar(0.001, 0.020, g));

// ── Body resonance (Padé-saturated peaking EQ) ───────────────────
// Models a physical resonance at roughly midi-dependent frequency.
// Drive into Padé32 saturator for subtle harmonic content.
bodyFilter(f, amt, drive) =
    _ : (fi.peak_eq(peakDb, peakFreq, bw) : pade32Scaled)
with {
    peakFreq  = min(f * 2.0, 4000);
    peakDb    = amt * 10.0;
    bw        = peakFreq / 2.5;
    pade32Scaled(x) = pade32(x * (1 + drive * 2)) / (1 + drive * 0.5);
};

// ── Complete KS voice ─────────────────────────────────────────────
ksVoice(f, g, gt, pick, damp, body, drive) =
    noiseBurst(actualFreq, gt)
    : pickComb(D(actualFreq), pick)                          // EKS excitation shaping
    : ( + : de.fdelay4(maxLen, D(actualFreq)) )             // KS delay loop
      ~ loopFilt(damp)                                       // two-point average feedback
    : bodyFilter(actualFreq, body, drive)                    // body resonance + saturation
    : *(g)
    : fi.dcblocker                                           // DeMoD SKILL: DC block on output
with {
    actualFreq = f * select2(bassMode, 1.0, 0.5); // Faust has no ?: ternary
};

process = ksVoice(freq, gain, gate, pickPos, damping, bodyAmt, driveAmt)
       <: (_, _);  // stereo output
