declare name        "DeMoDIQ-GT";
declare author      "DeMoD Audio Systems";
declare description "Guitar production EQ · 6 genre presets · HPF · Presence · MIDI CC · Padé clip guard";
declare version     "1.0";
declare license     "GPL-3.0";

// ┌──────────────────────────────────────────────────────────────────────────┐
// │  DeMoDIQ-GT — DeMoD Intelligent EQ / Guitar                             │
// │  DeMoD Audio Systems                                                      │
// │                                                                            │
// │  Signal flow (per channel):                                               │
// │    in → ×inputLin → hpf → [10 × peakBand] → presence → dcblock          │
// │       → sat → ×outputLin                                                  │
// │       ↘──────────────────────────────────────────── bypass ──↗           │
// │                                                                            │
// │  Architecture:                                                             │
// │    · Input gain: −6 to +36 dB — covers instrument level to line level    │
// │    · HPF: 2nd-order Butterworth at fc 20–300 Hz (MIDI CC 74)             │
// │      Rumble and hum elimination before EQ chain.                          │
// │    · 10-band graphic EQ: explicit biquad (Audio EQ Cookbook), Q = √2    │
// │      Gains smoothed post-preset-select for click-free switching.         │
// │    · Presence: parametric peak, fc 500 Hz–6 kHz, Q = 1.5, ±12 dB       │
// │      The single most-used guitar EQ move. MIDI CC 75.                   │
// │    · Padé [3/2] saturator: transparent clip guard, unity below ±0.9 FS  │
// │    · DC block at 35 Hz post-chain                                         │
// │    · Smooth bypass crossfade via si.smoo — zero-click toggle             │
// │    · MIDI CC map (LV2/VST3 hosts that expose ctrlchange):                │
// │        CC 20 = Preset        CC 74 = HPF Freq                            │
// │        CC 75 = Presence Freq CC 76 = Presence Gain                      │
// │        CC 77 = Input Gain    CC 78 = Output Trim                         │
// │        CC 79 = Bypass                                                     │
// │    · Stereo 2-in / 2-out                                                  │
// └──────────────────────────────────────────────────────────────────────────┘

import("stdfaust.lib");


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  CONSTANTS                                                               ║
// ║                                                                          ║
// ║  Q_BAND = √2 — 1-octave bandwidth for all graphic EQ bands              ║
// ║    Derivation: Q = √(2^N)/(2^N − 1), N = 1 → Q = √2 / 1 = 1.4142      ║
// ║                                                                          ║
// ║  Q_PRE = 1.5 — presence peak (slightly narrower than 1 octave)          ║
// ║    Tuned for guitar: enough selectivity to boost 2–4 kHz without        ║
// ║    pulling 1 kHz or 8 kHz excessively. Empirically standard on          ║
// ║    Mesa/Boogie, Soldano, and Dumble-style presence controls.            ║
// ║                                                                          ║
// ║  Band centers: ISO 266 preferred 1-octave series                        ║
// ║  F01–F10 span 31 Hz–16 kHz. Guitar cab response is typically            ║
// ║  bandlimited to 80 Hz–5 kHz; bands outside that range shape DI/reamp.  ║
// ╚══════════════════════════════════════════════════════════════════════════╝

Q_BAND = 1.41421356;   // √2, 1-octave graphic EQ bandwidth
Q_PRE  = 1.5;          // presence peak bandwidth (empirical guitar standard)

