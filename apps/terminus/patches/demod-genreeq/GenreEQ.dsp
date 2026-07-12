declare name        "DeMoD·GenreEQ";
declare author      "DeMoD Audio Systems";
declare description "Preset-switchable 10-band graphic EQ · 6 genre presets · Harman-base compatible";
declare version     "1.0";
declare license     "GPL-3.0";

// ┌──────────────────────────────────────────────────────────────────────────┐
// │  DeMoD GenreEQ                                                            │
// │  DeMoD Audio Systems                                                      │
// │                                                                            │
// │  Architecture:                                                             │
// │    · 10-band graphic EQ (ISO 266 centers, Q = √2 → 1-octave BW)          │
// │    · 6 genre presets (Rock, Hip-Hop, Pop, Classical, Acoustic, EDM)       │
// │    · Preset-dependent preamp for headroom management                      │
// │    · Gains smoothed post-select → zipper-free, interpolated transitions   │
// │    · Master trim + bypass                                                  │
// └──────────────────────────────────────────────────────────────────────────┘

import("stdfaust.lib");


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  CONSTANTS                                                               ║
// ║                                                                          ║
// ║  Q = √2 — 1-octave bandwidth for graphic EQ peak stages                 ║
// ║  Derivation: for N-octave BW, Q = √(2^N) / (2^N − 1)                   ║
// ║    N=1: Q = √2 / (2 − 1) = √2 ≈ 1.4142                                 ║
// ║                                                                          ║
// ║  Band centers: ISO 266 preferred 1-octave series, 31 Hz – 16 kHz        ║
// ╚══════════════════════════════════════════════════════════════════════════╝

Q   = 1.4142135;  // √2, 1-octave bandwidth

F1  =    31.25;   // sub-bass
F2  =    62.5;    // bass
F3  =   125.0;    // upper bass
F4  =   250.0;    // low-mid
F5  =   500.0;    // mid
F6  =  1000.0;    // upper-mid / fundamental presence
F7  =  2000.0;    // presence
F8  =  4000.0;    // definition / attack
F9  =  8000.0;    // air / sibilance
F10 = 16000.0;    // brilliance


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  UI PARAMETERS                                                           ║
// ╚══════════════════════════════════════════════════════════════════════════╝

// Preset index 0–5:
//   0 = Rock / Metal
//   1 = Hip-Hop / Electronic
//   2 = Pop / Top 40
//   3 = Classical / Jazz
//   4 = Acoustic / Country
//   5 = Electronic Dance

preset = nentry("v:GenreEQ/[0] Preset
[style:menu{'Rock-Metal':0;'Hip-Hop':1;'Pop-Top40':2;'Classical-Jazz':3;'Acoustic-Country':4;'Electronic-Dance':5}]",
  0, 0, 5, 1);

master = hslider("v:GenreEQ/[1] Master [unit:dB][style:knob]",
  0.0, -12.0, 12.0, 0.1) : si.smoo;

bypass = checkbox("v:GenreEQ/[2] Bypass");


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  PRESET DATA                                                             ║
// ║                                                                          ║
// ║  sel(s, a, b, c, d, e, f):                                              ║
// ║    6-way integer selector via nested select2 comparisons.               ║
// ║    s ∈ {0..5} → returns corresponding argument.                         ║
// ║    Evaluation: (s==k) returns 1.0 when true, 0.0 otherwise.             ║
// ║                                                                          ║
// ║  All gain values in dB. Applied to fi.peak_eq(gain_dB, fc, Q).          ║
// ║  Gains piped through si.smoo AFTER selection so preset transitions       ║
// ║  interpolate smoothly (~20ms) rather than stepping.                     ║
// ║                                                                          ║
// ║  Preset columns (order matches sel args):                                ║
// ║    [rock | hiphop | pop | classical | acoustic | edm]                   ║
// ║                                                                          ║
// ║  Preamp (dB):   -3    -5    -3    -2    -3    -5                        ║
// ║  31  Hz  (dB):  +3    +5    +2    +1    +1    +5                        ║
// ║  62  Hz  (dB):  +3    +5    +2    +1    +1    +4                        ║
// ║  125 Hz  (dB):  +2    +3    +1     0     0    +2                        ║
// ║  250 Hz  (dB):  -1    -2     0    -1    -1    -2                        ║
// ║  500 Hz  (dB):  -1    -2     0     0     0    -2                        ║
// ║  1   kHz (dB):   0     0    +1    +1    +2     0                        ║
// ║  2   kHz (dB):  +2    +1    +3    +2    +3    +1                        ║
// ║  4   kHz (dB):  +2    +2    +2    +2    +2    +2                        ║
// ║  8   kHz (dB):  +3    +3    +2    +2    +2    +4                        ║
// ║  16  kHz (dB):  +2    +2    +1    +3    +2    +3                        ║
// ╚══════════════════════════════════════════════════════════════════════════╝

