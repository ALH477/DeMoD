declare name        "KyokuGen";
declare author      "Asher / DeMoD Audio Systems";
declare description "Dispersive waveguide · torsional coupling · OU sympathetic detuning · koto-body resonator";
declare version     "1.1";
declare license     "GPL-3.0";

// ┌──────────────────────────────────────────────────────────────────────────┐
// │  KyokuGen — 曲弦  ("Curved/Bent String")                                  │
// │  DeMoD Audio Systems                                                      │
// │                                                                            │
// │  Koto-inspired plucked-string synthesizer.  Physics layers:              │
// │    · Karplus-Strong waveguide with fractional delay (de.fdelay)          │
// │    · Stiff-string dispersion via all-pass chain (Jaffe-Smith 1983)       │
// │    · Frequency-dependent loss (1-zero FIR loss filter)                   │
// │    · Pickup-position comb filter on excitation                           │
// │    · Torsional mode secondary loop at f·0.618                            │
// │    · 5-mode koto body resonator (parallel biquad bank)                   │
// │    · Two-voice stereo with independent OU pitch drift                    │
// └──────────────────────────────────────────────────────────────────────────┘

import("stdfaust.lib");


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  CONSTANTS                                                               ║
// ╚══════════════════════════════════════════════════════════════════════════╝

// Max delay buffer: C1=32.7 Hz at 192 kHz → ceil(192000/32.7)=5872 → 8192
MAXN      = 8192;

// All-pass dispersion stage count
N_AP      = 4;

// Torsional/transverse wave speed ratio (steel string, golden ratio ≈ 0.618)
RATIO_TOR = 0.618;


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  UI PARAMETERS                                                           ║
// ╚══════════════════════════════════════════════════════════════════════════╝

freq   = hslider("v:KyokuGen/[01] freq [unit:Hz][style:knob]",     220.0, 32.7, 1760.0, 0.01) : si.smoo;
gate   = hslider("v:KyokuGen/[02] gate", 0.0, 0.0, 1.0, 1.0);
// Edge-detect gate 0→1 to produce a one-sample trigger pulse for en.ar
trig   = gate > gate';
gain   = hslider("v:KyokuGen/[03] gain",                   0.8,   0.0,   1.0,  0.001) : si.smoo;
hard   = hslider("v:KyokuGen/[04] Hardness [style:knob]",          0.5,   0.0,   1.0,  0.001) : si.smoo;
pickb  = hslider("v:KyokuGen/[05] Pick Pos β [style:knob]",        0.12,  0.01,  0.49, 0.001) : si.smoo;
inhar  = hslider("v:KyokuGen/[06] Inharmonicity [style:knob]",     0.3,   0.0,   1.0,  0.001) : si.smoo;
damp   = hslider("v:KyokuGen/[07] Damping [style:knob]",           0.5,   0.0,   1.0,  0.001) : si.smoo;
torcpl = hslider("v:KyokuGen/[08] Torsion Coupling [style:knob]",  0.15,  0.0,   0.45, 0.001) : si.smoo;
bodymx = hslider("v:KyokuGen/[09] Body Mix [style:knob]",          0.35,  0.0,   1.0,  0.001) : si.smoo;
wow    = hslider("v:KyokuGen/[10] Sympathetic [style:knob]",       0.2,   0.0,   1.0,  0.001) : si.smoo;
ogain  = hslider("v:KyokuGen/[11] Output [unit:dB]",               0.0, -24.0,  12.0,  0.1)   : si.smoo;


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  PADÉ [3/2] SATURATOR                                                    ║
// ║  tanh(x) ≈ x·(27+x²)/(27+9x²)   |error|<0.5% for |x|≤2               ║
// ║  Odd symmetry → zero DC in feedback. Unit slope at origin.              ║
// ╚══════════════════════════════════════════════════════════════════════════╝

sat(x) = x * (27.0 + x*x) / (27.0 + 9.0*x*x);


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  ORNSTEIN-UHLENBECK DRIFT                                                ║
// ║  Exact discrete solution: X[n] = α·X[n-1] + σ_d·ξ[n]                  ║
// ║  α = exp(-θ/fs),  σ_d = σ·√(1-α²)  (stationary variance = σ²)         ║
// ║  Two independent instances → stereo organic detuning                    ║
// ╚══════════════════════════════════════════════════════════════════════════╝

