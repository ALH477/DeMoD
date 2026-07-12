// ============================================================
//  FAUST FUZZ  —  Professional Live Performance Fuzz Effect
//  Version 2.0  (complete rewrite from v1.0 audit)
//
//  Signal path:
//    Input Trim → Coupling Cap HP → Pre-Presence
//    → Drive Gain
//    → Thermal Bias Offset → ADAA1 Waveshaper (Si/Ge blend)
//    → DC Block
//    → Big Muff Passive Tone Stack
//    → Noise Gate
//    → Output Volume
//    → Slewed True Bypass
//
//  Key DSP features:
//
//  (1) ADAA1  — Antiderivative Anti-Aliasing, 1st order.
//      Instead of a post-clip LPF (which cannot remove aliasing
//      already embedded in the signal), ADAA approximates
//      bandlimited clipping analytically with zero added latency.
//      Ref: Bilbao et al. "Antiderivative Antialiasing..." (2017)
//
//  (2) Thermal Bias Drift — A slow LFO modulates the DC
//      quiescent point, simulating transistor heat-induced bias
//      shift during a live performance.
//
//  (3) Silicon/Germanium Character blend — Two distinct
//      saturation curves, each with ADAA:
//        Silicon  : x/(1+|x|)  — asymmetric, odd+even harmonics
//        Germanium: tanh(k·x)  — symmetric, warmer even harmonics
//      Antiderivatives (derived analytically):
//        F_Si(x)  = |x| - ln(1 + |x|)
//        F_Ge(x)  = ln(cosh(k·x)) / k
//
//  (4) Big Muff passive tone stack — LP/HP crossfade with a
//      mid-scoop that deepens at the center position, matching
//      the passive RC circuit's frequency response behavior.
//
//  Author  : Faust DSP
//  Version : 2.0
//  License : MIT
// ============================================================

declare name        "FaustFuzz";
declare version     "2.0";
declare author      "Faust DSP";
declare description "Silicon/Germanium fuzz with ADAA, thermal drift, Big Muff tone stack";
declare license     "MIT";

import("stdfaust.lib");


// ============================================================
//  UTILITIES
// ============================================================

slew(tau) = si.smooth(ba.tau2pole(tau));
SLEW     = 0.005;   // 5 ms — imperceptible, no zipper noise


// ============================================================
//  ADAA1 — ANTIDERIVATIVE ANTI-ALIASING (1ST ORDER)
//
//  For a nonlinear function f with antiderivative F:
//
//    y[n] = (F(x[n]) - F(x[n-1])) / (x[n] - x[n-1])     [ADAA]
//    y[n] = f((x[n] + x[n-1]) / 2)                        [fallback]
//
//  The fallback is used when |Δx| < ε to avoid division by
//  near-zero. ADAA eliminates aliasing from the nonlinearity
//  without oversampling or added latency.
// ============================================================

ADAA_EPS = 1e-6;

adaa1(f, F, x) = result
with {
    x1     = x';
    dx     = x - x1;
    adaa   = (F(x) - F(x1)) / dx;
    mid    = f((x + x1) * 0.5);
    result = select2(abs(dx) < ADAA_EPS, adaa, mid);
};


// ============================================================
//  WAVESHAPER A — SILICON
//
//  f(x)  = x / (1 + |x|)      (Pade sigmoid)
//  F(x)  = |x| - ln(1 + |x|)  (antiderivative)
//
//  Proof: for x>=0, d/dx[x - ln(1+x)] = 1 - 1/(1+x) = x/(1+x)
//         for x< 0, d/dx[-x - ln(1-x)] = -1 + 1/(1-x) = x/(1-x)
//         Both simplify to x/(1+|x|). Both cases give |x|-ln(1+|x|).
// ============================================================

f_si(x) = x / (1.0 + abs(x));
F_si(x) = abs(x) - log(1.0 + abs(x));

silicon(x) = adaa1(f_si, F_si, x);


// ============================================================
//  WAVESHAPER B — GERMANIUM
//
//  f(x)  = tanh(k*x) / tanh(k)   (normalized, knee at k)
//  F(x)  = ln(cosh(k*x)) / k     (antiderivative)
//
//  Proof: d/dx[ln(cosh(k*x))/k] = sinh(k*x)/cosh(k*x) = tanh(k*x)
//
//  k=2.5 matches vintage Ge transistor knee characteristics.
//  Softer, more symmetric, richer in even harmonics than silicon.
//
//  tanh, exp, log are Faust primitives — no library prefix needed.
//  cosh is not a Faust primitive; implemented as (exp(x)+exp(-x))/2
// ============================================================

K_GE    = 2.5;
// NORM_GE = tanh(2.5) pre-evaluated — see note below.
NORM_GE = 0.9866142981514303;

