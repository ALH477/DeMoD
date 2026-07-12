import("stdfaust.lib");

// ╔══════════════════════════════════════════════════════════════════════╗
// ║  DECIMATOR v1.0 — Nu Metal Distortion Unit                         ║
// ║  DeMoD LLC                                                          ║
// ╠══════════════════════════════════════════════════════════════════════╣
// ║  Signal Chain:                                                       ║
// ║                                                                      ║
// ║  Input → [Noise Gate] → [Pre-EQ] → [Asymmetric Tube Clipper]       ║
// ║        → [Scooped Tone Stack] → [4×12 Cab Sim] → Output            ║
// ║                                                                      ║
// ╠══════════════════════════════════════════════════════════════════════╣
// ║  WAVESHAPING MATH                                                    ║
// ║                                                                      ║
// ║  Asymmetric hyperbolic tangent saturation:                           ║
// ║                                                                      ║
// ║    For x ≥ 0 (positive rail — soft, triode plate behavior):         ║
// ║      f⁺(x) = tanh(k·x)                                             ║
// ║                                                                      ║
// ║    For x < 0 (negative rail — harder, cathode follower behavior):   ║
// ║      f⁻(x) = tanh(k·α·x) / α,   α = 1.5                           ║
// ║                                                                      ║
// ║    Normalized output:                                                ║
// ║      y = f(x) / tanh(k)                                             ║
// ║                                                                      ║
// ║  Why this works:                                                     ║
// ║    • Symmetric tanh → only ODD harmonics (3rd, 5th...) = thin buzz  ║
// ║    • Asymmetry (α ≠ 1) → EVEN harmonics too (2nd, 4th...)          ║
// ║    • Combined spectrum = thick, full, "beefy" nu metal crunch       ║
// ║    • Higher k → harder clip → more high-order harmonics → grit      ║
// ║                                                                      ║
// ║  Fourier series of asymmetric clipped sine (input A·sin(ωt)):       ║
// ║    y = Σ [aₙ·cos(nωt) + bₙ·sin(nωt)]                              ║
// ║    aₙ ≠ 0 when asymmetric (even harmonics present)                  ║
// ║    bₙ ≠ 0 for all n (odd harmonics from tanh nonlinearity)          ║
// ╚══════════════════════════════════════════════════════════════════════╝

// ─────────────────────────────────────────────────────────────────────────
// CONTROLS
// ─────────────────────────────────────────────────────────────────────────
drive    = hslider("v:DECIMATOR/[1] Drive[style:knob][unit:%%]",
                    40.0,  1.0, 80.0, 0.1) : si.smoo;

bass     = hslider("v:DECIMATOR/[2] Bass[style:knob][unit:dB]",
                     6.0, -12.0, 12.0, 0.1) : si.smoo;

mid      = hslider("v:DECIMATOR/[3] Mid[style:knob][unit:dB]",
                   -10.0, -18.0,  6.0, 0.1) : si.smoo;

presence = hslider("v:DECIMATOR/[4] Presence[style:knob][unit:dB]",
                     4.0, -12.0, 12.0, 0.1) : si.smoo;

gate_db  = hslider("v:DECIMATOR/[5] Gate[style:knob][unit:dB]",
                   -50.0, -80.0,  0.0, 1.0) : si.smoo;

vol      = hslider("v:DECIMATOR/[6] Volume[style:knob]",
                     0.7,   0.0,  1.0, 0.01) : si.smoo;


// ─────────────────────────────────────────────────────────────────────────
// NOISE GATE
// ─────────────────────────────────────────────────────────────────────────
// RMS envelope follower with fast attack / slow release.
// Computes:   env = sqrt( x² * (1-c_att) + env_prev * c_att )
// Gate is binary: 0 when env < threshold, 1 when above.
// This gives the characteristic "tight" chug of nu metal — no bloom.
//
noise_gate(thresh_db) = _ <: sidechain, _ : *
with {
  c_att    = exp(-1.0 / (0.001 * ma.SR));   // 1ms attack time constant
  c_rel    = exp(-1.0 / (0.080 * ma.SR));   // 80ms release time constant
  rms_env  = _ * _ : leak_int : sqrt
  with {
    // Leaky integrator: y[n] = c*y[n-1] + (1-c)*x[n]
    leak_int = _ : + ~ *(c_rel) : *(1.0 - c_rel);
  };
  threshold = ba.db2linear(thresh_db);
  sidechain = rms_env : >(threshold);
};


