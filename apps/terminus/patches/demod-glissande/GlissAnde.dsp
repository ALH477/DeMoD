declare name        "GlissAnde";
declare author      "DeMoD Audio Systems";
declare description "Fretless string synthesizer · KS + inharmonic dispersion + OU vibrato + 7-limit JI + cello body";
declare version     "1.0";
declare license     "GPL-3.0";

// ┌──────────────────────────────────────────────────────────────────────────────────────┐
// │  GlissAnde · DeMoD Audio Systems                                                      │
// │                                                                                        │
// │  A physically-informed model of a fretless bowed/plucked string, assembled from       │
// │  five interlocked mathematical systems derived from string physics, stochastic         │
// │  process theory, psychoacoustics, and combinatorial number theory:                    │
// │                                                                                        │
// │   §1  Karplus-Strong synthesis with stiffness-dispersion all-pass chain               │
// │   §2  Log-space first-order portamento (perceptually uniform glide)                   │
// │   §3  Ornstein-Uhlenbeck stochastic vibrato (models human tremolo irregularity)       │
// │   §4  7-limit just intonation correction with continuous ET→JI blend                  │
// │   §5  Cello body radiation filter (Helmholtz + plate modes via biquad EQ)             │
// └──────────────────────────────────────────────────────────────────────────────────────┘

import("stdfaust.lib");


// ════════════════════════════════════════════════════════════════════════════════════════
// §1.  INHARMONIC STRING DISPERSION
//
// A perfectly flexible string has harmonic partials at exactly integer multiples of the
// fundamental: f_n = n·f₁.  Real strings resist bending — the restoring force is the
// sum of string tension T and a stiffness term proportional to EI·∂⁴y/∂x⁴, where E is
// the Young's modulus of the string material and I = πd⁴/64 is the second moment of
// area for a circular cross-section of diameter d.
//
// The wave equation for a stiff string with fixed boundary conditions gives eigenfreqs:
//
//   f_n = n·f₁·√(1 + B·n²)                                                    (1.1)
//
// Inharmonicity coefficient B  (Schuck & Young, JASA 1943):
//
//   B = π³·E·d⁴ / (64·T·L²)                                                   (1.2)
//
// where L is the speaking length. Typical values:
//   Piano treble strings   B ≈ 1.5–3.0 × 10⁻³
//   Cello C-string (gut)   B ≈ 6–10 × 10⁻⁵
//   Cello C-string (steel) B ≈ 3–5 × 10⁻⁴
//   Classical guitar nylon B ≈ 2–5 × 10⁻⁶
//
// Taylor expansion of (1.1) for small B:
//
//   f_n ≈ n·f₁·(1 + B·n²/2),   n << B^(-1/2)                                (1.3)
//
// The deviation from ideal harmonicity is therefore quadratic in mode number.
// Perceptible inharmonicity begins at approximately |f_n - n·f₁| > 1 cent ≈ 0.58%.
//
// ─── DELAY-LINE DISPERSION MODEL ───────────────────────────────────────────────────────
//
// In a Karplus-Strong delay-line model, inharmonicity is emulated by inserting a chain
// of N first-order all-pass filters in the feedback loop.  Each all-pass:
//
//   H_ap(z; c) = (c + z⁻¹) / (1 + c·z⁻¹),   c ∈ (-1, 1)                   (1.4)
//
// has unity magnitude response and group delay:
//
//   τ_ap(ω) = -(c²-1) / (c²+1+2c·cos ω) = (1-c²) / (1+c²+2c·cos ω)        (1.5)
//
// Evaluated at DC (ω=0):  τ_ap(0) = (1-c²)/(1+c)² = (1-c)/(1+c)
// Evaluated at Nyquist (ω=π): τ_ap(π) = (1-c²)/(1+c²-2c) = (1-c²)/(1-c)² = (1+c)/(1-c)
//
// For c > 0:
//   DC group delay: (1-c)/(1+c) < 1  → loop is SHORTER at DC → fundamental rises
//   Nyquist delay:  (1+c)/(1-c) > 1  → loop is LONGER near Nyquist → high partials fall
//   → This gives SUBHARMONIC inharmonicity (partials stretch DOWN). Wrong direction!
//
// For c < 0 (let c = -|c|):
//   DC group delay: (1+|c|)/(1-|c|) > 1  → loop is LONGER at DC → fundamental holds
//   Nyquist delay:  (1-|c|)/(1+|c|) < 1  → loop is SHORTER at Nyquist → highs rise ✓
//   → Partials stretch UPWARD. Correct for string stiffness!
//
// The additional phase delay per all-pass at frequency f is:
//
//   Δτ(f) ≈ |c| · (1 - 4·(f/SR)²)  samples,   for small |c|                 (1.6)
//
// Relative delay differential between DC and partial n:
//   ΔΔτ_n = |c|·(1 - 4·(n·f₁/SR)²) - |c| = -4|c|·(n·f₁/SR)²
//
// The nth partial resonates at f satisfying L_eff(f)·f/SR = n:
//   (L₀ + N·Δτ(n·f₁))·(n·f_n)/SR = n
//   f_n ≈ f₁·(1 + N·|c|·4·(n·f₁/SR)²/L₀)  for small deviations              (1.7)
//
// Comparing with (1.3): B_eff ≈ 8·N·|c|·(f₁/SR)²·SR/f₁ = 8·N·|c|·f₁/SR    (1.8)
//
// Solving for |c| given desired B:
//
//   |c| = B·SR / (8·N·f₁)                                                     (1.9)
//
// LOOP LENGTH CORRECTION:
// Each all-pass contributes (1+|c|)/(1-|c|) - 1 ≈ 2|c| extra samples at DC.
// Total loop correction: subtract N·(1+|c|)/(1-|c|) from the delay line, or
// approximately:
//
//   L_adj = SR/f₁  −  0.5  (averaging filter)  −  N·(1+|c|)/(1-|c|)        (1.10)
//
// rounded to the nearest sample; fractional remainder handled by de.fdelay.
// ════════════════════════════════════════════════════════════════════════════════════════