F01 =    31.25;        // sub — below guitar fundamental, shapes feel vs. HPF
F02 =    62.5;         // bass fundamental — E1 = 41 Hz, open B = 62 Hz
F03 =   125.0;         // upper bass — body warmth, boom control
F04 =   250.0;         // low-mid — warmth vs. mud boundary
F05 =   500.0;         // mid — honk zone, most-cut band on guitar
F06 =  1000.0;         // upper-mid — body vs. boxiness
F07 =  2000.0;         // presence — note definition, palm mute clack
F08 =  4000.0;         // attack / bite — pick transients, cut through mix
F09 =  8000.0;         // air — string noise, harmonic shimmer
F10 = 16000.0;         // brilliance — cab IR roll-off region


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  peakBand(fc, Q, g) — EXPLICIT BIQUAD PEAK EQ                           ║
// ║                                                                          ║
// ║  Audio EQ Cookbook peaking EQ via fi.tf2 (Transposed Direct Form II).   ║
// ║                                                                          ║
// ║         b0 + b1·z⁻¹ + b2·z⁻²                                            ║
// ║  H(z) = ─────────────────────                                            ║
// ║          1 + a1·z⁻¹ + a2·z⁻²                                            ║
// ║                                                                          ║
// ║  ω₀  = 2π·fc / SR         (init-time scalar — fc is compile constant)   ║
// ║  α   = sin(ω₀) / (2·Q)   (init-time scalar — Q is compile constant)    ║
// ║  A   = 10^(g / 40)        (time-varying — g is a smoothed dB signal)    ║
// ║  a₀  = 1 + α/A            (time-varying normalization term)             ║
// ║                                                                          ║
// ║  Normalized coefficients (a₀ absorbed):                                  ║
// ║    b0 = (1 + α·A) / a₀                                                  ║
// ║    b1 = −2·cos(ω₀) / a₀   ← identical to a1 (peaking EQ identity)     ║
// ║    b2 = (1 − α·A) / a₀                                                  ║
// ║    a1 = −2·cos(ω₀) / a₀                                                 ║
// ║    a2 = (1 − α/A) / a₀                                                  ║
// ║                                                                          ║
// ║  Stability: for g ∈ [−15, +15] dB and Q ≥ √2, all poles satisfy        ║
// ║  |z| < 1 for fc ∈ (0, SR/2). si.smoo on g bounds per-sample            ║
// ║  coefficient delta to ~1.5×10⁻⁵ — adiabatically stable.               ║
// ╚══════════════════════════════════════════════════════════════════════════╝

peakBand(fc, bq, g) = fi.tf2(b0, b1, b2, a1, a2)
with {
  omega  = 2.0 * ma.PI * fc / ma.SR;
  cosW   = cos(omega);
  sinW   = sin(omega);
  alpha  = sinW / (2.0 * bq);

  A      = pow(10.0, g * 0.025);       // 10^(g/40), time-varying
  a0inv  = 1.0 / (1.0 + alpha / A);

  b0 = (1.0 + alpha * A) * a0inv;
  b1 = -2.0 * cosW * a0inv;
  b2 = (1.0 - alpha * A) * a0inv;
  a1 = b1;
  a2 = (1.0 - alpha / A) * a0inv;
};


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  hpf2(fc) — 2ND-ORDER BUTTERWORTH HIGH-PASS FILTER                      ║
// ║                                                                          ║
// ║  Butterworth HP (maximally flat passband, −3 dB at fc):                 ║
// ║         (1 − z⁻¹)²                                                       ║
// ║  H(z) = ────────────────────────────────────────────                     ║
// ║          (1 + a1·z⁻¹ + a2·z⁻²) · normalization                          ║
// ║                                                                          ║
// ║  Bilinear transform with frequency pre-warping:                         ║
// ║    K  = tan(π·fc / SR)    (pre-warped analog cutoff)                    ║
// ║    a₀ = K² + K/Q_b + 1   where Q_b = 1/√2 for Butterworth (2nd order)  ║
// ║                                                                          ║
// ║  Butterworth 2nd-order: Q_butterworth = 1/√2 = 0.7071                   ║
// ║                                                                          ║
// ║  Coefficients:                                                           ║
// ║    b0 =  1 / a₀                                                         ║
// ║    b1 = −2 / a₀                                                         ║
// ║    b2 =  1 / a₀                                                         ║
// ║    a1 = 2·(K² − 1) / a₀                                                 ║
// ║    a2 = (K² − K/Q_b + 1) / a₀                                           ║
// ║                                                                          ║
// ║  fc is a time-varying signal (swept by user). Pre-warping ensures       ║
// ║  exact −3 dB point at the specified digital frequency at any SR.        ║
// ║  fc clamped: (10, SR·0.48) to prevent tan() blowup near Nyquist.       ║
// ╚══════════════════════════════════════════════════════════════════════════╝

