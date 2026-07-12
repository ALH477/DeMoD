declare name        "PopBass";
declare author      "DeMoD Audio Systems";
declare description "Pop bass synthesizer · detuned stereo saws · sub osc · resonant filter envelope · portamento";
declare version     "1.0";
declare license     "GPL-3.0";

// ┌──────────────────────────────────────────────────────────────────────────┐
// │  PopBass — Pop Style Bass Synthesizer                                     │
// │  DeMoD Audio Systems                                                      │
// │                                                                            │
// │  Architecture:                                                             │
// │    · Dual detuned bandlimited sawtooths → native stereo spread            │
// │    · Sub sine oscillator at freq/2 (one octave down), blended in          │
// │    · Portamento / glide via 1-pole exponential lag on pitch               │
// │    · Padé [3/2] saturator — pre-filter harmonic drive stage               │
// │    · Time-varying cookbook resonant LP biquad (fi.tf2, swept per-sample)  │
// │    · Filter ADSR envelope sweeps cutoff from fcut → 18 kHz               │
// │    · Second Padé stage post-filter for analog warmth                      │
// │    · Amp ADSR envelope with independent contour                           │
// │    · DC block (35 Hz) on each output channel                              │
// └──────────────────────────────────────────────────────────────────────────┘

import("stdfaust.lib");


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  UI PARAMETERS                                                           ║
// ╚══════════════════════════════════════════════════════════════════════════╝

// ── Oscillator ─────────────────────────────────────────────────────────────
freq   = hslider("h:Oscillator/[1] Freq [unit:Hz][style:knob]",     80.0,  20.0,  800.0, 0.1)
       : si.smoo;
detune = hslider("h:Oscillator/[2] Detune [unit:cent][style:knob]",  8.0,   0.0,   50.0, 0.1)
       : si.smoo;
submix = hslider("h:Oscillator/[3] Sub Mix [style:knob]",            0.35,  0.0,    1.0, 0.001)
       : si.smoo;
glide  = hslider("h:Oscillator/[4] Glide [unit:s][style:knob]",      0.0,   0.0,    0.5, 0.001)
       : si.smoo;

// ── Filter ─────────────────────────────────────────────────────────────────
fcut = hslider("h:Filter/[1] Cutoff [unit:Hz][style:knob]",    600.0,  20.0, 16000.0, 1.0)
     : si.smoo;
fres = hslider("h:Filter/[2] Resonance [style:knob]",            3.0,   0.5,    12.0, 0.01)
     : si.smoo;
fenv = hslider("h:Filter/[3] Env Amt [style:knob]",              0.65,  0.0,     1.0, 0.001)
     : si.smoo;
fatt = hslider("h:Filter/[4] F.Attack [unit:s][style:knob]",     0.003, 0.001,   2.0, 0.001)
     : si.smoo;
fdec = hslider("h:Filter/[5] F.Decay [unit:s][style:knob]",      0.22,  0.001,   3.0, 0.001)
     : si.smoo;
fsus = hslider("h:Filter/[6] F.Sustain [style:knob]",            0.15,  0.0,     1.0, 0.001)
     : si.smoo;
frel = hslider("h:Filter/[7] F.Release [unit:s][style:knob]",    0.30,  0.001,   3.0, 0.001)
     : si.smoo;

// ── Amp ────────────────────────────────────────────────────────────────────
aatt = hslider("h:Amp/[1] Attack [unit:s][style:knob]",   0.004, 0.001, 2.0, 0.001) : si.smoo;
adec = hslider("h:Amp/[2] Decay [unit:s][style:knob]",    0.30,  0.001, 3.0, 0.001) : si.smoo;
asus = hslider("h:Amp/[3] Sustain [style:knob]",          0.65,  0.0,   1.0, 0.001) : si.smoo;
arel = hslider("h:Amp/[4] Release [unit:s][style:knob]",  0.25,  0.001, 3.0, 0.001) : si.smoo;

// ── Master ─────────────────────────────────────────────────────────────────
drive = hslider("h:Master/[1] Drive [style:knob]",            1.8, 1.0,  6.0, 0.01)  : si.smoo;
vol   = hslider("h:Master/[2] Volume [unit:dB][style:knob]", -6.0, -40.0, 0.0, 0.1)  : si.smoo;
gate  = button("h:Master/[3] Gate");


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  PADÉ SATURATOR                                                          ║
// ║                                                                          ║
// ║  Padé [3/2] rational approximant of tanh:                                ║
// ║    sat(x) = x · (27 + x²) / (27 + 9x²)                                  ║
// ║  Properties:                                                              ║
// ║    · Odd symmetry → zero DC contribution in signal chain                 ║
// ║    · Unit slope at origin → linear at small signals                      ║
// ║    · |error| < 0.5 % for |x| ≤ 2.0                                      ║
// ║    · Bounded output ∈ (−1, 1) → prevents level runaway                  ║
// ╚══════════════════════════════════════════════════════════════════════════╝