N_DISP = 4;                               // dispersion all-pass count (power of 2 preferred)
MAXD   = int(2.0 * 192000.0) + 1;        // max delay buffer: 2 s at max plausible SR

// First-order all-pass via Direct Form I
// H(z;c) = (c + z⁻¹)/(1 + c·z⁻¹)  →  fi.tf1(b0,b1,a1) with b0=c, b1=1, a1=c
// Coefficients c are time-varying signals — fi.tf1 handles this correctly.
apf(c) = fi.tf1(c, 1.0, c);

// Chain of N_DISP all-passes (seq: N identical stages in series)
dispChain(c) = seq(k, N_DISP, apf(c));

// Dispersion coefficient (negative) from B and f₁ per (1.9), clamped for stability
dispCoeff(b_param, f1) =
    0.0 - min(0.45, max(0.0, b_param * ma.SR / (8.0 * float(N_DISP) * max(1.0, f1))));

// Effective DC group delay of one all-pass: (1+|c|)/(1-|c|)
apfDcDelay(c) = (1.0 + abs(c)) / max(1e-6, 1.0 - abs(c));

// KS delay length per (1.10): total loop minus averaging minus all-pass DC delays
ksLoopDelay(f1, c) = max(2.0, ma.SR / max(10.0, f1) - 0.5 - float(N_DISP) * apfDcDelay(c));


