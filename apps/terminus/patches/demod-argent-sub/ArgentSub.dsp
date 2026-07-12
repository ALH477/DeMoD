declare name        "ArgentSub";
declare author      "DeMoD Audio Systems";
declare description "Sub bass processor · inharmonic metallic resonator bank · Argent Series";
declare version     "1.0";
declare license     "GPL-3.0";

// ┌──────────────────────────────────────────────────────────────────────────┐
// │  ArgentSub — Silver Metal Sub Bass Processor                              │
// │  DeMoD Audio Systems · Argent Series                                      │
// │                                                                            │
// │  Architecture:                                                             │
// │    · Stereo input summed to mono sub path                                 │
// │    · 4th-order Butterworth LP isolates the sub band                       │
// │    · Padé-saturated sub path for dense harmonic content                   │
// │    · 3-voice inharmonic metallic resonator bank (×2, stereo)             │
// │      Partials: [1.000, 2.030, 3.070] — struck-silver inharmonicity       │
// │    · Independent OU drift per voice per channel → organic stereo spread   │
// │    · Wet/dry mix preserves full input signal                              │
// └──────────────────────────────────────────────────────────────────────────┘

import("stdfaust.lib");


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  UI PARAMETERS                                                           ║
// ╚══════════════════════════════════════════════════════════════════════════╝

// — Sub Band ————————————————————————————————————————————————————————————————
sub_cut = hslider("h:ArgentSub/v:[1] Sub/[1] Cut [unit:Hz][style:knob]",
                   60.0,  20.0, 120.0, 0.1)  : si.smoo;
sub_drv = hslider("h:ArgentSub/v:[1] Sub/[2] Drive [style:knob]",
                   0.5,   0.0,   1.0,  0.001) : si.smoo;
sub_lvl = hslider("h:ArgentSub/v:[1] Sub/[3] Level [style:knob]",
                   0.8,   0.0,   1.0,  0.001) : si.smoo;

// — Metallic Resonator ———————————————————————————————————————————————————————
met_root = hslider("h:ArgentSub/v:[2] Metal/[1] Root [unit:Hz][style:knob]",
                    50.0,  20.0, 200.0, 0.1)  : si.smoo;
met_q    = hslider("h:ArgentSub/v:[2] Metal/[2] Q [style:knob]",
                    8.0,   1.0,  20.0,  0.1)  : si.smoo;
met_drft = hslider("h:ArgentSub/v:[2] Metal/[3] Drift [style:knob]",
                    0.3,   0.0,   1.0,  0.001) : si.smoo;
met_amt  = hslider("h:ArgentSub/v:[2] Metal/[4] Amount [style:knob]",
                    0.6,   0.0,   1.0,  0.001) : si.smoo;

// — Output ————————————————————————————————————————————————————————————————
sprd     = hslider("h:ArgentSub/v:[3] Output/[1] Spread [style:knob]",
                    0.5,   0.0,   1.0,  0.001) : si.smoo;
mix      = hslider("h:ArgentSub/v:[3] Output/[2] Mix [style:knob]",
                    0.8,   0.0,   1.0,  0.001) : si.smoo;


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  PADÉ [3/2] SATURATOR                                                   ║
// ║                                                                          ║
// ║  Rational approximation to tanh(x):                                      ║
// ║    sat(x) = x·(27 + x²) / (27 + 9x²)                                   ║
// ║  · Max error < 0.5% for |x| ≤ 2.0                                      ║
// ║  · Odd symmetry → zero DC component in harmonic content                 ║
// ║  · Output bounded on ℝ → safe in all signal paths                       ║
// ╚══════════════════════════════════════════════════════════════════════════╝

sat(x) = x * (27.0 + x*x) / (27.0 + 9.0*x*x);


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  ORNSTEIN-UHLENBECK PROCESS                                             ║
// ║                                                                          ║
// ║  SDE:       dX = −θ·X dt + σ dW                                        ║
// ║  Discrete:  X[n] = α·X[n-1] + σ_d·w[n]                                ║
// ║    α   = exp(−θ/fs)         — mean-reversion coefficient               ║
// ║    σ_d = σ·√(1 − α²)       — per-sample noise amplitude               ║
// ║  Parameters:                                                             ║
// ║    theta: mean-reversion rate [1/s]. Higher → faster return to zero.   ║
// ║    sigma: stationary standard deviation (Hz deviation at full control). ║
// ║  Each structural instance has its own independent no.noise seed.        ║
// ╚══════════════════════════════════════════════════════════════════════════╝

ouProcess(theta, sigma) = _ ~ step
with {
    alp  = exp(0.0 - theta / float(ma.SR));
    sigd = sigma * sqrt(1.0 - alp * alp);
    step(s) = s * alp + no.noise * sigd;
};


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  RESONANT BANDPASS — TIME-VARYING COEFFICIENTS                         ║
// ║                                                                          ║
// ║  RBJ cookbook constant-0dB-peak bandpass:                               ║
// ║    ω₀ = 2π·fc/SR,  α = sin(ω₀)/(2Q),  a₀ = 1 + α                     ║
// ║    b₀ =  α/a₀,  b₁ = 0,  b₂ = −α/a₀                                  ║
// ║    ã₁ = −2cos(ω₀)/a₀,   ã₂ = (1−α)/a₀                                ║
// ║                                                                          ║
// ║  fi.tf2 accepts per-sample coefficient signals → OU modulation of fc    ║
// ║  is fully supported without aliasing at these low centre frequencies.   ║
// ╚══════════════════════════════════════════════════════════════════════════╝

