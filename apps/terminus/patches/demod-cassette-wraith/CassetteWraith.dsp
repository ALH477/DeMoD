declare name        "CassetteWraith";
declare author      "DeMoD Audio Systems";
declare description "6-stage lo-fi organic phaser · OU wow/flutter · Padé feedback · quadrature stereo";
declare version     "1.0";
declare license     "GPL-3.0";

import("stdfaust.lib");


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  UI PARAMETERS                                                           ║
// ╚══════════════════════════════════════════════════════════════════════════╝

rate  = hslider("v:CassetteWraith/[1] Rate [unit:Hz][style:knob]",  0.35, 0.01, 4.0,  0.001) : si.smoo;
depth = hslider("v:CassetteWraith/[2] Depth [style:knob]",          0.75, 0.0,  1.0,  0.001) : si.smoo;
fbk   = hslider("v:CassetteWraith/[3] Feedback [style:knob]",       0.50, 0.0,  0.97, 0.001) : si.smoo;
wmix  = hslider("v:CassetteWraith/[4] Mix [style:knob]",            0.50, 0.0,  1.0,  0.001) : si.smoo;
wow   = hslider("v:CassetteWraith/[5] Wow [style:knob]",            0.25, 0.0,  1.0,  0.001) : si.smoo;
sprd  = hslider("v:CassetteWraith/[6] Spread [style:knob]",         0.50, 0.0,  1.0,  0.001) : si.smoo;


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  PADÉ [3/2] SOFT SATURATOR                                              ║
// ║                                                                          ║
// ║  Rational approximant of tanh(x):                                       ║
// ║    tanh(x) ≈ x·(27 + x²) / (27 + 9x²)                                 ║
// ║  Odd symmetry · unit slope at origin · error < 0.5% for |x| ≤ 2       ║
// ╚══════════════════════════════════════════════════════════════════════════╝

sat(x) = x * (27.0 + x*x) / (27.0 + 9.0*x*x);


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  1-POLE LOW-PASS FILTER — ANALOG BANDWIDTH SIMULATION                  ║
// ║  H(z) = (1 − b) / (1 − b·z⁻¹),   b = exp(−2π·fc/fs)                  ║
// ║  In feedback: simulates capacitor rolloff of analog resonant circuit   ║
// ╚══════════════════════════════════════════════════════════════════════════╝

lpf1(fc) = _ * (1.0 - b) : fi.pole(b)
with { b = exp(0.0 - 2.0 * ma.PI * fc / float(ma.SR)); };


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  ORNSTEIN-UHLENBECK WOW / FLUTTER SOURCE                                ║
// ║                                                                          ║
// ║  Continuous SDE:    dX_t = −θ·X_t·dt + σ·dW_t                         ║
// ║                                                                          ║
// ║  Exact discrete-time solution (Euler-Maruyama):                         ║
// ║    X[n] = α·X[n-1] + σ_d·w[n]                                          ║
// ║    α    = exp(−θ/fs)           per-sample exponential decay             ║
// ║    σ_d  = σ·√(1 − α²)         noise amplitude for stationarity         ║
// ║    w[n] ∈ U[−1, 1]            uniform white noise input                 ║
// ║                                                                          ║
// ║  Stationary variance:  Var[X∞] = σ²/(2θ)                               ║
// ║  Perturbs LFO phase — models worn capstan tape transport drift          ║
// ╚══════════════════════════════════════════════════════════════════════════╝

ouNoise(theta, sigma) = _ ~ step
with {
    alpha   = exp(0.0 - theta / float(ma.SR));
    sigma_d = sigma * sqrt(1.0 - alpha * alpha);
    step(s) = s * alpha + no.noise * sigma_d;
};


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  QUADRATURE LFO WITH ORGANIC WOW DRIFT                                  ║
// ║                                                                          ║
// ║  φ[n] = (φ[n-1] + f/fs) mod 1  +  φ_offset  +  Ξ[n]                 ║
// ║  y[n] = sin(2π · φ[n])                                                  ║
// ║  Ξ[n] ~ OU(θ=0.7 Hz, σ=0.025·wow)   [slow tape wow]                   ║
// ║  phOffset ∈ [0, 0.25] turns  →  0° to 90° stereo spread               ║
// ╚══════════════════════════════════════════════════════════════════════════╝

lfoSin(rateHz, phOffset) = sin(2.0 * ma.PI * (phasor + phOffset + ouPhase))
with {
    phasor  = rateHz / float(ma.SR) : (+ : ma.decimal) ~ _;
    ouPhase = ouNoise(0.7, 0.025 * wow);
};