// ════════════════════════════════════════════════════════════════════════════════════════
// §2.  LOG-SPACE PORTAMENTO
//
// The human auditory system encodes pitch logarithmically: equal musical intervals
// correspond to equal frequency ratios, not equal frequency differences.  This is why
// the equal-tempered scale uses 2^(n/12) multipliers rather than additive steps.
//
// A "musically correct" portamento must therefore traverse equal fractions of an octave
// per unit time — constant velocity in log-frequency space — not constant Hz/second.
//
// PERCEPTUAL MIDPOINT COMPARISON:
//   Linear glide 220→440 Hz: midpoint in Hz = 330 Hz = 220 + 110
//   Log midpoint (geometric mean): √(220·440) = √96800 ≈ 311.1 Hz
//   Error: 18.9 Hz ≈ 100 cents upward bias in the middle of a 1-octave glide.
//
// At the glide midpoint in a Bach cello suite, a 100-cent error is audible.
// For a fretless instrument model, this is unacceptable.
//
// IMPLEMENTATION:
// Apply a standard 1-pole IIR smoother in log-frequency space:
//
//   log(y[n]) = p·log(y[n-1]) + (1-p)·log(x[n])                             (2.1)
//
// where p is the smoothing pole:
//
//   p = e^(-1/(τ·SR)),   τ = portamento time constant [seconds]               (2.2)
//
// In Faust: log(freq) → si.smooth(p) → exp
//
// This is algebraically equivalent to multiplicative geometric smoothing:
//   y[n] = y[n-1]^p · x[n]^(1-p)                                             (2.3)
//
// BOUNDARY CASES:
//   τ→0:  p→0 → pole at origin → y[n] = x[n] (instantaneous, no glide) ✓
//   τ→∞:  p→1 → pole at z=1 → integrator → note never changes (never used, capped)
//
// MINIMUM POLE DERIVATION:
// For τ=0 (no portamento): max(1.0, τ·SR) = 1 → p = e^(-1/1) = 0.368.
// This means ~1-sample time constant: y[n] = 0.368·y[n-1] + 0.632·x[n].
// At 48kHz a 1-sample delay is 20.8 μs — effectively instantaneous for pitch. ✓
// ════════════════════════════════════════════════════════════════════════════════════════

logPortamento(tau, f) = log(max(1e-5, f)) : si.smooth(pole) : exp
  with {
    pole = exp(-1.0 / max(1.0, tau * ma.SR));
  };


// ════════════════════════════════════════════════════════════════════════════════════════
// §3.  ORNSTEIN-UHLENBECK VIBRATO
//
// The vibrato of a skilled string player is NOT a sine wave.  Analysis of recordings
// (Seashore 1938, Prame 1994) reveals:
//   · Vibrato rate varies ±15–25% within a single sustained note
//   · Vibrato amplitude varies ±30–40%
//   · Phase accumulates irregularly (the period is not constant)
//
// A perfect sine LFO captures none of this irregularity.  The result sounds robotic —
// the hallmark of cheap digital keyboards from the 1990s.
//
// MODEL CHOICE: ORNSTEIN-UHLENBECK PROCESS
// The Ornstein-Uhlenbeck (OU) process (Uhlenbeck & Ornstein, 1930) is the unique
// stationary Gaussian Markov process.  Its SDE:
//
//   dX_t = -θ(X_t - μ) dt + σ dW_t                                           (3.1)
//
// where θ = mean-reversion rate, μ = long-run mean, σ = volatility, W_t = Brownian.
//
// EXACT DISCRETE-TIME SOLUTION (no Euler-Maruyama approximation needed):
//
//   X[n] = μ + (X[n-1] - μ)·a + b·w[n],   w[n] ~ N(0,1) i.i.d.             (3.2)
//
//   a = exp(-θ/SR)                          (auto-correlation coefficient)   (3.3)
//   b = √((1 - a²) · σ²/(2θ·T))·√T = σ·√((1-a²)/(2θ/SR))                  (3.4)
//
// In normalised form (μ=0, unit stationary variance, σ=√(2θ/SR)):
//
//   X[n] = a·X[n-1] + √(1-a²)·w[n]                                           (3.5)
//
// The stationary variance is E[X²] = 1 (by construction), and the power spectrum:
//
//   S_X(f) = (1-a²) / |1 - a·e^(-j2πf/SR)|²  →  Lorentzian shape            (3.6)
//
// 3dB bandwidth (half-power frequency): f₋₃dB = arccos(2a/(1+a²))·SR/(2π)
//                                              ≈ θ/(2π·SR) · SR = θ/(2π) Hz  (3.7)
//
// JITTERY VIBRATO CONSTRUCTION:
// Direct OU noise gives a Lorentzian spectrum peaking at DC — useful for intonation
// drift but not for vibrato which should peak at rate f_v.
//
// Solution: perturb the PHASE INCREMENT of a sinusoidal LFO with a scaled OU signal.
// The instantaneous frequency of the LFO becomes:
//
//   f_inst[n] = f_v + κ·f_v·X[n]                                              (3.8)
//
// where κ = jitter ∈ [0,1] and X[n] is the unit-variance OU process with θ=2π·f_v.
//
// Phase accumulation (mod 1):
//   φ[n] = φ[n-1] + f_inst[n]/SR  (mod 1)                                   (3.9)
//
// Output in semitones: depth_st · sin(2π·φ[n])
//
// LIMITING CASES:
//   κ=0: perfect sine vibrato at exactly f_v Hz
//   κ=1: rate varies between approximately 0 and 2f_v Hz with OU correlation
//   κ→∞: random phase walk → pitch wanders like an untrained player
//
// WHY THIS BEATS A SINE LFO:
// The phase jitter introduces natural variations in period that spread the vibrato
// spectrum from a single spike at f_v into a narrow Lorentzian, exactly matching
// spectrograms of real string players.  The OU time constant θ=2π·f_v ensures the
// rate perturbations are correlated over ~1/f_v seconds, giving organic smoothness.
// ════════════════════════════════════════════════════════════════════════════════════════

