// ═══════════════════════════════════════════════════════════════════════════
//   ██  ██████   ██████  ███    ██  ██████ ██       █████  ██████
//   ██  ██   ██ ██    ██ ████   ██ ██      ██      ██   ██ ██   ██
//   ██  ██████  ██    ██ ██ ██  ██ ██      ██      ███████ ██   ██
//   ██  ██   ██ ██    ██ ██  ██ ██ ██      ██      ██   ██ ██   ██
//   ██  ██   ██  ██████  ██   ████  ██████ ███████ ██   ██ ██████
//
//   Industrial Metal Effect — DeMoD LLC
// ═══════════════════════════════════════════════════════════════════════════
//
//   Signal Chain:
//     Input → PreGain → PreEQ → Waveshaper → BitCrusher
//           → RingMod → CombResonator → CabSim → NoiseGate → Output
//
//   Core Math:
//
//     [1] Asymmetric Waveshaper
//         f(x) = tanh(k·(x + α·x²)) / tanh(k)
//
//         The α·x² term introduces a quadratic bias into the argument of
//         tanh before saturation. Symmetric saturation (tanh alone) produces
//         only odd harmonics {f, 3f, 5f, ...}. The x² bias breaks fold
//         symmetry: f(x) ≠ -f(-x), generating even harmonics {2f, 4f, 6f}
//         as well. This is the transfer characteristic of asymmetrically
//         biased diode clippers in analog circuits — the "germanium fuzz" secret.
//         tanh(k) in the denominator normalizes small-signal gain to unity.
//
//     [2] Hard Clip Ceiling
//         y = clamp(x, -Th, +Th)
//
//         Applied post-waveshaper to prevent runaway peaks and add an
//         additional harmonic shelf. Saturates the top/bottom excursions
//         with infinite-order harmonics (brick-wall = all Fourier components).
//
//     [3] Bit Crusher
//         y = ⌊x · 2^(b-1) + 0.5⌋ / 2^(b-1)
//
//         Uniform scalar quantization with rounding. At b=2: 2 steps per
//         unit → extreme staircase distortion. At b=16: virtually lossless.
//         Quantization error e(n) = y(n) - x(n) adds spectrally shaped noise
//         correlated with the signal — characteristic "digital grit" texture
//         that defines 90s industrial and breakcore aesthetics.
//
//     [4] Ring Modulator — Square Wave Carrier
//         y(t) = x(t) · sgn(sin(2π·fc·t))
//
//         A sine carrier ring mod produces sidebands at f_in ± fc. A square
//         wave carrier is the Fourier sum of all odd harmonics of fc, so the
//         output contains sidebands at f_in ± n·fc for all odd n ∈ {1,3,5,...}.
//         This creates a dense, inharmonic sideband cluster — the raw clang
//         of metal on metal in the spectral domain.
//
//     [5] Feedback Comb Filter
//         y(n) = x(n) + g · y(n - D),  D = ⌊SR / f₀⌋
//
//         Transfer function H(z) = 1 / (1 - g·z^(-D))
//         Poles at z = g^(1/D) · e^(j·2π·k/D), k = 0..D-1
//         → resonant peaks at f₀, 2f₀, 3f₀, ... (harmonic series of f₀)
//         Decay time τ ≈ -D / (SR · ln|g|) seconds.
//         With g → 1.0: poles approach unit circle → metallic infinite sustain.
//         This is the physics of a plucked string (Karplus-Strong) turned brutal.
//
//     [6] Cabinet Simulation
//         Highpass(2, 80 Hz) — port / excursion rolloff
//         Lowpass(4, 4500 Hz) — cone mass + air coupling rolloff
//         PeakEQ(+4 dB, 3 kHz, BW=2500) — Celestion presence character
//         PeakEQ(-3 dB, 650 Hz, BW=810) — classic scooped metal mid dip
//
//     [7] Noise Gate
//         Peak envelope follower: E(n) = max(|x(n)|, α · E(n-1))
//         α = exp(-1 / (SR · τ_release)) ≈ 0.999 at SR=44100, τ=0.1s
//         Gate: y(n) = x(n) if E(n) > threshold, else 0
//
// ═══════════════════════════════════════════════════════════════════════════