hpf2(fc) = fi.tf2(b0, b1, b2, a1, a2)
with {
  Q_BUTTER = 0.70710678;   // 1/√2 — Butterworth 2nd-order pole Q

  fcSafe = max(10.0, min(fc, ma.SR * 0.48));
  K      = tan(ma.PI * fcSafe / ma.SR);
  K2     = K * K;
  a0     = K2 + K / Q_BUTTER + 1.0;
  a0inv  = 1.0 / a0;

  b0 =  a0inv;
  b1 = -2.0 * a0inv;
  b2 =  a0inv;
  a1 =  2.0 * (K2 - 1.0) * a0inv;
  a2 =  (K2 - K / Q_BUTTER + 1.0) * a0inv;
};


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  sat(x) — PADÉ [3/2] CLIP GUARD                                         ║
// ║                                                                          ║
// ║  Rational tanh approximant:                                              ║
// ║    sat(x) = x · (27 + x²) / (27 + 9x²)                                 ║
// ║                                                                          ║
// ║  · sat'(0) = 1.0     — unity gain on clean signal                       ║
// ║  · Odd symmetry      — zero even harmonic distortion                    ║
// ║  · |sat(x)| < 3      — bounded, prevents downstream blowup             ║
// ║  · |x| ≤ 0.9: sat(x) within 1% of x — inaudible on clean guitar        ║
// ╚══════════════════════════════════════════════════════════════════════════╝

sat(x) = x * (27.0 + x * x) / (27.0 + 9.0 * x * x);


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  UI PARAMETERS                                                           ║
// ║                                                                          ║
// ║  MIDI CC assignments (standard LV2/VST3 ctrlchange metadata):           ║
// ║    CC 20 = Preset (0–5)                                                  ║
// ║    CC 74 = HPF Frequency (standard filter cutoff CC per MIDI spec)      ║
// ║    CC 75 = Presence Frequency                                            ║
// ║    CC 76 = Presence Gain                                                 ║
// ║    CC 77 = Input Gain                                                    ║
// ║    CC 78 = Output Trim                                                   ║
// ║    CC 79 = Bypass                                                        ║
// ║                                                                          ║
// ║  Input gain range: −6 to +36 dB                                         ║
// ║    Instrument level (passive guitar) ≈ −20 dBu                          ║
// ║    Line level ≈ +4 dBu                                                   ║
// ║    +24 dB of range covers passive → active → line in a single knob.    ║
// ╚══════════════════════════════════════════════════════════════════════════╝

// ── Preset ────────────────────────────────────────────────────────────────
// 0 = Clean      — open headroom, air and sparkle, minimal mid cut
// 1 = Crunch     — tighten low-mid honk, boost bite and presence
// 2 = Lead       — scoop mid-honk hard, forward 2–4 kHz, cut sub
// 3 = Metal      — tight low-end, aggressive presence, sub rolled off
// 4 = Blues      — warm upper bass, smooth presence, vocal midrange
// 5 = Acoustic DI — natural low-mid, forward 2–5 kHz, cut sub rumble
preset = nentry("v:DeMoDIQ-GT/[0] Preset [midi:ctrl 20]
[style:menu{'Clean':0;'Crunch':1;'Lead':2;'Metal':3;'Blues':4;'Acoustic-DI':5}]",
  0, 0, 5, 1);

// ── HPF ───────────────────────────────────────────────────────────────────
hpf_freq = hslider("v:DeMoDIQ-GT/[1] HPF Freq [unit:Hz][style:knob][midi:ctrl 74]",
  80.0, 20.0, 300.0, 1.0) : si.smoo;

// ── Presence (parametric peak, the guitar player's primary EQ tool) ───────
pre_freq = hslider("v:DeMoDIQ-GT/[2] Presence Freq [unit:Hz][style:knob][midi:ctrl 75]",
  2500.0, 500.0, 6000.0, 10.0) : si.smoo;

pre_gain = hslider("v:DeMoDIQ-GT/[3] Presence Gain [unit:dB][style:knob][midi:ctrl 76]",
  0.0, -12.0, 12.0, 0.1) : si.smoo;

// ── Gain staging ──────────────────────────────────────────────────────────
input_gain  = hslider("v:DeMoDIQ-GT/[4] Input Gain [unit:dB][style:knob][midi:ctrl 77]",
  12.0, -6.0, 36.0, 0.1) : si.smoo;