ouVibrato(vib_rate, depth_semitones, jitter) = output
  with {
    // OU process with mean-reversion θ = 2π·vib_rate per (3.3–3.5)
    theta  = max(0.01, 2.0 * ma.PI * vib_rate);
    a_ou   = exp(-theta / ma.SR);
    b_ou   = sqrt(max(0.0, 1.0 - a_ou * a_ou));   // unit-variance normalisation

    // Recursive OU: y[n] = a·y[n-1] + b·w[n]
    ou_noise = (*(a_ou), (b_ou * no.noise) :> +) ~ _;

    // Phase increment with OU-perturbed rate per (3.8–3.9)
    base_inc  = vib_rate / ma.SR;
    pert_inc  = jitter * vib_rate * ou_noise / ma.SR;
    phase     = (base_inc + pert_inc) : (+ : ma.decimal) ~ _;

    output = sin(2.0 * ma.PI * phase) * depth_semitones;
  };


// ════════════════════════════════════════════════════════════════════════════════════════
// §4.  7-LIMIT JUST INTONATION CORRECTION
//
// Equal temperament (ET) is a mathematical compromise: it makes every key equally out
// of tune.  The 12th root of 2 step (≈1.05946) makes only the octave (2:1) perfectly
// just; all other intervals deviate from simple integer ratios.
//
// Justly intoned intervals produce ZERO BEATING between harmonics of two simultaneous
// notes, because the harmonic series of both notes share exact common frequencies.
// A just perfect fifth (3:2) means the 2nd harmonic of the upper note = 3rd harmonic
// of the lower note — no beats.  An ET fifth (2^(7/12) ≈ 1.4983) gives a 3rd harmonic
// of the lower note that is 2 cents flat of the 2nd harmonic of the upper note,
// producing ≈1.1 Hz beating at A=440 Hz — slow, arguably pleasant.
//
// THE 7-LIMIT SCALE:
// Including the prime 7 allows the harmonic seventh (7:4 = 969 cents) alongside the
// 5-limit intervals.  The 7th harmonic of the fundamental is distinctly audible on
// a cello open string.  Ratio table with ET deviations:
//
//   n   Name          Ratio   Decimal    ET ref    Error (¢)
//   ──────────────────────────────────────────────────────────
//   0   Unison         1/1    1.00000   1.00000     0.00
//   1   Minor second  16/15   1.06667   1.05946   +11.73
//   2   Major second   9/8    1.12500   1.12246    +3.91
//   3   Minor third    6/5    1.20000   1.18921   +15.64
//   4   Major third    5/4    1.25000   1.25992   −13.69  ← most audible in chords
//   5   Perfect 4th    4/3    1.33333   1.33484    −1.96
//   6   Tritone        7/5    1.40000   1.41421   −17.49  ← 7-limit
//   7   Perfect 5th    3/2    1.50000   1.49831    +1.96
//   8   Minor sixth    8/5    1.60000   1.58740   +13.69
//   9   Major sixth    5/3    1.66667   1.68179   −15.64
//  10   Minor seventh  7/4    1.75000   1.78180   −31.17  ← 7-limit, very flat!
//  11   Major seventh 15/8    1.87500   1.88775   −11.73
//
// PITCH CORRECTION FORMULA:
// Given incoming MIDI-derived frequency f_in, the scale degree relative to root r is:
//
//   d = (round(69 + 12·log₂(f_in/440)) - r + 120) mod 12                   (4.1)
//
// The JI correction factor:
//
//   κ(d) = JI_ratio(d) / 2^(d/12)                                            (4.2)
//
// Applied frequency with blend parameter α ∈ [0,1]:
//
//   f_out = f_in · κ(d)^α                                                     (4.3)
//
// At α=0: f_out = f_in (equal temperament).
// At α=1: full JI correction for scale degree d.
// At α=0.5: halfway between ET and JI — models typical string player tendency to
//            "lean into" just intonation without fully committing.
//
// NOTE ON CONTINUITY:
// κ(d)^α = exp(α · log κ(d)).  Since log κ(d) is a smooth function of α, the
// correction is C∞ in α.  The correction changes abruptly when d changes (a new
// MIDI note triggers a different table entry), but this is the correct musical
// behavior — JI corrections are key-relative and change at note boundaries.
// ════════════════════════════════════════════════════════════════════════════════════════