// ─────────────────────────────────────────────────────────────────────────
// PRE-EQ
// ─────────────────────────────────────────────────────────────────────────
// +4dB low shelf at 150Hz.
// Boosts bass fundamentals BEFORE clipping — fat low strings distort
// harder, thin high strings clip less. This is why nu metal has that
// "chunk" on low chords but stays articulate on high notes.
//
pre_eq = fi.low_shelf(4.0, 150.0);


// ─────────────────────────────────────────────────────────────────────────
// ASYMMETRIC WAVESHAPER
// ─────────────────────────────────────────────────────────────────────────
// Split signal into positive and negative half-waves,
// apply different tanh slopes, recombine.
//
// f⁺(u) = tanh(u)          where u = k·max(x, 0)
// f⁻(u) = tanh(α·u) / α   where u = k·min(x, 0),  α = 1.5
//
asym_clip = _ <: pos_rail, neg_rail :> _
with {
  alpha    = 1.5;
  pos_rail = max(0.0) : ma.tanh;
  neg_rail = min(0.0) : *(alpha) : ma.tanh : /(alpha);
};

// Full distortion stage:
//   1. Scale input by k (drive coefficient)
//   2. Apply asymmetric clip
//   3. Normalize by tanh(k) so unity-gain input → ~unity-gain output
//   4. 1.5× makeup gain (clipping is lossy)
//
distortion(drv) = _ * k : asym_clip : *(norm) : *(1.5)
with {
  k    = drv / 8.0;
  norm = 1.0 / ma.tanh(k);
};


// ─────────────────────────────────────────────────────────────────────────
// SCOOPED TONE STACK
// ─────────────────────────────────────────────────────────────────────────
// The defining EQ signature of nu metal:
//
//   Stage 1 — Bass boost    ~80Hz   Q≈1.5  (+bass dB)
//             Deep low end, earthquake fundamental
//
//   Stage 2 — Mid scoop     ~700Hz  Q≈1.8  (mid dB, usually negative)
//             The classic "hollow" scooped sound. Cuts the
//             200–1200Hz range that gives guitar its nasal character.
//             Bandwidth = 700/1.8 ≈ 390Hz
//
//   Stage 3 — Presence peak ~3.5kHz Q≈1.5  (+presence dB)
//             Pick attack, string definition, "djent" transient click.
//             Bandwidth = 3500/1.5 ≈ 2333Hz
//
tone_stack =
  fi.peak_eq(bass,     80.0,  54.0)  :   // bw = 80/1.5
  fi.peak_eq(mid,     700.0, 390.0)  :   // bw = 700/1.8
  fi.peak_eq(presence,3500.0,2333.0) ;   // bw = 3500/1.5


// ─────────────────────────────────────────────────────────────────────────
// 4×12 CABINET SIMULATION
// ─────────────────────────────────────────────────────────────────────────
// Models a Celestion-loaded 4×12 closed-back cab:
//
//   Stage 1 — Highpass   80Hz   order 2
//             Speakers physically can't reproduce sub-bass.
//             Cuts the mud that distortion generates below 80Hz.
//
//   Stage 2 — Resonance  120Hz  Q=4  (+3dB)
//             Speaker cone mechanical resonance (Fs).
//             Adds that "thump" on palm mutes and kick drum bleed.
//             Bandwidth = 120/4 = 30Hz
//
//   Stage 3 — Lowpass    5.5kHz order 3
//             Cone breakup rolloff. Real speakers stop moving above ~5kHz.
//             Softens digital harshness, makes it sound like air moved.
//
//   Stage 4 — Air notch  1.2kHz Q=2  (-3dB)
//             Cabinet internal resonance cancellation. The "boxiness"
//             dip present in most closed-back cabs.
//             Bandwidth = 1200/2 = 600Hz
//
//   Stage 5 — Bite peak  4kHz   Q=2  (+2dB)
//             Tweeter/dust cap presence. Definition and "air" above
//             the cab dip. Gives pick attack its snap.
//             Bandwidth = 4000/2 = 2000Hz
//
cab_sim =
  fi.highpass(2, 80.0)          :
  fi.peak_eq( 3.0, 120.0,  30.0) :
  fi.lowpass(3, 5500.0)         :
  fi.peak_eq(-3.0, 1200.0, 600.0) :
  fi.peak_eq( 2.0, 4000.0,2000.0) ;


// ─────────────────────────────────────────────────────────────────────────
// MASTER PROCESS
// ─────────────────────────────────────────────────────────────────────────
process = _
  : noise_gate(gate_db)
  : pre_eq
  : distortion(drive)
  : tone_stack
  : cab_sim
  : *(vol);