declare name        "IRONCLAD";
declare author      "DeMoD LLC";
declare version     "1.0.0";
declare license     "GPL-3.0";
declare description "Industrial Metal Effect — asymmetric waveshaping, bitcrusher, ring mod, metallic comb resonator, cab sim";

import("stdfaust.lib");

// ═══════════════════════════════════════════════════════════════════════════
//  CONTROL PARAMETERS
// ═══════════════════════════════════════════════════════════════════════════

// ── Drive ────────────────────────────────────────────────────────────────

pre_gain  = hslider("v:IRONCLAD/h:[1]Drive/[1]Pre Gain [unit:dB][style:knob]",
                18, 0, 40, 0.1)
            : ba.db2linear : si.smoo;

drive     = hslider("v:IRONCLAD/h:[1]Drive/[2]Drive [style:knob]",
                0.75, 0.0, 1.0, 0.01)
            : si.smoo;

// Asymmetry coefficient — higher = more even harmonics (nastier/rawer)
asym      = hslider("v:IRONCLAD/h:[1]Drive/[3]Asymmetry [style:knob]",
                0.30, 0.0, 1.0, 0.01)
            : si.smoo;

// ── Bit Crusher ───────────────────────────────────────────────────────────

bits      = hslider("v:IRONCLAD/h:[2]Crusher/[1]Bit Depth [style:knob]",
                10, 2, 16, 0.1)
            : si.smoo;

crush_mix = hslider("v:IRONCLAD/h:[2]Crusher/[2]Crush Mix [style:knob]",
                0.50, 0.0, 1.0, 0.01)
            : si.smoo;

// ── Ring Modulator ────────────────────────────────────────────────────────

// 137 Hz is non-musically-related to standard tuning → maximum dissonance
rm_freq   = hslider("v:IRONCLAD/h:[3]RingMod/[1]Carrier Hz [unit:Hz][style:knob]",
                137, 20, 3000, 1)
            : si.smoo;

rm_mix    = hslider("v:IRONCLAD/h:[3]RingMod/[2]Ring Mix [style:knob]",
                0.35, 0.0, 1.0, 0.01)
            : si.smoo;

// ── Comb Resonator ────────────────────────────────────────────────────────

comb_f    = hslider("v:IRONCLAD/h:[4]Comb/[1]Resonant Freq [unit:Hz][style:knob]",
                250, 50, 5000, 1)
            : si.smoo;

// Keep < 1.0 or you'll have a bad time (and a great noise machine)
comb_g    = hslider("v:IRONCLAD/h:[4]Comb/[2]Feedback [style:knob]",
                0.65, 0.0, 0.98, 0.01)
            : si.smoo;

comb_mix  = hslider("v:IRONCLAD/h:[4]Comb/[3]Comb Mix [style:knob]",
                0.40, 0.0, 1.0, 0.01)
            : si.smoo;

// ── Output ────────────────────────────────────────────────────────────────

gate_db   = hslider("v:IRONCLAD/h:[5]Output/[1]Gate Threshold [unit:dB][style:knob]",
                -45, -80, 0, 0.5);

out_gain  = hslider("v:IRONCLAD/h:[5]Output/[2]Output [unit:dB][style:knob]",
                -6, -24, 6, 0.1)
            : ba.db2linear : si.smoo;


// ═══════════════════════════════════════════════════════════════════════════
//  DSP MODULES
// ═══════════════════════════════════════════════════════════════════════════

// ── [1+2] Asymmetric Waveshaper + Hard Clip ───────────────────────────────
//
// k = drive coefficient (1..31), α = asymmetry coefficient (0..0.5)
// f(x) = tanh(k · (x + α·x²)) / tanh(k)
//
// Biasing by x² before tanh pushes positive half harder into saturation
// than the negative half — just like an asymmetrically biased diode clipper.
// After waveshaping, hard clip at ±0.95 for brick-wall ceiling artifacts.

waveshaper(k, a, x) = ma.tanh(k * (x + a * x * x)) / max(ma.tanh(k), 0.0001);
hardclip(x)         = max(-0.95, min(0.95, x));

distortion(x) = x
    : waveshaper(drive * 30.0 + 1.0, asym * 0.5)
    : hardclip;