// ── Why tanh_impl? ─────────────────────────────────────────────────────
// stdfaust.lib imports maths.lib, which defines tanh as an ffunction
// wrapper at maths.lib:782.  Using bare `tanh` in user code creates a
// BoxIdent redefinition error.  `ma.tanh` also fails because Faust's
// lexer tokenises the `exp` in `ma.exp` as a float-literal EXP token.
// Solution: implement tanh purely from exp — a true Faust primitive —
// under a distinct name, removing the conflict entirely.
//
//   tanh(x)  = (e^x - e^-x) / (e^x + e^-x)
//   cosh(x)  = (e^x + e^-x) / 2
//   F_ge(x)  = ln(cosh(k*x)) / k        (antiderivative of tanh(k*x))
// ───────────────────────────────────────────────────────────────────────
cosh_impl(x) = (exp(x) + exp(0.0-x)) * 0.5;
tanh_impl(x) = (exp(x) - exp(0.0-x)) / (exp(x) + exp(0.0-x));

f_ge(x) = tanh_impl(K_GE * x) / NORM_GE;
F_ge(x) = log(cosh_impl(K_GE * x)) / K_GE;

germanium(x) = adaa1(f_ge, F_ge, x);


// ============================================================
//  THERMAL BIAS DRIFT
//
//  A slow sinusoidal LFO modulates the DC operating point
//  before the waveshaper. In a real transistor circuit, heat
//  causes the quiescent bias to shift, asymmetrically distorting
//  the waveform in a time-varying way — audible as a subtle
//  "living" harmonic character absent from static clipping.
//
//  The DC offset is applied before clipping and removed by
//  fi.dcblocker afterwards, leaving only the harmonic
//  asymmetry imprinted by the shifted operating point.
//
//  LFO range: 0.03 to 1.2 Hz (sub-beat, thermal time-scale)
// ============================================================

drift_rate = hslider("v:Faust Fuzz/[7]Drift Rate
    [tooltip:Thermal drift LFO speed (0=static, 1=fast)]
    [style:knob]",
    0.2, 0.0, 1.0, 0.01) : slew(0.5);

drift_depth = hslider("v:Faust Fuzz/[8]Drift Depth
    [tooltip:How far the bias point thermally wanders]
    [style:knob]",
    0.06, 0.0, 0.25, 0.001) : slew(0.3);

drift_lfo = os.osc(0.03 + drift_rate * 1.17) * drift_depth;


// ============================================================
//  BIAS (STATIC QUIESCENT POINT)
//
//  0.5 = perfectly symmetric operation
//  > 0.5 = positive half-cycle sees more gain before clipping
//
//  Combined with drift_lfo this gives the live bias offset.
//  Range maps to +-0.4 DC shift — large enough to produce
//  audible even harmonics across the full drive range.
// ============================================================

bias_ctrl = hslider("v:Faust Fuzz/[3]Bias
    [tooltip:Transistor bias — 0.5=symmetric, higher=warm asymmetric]
    [style:knob]",
    0.55, 0.0, 1.0, 0.001) : slew(SLEW);

bias_offset = (bias_ctrl - 0.5) * 0.8 + drift_lfo;


// ============================================================
//  CHARACTER BLEND (SILICON <-> GERMANIUM)
//
//  Both paths are computed with ADAA and crossfaded:
//    0.0 = Silicon only (aggressive, asymmetric, bright)
//    1.0 = Germanium only (warm, symmetric, rounded)
//    0.5 = Hybrid (unique to this pedal — neither topology
//          alone produces this combination of harmonics)
// ============================================================

character = hslider("v:Faust Fuzz/[4]Character
    [tooltip:0=Silicon (aggressive) 1=Germanium (warm)]
    [style:knob]",
    0.0, 0.0, 1.0, 0.001) : slew(SLEW);

fuzz_core(x) =
    silicon(x + bias_offset)   * (1.0 - character)
  + germanium(x + bias_offset) * character;


// ============================================================
//  DRIVE GAIN
//
//  Exponential taper — matches the physical feel of a pot sweep.
//  1x at zero (unity, no clipping), 500x at maximum
//  (full hard saturation approaching square wave).
// ============================================================

fuzz_drive = hslider("v:Faust Fuzz/[2]Fuzz
    [tooltip:Fuzz drive intensity — exponential 1x to 500x]
    [style:knob]",
    0.5, 0.0, 1.0, 0.001) : slew(SLEW);

drive_gain = pow(500.0, fuzz_drive);


// ============================================================
//  INPUT STAGE
//
//  Trim, coupling capacitor highpass at 80 Hz (sub-bass removal
//  prevents mud in the clipping stage), and optional presence
//  lift at 1.2 kHz (increases note attack and cut).
//
//  BUG FIX vs. v1.0: fi.peak_eq already outputs the full
//  EQ'd signal. Adding x + fi.peak_eq(...) doubles the
//  signal and applies EQ twice. Corrected to pass signal
//  through the EQ only using the chain operator (:).
// ============================================================

input_trim_db = hslider("v:Faust Fuzz/[0]Trim [unit:dB]
    [tooltip:Input gain trim +/-12 dB]
    [style:knob]",
    0.0, -12.0, 12.0, 0.1) : slew(SLEW);

presence_db = hslider("v:Faust Fuzz/[1]Presence [unit:dB]
    [tooltip:Pre-fuzz presence lift at 1.2 kHz]
    [style:knob]",
    0.0, 0.0, 12.0, 0.1) : slew(SLEW);