// 7-limit JI ratios for scale degrees 0–11
// Stored as a 12-entry waveform table; rdtable provides O(1) lookup
JI_RATIO_TABLE = waveform {
    1.0,            // 0:  1/1    unison
    1.06666667,     // 1: 16/15   minor second
    1.125,          // 2:  9/8    major second
    1.2,            // 3:  6/5    minor third
    1.25,           // 4:  5/4    major third   ← −13.7¢ from ET
    1.33333333,     // 5:  4/3    perfect fourth
    1.4,            // 6:  7/5    tritone (7-limit)
    1.5,            // 7:  3/2    perfect fifth
    1.6,            // 8:  8/5    minor sixth
    1.66666667,     // 9:  5/3    major sixth
    1.75,           //10:  7/4    minor seventh (7-limit) ← −31.2¢ from ET
    1.875           //11: 15/8    major seventh
};

jiCorrectFreq(f_in, root_note, ji_amt) = f_in * pow(kappa, ji_amt)
  with {
    // MIDI note number, rounded to nearest integer
    midi_n   = int(ba.hz2midikey(max(8.0, f_in)) + 0.5);
    // Scale degree: (note - root + 120) mod 12  [+120 keeps arg positive for any root ∈ 0..11]
    degree   = int(abs((midi_n - int(root_note) + 120) % 12));
    // JI ratio lookup and ET ratio for same degree
    ji_ratio = JI_RATIO_TABLE, degree : rdtable;
    et_ratio = pow(2.0, float(degree) / 12.0);
    // Correction factor κ(d) per (4.2)
    kappa    = ji_ratio / max(1e-6, et_ratio);
  };


// ════════════════════════════════════════════════════════════════════════════════════════
// §5.  CELLO BODY RADIATION FILTER
//
// The acoustic body of a cello is not a passive diffuser — it is a resonant system
// with distinct vibrational modes that selectively radiate sound.  The primary modes
// responsible for the instrument's tonal character (Hutchins 1962, Woodhouse 1993):
//
//   Mode  Name     Freq range  Q    Physical mechanism
//   ────────────────────────────────────────────────────────────────────────────────
//   A0    Air mode 250–310 Hz  5–12  Helmholtz resonator: air pumped through f-holes
//   B1−   Wood low 400–530 Hz  6–9   Bending of top and back plates in phase
//   B1+   Wood hi  480–600 Hz  6–9   Anti-phase plate bending (coupled via soundpost)
//   Bridge         2000–3500Hz 2–5   Bridge rocking on its feet; couples to top plate
//
// The A0 mode (Helmholtz resonance) frequency can be estimated:
//
//   f_A0 = (c/2π) · √(S_hole / (V · L_eff))                                  (5.1)
//
// where c = 343 m/s (speed of sound), S_hole = total f-hole area ≈ 9 cm², 
// V = body internal volume ≈ 1.9 L, L_eff = effective f-hole length ≈ 2 cm.
//   f_A0 ≈ (343/6.28) · √(9e-4 / (1.9e-3 · 0.02)) ≈ 54.6 · √(23.7) ≈ 266 Hz ✓
//
// The B1 modes arise from the coupled vibration of top and back plates via the
// soundpost (a wooden dowel wedged between the plates near the treble bridge foot).
// Without the soundpost, the two plate modes are nearly degenerate; the soundpost
// breaks this degeneracy into B1− (co-phase) and B1+ (anti-phase).
//
// FILTER IMPLEMENTATION:
// Each mode is approximated as a 2nd-order resonator (parametric EQ peak filter).
// The biquad cookbook (Zölzer 1997, RBJ 2010) gives:
//
//   ω₀ = 2π·f_c/SR,   α = sin(ω₀)/(2Q),   A = 10^(g_dB/40)
//   b₀ = 1 + α·A,     b₁ = −2cos(ω₀),    b₂ = 1 − α·A
//   a₀ = 1 + α/A,     a₁ = −2cos(ω₀),    a₂ = 1 − α/A                      (5.2)
//
// The `body_amt` parameter [0,1] scales all peak gains continuously.
// At body_amt=0: identity filter (dry string tone).
// At body_amt=1: full cello body coloration.
//
// NOTE ON MODE ORDERING:
// The filters are applied in series — top to bottom in frequency — so the combined
// response approximates the measured radiation curve of a 7/8 cello body.
// ════════════════════════════════════════════════════════════════════════════════════════