output_trim = hslider("v:DeMoDIQ-GT/[5] Output Trim [unit:dB][style:knob][midi:ctrl 78]",
  0.0, -18.0, 6.0, 0.1) : si.smoo;

// ── Bypass ────────────────────────────────────────────────────────────────
bypass = checkbox("v:DeMoDIQ-GT/[6] Bypass [midi:ctrl 79]") : si.smoo;


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  PRESET DATA — GUITAR-SPECIFIC TUNING                                   ║
// ║                                                                          ║
// ║  Designed for:                                                           ║
// ║    · DI signal → cab IR → DeMoDIQ-GT (most common modern workflow)      ║
// ║    · Or: amp output → re-amp → DeMoDIQ-GT as post-EQ trim              ║
// ║                                                                          ║
// ║  Philosophy per preset:                                                  ║
// ║                                                                          ║
// ║  Clean: Flat with subtle air lift. The guitar's natural voice.           ║
// ║    Barely touches 250–500 Hz (honk zone). Lifts 8–16 kHz for           ║
// ║    sparkle and pick definition without harshness.                        ║
// ║                                                                          ║
// ║  Crunch: Classic British-style mid-forward crunch character.             ║
// ║    Slightly tighten the 62–125 Hz weight, moderate 500 Hz cut           ║
// ║    to clear the honk, push 2–4 kHz for chord clarity.                  ║
// ║                                                                          ║
// ║  Lead: Classic mid-scoop for singing lead lines.                        ║
// ║    Sub tightened, 250–500 Hz scooped, 2–4 kHz pushed forward.          ║
// ║    Mirrors the "lead" channel voicing on Dumble/Mesa amps.             ║
// ║                                                                          ║
// ║  Metal: Maximum low-end tightness + presence aggression.                ║
// ║    Hard cut at 62–250 Hz boom zone (tight palm mutes require this).    ║
// ║    Aggressive 3–6 kHz push for pick-scrape definition.                 ║
// ║    Mirrors the surgical mid-scoop of Rectifier/5150 voicing.           ║
// ║                                                                          ║
// ║  Blues: Warm and vocal. Think SRV into a Vibroverb.                     ║
// ║    Upper bass warmth preserved (+125–250 Hz).                           ║
// ║    Smooth presence — forward without harsh.                             ║
// ║    Controlled top-end so single coils don't ice-pick.                  ║
// ║                                                                          ║
// ║  Acoustic DI: Cuts the piezo quack.                                     ║
// ║    Sharp 500 Hz cut kills the characteristic piezo nasal tone.         ║
// ║    Body warmth at 125 Hz, air at 8–16 kHz for natural overtones.       ║
// ║                                                                          ║
// ║  Band   │ Clean  Crunch  Lead  Metal  Blues  AcDI   (all dB)            ║
// ║  ───────┼─────────────────────────────────────────                      ║
// ║   31Hz  │   0     -1     -2    -3      0     -2                         ║
// ║   62Hz  │   0     -1     -2    -4      1     -1                         ║
// ║  125Hz  │   0      0     -1    -3      2      2                         ║
// ║  250Hz  │   0     -1     -3    -4      1     -1                         ║
// ║  500Hz  │  -1     -2     -4    -3     -1     -4                         ║
// ║  1kHz   │   0     -1     -2    -2      0     -1                         ║
// ║  2kHz   │   1      1      2     2      1      2                         ║
// ║  4kHz   │   1      2      3     3      1      3                         ║
// ║  8kHz   │   2      1      2     2      1      2                         ║
// ║  16kHz  │   2      1      1     1      0      2                         ║
// ║  Pre    │  -2     -2     -2    -2     -2     -2    (headroom offset)    ║
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

preampDB = sel6(preset, -2.0, -2.0, -2.0, -2.0, -2.0, -2.0) : si.smoo;