resBP(fc, q) = fi.tf2(b0, 0.0, neg_b0, a1n, a2n)
with {
    fc_c  = max(20.0, min(float(ma.SR) * 0.499, fc));
    w0    = 2.0 * ma.PI * fc_c / float(ma.SR);
    alp   = sin(w0) / (2.0 * max(0.1, q));
    a0    = 1.0 + alp;
    b0    = alp / a0;
    neg_b0 = 0.0 - b0;
    a1n   = (0.0 - 2.0) * cos(w0) / a0;
    a2n   = (1.0 - alp) / a0;
};


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  METALLIC RESONATOR BANK                                                ║
// ║                                                                          ║
// ║  3 high-Q bandpass filters at inharmonic partial ratios:               ║
// ║    r₀ = 1.000  — fundamental resonance (sub root)                      ║
// ║    r₁ = 2.030  — sharp-octave partial (Ag metallic beating ≈ +30¢)    ║
// ║    r₂ = 3.070  — sharp-12th partial (cold silver shimmer ≈ +40¢)      ║
// ║                                                                          ║
// ║  Ratios are intentionally non-integer. In struck metal, the bending     ║
// ║  stiffness term κ stretches overtones above their harmonic positions.   ║
// ║  These values approximate thin silver-alloy plate acoustics.            ║
// ║                                                                          ║
// ║  OU drift per voice, decorrelated L/R via distinct θ values:           ║
// ║    θ_L = [0.70, 1.10, 1.70] — slower correlation times on left        ║
// ║    θ_R = [1.00, 1.50, 2.10] — faster correlation times on right       ║
// ║  sprd scales sigma: σ = met_root · met_drft · 0.05 · (0.5 + 0.5·sprd) ║
// ║    sprd=0 → minimal drift, near-mono resonators                        ║
// ║    sprd=1 → full drift amplitude, wide organic stereo                  ║
// ╚══════════════════════════════════════════════════════════════════════════╝

NRES    = 3;
DSCALE  = 0.05;   // ±5% of met_root at full drift and full spread

resRatio(0) = 1.000;
resRatio(1) = 2.030;
resRatio(2) = 3.070;

thetaL(0) = 0.70;   thetaL(1) = 1.10;   thetaL(2) = 1.70;
thetaR(0) = 1.00;   thetaR(1) = 1.50;   thetaR(2) = 2.10;

// OU processes use unit sigma internally; scaling applied at call site.
// This keeps IIR coefficients constant — no coefficient modulation artifacts.
dL(k) = ouProcess(thetaL(k), 1.0);
dR(k) = ouProcess(thetaR(k), 1.0);

// Per-sample drift scale (smoothed UI params multiply the drift output, not sigma)
driftScale = met_root * met_drft * DSCALE * (0.5 + 0.5 * sprd);

metalL(sig) = sum(k, NRES, sig : resBP(met_root * resRatio(k) + dL(k) * driftScale, met_q))
              * (1.0 / float(NRES));

metalR(sig) = sum(k, NRES, sig : resBP(met_root * resRatio(k) + dR(k) * driftScale, met_q))
              * (1.0 / float(NRES));


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  SUB PATH                                                               ║
// ║                                                                          ║
// ║  Transfer function (s-domain, 4th-order Butterworth LP):               ║
// ║    H_sub(s) = ωc⁴ / B₄(s/ωc),   ωc = 2π·sub_cut                      ║
// ║  After isolation, drive-controlled Padé saturation:                     ║
// ║    gain(drv) = 1 + 3·drv     (×1 at drv=0, ×4 at drv=1)              ║
// ║    subPath(x) = sat(x · gain) · sub_lvl                                ║
// ║  At drv=0: linear unity pass-through (no saturation)                   ║
// ║  At drv=1: heavy even+odd harmonic content, bounded by sat             ║
// ╚══════════════════════════════════════════════════════════════════════════╝

subPath(sig) = sig
    : fi.lowpass(4, sub_cut)
    : *(1.0 + 3.0 * sub_drv)
    : sat
    : *(sub_lvl);


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  PROCESS — Stereo 2-in / 2-out                                         ║
// ║                                                                          ║
// ║  Signal flow:                                                            ║
// ║    mono   = (inL + inR) * 0.5          — sum to mono sub feed          ║
// ║    subSig = subPath(mono)              — saturated sub band             ║
// ║    wetL   = subSig + metalL(mono)·amt  — sub + silver shimmer, left    ║
// ║    wetR   = subSig + metalR(mono)·amt  — sub + silver shimmer, right   ║
// ║    outL/R = wetL/R·mix + inL/R·(1−mix) — parallel dry/wet blend       ║
// ║                                                                          ║
// ║  The sub path is kept mono (centred bass) while the metallic layer      ║
// ║  is stereo via decorrelated OU drift, preserving sub punch and          ║
// ║  adding spatial metallic width.                                          ║
// ╚══════════════════════════════════════════════════════════════════════════╝

argent(inL, inR) = outL, outR
with {
    mono   = (inL + inR) * 0.5;
    subSig = subPath(mono);
    wetL   = subSig + metalL(mono) * met_amt;
    wetR   = subSig + metalR(mono) * met_amt;
    outL   = wetL * mix + inL * (1.0 - mix);
    outR   = wetR * mix + inR * (1.0 - mix);
};

process = argent;