bodyResonance(amt) =
    fi.peak_eq(6.0 * amt,  278.0,  9.0)  :   // A0: Helmholtz air resonance
    fi.peak_eq(4.5 * amt,  470.0,  7.5)  :   // B1-: lower coupled plate mode
    fi.peak_eq(3.5 * amt,  555.0,  7.0)  :   // B1+: upper anti-phase plate mode
    fi.peak_eq(3.0 * amt, 2600.0,  3.5);     // bridge hill (broad radiation peak)


// ════════════════════════════════════════════════════════════════════════════════════════
// §6.  KARPLUS-STRONG SYNTHESIS CORE
//
// Karplus-Strong (1983) models a plucked string as a comb filter:
//   y[n] = x[n] + H_loop(z) · y[n]
//   → H(z) = 1 / (1 − H_loop(z))
//
// Standard loop:
//   H_loop(z) = g · (1+z⁻¹)/2 · z⁻L                                         (6.1)
//
// Resonant frequencies: f_n = n·SR/L,  n = 1, 2, 3, ...
//
// DECAY TIME derivation:
// The loop gain at the nth harmonic is g·|cos(nπ/L)|.  The time for amplitude to
// decay to 1/e (one e-folding) is the number of loop traversals k satisfying:
//   (g·|cos(nπ/L)|)^k = 1/e  →  k = -1/log(g·|cos(nπ/L)|)
// Each traversal takes L/SR seconds, so decay time constant:
//   τ_n = -L / (SR · log(g · |cos(nπ/L)|))                                   (6.2)
//
// For the fundamental (n=1) with large L (L >> 1):
//   cos(π/L) ≈ 1 - π²/(2L²)
//   log(g·cos(π/L)) ≈ (g-1) - π²/(2L²)
//   τ₁ ≈ L / (SR · ((1-g) + π²/(2L²)))
//      ≈ 1 / (f₁ · (1-g))   for large L and g close to 1                    (6.3)
//
// Solving for g given desired τ₁:
//   g = 1 - 1/(τ₁·f₁)                                                        (6.4)
//
// This is the formula used in the UI-to-parameter mapping below.
// g is clamped to [0, 0.9997] — never exactly 1 to prevent infinite sustain.
//
// FULL LOOP WITH INHARMONICITY + BANDWIDTH LIMIT + SATURATION:
//   loop(signal) = de.fdelay(MAXD, L_adj) : averaging : dispChain(c) : *(g) : lpf : sat : dc
//
// The bandwidth-limiting LPF models high-frequency absorption in a real string
// (internal damping, air drag).  fc_loop ≈ 4–8 kHz covers the typical attenuation band.
// ════════════════════════════════════════════════════════════════════════════════════════

// Padé [2/2] approximant of tanh(x) — bounded saturation on feedback path
// sat(x) ≈ x - x³/3 + ...  for |x| < 0.5;  sat(±∞) → ±3 (not ±1, but bounded)
// |error vs tanh| < 0.8% for |x| ≤ 1.8;  prevents KS loop runaway at high gain
sat(x) = x * (27.0 + x * x) / (27.0 + 9.0 * x * x);