// ── [3] Bit Crusher ───────────────────────────────────────────────────────
//
// Scalar quantization to 2^(b-1) steps per unit amplitude.
// Parallel mix blends clean signal with crushed for parallel saturation.

bitcrush(b, x) = floor(x * s + 0.5) / s
    with { s = pow(2.0, b - 1.0); };

crusher(x) = (1.0 - crush_mix) * x + crush_mix * bitcrush(bits, x);


// ── [4] Ring Modulator — Square Wave Carrier ──────────────────────────────
//
// Square carrier = sgn(sin(2π·fc·t))
// Generates sidebands at f_signal ± n·fc for all odd n.
// Far more harmonically dense than a sine carrier.

sq_carrier(f) = os.osc(f) : ma.signum;

ring_mod(x) = (1.0 - rm_mix) * x
            + rm_mix * (x * sq_carrier(rm_freq));


// ── [5] Metallic Feedback Comb Filter ────────────────────────────────────
//
// y(n) = x(n) + g · y(n - D),  D = SR / f₀
// Resonant peaks form a harmonic series at multiples of f₀.
// High g → long metallic sustain (approaching Karplus-Strong string model).
// maxdel = 2^17 = 131072 → supports f₀ as low as SR/131072 ≈ 0.34 Hz.

comb_delay = int(float(ma.SR) / max(comb_f, 20.0));

metallic_comb(x) =
      (1.0 - comb_mix) * x
    + comb_mix * (x : fi.fb_comb(131072, comb_delay, 1.0, comb_g));


// ── [6] Cabinet Simulation ────────────────────────────────────────────────
//
// Approximates a closed-back 4×12 loaded with Celestion Vintage 30s:
//   HP(2, 80 Hz)        — port rolloff / excursion limit
//   LP(4, 4500 Hz)      — cone mass + air coupling
//   Peak +4dB @ 3kHz   — Vintage 30 presence character (BW = 2500 Hz)
//   Peak -3dB @ 650Hz  — scooped mid (BW = 810 Hz, Q ≈ 0.8)
//
// fi.peak_eq(gainDB, centerHz, bandwidthHz)

cab_sim = fi.highpass(2, 80.0)
        : fi.lowpass(4, 4500.0)
        : fi.peak_eq(4.0,  3000.0, 2500.0)
        : fi.peak_eq(-3.0,  650.0,  810.0);


// ── Pre-Distortion EQ ─────────────────────────────────────────────────────
//
// Boost midrange before saturation — the waveshaper then folds these
// boosted mids into dense upper harmonics in the 2–6 kHz presence band.
// HP at 60 Hz kills DC offset and subsonic content before clipping.

pre_eq = fi.highpass(2, 60.0)
       : fi.peak_eq(5.0, 1000.0, 670.0);


// ── [7] Noise Gate ────────────────────────────────────────────────────────
//
// Leaky-max peak follower:
//   E(n) = max(|x(n)|, α · E(n-1))
//   α = exp(-1 / (SR · τ)) — release time constant
//
// Hard gate: output is silenced when E(n) drops below threshold.
// τ = 100ms keeps the tail alive without mud.

release_coeff = exp(-1.0 / (float(ma.SR) * 0.1));
peak_env(x)   = abs(x) : (max ~ *(release_coeff));
noise_gate(x) = x * float(peak_env(x) > ba.db2linear(gate_db));


// ═══════════════════════════════════════════════════════════════════════════
//  SIGNAL CHAIN
// ═══════════════════════════════════════════════════════════════════════════

ironclad =
      *(pre_gain)       // [0] Input gain staging
    : pre_eq            // [1] Pre-distortion EQ (shape the meal before grinding)
    : distortion        // [2] Asymmetric tanh waveshaper + hard clip ceiling
    : crusher           // [3] Bit depth reduction (quantization grit)
    : ring_mod          // [4] Ring mod — square carrier (sideband cluster hell)
    : metallic_comb     // [5] Feedback comb resonator (metallic harmonic series)
    : cab_sim           // [6] 4×12 cabinet simulation
    : noise_gate        // [7] Tighten the tail
    : *(out_gain);      // [8] Output level trim

// Mono in → stereo out
process = ironclad <: (_, _);
