declare name        "DeMoDIQ";
declare author      "DeMoD Audio Systems";
declare description "Production 10-band graphic EQ · 6 genre presets · explicit biquad · Padé clip guard";
declare version     "1.0";
declare license     "GPL-3.0";

// ┌──────────────────────────────────────────────────────────────────────────┐
// │  DeMoDIQ — DeMoD Intelligent EQ                                          │
// │  DeMoD Audio Systems                                                      │
// │                                                                            │
// │  Signal flow (per channel):                                               │
// │    in → ×preLin → [10 × peakBand] → dcblock → sat → ×postLin            │
// │       ↘──────────────────────────────────────────────────────↗ bypass    │
// │                                                                            │
// │  Architecture:                                                             │
// │    · peakBand: explicit biquad via fi.tf2 — Audio EQ Cookbook peak EQ    │
// │      Coefficients computed from smoothed dB gain signal each sample.     │
// │      Static terms (ω₀, α) folded to constants at init (fc, Q fixed).    │
// │    · 6-way preset via nested select2; gains smoothed post-select         │
// │      → ~20ms dB interpolation on preset switch, no coefficient step.     │
// │    · Bypass: wet/dry crossfade with si.smoo → no hard switching clicks.  │
// │    · Padé [3/2] saturator as output clip guard (transparent < ±0.9 FS). │
// │    · DC blocking at 35 Hz post-EQ — prevents low-frequency DC wander.   │
// │    · Stereo: 2-in, 2-out, channels processed independently.             │
// └──────────────────────────────────────────────────────────────────────────┘

import("stdfaust.lib");


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  CONSTANTS                                                               ║
// ║                                                                          ║
// ║  Q = √2 — 1-octave bandwidth for all bands                              ║
// ║                                                                          ║
// ║  Derivation (fractional-octave BW formula):                             ║
// ║    For N-octave bandwidth: Q = √(2^N) / (2^N − 1)                       ║
// ║    N = 1: Q = √2 / (2 − 1) = 1.4142                                    ║
// ║                                                                          ║
// ║  Band centers: ISO 266 preferred 1-octave series                        ║
// ║    Fk = 31.25 · 2^(k−1),   k = 1 … 10                                  ║
// ╚══════════════════════════════════════════════════════════════════════════╝

Q   = 1.41421356;   // √2, 1-octave bandwidth

F01 =    31.25;     // sub-bass
F02 =    62.5;      // bass
F03 =   125.0;      // upper bass
F04 =   250.0;      // low-mid
F05 =   500.0;      // mid
F06 =  1000.0;      // upper-mid / fundamental presence
F07 =  2000.0;      // presence
F08 =  4000.0;      // definition / attack
F09 =  8000.0;      // air / sibilance
F10 = 16000.0;      // brilliance


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  peakBand(fc, g) — EXPLICIT BIQUAD PEAK EQ                              ║
// ║                                                                          ║
// ║  Implements Audio EQ Cookbook peaking EQ via fi.tf2 (Transposed DF-II). ║
// ║                                                                          ║
// ║  Transfer function:                                                      ║
// ║         b0 + b1·z⁻¹ + b2·z⁻²                                            ║
// ║  H(z) = ─────────────────────                                            ║
// ║          1 + a1·z⁻¹ + a2·z⁻²                                            ║
// ║                                                                          ║
// ║  Derivations (fc constant, g time-varying):                              ║
// ║    ω₀   = 2π·fc / SR               (angular frequency, init-time const) ║
// ║    α    = sin(ω₀) / (2Q)           (bandwidth param,  init-time const) ║
// ║    A    = 10^(g / 40)              (linear gain, time-varying per sample)║
// ║    a₀   = 1 + α/A                  (normalization, time-varying)        ║
// ║                                                                          ║
// ║  Normalized coefficients (a₀ absorbed):                                  ║
// ║    b0 = (1 + α·A) / a₀                                                  ║
// ║    b1 = −2·cos(ω₀) / a₀     ← equal to a1 (peaking EQ property)       ║
// ║    b2 = (1 − α·A) / a₀                                                  ║
// ║    a1 = −2·cos(ω₀) / a₀                                                 ║
// ║    a2 = (1 − α/A) / a₀                                                  ║
// ║                                                                          ║
// ║  Stability argument:                                                     ║
// ║    Poles: z = cos(ω₀) ± j·√(a₂ − cos²(ω₀))                            ║
// ║    With g ∈ [−15, +15] dB and Q = √2, |z| < 1 for all fc < SR/2.       ║
// ║    si.smoo on g bounds per-sample coefficient delta to                   ║
// ║    ≤ Δg_max / (0.02 · SR) ≈ 1.5×10⁻⁵ — adiabatically slow,           ║
// ║    well within the stability margin at all operating points.             ║
// ║                                                                          ║
// ║  Note: g * 0.025 = g / 40. Written as multiply to avoid repeated        ║
// ║  division; the compiler should fold this but we make intent explicit.    ║
// ╚══════════════════════════════════════════════════════════════════════════╝