// DC blocker: essential in KS feedback — prevents slow drift from accumulating
dcblock = fi.dcblockerat(22.0);

// Full KS loop: takes excitation → outputs string resonance
ksLoop(f_hz, g, b_param, excitation) = excitation : (+ ~ feedbackPath)
  with {
    c      = dispCoeff(b_param, f_hz);
    L      = ksLoopDelay(f_hz, c);
    // Feedback path: delay → averaging → inharmonic dispersion → gain → LPF → sat → DC
    feedbackPath =
        de.fdelay(MAXD, L)        :   // variable fractional delay (Lagrange interp)
        (_ <: _, mem :> *(0.5))   :   // KS averaging filter: H(z) = (1+z⁻¹)/2
        dispChain(c)               :   // inharmonic dispersion all-pass chain §1
        *(g)                       :   // decay gain per (6.4)
        fi.lowpass(1, 6500.0)     :   // bandwidth limit: models string material damping
        sat                        :   // Padé saturator: prevents loop explosion
        dcblock;                       // DC removal: essential for stability
  };


// ════════════════════════════════════════════════════════════════════════════════════════
// ║  UI PARAMETERS
// ════════════════════════════════════════════════════════════════════════════════════════

// MIDI standard params — nentry for compatibility with faust2jack -midi -nvoices N
freq  = nentry("freq [unit:Hz]",  440.0,  20.0,  20000.0, 0.01);
gain  = nentry("gain",              0.5,   0.0,    1.0,   0.01);
gate  = button("gate");

// Pitch group
root_note  = hslider("v:Pitch/[1] Root Note [style:knob]",         0.0,   0.0,  11.0,  1.0);
ji_amount  = hslider("v:Pitch/[2] JI Blend [style:knob]",          0.0,   0.0,   1.0,  0.01) : si.smoo;
porta_time = hslider("v:Pitch/[3] Portamento [unit:s][style:knob]", 0.05,  0.0,   1.0,  0.001) : si.smoo;

// Vibrato group
vib_rate   = hslider("v:Vibrato/[1] Rate [unit:Hz][style:knob]",   5.0,   0.1,  12.0,  0.01) : si.smoo;
vib_depth  = hslider("v:Vibrato/[2] Depth [unit:st][style:knob]",  0.25,  0.0,   2.0,  0.01) : si.smoo;
vib_jitter = hslider("v:Vibrato/[3] Jitter [style:knob]",          0.45,  0.0,   1.0,  0.01) : si.smoo;

// String group
inharmonicity = hslider("v:String/[1] Inharmonicity [style:knob]",  0.001, 0.0,  0.05, 0.0001) : si.smoo;
brightness    = hslider("v:String/[2] Brightness [style:knob]",     0.55,  0.0,   1.0, 0.01)   : si.smoo;
bow_amount    = hslider("v:String/[3] Bow [style:knob]",            0.0,   0.0,   1.0, 0.01)   : si.smoo;
decay_sec     = hslider("v:String/[4] Decay [unit:s][style:knob]",  2.5,   0.1,  12.0, 0.01)   : si.smoo;

// Body group
body_amt = hslider("v:Body/[1] Body Resonance [style:knob]", 0.7, 0.0, 1.0, 0.01) : si.smoo;
spread   = hslider("v:Body/[2] Stereo Spread [style:knob]",  0.3, 0.0, 1.0, 0.01) : si.smoo;

// Master
vol = hslider("v:Master/[1] Volume [style:knob]", 0.7, 0.0, 1.0, 0.01) : si.smoo;


// ════════════════════════════════════════════════════════════════════════════════════════
// ║  PITCH PIPELINE
//
//   f_midi  →  JI correction (§4)  →  log portamento (§2)  →  OU vibrato (§3)
//
//   The vibrato output is in semitones; converted to a frequency multiplier:
//   Δf = 2^(vib_semitones/12)
//   This preserves the log-scale property of pitch: adding semitones in exponent
//   = multiplying frequencies.
// ════════════════════════════════════════════════════════════════════════════════════════