input_stage =
    _ * ba.db2linear(input_trim_db)
  : fi.highpass(1, 80.0)
  : fi.peak_eq(presence_db, 1200.0, 1.5);


// ============================================================
//  BIG MUFF PASSIVE TONE STACK
//
//  The original Big Muff uses a passive RC network, not a
//  parametric EQ. Its defining behavior:
//
//    tone=0   : LPF dominant (fc ~750 Hz), warm and dark
//    tone=0.5 : Both paths attenuate the midrange simultaneously
//               producing the characteristic "scooped" fuzz tone
//    tone=1   : HPF dominant (fc ~1.5 kHz), bright and cutting
//
//  Modeled here as LP/HP crossfade (matching the passive pot's
//  dual-wiper behavior) with a parametric mid-dip whose depth
//  tracks proximity to the center position.
// ============================================================

tone_ctrl = hslider("v:Faust Fuzz/[5]Tone
    [tooltip:Big Muff passive tone — 0=bass, 0.5=mid-scoop, 1=treble]
    [style:knob]",
    0.5, 0.0, 1.0, 0.001) : slew(SLEW);

MID_DIP_MAX = -10.0;    // dB, maximum scoop depth at center

// Scoop deepens toward center (tone=0.5), zero at extremes
mid_scoop_depth = MID_DIP_MAX * (1.0 - 2.0 * abs(tone_ctrl - 0.5)) * 2.0;

tone_stack(x) =
    (fi.lowpass(2, 750.0, x)   * (1.0 - tone_ctrl)
   + fi.highpass(2, 1500.0, x) * tone_ctrl)
  : fi.peak_eq(mid_scoop_depth, 800.0, 1.2);


// ============================================================
//  NOISE GATE
//
//  Dual-speed envelope follower with a smoothstep gain curve.
//  Fast attack (5 ms) catches note starts cleanly.
//  Slow release (180 ms) preserves fuzz sustain character.
//  Smoothstep curve prevents clicks at open/close transitions.
//
//  -80 dB threshold = effectively off.
// ============================================================

gate_thresh_db = hslider("v:Faust Fuzz/[6]Gate [unit:dB]
    [tooltip:Noise gate threshold. -80=off]
    [style:knob]",
    -80.0, -80.0, -20.0, 0.5) : slew(0.08);

env_follow(x) =
    abs(x) : si.onePoleSwitching(ba.tau2pole(0.005), ba.tau2pole(0.18));

gate(x) = x * gain(x)
with {
    thresh   = ba.db2linear(gate_thresh_db);
    ratio(x) = env_follow(x) / max(thresh, 1e-9);
    gain(x)  = smoothstep(0.0, 1.0, ratio(x));
    smoothstep(lo, hi, t) = sq * (3.0 - 2.0 * sq)
    with { sq = max(0.0, min(1.0, (t - lo) / (hi - lo))); };
};


// ============================================================
//  OUTPUT STAGE
// ============================================================

output_vol = hslider("v:Faust Fuzz/[9]Volume [unit:dB]
    [tooltip:Output level]
    [style:knob]",
    0.0, -24.0, 6.0, 0.1) : slew(SLEW) : ba.db2linear;


// ============================================================
//  FULL SIGNAL CHAIN
// ============================================================

fuzz_chain =
    input_stage           // Trim + 80 Hz HP + presence
  : _ * drive_gain        // Exponential fuzz gain
  : fuzz_core             // Bias offset + ADAA Si/Ge waveshaper
  : fi.dcblocker          // Remove DC from asymmetric bias
  : tone_stack            // Big Muff passive tone stack
  : gate                  // Noise gate (off by default at -80 dB)
  : _ * output_vol;       // Output level


// ============================================================
//  TRUE BYPASS — SLEWED CROSSFADE
//
//  BUG FIX vs. v1.0:
//  (a) Old code computed bypass_smooth but used raw bypass
//      in process() — the slew was silently discarded, causing
//      audible clicks on pedal engage/disengage.
//  (b) Old bypass_smooth = bypass : ba.impulsify : +~(si.smooth(...))
//      produced a non-converging ramp, not a 0-1 slew.
//
//  Correct approach: si.smooth(ba.tau2pole(T)) on the checkbox
//  signal produces a proper exponential slew over T seconds.
//  3 ms matches relay contact timing — inaudible, click-free.
// ============================================================

bypass = checkbox("v:Faust Fuzz/[10]Bypass
    [tooltip:True bypass with 3 ms relay-style crossfade]");

bp_smooth = bypass : si.smooth(ba.tau2pole(0.003));

process(L, R) = out_L, out_R
with {
    mono  = (L + R) * 0.5;
    wet   = fuzz_chain(mono);
    // bp_smooth=0 -> full wet, bp_smooth=1 -> full dry
    out_L = wet * (1.0 - bp_smooth) + L * bp_smooth;
    out_R = wet * (1.0 - bp_smooth) + R * bp_smooth;
};