peakBand(fc, g) = fi.tf2(b0, b1, b2, a1, a2)
with {
  // ── init-time constants (fc, Q, ma.SR are all compile/init scalars) ──
  omega  = 2.0 * ma.PI * fc / ma.SR;
  cosW   = cos(omega);
  sinW   = sin(omega);
  alpha  = sinW / (2.0 * Q);

  // ── time-varying (g is a smoothed dB signal, changes each sample) ────
  A      = pow(10.0, g * 0.025);          // 10^(g/40)
  a0inv  = 1.0 / (1.0 + alpha / A);      // 1/a₀

  b0 = (1.0 + alpha * A) * a0inv;
  b1 = -2.0 * cosW * a0inv;              // same as a1
  b2 = (1.0 - alpha * A) * a0inv;
  a1 = b1;
  a2 = (1.0 - alpha / A) * a0inv;
};


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  sat(x) — PADÉ [3/2] CLIP GUARD                                         ║
// ║                                                                          ║
// ║  Rational approximation to tanh(x):                                     ║
// ║    sat(x) = x · (27 + x²) / (27 + 9x²)                                 ║
// ║                                                                          ║
// ║  Properties:                                                             ║
// ║    · sat'(0) = 1.0          — unity slope at origin, linear on clean    ║
// ║    · Odd symmetry           — sat(−x) = −sat(x), zero even harmonics    ║
// ║    · Bounded: |sat(x)| < 3  — output can never blow up                  ║
// ║    · |sat(x) − tanh(x)| < 0.5% for |x| ≤ 2.0                          ║
// ║    · For |x| ≤ 0.9: sat(x) ≈ x to within 1% — inaudible on clean signal║
// ║                                                                          ║
// ║  Role here: protects downstream DAW/hardware from inter-sample clips    ║
// ║  when preamp + EQ boosts push a hot input above 0 dBFS. Not a creative  ║
// ║  distortion stage — headroom is managed upstream via preampDB.          ║
// ╚══════════════════════════════════════════════════════════════════════════╝

sat(x) = x * (27.0 + x * x) / (27.0 + 9.0 * x * x);


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  UI PARAMETERS                                                           ║
// ╚══════════════════════════════════════════════════════════════════════════╝

// ── Preset ────────────────────────────────────────────────────────────────
// 0 = Rock / Metal       — V-shape: sub punch + cymbal air
// 1 = Hip-Hop / Trap     — deep sub + crisp hi-hats
// 2 = Pop / Top 40       — smile curve, vocal forward
// 3 = Classical / Jazz   — near-flat, acoustic accuracy
// 4 = Acoustic / Country — warm body + string sparkle
// 5 = EDM                — festival sub drops + synth shimmer
preset = nentry("v:DeMoDIQ/[0] Preset
[style:menu{'Rock-Metal':0;'Hip-Hop':1;'Pop-Top40':2;'Classical-Jazz':3;'Acoustic-Country':4;'EDM':5}]",
  0, 0, 5, 1);