sel(s,a,b,c,d,e,f) =
  select2(s==5,
    select2(s==4,
      select2(s==3,
        select2(s==2,
          select2(s==1, a, b),
        c),
      d),
    e),
  f);

// Preamp: per-preset headroom offset (prevents inter-sample clipping at high gains)
preamp = sel(preset, -3.0, -5.0, -3.0, -2.0, -3.0, -5.0) : si.smoo;

// Per-band gains (dB) — smoothed for zipper-free preset switching
g1  = sel(preset,  3.0,  5.0,  2.0,  1.0,  1.0,  5.0) : si.smoo;  //  31 Hz  sub-bass
g2  = sel(preset,  3.0,  5.0,  2.0,  1.0,  1.0,  4.0) : si.smoo;  //  62 Hz  bass
g3  = sel(preset,  2.0,  3.0,  1.0,  0.0,  0.0,  2.0) : si.smoo;  // 125 Hz  upper bass
g4  = sel(preset, -1.0, -2.0,  0.0, -1.0, -1.0, -2.0) : si.smoo;  // 250 Hz  low-mid
g5  = sel(preset, -1.0, -2.0,  0.0,  0.0,  0.0, -2.0) : si.smoo;  // 500 Hz  mid
g6  = sel(preset,  0.0,  0.0,  1.0,  1.0,  2.0,  0.0) : si.smoo;  //   1 kHz presence
g7  = sel(preset,  2.0,  1.0,  3.0,  2.0,  3.0,  1.0) : si.smoo;  //   2 kHz upper presence
g8  = sel(preset,  2.0,  2.0,  2.0,  2.0,  2.0,  2.0) : si.smoo;  //   4 kHz definition
g9  = sel(preset,  3.0,  3.0,  2.0,  2.0,  2.0,  4.0) : si.smoo;  //   8 kHz air
g10 = sel(preset,  2.0,  2.0,  1.0,  3.0,  2.0,  3.0) : si.smoo;  //  16 kHz brilliance


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  EQ CHAIN                                                                ║
// ║                                                                          ║
// ║  H_total(z) = ∏_{k=1}^{10} H_peak(gk, fk, Q)                           ║
// ║                                                                          ║
// ║  Each stage is a biquad peak equalizer (fi.peak_eq), which implements   ║
// ║  the Audio EQ Cookbook peaking EQ:                                       ║
// ║    b0 = 1 + α·A,  b1 = −2cos(ω0),  b2 = 1 − α·A                       ║
// ║    a0 = 1 + α/A,  a1 = −2cos(ω0),  a2 = 1 − α/A                       ║
// ║    where A = 10^(gain_dB/40), ω0 = 2π·fc/SR, α = sin(ω0)/(2Q)         ║
// ║                                                                          ║
// ║  fi.peak_eq accepts time-varying gain — smooth dB signals feed directly ║
// ║  into coefficient computation each sample.                               ║
// ║                                                                          ║
// ║  Signal flow:                                                            ║
// ║    input → ×preampLin → [10 peak stages] → output                       ║
// ╚══════════════════════════════════════════════════════════════════════════╝

// Combine preset preamp + master trim into a single linear gain factor
preampLin = ba.db2linear(preamp + master);

eqChain =
    fi.peak_eq(g1,  F1,  Q)
  : fi.peak_eq(g2,  F2,  Q)
  : fi.peak_eq(g3,  F3,  Q)
  : fi.peak_eq(g4,  F4,  Q)
  : fi.peak_eq(g5,  F5,  Q)
  : fi.peak_eq(g6,  F6,  Q)
  : fi.peak_eq(g7,  F7,  Q)
  : fi.peak_eq(g8,  F8,  Q)
  : fi.peak_eq(g9,  F9,  Q)
  : fi.peak_eq(g10, F10, Q);

// Mono processing unit: preamp → EQ chain
monoEQ = *(preampLin) : eqChain;


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  PROCESS                                                                 ║
// ║                                                                          ║
// ║  Stereo (2-in, 2-out). Each channel processed independently.            ║
// ║  bypass=0 → processed output                                             ║
// ║  bypass=1 → dry passthrough (select2: 0=false/process, 1=true/bypass)  ║
// ╚══════════════════════════════════════════════════════════════════════════╝

process = par(i, 2,
  _ <: (monoEQ, _) : select2(bypass, _, _)
);