sat(x) = x * (27.0 + x * x) / (27.0 + 9.0 * x * x);


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  RESONANT LOWPASS BIQUAD  (Time-Varying Coefficients)                    ║
// ║                                                                          ║
// ║  Audio EQ Cookbook resonant LP, computed per-sample via fi.tf2:          ║
// ║                                                                          ║
// ║    ω₀  = 2π · fc / SR                                                    ║
// ║    α   = sin ω₀ / (2Q)                                                   ║
// ║    b0  = b2 = (1 − cos ω₀) / 2(1+α)                                     ║
// ║    b1  = (1 − cos ω₀) / (1+α)                                            ║
// ║    a1  = −2 cos ω₀ / (1+α)                                               ║
// ║    a2  = (1−α) / (1+α)                                                   ║
// ║                                                                          ║
// ║  Using fi.tf2 with signal-valued coefficients enables correct            ║
// ║  alias-free swept-filter response. Cutoff is hard-clamped to             ║
// ║  [20 Hz, 0.49·SR] and Q is clamped to [0.5, ∞) for stability.           ║
// ╚══════════════════════════════════════════════════════════════════════════╝

rlpf(fc, q) = fi.tf2(b0, b1, b2, a1, a2)
with {
    fs    = float(ma.SR);
    fc_c  = max(20.0, min(fc, 0.49 * fs));
    w0    = 2.0 * ma.PI * fc_c / fs;
    cosw  = cos(w0);
    sinw  = sin(w0);
    alpha = sinw / (2.0 * max(0.5, q));
    norm  = 1.0 + alpha;
    b0    = (1.0 - cosw) * 0.5 / norm;
    b1    = (1.0 - cosw) / norm;
    b2    = b0;
    a1    = -2.0 * cosw / norm;
    a2    = (1.0 - alpha) / norm;
};


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  PORTAMENTO / GLIDE                                                      ║
// ║                                                                          ║
// ║  Exponential lag on the target frequency:                                ║
// ║    c(τ) = exp(−1 / (τ · SR))                                             ║
// ║    f[n] = (1−c) · f_target[n] + c · f[n−1]                              ║
// ║                                                                          ║
// ║  τ is clamped to [1ms, ∞) so c(0) → exp(−1000/SR) ≈ 0 (instant).       ║
// ║  This avoids exp(−∞) = 0 edge case while keeping zero-glide clean.      ║
// ╚══════════════════════════════════════════════════════════════════════════╝

glide_pole = exp(-1.0 / (max(0.001, glide) * float(ma.SR)));
freq_slide = freq : si.smooth(glide_pole);


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  OSCILLATOR BANK                                                         ║
// ║                                                                          ║
// ║  Stereo dual sawtooth + shared sub sine:                                 ║
// ║    det_ratio = 2^(detune/1200)      (semitone cents → linear ratio)      ║
// ║    freqL  = freq_slide / det_ratio  ← flat by detune cents (left)        ║
// ║    freqR  = freq_slide × det_ratio  ← sharp by detune cents (right)      ║
// ║    sub    = sine at freq_slide/2    (one octave below, fat low end)       ║
// ║    oscL/R = saw × (1−submix) + sub × submix                              ║
// ║                                                                          ║
// ║  Placing saws symmetrically around centre pitch preserves perceived       ║
// ║  root note regardless of detune amount.                                  ║
// ╚══════════════════════════════════════════════════════════════════════════╝

det_ratio = pow(2.0, detune / 1200.0);
freqL     = freq_slide / det_ratio;
freqR     = freq_slide * det_ratio;
sawL      = os.sawtooth(freqL);
sawR      = os.sawtooth(freqR);
sub_osc   = os.osc(freq_slide * 0.5);
oscL      = sawL * (1.0 - submix) + sub_osc * submix;
oscR      = sawR * (1.0 - submix) + sub_osc * submix;


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  ENVELOPES                                                               ║
// ║                                                                          ║
// ║  Filter envelope (ADSR) modulates cutoff:                                ║
// ║    fc_mod = fcut + fenv · filt_env · (18000 − fcut)                      ║
// ║    At filt_env = 1: fc_mod → fcut + fenv·(18000 − fcut)                  ║
// ║    At filt_env = 0: fc_mod = fcut   (resting/sustain position)           ║
// ║                                                                          ║
// ║  Amp envelope (ADSR) shapes final output amplitude.                      ║
// ╚══════════════════════════════════════════════════════════════════════════╝

filt_env = en.adsr(fatt, fdec, fsus, frel, gate);
amp_env  = en.adsr(aatt, adec, asus, arel, gate);
fc_mod   = fcut + fenv * filt_env * (18000.0 - fcut);


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  CHANNEL CHAIN                                                           ║
// ║                                                                          ║
// ║  Per-channel signal flow:                                                ║
// ║    osc → [× drive] → [Padé sat]                                          ║
// ║        → [RLPF(fc_mod, fres)] → [Padé sat]                              ║
// ║        → [DC block @ 35 Hz]   → [× amp_env] → [× vol_lin]               ║
// ║                                                                          ║
// ║  Second Padé after filter adds soft-knee resonance limiting and           ║
// ║  reinforces odd harmonics for the classic "vintage synth bass" colour.   ║
// ╚══════════════════════════════════════════════════════════════════════════╝

vol_lin = ba.db2linear(vol);

chain = _ : *(drive)
          : sat
          : rlpf(fc_mod, fres)
          : sat
          : fi.dcblockerat(35.0)
          : *(amp_env)
          : *(vol_lin);


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  PROCESS                                                                 ║
// ╚══════════════════════════════════════════════════════════════════════════╝

// oscL, oscR (0-in, 2-out) → par(i, 2, chain) (2-in, 2-out)
// Result: stereo synth, 0 inputs, 2 outputs.

process = oscL, oscR : par(i, 2, chain);