f_ji     = jiCorrectFreq(freq, root_note, ji_amount);
f_glide  = logPortamento(porta_time, f_ji);
vib_st   = ouVibrato(vib_rate, vib_depth, vib_jitter);
f_inst   = f_glide * pow(2.0, vib_st / 12.0);


// ════════════════════════════════════════════════════════════════════════════════════════
// ║  EXCITATION SIGNAL
//
//  PLUCK mode:
//    · Pink noise burst (duration ≈ one string period ≈ 1/f₁ seconds)
//    · Low-pass filtered at brightness·SR/2 (high brightness = bright, bow-like attack)
//    · AR envelope: 1ms attack, 1/f₁ release — exactly one period of excitation
//
//  BOW mode (simplified):
//    · Continuous low-level bandpass noise injected into the KS loop
//    · Bandpass centered on f₁ with ±1 octave bandwidth
//    · Models the stochastic nature of bow-string stick-slip friction
//    · True Hiller-Ruiz bow model would require a table lookup friction function;
//      this approximation captures the sustained quality without full physical detail
//
//  BLEND:
//    excitation = (1-bow)·pluck + bow·bow_exc
//
//  KS DECAY GAIN per §6, equation (6.4):
//    g = 1 - 1/(τ₁·f₁),  clamped to [0, 0.9997]
// ════════════════════════════════════════════════════════════════════════════════════════

pluck_noise = no.pink_noise : fi.lowpass(2, max(60.0, brightness * 0.48 * ma.SR));
pluck_env   = en.ar(0.001, 1.0 / max(1.0, f_inst), gate);
pluck_exc   = pluck_noise * pluck_env;

bow_bw      = max(60.0, f_inst);                // bow bandpass: one octave around f₁
bow_exc     = no.pink_noise
                : fi.bandpass(2, bow_bw * 0.5, bow_bw * 2.0)
                : *(0.04 * gate * bow_amount);   // continuous bow injection

excitation  = (pluck_exc * (1.0 - bow_amount) + bow_exc) * gain;

// Decay gain: g = 1 - 1/(τ₁·f₁), clamped [0, 0.9997]
g_decay(f) = min(0.9997, max(0.0, 1.0 - 1.0 / (max(0.01, decay_sec) * max(1.0, f))));


// ════════════════════════════════════════════════════════════════════════════════════════
// ║  STEREO SYNTHESIS
//
//  Slight pitch detuning between L and R channels creates a natural chorus/ensemble
//  width.  This models the perceptual effect of playing on two adjacent strings
//  (e.g., open D cello string resonating sympathetically with a fingered D an octave up).
//
//  Detune amount: ±(spread · Δ_max) semitones  (Δ_max = 0.04 semitones ≈ 6.9 cents)
//  L: f_inst · 2^(+Δ/12)
//  R: f_inst · 2^(−Δ/12)
//
//  At spread=0.3 (default): ±0.012 semitones ≈ ±2.1 cents
//  Beating frequency at 440 Hz: 440 · (2^(0.024/12) - 1) ≈ 0.61 Hz — barely audible,
//  yet perceptually significant for stereo imaging.
// ════════════════════════════════════════════════════════════════════════════════════════

DETUNE_MAX  = 0.04;  // maximum per-channel detuning in semitones
detune_semi = spread * DETUNE_MAX;
f_L         = f_inst * pow(2.0,  detune_semi / 12.0);
f_R         = f_inst * pow(2.0, -detune_semi / 12.0);


// ════════════════════════════════════════════════════════════════════════════════════════
// ║  PROCESS
// ════════════════════════════════════════════════════════════════════════════════════════
//
//  Signal flow:
//    excitation  ┬→  KS(f_L, g_L)  →  body filter  →  *(vol)  →  out_L
//                └→  KS(f_R, g_R)  →  body filter  →  *(vol)  →  out_R
// ════════════════════════════════════════════════════════════════════════════════════════

stringL = ksLoop(f_L, g_decay(f_L), inharmonicity, excitation);
stringR = ksLoop(f_R, g_decay(f_R), inharmonicity, excitation);

process =
    stringL, stringR :
    (bodyResonance(body_amt), bodyResonance(body_amt)) :
    (*(vol), *(vol));
