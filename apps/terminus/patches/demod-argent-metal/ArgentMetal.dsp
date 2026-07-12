declare name        "ArgentMetal";
declare author      "DeMoD Audio Systems — Asher";
declare description "Argent Metal Synth · inharmonic stiff-string partials + FM transient + resonant shimmer";
declare version     "1.0";
declare license     "GPL-3.0";

// ┌──────────────────────────────────────────────────────────────────────────┐
// │  ArgentMetal — Silver Metallic Additive/FM Synthesizer                   │
// │  DeMoD Audio Systems                                                     │
// │                                                                          │
// │  Architecture:                                                           │
// │    · 8 inharmonic partials, stretched by stiffness coefficient B         │
// │    · Stiff-string partial frequencies: fₙ = n·f₀·√(1 + B·n²)           │
// │    · Per-partial exponential decay: τₙ = τ₀ / n^α  (higher = faster)    │
// │    · FM brightness burst on attack: mod ratio sweeps via AR envelope     │
// │    · High-Q resonant bandpass for "silver ring" at Fc                    │
// │    · Stereo spread via per-partial phase offset (odd→L, even→R bias)     │
// │    · Padé saturator on output to prevent digital clips                   │
// └──────────────────────────────────────────────────────────────────────────┘

import("stdfaust.lib");


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  CONSTANTS                                                               ║
// ╚══════════════════════════════════════════════════════════════════════════╝

NPART   = 8;          // number of inharmonic partials
SPRD    = 0.003;      // fixed stereo detune offset per partial (fraction of f0)


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  UI PARAMETERS                                                           ║
// ╚══════════════════════════════════════════════════════════════════════════╝

// ── Renderer interface params (flat labels — addressed by render.py) ─────────
// freq: MIDI note frequency in Hz — set per-note by RenderEngine
freq  = hslider("freq [unit:Hz]", 220.0, 20.0, 20000.0, 0.01) : si.smoo;

// gate: 1.0 while note held, 0.0 on note-off — drives AR envelope trigger
//   checkbox gives a held 0/1 signal (unlike button which is momentary)
gate  = checkbox("gate");

// gain: MIDI velocity mapped to [0,1] by RenderEngine
gain  = hslider("gain", 0.8, 0.0, 1.0, 0.001) : si.smoo;

// ── Synth timbre params (grouped for GUI) ────────────────────────────────────
// — Stiffness  B ∈ [0,1]  (0 = harmonic, 1 = very inharmonic / bell-like)
//   fₙ = n·f₀·√(1 + B·n²)
stiff = hslider("v:ArgentMetal/[1] Stiffness [style:knob]",
                0.35, 0.0, 1.0, 0.001) : si.smoo;

// — Envelope: attack and decay (shared shape, per-partial decay scaled by n)
atk   = hslider("v:ArgentMetal/[2] Attack [unit:s][style:knob]",
                0.002, 0.001, 0.5, 0.001) : si.smoo;
dcy   = hslider("v:ArgentMetal/[3] Decay [unit:s][style:knob]",
                1.2, 0.05, 8.0, 0.01) : si.smoo;

// — Decay taper exponent α: how much faster high partials fade
//   τₙ = τ₀ / n^α   (α=0 → all equal, α=1 → linear, α=2 → quadratic)
alpha = hslider("v:ArgentMetal/[4] Taper [style:knob]",
                1.2, 0.0, 3.0, 0.01) : si.smoo;

// — FM transient burst
fmamt = hslider("v:ArgentMetal/[5] FM Transient [style:knob]",
                0.6, 0.0, 4.0, 0.01) : si.smoo;
fmrat = hslider("v:ArgentMetal/[6] FM Ratio [style:knob]",
                3.14, 0.5, 8.0, 0.01) : si.smoo;

// — Resonant silver ring
ringfc = hslider("v:ArgentMetal/[7] Ring Freq [unit:Hz][style:knob]",
                 4200.0, 800.0, 12000.0, 1.0) : si.smoo;
ringQ  = hslider("v:ArgentMetal/[8] Ring Q [style:knob]",
                 18.0, 1.0, 60.0, 0.1) : si.smoo;

// — Output level and ring mix
outdb  = hslider("v:ArgentMetal/[9] Level [unit:dB][style:knob]",
                 -6.0, -40.0, 6.0, 0.1) : si.smoo : ba.db2linear;
wmix   = hslider("v:ArgentMetal/[10] Ring Mix [style:knob]",
                 0.45, 0.0, 1.0, 0.001) : si.smoo;


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  PADÉ SATURATOR                                                          ║
// ║                                                                          ║
// ║  Rational approximation of tanh(x):                                     ║
// ║    sat(x) = x(27 + x²) / (27 + 9x²)                                    ║
// ║  Error < 0.5% for |x| ≤ 2.0 · Bounded output                          ║
// ╚══════════════════════════════════════════════════════════════════════════╝

sat(x) = x * (27.0 + x*x) / (27.0 + 9.0*x*x);


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  STIFF-STRING PARTIAL FREQUENCY                                          ║
// ║                                                                          ║
// ║  Physical stiff-string model (Morse & Ingard):                          ║
// ║    fₙ = n · f₀ · √(1 + B · n²)                                         ║
// ║  B = stiffness coefficient (0 = ideal string, >0 = piano/metal)         ║
// ╚══════════════════════════════════════════════════════════════════════════╝

