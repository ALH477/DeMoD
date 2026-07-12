declare name        "OrchestraSynth";
declare author      "Asher / DeMoD Audio Systems";
declare description "4-voice physical-modeling synth · bowed string · clarinet reed · lip-reed brass · Chladni plate";
declare version     "1.3";
declare license     "GPL-3.0";

// ┌──────────────────────────────────────────────────────────────────────────┐
// │  OrchestraSynth v1.3                                                      │
// │  Parameter interface: freq / gate / gain  (render.py convention)         │
// └──────────────────────────────────────────────────────────────────────────┘

import("stdfaust.lib");


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  RENDER.PY INTERFACE                                                     ║
// ╚══════════════════════════════════════════════════════════════════════════╝

freq = hslider("freq", 440.0, 27.5, 20000.0, 0.01) : si.smoo;
gate = hslider("gate", 0.0,   0.0,  1.0,     1.0);   // raw — no smoo
gain = hslider("gain", 0.5,   0.0,  1.0,     0.01) : si.smoo;


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  SYNTH CONTROLS                                                          ║
// ╚══════════════════════════════════════════════════════════════════════════╝

morph = hslider("h:Controls/[1] Morph [style:knob]",  0.0,   0.0, 3.0, 0.001) : si.smoo;
exAmt = hslider("h:Controls/[2] Excite [style:knob]", 0.5,   0.0, 1.0, 0.001) : si.smoo;
atk   = hslider("h:Controls/[3] Attack [unit:s]",     0.005, 0.001, 2.0, 0.001);
rel   = hslider("h:Controls/[4] Release [unit:s]",    1.5,   0.05,  8.0, 0.01);


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  ENVELOPE                                                                ║
// ╚══════════════════════════════════════════════════════════════════════════╝

impulse = gate > gate';
env     = en.ar(atk, rel, impulse) * gain;


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  ORNSTEIN-UHLENBECK DRIFT (0-in, 1-out)                                 ║
// ╚══════════════════════════════════════════════════════════════════════════╝

OU_THETA = 6.0;
ouDrift(sigma) = no.noise * (sigma * sqrt(2.0 * OU_THETA * ma.T))
               : (_, ((_ * (1.0 - OU_THETA * ma.T)) ~ _)) :> +;


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  SATURATOR — Padé [2/2] ≈ tanh, hard-bounded to (-1, 1)                ║
// ╚══════════════════════════════════════════════════════════════════════════╝

// Primary soft sat — Padé approx to tanh, |out| < 1 always
sat(x) = x * (27.0 + x * x) / (27.0 + 9.0 * x * x);

// Hard NaN/inf guard — clip to [-1, 1] after sat in every loop
guard(x) = max(-1.0, min(1.0, x));

// Combined: sat then hard clip — ensures feedback can never exceed ±1
safeSat(x) = sat(x) : guard;


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  DELAY CONSTANTS                                                         ║
// ╚══════════════════════════════════════════════════════════════════════════╝

MAXD = 7200;  // 27.5 Hz @ 192kHz = 6981 samples; 7200 is safe headroom

// Safe delay length: clamp to [1, MAXD-1] so fdelay never gets 0 or overflow
safeN(f, offset) = max(1.0, min(float(MAXD - 1), float(ma.SR) / max(27.5, f) - offset));


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  VOICE 0 — BOWED STRING                                                 ║
// ║                                                                          ║
// ║  Thiran allpass: η̂ = (1−η)/(1+η)                                       ║
// ║  Degenerate when η → 0 (N is nearly integer):                          ║
// ║    η < 0.001 → skip allpass, use integer delay only.                   ║
// ║  All feedback signals pass through safeSat before re-entering loop.     ║
// ╚══════════════════════════════════════════════════════════════════════════╝