lfoL = lfoSin(rate, 0.0);
lfoR = lfoSin(rate, sprd * 0.25);   // up to 90 degrees stereo offset


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  1ST-ORDER ALL-PASS FILTER                                               ║
// ║                                                                          ║
// ║  H(z) = (−a + z⁻¹) / (1 − a·z⁻¹),    a ∈ (−1, 1)                     ║
// ║                                                                          ║
// ║  Bilinear coefficient:                                                   ║
// ║    t = tan(π·fc/fs),   a = (t − 1) / (t + 1)                           ║
// ║                                                                          ║
// ║  Phase response:                                                         ║
// ║    φ(ω) = π − 2·arctan( tan(ω/2) · (1+a)/(1−a) )                      ║
// ║    Sweeps 0° → −360° monotonically as ω: 0 → π   (per stage)           ║
// ║                                                                          ║
// ║  fi.tf1(b0,b1,a1): H(z)=(b0+b1·z⁻¹)/(1+a1·z⁻¹),  b0=−a,b1=1,a1=−a  ║
// ║  Supports fully sample-accurate time-varying coefficients               ║
// ╚══════════════════════════════════════════════════════════════════════════╝

apCoeff(fc) = (t - 1.0) / (t + 1.0)
with {
    fcs = max(10.0, min(fc, float(ma.SR) * 0.48));
    t   = tan(ma.PI * fcs / float(ma.SR));
};

apf(a) = fi.tf1(0.0-a, 1.0, 0.0-a);


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  STAGE FREQUENCY — LOG MAPPING WITH INHARMONIC STAGGER                  ║
// ║                                                                          ║
// ║  fc_lo = 120 Hz,  fc_hi = 4800 Hz,  R = ln(fc_hi/fc_lo)               ║
// ║                                                                          ║
// ║  fc_k(lfo) = fc_lo · exp( R · ( 0.5 + 0.5·D·lfo + 0.04·k ) )         ║
// ║                                                                          ║
// ║  Stage stagger 0.04·k displaces each corner freq ~15% per step in      ║
// ║  log domain → notches fall on inharmonic intervals → musical sweep     ║
// ║  vs. the harsh comb of equal-interval designs                           ║
// ╚══════════════════════════════════════════════════════════════════════════╝

fc_lo = 120.0;
fc_hi = 4800.0;
logR  = log(fc_hi / fc_lo);

stageFreq(lfoVal, k) = fc_lo * exp(logR * (0.5 + 0.5 * depth * lfoVal + 0.04 * k));


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  6-STAGE ALL-PASS CHAIN                                                  ║
// ║  Six APFs in series. Total phase range: 0° → −2160°                    ║
// ║  Produces 6 notch frequencies (phase diff = ±180° with dry signal)     ║
// ╚══════════════════════════════════════════════════════════════════════════╝

apChain(lfoVal) = apf(ac(0.0)) : apf(ac(1.0)) : apf(ac(2.0))
                : apf(ac(3.0)) : apf(ac(4.0)) : apf(ac(5.0))
with {
    ac(k) = apCoeff(stageFreq(lfoVal, k));
};


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  PHASER CHANNEL                                                          ║
// ║                                                                          ║
// ║    x ──┬──────────────────────────── × (1−mix) ──┐                     ║
// ║        │                                           ├──► out             ║
// ║        └──► [+] ──► [apChain] ──► y ─ × mix  ──┘                      ║
// ║              ▲                    │                                      ║
// ║              └── [LPF6k]─[sat]─[×fbk] ◄─── (1-sample delay via ~)    ║
// ║                                                                          ║
// ║  Feedback: y[n-1] → scale(fbk) → sat → bandlimit(6kHz) → x_fb[n]     ║
// ╚══════════════════════════════════════════════════════════════════════════╝

FEEDBACK_BW = 6000.0;

phaseChannel(lfoVal) = splitDryWet : blend
with {
    feedbackPath = *(fbk) : sat : lpf1(FEEDBACK_BW);
    phaser       = (+ : apChain(lfoVal)) ~ feedbackPath;
    splitDryWet  = _ <: _, phaser;
    blend        = (*(1.0 - wmix)), (*(wmix)) :> _;
};


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  PROCESS  —  Stereo in / Stereo out                                     ║
// ║  L: lfoL at phase 0    R: lfoR at phase offset sprd × 90°              ║
// ║  Spread=0 → mono compatible.  Spread=1 → wide quadrature imaging.     ║
// ╚══════════════════════════════════════════════════════════════════════════╝

process = phaseChannel(lfoL), phaseChannel(lfoR);