ouDrift1 = step1 ~ _
with {
    theta1   = 0.5;
    alp1     = exp(0.0 - theta1 / float(ma.SR));
    sigd1    = wow * 0.008 * sqrt(1.0 - alp1 * alp1);
    step1(s) = s * alp1 + no.noise * sigd1;
};

ouDrift2 = step2 ~ _
with {
    theta2   = 0.5;
    alp2     = exp(0.0 - theta2 / float(ma.SR));
    sigd2    = wow * 0.008 * sqrt(1.0 - alp2 * alp2);
    step2(s) = s * alp2 + no.noise * sigd2;
};


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  DISPERSIVE ALL-PASS CHAIN                                               ║
// ║  Stiff-string model: fₙ = n·f₁·√(1+Bn²)                               ║
// ║  AP group delay τ(ω) = (1-a²)/(1+a²-2a·cosω) — larger at low freq     ║
// ║  so the loop appears shorter to high harmonics → they go sharp.        ║
// ║  H(z) = (-a + z⁻¹)/(1 - a·z⁻¹)  via fi.tf1(b0=-a, b1=1, a1=-a)      ║
// ╚══════════════════════════════════════════════════════════════════════════╝

apGD(a, f) = (1.0 - a*a)
           / max(1.0e-6, 1.0 + a*a - 2.0*a*cos(2.0*ma.PI*f/float(ma.SR)));

apStage(a) = fi.tf1(neg_a, 1.0, neg_a)
with { neg_a = 0.0 - a; };

dispChain(a) = seq(k, N_AP, apStage(a));

dispA = inhar * 0.5;


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  FREQUENCY-DEPENDENT LOSS FILTER                                         ║
// ║  H(z) = g_lo + g_hi·z⁻¹                                                ║
// ║  |H(0)| = g_lo+g_hi = α_DC,  |H(π)| = g_lo-g_hi = α_Ny               ║
// ║  Linear phase → exactly 0.5 sample group delay (subtracted from DL)    ║
// ╚══════════════════════════════════════════════════════════════════════════╝

lossFilter(d) = fi.tf1(g_lo, g_hi, 0.0)
with {
    a_DC = 0.999 - 0.04 * d;
    a_Ny = 0.999 - 0.80 * d;
    g_lo = (a_DC + a_Ny) * 0.5;
    g_hi = (a_DC - a_Ny) * 0.5;
};


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  PICKUP POSITION COMB FILTER                                             ║
// ║  Plucking at β·L zeros harmonics where sin(n·π·β)=0, i.e. n=1/β,2/β…  ║
// ║  H(z) = 1 - z^{-N_pick},  N_pick = fs·β/f₀  (fractional via fdelay)   ║
// ╚══════════════════════════════════════════════════════════════════════════╝

pickComb(f, beta) = _ <: _, (de.fdelay(MAXN, d_pick) : *(0.0-1.0)) :> +
with { d_pick = max(1.0, float(ma.SR) * beta / f); };


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  KOTO BODY RESONATOR                                                     ║
// ║  Parallel 2nd-order resonators: H_k = b·(1-z⁻²)/(1-2r·cosω₀·z⁻¹+r²z⁻²)║
// ║  r = exp(-π·fk/(Q·fs)),  b = (1-r²)/2                                  ║
// ╚══════════════════════════════════════════════════════════════════════════╝

bodyMode(fm, qm) = fi.tf2(b0, 0.0, neg_b0, a1c, r2)
with {
    w0    = 2.0 * ma.PI * fm / float(ma.SR);
    r     = exp(0.0 - ma.PI * fm / (qm * float(ma.SR)));
    b0    = (1.0 - r * r) * 0.5;
    neg_b0= 0.0 - b0;
    a1c   = 0.0 - 2.0 * r * cos(w0);
    r2    = r * r;
};