stringVoice(f) = (excite + _) ~ loop
with {
  delN     = safeN(f, 1.0);
  N_full   = float(ma.SR) / max(27.5, f);
  eta      = N_full - float(int(N_full));
  // Guard η: Thiran is ill-conditioned at eta≈0 (etaHat → 1, pole at z=1)
  etaSafe  = max(0.02, eta);
  etaHat   = (1.0 - etaSafe) / (1.0 + etaSafe);
  thiran1  = fi.tf1(etaHat, 1.0, etaHat);
  avgLP(x) = (x + x') * 0.5;
  // Loop: delay → fractional AP → lowpass → gain → hard clip
  loop     = de.fdelay(MAXD, delN) : thiran1 : avgLP : *(0.995) : guard;
  excite   = no.noise * exAmt * (1.0 + ouDrift(0.12)) * env : safeSat;
};


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  VOICE 1 — WOODWIND REED (Clarinet bore)                                ║
// ║                                                                          ║
// ║  Bore loop gain budget:                                                  ║
// ║    sat output ≤ 1.0  ×  loop gain 0.995  →  stable for any input       ║
// ╚══════════════════════════════════════════════════════════════════════════╝

reedVoice(f) = (pMouth + _) ~ boreLoop
with {
  delN     = safeN(f, 1.0);
  // sat first (nonlinearity), then delay, negate, dcblock, hard clip
  boreLoop = safeSat : de.fdelay(MAXD, delN) : *(-0.995) : fi.dcblockerat(35.0) : guard;
  pMouth   = (exAmt * 0.5 + no.noise * exAmt * 0.05 * (1.0 + ouDrift(0.15))) * env;
};


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  VOICE 2 — BRASS (Lip-Reed + Exponential Horn)                          ║
// ║                                                                          ║
// ║  Lip biquad poles at r=0.85 (was 0.88 — reduced to avoid resonance     ║
// ║  buildup at high exAmt).                                                 ║
// ╚══════════════════════════════════════════════════════════════════════════╝

brassVoice(f) = (pMouth + _) ~ boreLoop
with {
  delN     = safeN(f, 1.5);
  f_lip    = max(20.0, f * 0.85);
  w_lip    = 2.0 * ma.PI * f_lip * ma.T;
  r_lip    = 0.85;
  lip      = fi.tf2(1.0, 0.0, 0.0, -2.0*r_lip*cos(w_lip), r_lip*r_lip);
  bellLP   = fi.lowpass(1, max(20.0, f * 5.0));
  // lip → safeSat → delay → bell filter → gain → guard
  boreLoop = lip : safeSat : de.fdelay(MAXD, delN) : bellLP : *(0.990) : guard;
  pMouth   = (exAmt * 0.45 + no.noise * exAmt * 0.03 * (1.0 + ouDrift(0.08))) * env;
};


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  VOICE 3 — KIRCHHOFF-LOVE PLATE (Chladni modal)                        ║
// ║                                                                          ║
// ║  IIR resonators can't diverge: poles are at r = exp(-ζω₀T) < 1         ║
// ║  with ζ > 0 enforced. Guard added anyway for safety.                    ║
// ╚══════════════════════════════════════════════════════════════════════════╝

plateMode(f0, ratio, zeta0, amp) = fi.tf2(b0, 0.0, 0.0, a1, a2) : *(amp) : guard
with {
  fm   = max(20.0, f0 * ratio);
  wm   = 2.0 * ma.PI * fm * ma.T;
  zeta = max(1e-3, zeta0 * sqrt(ratio));   // enforce positive damping
  r    = exp(-zeta * wm);
  a1   = -2.0 * r * cos(wm);
  a2   = r * r;
  b0   = 1.0 - r;
};

plateVoice(f) =
  mallet <:
    plateMode(f, 1.000, 0.0010, 1.00),
    plateMode(f, 1.581, 0.0013, 0.65),
    plateMode(f, 1.581, 0.0013, 0.55),
    plateMode(f, 2.000, 0.0016, 0.40),
    plateMode(f, 2.236, 0.0018, 0.28),
    plateMode(f, 2.236, 0.0018, 0.22)
  :> *(0.22)
with {
  mallet = no.noise * exAmt * env;
};


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  VOICE MORPHING                                                          ║
// ╚══════════════════════════════════════════════════════════════════════════╝

clamp01(x) = max(0.0, min(1.0, x));

voiceMix(v0, v1, v2, v3, m) = v0*w0 + v1*w1 + v2*w2 + v3*w3
with {
  c0 = clamp01(m);
  c1 = clamp01(m - 1.0);
  c2 = clamp01(m - 2.0);
  w0 = 1.0 - c0;
  w1 = c0 - c1;
  w2 = c1 - c2;
  w3 = c2;
};


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  PROCESS — 0 inputs, 2 outputs (stereo)                                 ║
// ╚══════════════════════════════════════════════════════════════════════════╝

process =
  voiceMix(
    stringVoice(freq),
    reedVoice(freq),
    brassVoice(freq),
    plateVoice(freq),
    morph
  )
  : *(0.5)   // headroom for 4 simultaneous voices
  <: _, _;