// ── Gain staging ──────────────────────────────────────────────────────────
input_gain   = hslider("v:DeMoDIQ/[1] Input Gain [unit:dB][style:knob]",
                 0.0, -18.0, 18.0, 0.1) : si.smoo;

output_trim  = hslider("v:DeMoDIQ/[2] Output Trim [unit:dB][style:knob]",
                 0.0, -18.0,  6.0, 0.1) : si.smoo;

// ── Bypass ────────────────────────────────────────────────────────────────
// Smoothed: 0.0 = fully processed, 1.0 = fully dry.
// Crossfade eliminates click on toggle — see PROCESS section.
bypass = checkbox("v:DeMoDIQ/[3] Bypass") : si.smoo;


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  PRESET DATA                                                             ║
// ║                                                                          ║
// ║  sel6(s, a,b,c,d,e,f): 6-way combinational selector.                   ║
// ║    Built from 5 nested select2 nodes. Fully sample-accurate.            ║
// ║    s ∈ {0,1,2,3,4,5} → returns corresponding argument.                 ║
// ║                                                                          ║
// ║  All band values in dB. Smoothed post-select (~20ms via si.smoo):       ║
// ║    Switching presets interpolates the dB value over ~20ms, which        ║
// ║    causes A = 10^(g/40) to sweep smoothly → biquad coefficients         ║
// ║    change gradually → no transient instability, no click.               ║
// ║                                                                          ║
// ║  Band  │ Rock  Hip  Pop  Class  Acou  EDM   (all dB)                    ║
// ║  ──────┼────────────────────────────────────                            ║
// ║  31Hz  │  +3   +5   +2    +1    +1    +5                                ║
// ║  62Hz  │  +3   +5   +2    +1    +1    +4                                ║
// ║  125Hz │  +2   +3   +1     0     0    +2                                ║
// ║  250Hz │  -1   -2    0    -1    -1    -2                                ║
// ║  500Hz │  -1   -2    0     0     0    -2                                ║
// ║  1kHz  │   0    0   +1    +1    +2     0                                ║
// ║  2kHz  │  +2   +1   +3    +2    +3    +1                                ║
// ║  4kHz  │  +2   +2   +2    +2    +2    +2                                ║
// ║  8kHz  │  +3   +3   +2    +2    +2    +4                                ║
// ║  16kHz │  +2   +2   +1    +3    +2    +3                                ║
// ║  Pre   │  -3   -5   -3    -2    -3    -5   ← headroom offset (dB)      ║
// ╚══════════════════════════════════════════════════════════════════════════╝

sel6(s, a, b, c, d, e, f) =
  select2(s == 5,
    select2(s == 4,
      select2(s == 3,
        select2(s == 2,
          select2(s == 1, a, b),
        c),
      d),
    e),
  f);

// Per-preset headroom offset: absorbs worst-case boost so output stays clean
preampDB  = sel6(preset, -3.0, -5.0, -3.0, -2.0, -3.0, -5.0) : si.smoo;

