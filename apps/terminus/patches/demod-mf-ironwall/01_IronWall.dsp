declare name        "IronWall";
declare author      "DeMoD Audio Systems";
declare description "Hard clipper · full harmonic series via Fourier · brick-wall clip";
declare version     "1.0";
declare license     "GPL-3.0";

// ┌──────────────────────────────────────────────────────────────────────────┐
// │  IronWall — Hard Clipper                                                  │
// │  DeMoD Audio Systems                                                      │
// │                                                                            │
// │  Architecture:                                                             │
// │    · Input gain stage (drive)                                              │
// │    · Clamped nonlinear transfer function y = clip(x, ±T) / T              │
// │    · DC blocker on output (removes asymmetry offset)                       │
// │    · Output trim + dry/wet blend                                           │
// │                                                                            │
// │  Mathematics:                                                              │
// │    Hard clip maps any |x| > T to ±T, producing a flat-topped waveform.   │
// │    By Fourier's theorem, a flat-topped periodic wave converges to a        │
// │    square wave as drive → ∞, whose series is:                              │
// │      x_sq(t) = (4/π) Σ(n=1,3,5,…) sin(nωt)/n                            │
// │    In practice, finite drive yields all harmonics nω at decreasing         │
// │    amplitude. THD rises monotonically with drive until saturation.         │
// │                                                                            │
// │    Transfer function:                                                       │
// │      y = max(-T, min(T, x·drive)) / T       (normalised to ±1)            │
// └──────────────────────────────────────────────────────────────────────────┘

import("stdfaust.lib");


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  UI PARAMETERS                                                           ║
// ╚══════════════════════════════════════════════════════════════════════════╝

drive  = hslider("h:IronWall/[1] Drive [style:knob]",   6.0,  1.0, 40.0, 0.01) : si.smoo;
thresh = hslider("h:IronWall/[2] Thresh [style:knob]",  0.5,  0.05, 1.0, 0.001): si.smoo;
trim   = hslider("h:IronWall/[3] Trim [unit:dB]",      -6.0,-24.0,  6.0, 0.1)
         : ba.db2linear : si.smoo;
wmix   = hslider("h:IronWall/[4] Mix",                  1.0,  0.0,  1.0, 0.01) : si.smoo;


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  HARD CLIP                                                               ║
// ║                                                                          ║
// ║  y = max(-T, min(T, x)) * (1/T)                                         ║
// ║  Bounded output, guaranteed ±1 range, bijective on (-T, T)              ║
// ╚══════════════════════════════════════════════════════════════════════════╝

hardClip(t, x) = max(0.0-t, min(t, x)) * (1.0/t);


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  PROCESS                                                                 ║
// ╚══════════════════════════════════════════════════════════════════════════╝

wet(x) = x * drive : hardClip(thresh) : fi.dcblockerat(35.0);

process = _ <: wet(_)*wmix + _*(1.0-wmix) : *(trim);