bodyReso = _ <:
    bodyMode(230.0,  30.0) * 1.00,
    bodyMode(410.0,  35.0) * 0.85,
    bodyMode(650.0,  42.0) * 0.60,
    bodyMode(940.0,  50.0) * 0.40,
    bodyMode(1380.0, 60.0) * 0.25
    :> *(0.35);


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  DELAY LINE LENGTHS                                                      ║
// ║  Total round-trip = 1 (implicit ~) + 0.5 (lossFilter) + N_AP·apGD + d  ║
// ║  Solve for d: d = fs/f - 1.5 - N_AP·apGD(dispA, f)                    ║
// ║  Torsional: no dispersion chain, d_tor = fs·RATIO_TOR/f - 1.5          ║
// ╚══════════════════════════════════════════════════════════════════════════╝

mainDL(f) = max(1.0, float(ma.SR)/f - 1.5 - float(N_AP)*apGD(dispA, f));
torDL(f)  = max(1.0, float(ma.SR)*RATIO_TOR/f - 1.5);


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  EXCITATION                                                              ║
// ║  Filtered noise burst: LP fc = 800 + hard·7200 Hz, AR envelope          ║
// ║  Shaped by pickComb for pluck-position spectral nulls                   ║
// ║                                                                          ║
// ║  NOTE: excitation is a 1-input → 1-output FUNCTION (takes a dummy       ║
// ║  wire x so it participates correctly in the KS + operator).             ║
// ╚══════════════════════════════════════════════════════════════════════════╝

// Returns a burst signal; written as a function of a dummy input so
// it can be used in the excitation-injection form:  _ <: excit, chain :> +
excitBurst(f) = no.noise
              : fi.lowpass(1, 800.0 + hard * 7200.0)
              : *(en.ar(0.0005, 0.05 + (1.0 - hard) * 0.08, trig) * gain)
              : pickComb(f, pickb);


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  SINGLE VOICE                                                            ║
// ║                                                                          ║
// ║  Karplus-Strong with external excitation injection:                      ║
// ║                                                                          ║
// ║    The standard KS loop is:                                              ║
// ║      y[n] = exc[n] + y[n-N] * H_loss                                   ║
// ║                                                                          ║
// ║  In Faust's algebra the correct form is:                                 ║
// ║                                                                          ║
// ║      xOut = (loopChain) ~ _ + excitBurst(f)                            ║
// ║                                                                          ║
// ║  where loopChain is a 1→1 function representing one round trip:         ║
// ║      loopChain(x) = x : de.fdelay(MAXN, d)                             ║
// ║                       : lossFilter(damp)                                ║
// ║                       : dispChain(dispA)                                ║
// ║                       : sat                                             ║
// ║                       : fi.dcblockerat(25.0)                            ║
// ║                                                                          ║
// ║  The `~` feeds back the output of loopChain to its own input,           ║
// ║  adding the implicit 1-sample delay.  excitBurst(f) is a 0-input        ║
// ║  source added to the result each sample.  No port conflict.             ║
// ║                                                                          ║
// ║  Torsional loop uses identical structure, driven by xOut * torcpl       ║
// ║  as its excitation injection.                                            ║
// ╚══════════════════════════════════════════════════════════════════════════╝

oneVoice(f_raw, ou) = dry + bodyReso(dry) * bodymx
with {
    f = f_raw * (1.0 + ou);

    // Loop chain: 1 in → 1 out, all processing per round trip
    mainLoop(x) = x : de.fdelay(MAXN, mainDL(f))
                    : lossFilter(damp)
                    : dispChain(dispA)
                    : sat
                    : fi.dcblockerat(25.0);

    torLoop(x)  = x : de.fdelay(MAXN, torDL(f))
                    : lossFilter(damp * 1.35)
                    : *(0.5)
                    : sat
                    : fi.dcblockerat(25.0);

    // KS feedback + excitation injection
    xOut   = mainLoop ~ _ + excitBurst(f);
    torOut = torLoop  ~ _ + xOut * torcpl;

    dry = xOut + torOut * torcpl * 0.6;
};


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  PROCESS                                                                 ║
// ╚══════════════════════════════════════════════════════════════════════════╝

process = oneVoice(freq, ouDrift1) * ba.db2linear(ogain),
          oneVoice(freq, ouDrift2) * ba.db2linear(ogain);