partFreq(n) = float(n) * freq * sqrt(1.0 + stiff * float(n) * float(n));


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  PER-PARTIAL EXPONENTIAL DECAY ENVELOPE                                 ║
// ║                                                                          ║
// ║  Shape: AR with exponential decay                                       ║
// ║  τₙ = dcy / n^alpha   → higher partials fade faster                    ║
// ║  Implemented via en.ar with per-partial release time                    ║
// ╚══════════════════════════════════════════════════════════════════════════╝

partEnv(n) = en.ar(atk, dcy / pow(float(n), alpha), gate);


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  FM TRANSIENT BURST                                                      ║
// ║                                                                          ║
// ║  Modulation index rides the attack envelope:                            ║
// ║    φ_mod(t) = fmamt · env_attack(t) · sin(2π · fmrat · f₀ · t)        ║
// ║  This creates the clangorous brightness spike on strike                 ║
// ╚══════════════════════════════════════════════════════════════════════════╝

// Attack-only envelope for FM burst (fast decay regardless of dcy setting)
fmEnv   = en.ar(atk, min(dcy * 0.15, 0.4), gate);

// FM modulator: sine at modulator frequency, scaled by burst envelope
fmMod   = fmamt * fmEnv * os.osc(fmrat * freq);


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  SINGLE INHARMONIC PARTIAL WITH FM TRANSIENT                            ║
// ║                                                                          ║
// ║  For partial n (1-indexed):                                             ║
// ║    out(t) = partEnv(n) · sin(2π · fₙ · t + fmMod(t))                  ║
// ║  Stereo: slight frequency detune between L and R channels               ║
// ║    fL = fₙ · (1 - SPRD · float(n) / NPART)                            ║
// ║    fR = fₙ · (1 + SPRD · float(n) / NPART)                            ║
// ╚══════════════════════════════════════════════════════════════════════════╝

// Stereo detune factor per partial
spreadL(n) = 1.0 - SPRD * float(n) / float(NPART);
spreadR(n) = 1.0 + SPRD * float(n) / float(NPART);

// FM-modulated sine for left channel at partial n
partL(n) = partEnv(n) * os.osc(partFreq(n) * spreadL(n) + fmMod);

// FM-modulated sine for right channel at partial n
partR(n) = partEnv(n) * os.osc(partFreq(n) * spreadR(n) + fmMod);

// Partial amplitude taper: 1/n^0.7 gives natural spectral roll-off
// (steeper than 1/n to avoid excessive high-partial energy)
partAmp(n) = 1.0 / pow(float(n), 0.7);


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  ADDITIVE STACK — sum NPART partials on each channel                    ║
// ╚══════════════════════════════════════════════════════════════════════════╝

// Sum all partials (1-indexed: k+1)
stackL = sum(k, NPART, partAmp(k+1) * partL(k+1));
stackR = sum(k, NPART, partAmp(k+1) * partR(k+1));

// Normalize by sum of amplitudes to keep output near unity
normFactor = sum(k, NPART, partAmp(k+1));
synthL = stackL / normFactor;
synthR = stackR / normFactor;


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  SILVER RING — resonant bandpass coloration                             ║
// ║                                                                          ║
// ║  High-Q bandpass models the bright resonant shimmer of polished silver  ║
// ║  H(z) = bandpass biquad at ringfc with Q = ringQ                        ║
// ║                                                                          ║
// ║  Biquad bandpass coefficients (RBJ cookbook):                           ║
// ║    ω₀ = 2π·fc/fs,   α = sin(ω₀)/(2Q)                                  ║
// ║    b0 =  α,   b1 = 0,   b2 = -α                                        ║
// ║    a0 =  1+α, a1 = -2cos(ω₀)/a0, a2 = (1-α)/a0                        ║
// ╚══════════════════════════════════════════════════════════════════════════╝

w0     = 2.0 * ma.PI * ringfc / ma.SR;
alphaQ = sin(w0) / (2.0 * ringQ);
a0inv  = 1.0 / (1.0 + alphaQ);

bpB0   =  alphaQ * a0inv;
bpB1   =  0.0;
bpB2   = -alphaQ * a0inv;
bpA1   = -2.0 * cos(w0) * a0inv;
bpA2   = (1.0 - alphaQ) * a0inv;

silverRing(x) = fi.tf2(bpB0, bpB1, bpB2, bpA1, bpA2, x);


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  OUTPUT MIX — dry additive + wet silver ring                            ║
// ║                                                                          ║
// ║  wet = silverRing(dry)                                                  ║
// ║  out = dry·(1-wmix) + wet·wmix                                          ║
// ╚══════════════════════════════════════════════════════════════════════════╝

mixRing(dry) = dry * (1.0 - wmix) + silverRing(dry) * wmix;


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  PROCESS                                                                 ║
// ╚══════════════════════════════════════════════════════════════════════════╝


outL = synthL : mixRing : *(outdb * gain) : sat;
outR = synthR : mixRing : *(outdb * gain) : sat;

process = outL, outR;