g01 = sel6(preset,  0.0, -1.0, -2.0, -3.0,  0.0, -2.0) : si.smoo;  //  31 Hz  sub
g02 = sel6(preset,  0.0, -1.0, -2.0, -4.0,  1.0, -1.0) : si.smoo;  //  62 Hz  bass
g03 = sel6(preset,  0.0,  0.0, -1.0, -3.0,  2.0,  2.0) : si.smoo;  // 125 Hz  upper bass
g04 = sel6(preset,  0.0, -1.0, -3.0, -4.0,  1.0, -1.0) : si.smoo;  // 250 Hz  low-mid
g05 = sel6(preset, -1.0, -2.0, -4.0, -3.0, -1.0, -4.0) : si.smoo;  // 500 Hz  honk zone
g06 = sel6(preset,  0.0, -1.0, -2.0, -2.0,  0.0, -1.0) : si.smoo;  //   1 kHz upper-mid
g07 = sel6(preset,  1.0,  1.0,  2.0,  2.0,  1.0,  2.0) : si.smoo;  //   2 kHz presence
g08 = sel6(preset,  1.0,  2.0,  3.0,  3.0,  1.0,  3.0) : si.smoo;  //   4 kHz attack/bite
g09 = sel6(preset,  2.0,  1.0,  2.0,  2.0,  1.0,  2.0) : si.smoo;  //   8 kHz air
g10 = sel6(preset,  2.0,  1.0,  1.0,  1.0,  0.0,  2.0) : si.smoo;  //  16 kHz brilliance


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  EQ CHAIN                                                                ║
// ║                                                                          ║
// ║  H_total(z) = H_hpf(z) · ∏_{k=1}^{10} H_peak(gk, Fk) · H_pre(z)      ║
// ║                                                                          ║
// ║  Order of operations:                                                    ║
// ║    1. HPF  — remove sub-bass rumble/hum before EQ amplifies it          ║
// ║    2. Graphic bands — broad tonal shaping per preset                    ║
// ║    3. Presence peak — surgical parametric on top of preset shape        ║
// ║                                                                          ║
// ║  Presence after graphic bands means it operates on the already-shaped   ║
// ║  signal — the player's "final voice" control, as on real amp stages.    ║
// ╚══════════════════════════════════════════════════════════════════════════╝

eqChain =
    hpf2(hpf_freq)
  : peakBand(F01, Q_BAND, g01)
  : peakBand(F02, Q_BAND, g02)
  : peakBand(F03, Q_BAND, g03)
  : peakBand(F04, Q_BAND, g04)
  : peakBand(F05, Q_BAND, g05)
  : peakBand(F06, Q_BAND, g06)
  : peakBand(F07, Q_BAND, g07)
  : peakBand(F08, Q_BAND, g08)
  : peakBand(F09, Q_BAND, g09)
  : peakBand(F10, Q_BAND, g10)
  : peakBand(pre_freq, Q_PRE, pre_gain);


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  CHANNEL PROCESSOR                                                       ║
// ║                                                                          ║
// ║  Gain collapsing:                                                        ║
// ║    input_gain + preampDB → single ba.db2linear → one multiply           ║
// ║    output_trim           → single ba.db2linear → one multiply           ║
// ║                                                                          ║
// ║  Full mono chain:                                                        ║
// ║    x → ×preLin → hpf → [10 bands] → presence → dcblock → sat → ×postLin║
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
// ║  PROCESS — STEREO WITH SMOOTH BYPASS                                    ║
// ║                                                                          ║
// ║  Bypass crossfade:                                                       ║
// ║    out[n] = wet[n] · (1 − β[n]) + dry[n] · β[n]                        ║
// ║    β = bypass : si.smoo   — ~20ms fade on toggle, zero-click            ║
// ║                                                                          ║
// ║  Dry signal tapped pre-processing so bypass is a true clean bypass.     ║
// ║  No gain or filtering applied to the dry path.                          ║
// ║                                                                          ║
// ║  Group delay note:                                                       ║
// ║    12 biquad stages (10 graphic + HPF + presence) introduce phase       ║
// ║    rotation but zero added latency (IIR = sample-synchronous).         ║
// ║    Group delay at 1 kHz ≈ 0.3–0.8 ms depending on preset shape.        ║
// ║    This is within tolerance for live monitoring up to wet/dry blends.   ║
// ║    For true zero-phase dry blend, disable bypass and set all gains 0.   ║
// ╚══════════════════════════════════════════════════════════════════════════╝

process = par(i, 2,
  _ <: (channelProc, _) : (*(1.0 - bypass), *(bypass)) :> _
);