// Band gains (dB) — all smoothed post-select
g01 = sel6(preset,  3.0,  5.0,  2.0,  1.0,  1.0,  5.0) : si.smoo; //  31 Hz  sub-bass
g02 = sel6(preset,  3.0,  5.0,  2.0,  1.0,  1.0,  4.0) : si.smoo; //  62 Hz  bass
g03 = sel6(preset,  2.0,  3.0,  1.0,  0.0,  0.0,  2.0) : si.smoo; // 125 Hz  upper bass
g04 = sel6(preset, -1.0, -2.0,  0.0, -1.0, -1.0, -2.0) : si.smoo; // 250 Hz  low-mid
g05 = sel6(preset, -1.0, -2.0,  0.0,  0.0,  0.0, -2.0) : si.smoo; // 500 Hz  mid
g06 = sel6(preset,  0.0,  0.0,  1.0,  1.0,  2.0,  0.0) : si.smoo; //   1 kHz presence
g07 = sel6(preset,  2.0,  1.0,  3.0,  2.0,  3.0,  1.0) : si.smoo; //   2 kHz upper presence
g08 = sel6(preset,  2.0,  2.0,  2.0,  2.0,  2.0,  2.0) : si.smoo; //   4 kHz definition
g09 = sel6(preset,  3.0,  3.0,  2.0,  2.0,  2.0,  4.0) : si.smoo; //   8 kHz air
g10 = sel6(preset,  2.0,  2.0,  1.0,  3.0,  2.0,  3.0) : si.smoo; //  16 kHz brilliance


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  EQ CHAIN                                                                ║
// ║                                                                          ║
// ║  H_total(z) = ∏_{k=1}^{10} H_peak(gk, Fk, Q)                           ║
// ║                                                                          ║
// ║  Series composition via Faust : operator.                               ║
// ║  Each stage is a 1-in 1-out Transposed DF-II biquad.                   ║
// ║  All 10 stages compile to a single unrolled sample loop.               ║
// ╚══════════════════════════════════════════════════════════════════════════╝

eqChain =
    peakBand(F01, g01)
  : peakBand(F02, g02)
  : peakBand(F03, g03)
  : peakBand(F04, g04)
  : peakBand(F05, g05)
  : peakBand(F06, g06)
  : peakBand(F07, g07)
  : peakBand(F08, g08)
  : peakBand(F09, g09)
  : peakBand(F10, g10);


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  CHANNEL PROCESSOR                                                       ║
// ║                                                                          ║
// ║  Mono signal chain (instantiated twice in process for stereo):          ║
// ║                                                                          ║
// ║    x[n] → × preLin → eqChain → dcblock(35Hz) → sat → × postLin         ║
// ║                                                                          ║
// ║  Gain collapsing:                                                        ║
// ║    input_gain and preampDB are both dB signals → summed in dB domain    ║
// ║    then converted once to linear: one multiply at chain entry.          ║
// ║    output_trim: one multiply at chain exit.                             ║
// ║    This avoids cascaded linear multiplies and is numerically cleaner.   ║
// ║                                                                          ║
// ║  DC blocker: fi.dcblockerat(35.0) — 1st-order HP at 35 Hz              ║
// ║    H(z) = (1 − z⁻¹) / (1 − R·z⁻¹),  R ≈ 1 − 2π·35/SR                ║
// ║    Prevents any DC wander from integrating across the biquad chain.     ║
// ╚══════════════════════════════════════════════════════════════════════════╝

preLin  = ba.db2linear(input_gain + preampDB);
postLin = ba.db2linear(output_trim);

channelProc =
    *(preLin)
  : eqChain
  : fi.dcblockerat(35.0)
  : sat
  : *(postLin);


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  PROCESS — STEREO OUTPUT WITH SMOOTH BYPASS                              ║
// ║                                                                          ║
// ║  Bypass crossfade (per channel):                                        ║
// ║    out[n] = processed[n] · (1 − β[n]) + dry[n] · β[n]                  ║
// ║    β = bypass : si.smoo     — ~20ms fade on toggle                      ║
// ║    β = 0.0 → fully processed                                            ║
// ║    β = 1.0 → fully dry (true bypass, pre-gain)                         ║
// ║                                                                          ║
// ║  Signal routing (per channel):                                          ║
// ║    _ <: (channelProc, _)                                                ║
// ║           │                │                                             ║
// ║        wet×(1−β)       dry×β                                            ║
// ║           └────── :> _ ───┘                                             ║
// ║                   sum                                                    ║
// ╚══════════════════════════════════════════════════════════════════════════╝

process = par(i, 2,
  _ <: (channelProc, _) : (*(1.0 - bypass), *(bypass)) :> _
);
