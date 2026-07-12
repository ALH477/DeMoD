// ============================================================
//  DEMOD_EXCITER  —  Spectral Fold Harmonic Exciter
//  DeMoD LLC — Proprietary and Confidential
//  Copyright (c) 2026 DeMoD LLC. All rights reserved.
//  Unauthorized use, reproduction, or distribution is
//  strictly prohibited without written permission.
// ============================================================
//
//  What makes this exciter distinctive:
//
//  (1) FOLD-BACK WAVESHAPER  (not soft clipping)
//      Most exciter plugins isolate the high band and apply
//      soft/hard clipping, which generates harmonics that
//      taper off as 1/n (strong 2nd, weak 3rd, very weak 4th).
//
//      This exciter uses fold-back distortion:
//        f(x, t) = x           when |x| <= t
//        f(x, t) = 2t - x      when x  >  t
//        f(x, t) = -2t - x     when x  < -t
//
//      Fold reflects the signal at ±threshold like a mirror,
//      rather than clamping it. The resulting harmonic series
//      distributes energy more evenly across harmonics 2–6,
//      producing a dense, shimmering upper register character
//      distinct from both soft clipping and hard clipping.
//
//  (2) MULTI-STAGE FOLD
//      The fold can be applied twice: a second fold on the
//      already-folded signal creates harmonic content at
//      even higher overtones — useful for extreme argent-metal
//      brightness without raising the base frequency.
//
//  (3) TUNABLE EXCITE BAND
//      The crossover frequency is user-controlled, so the
//      fold can target upper mids (1–2 kHz) for cut-through
//      presence, or higher (3–5 kHz) for air and shimmer.
//      Only the isolated band is processed — the fundamentals
//      are always preserved in full.
//
//  (4) PARALLEL BLEND (DRY + EXCITED)
//      The processed band is mixed back in parallel with the
//      original full-range signal. Exciter Mix = 0 is fully
//      transparent; Mix = 1 adds maximum fold harmonic content.
//
// ============================================================

declare name        "DeMoDExciter";
declare version     "1.0";
declare author      "DeMoD LLC";
declare description "Spectral fold-back harmonic exciter with tunable band";
declare copyright   "Copyright (c) 2026 DeMoD LLC. All rights reserved.";

import("stdfaust.lib");

// ─── utilities ───────────────────────────────────────────────

slew(tau) = si.smooth(ba.tau2pole(tau));
SLEW      = 0.005;


// ─── fold-back waveshaper ─────────────────────────────────────
//  Reflects signal at ±threshold boundaries.
//  Applied once: strong 2nd–4th harmonics.
//  Applied twice: rich 2nd–6th harmonics, more complex texture.
//
//  Note: unary minus on a signal avoids parser ambiguity
//  by writing (0.0 - x) rather than (-x).

single_fold(t, x) = result
with {
    t_safe = max(t, 0.001);
    above  = x > t_safe;
    below  = x < (0.0 - t_safe);
    result = select2(above,
                 select2(below, x, (0.0 - 2.0*t_safe) - x),
                 2.0*t_safe - x);
};

double_fold(t, x) = single_fold(t, single_fold(t, x));


// ─── controls ────────────────────────────────────────────────

excite_freq = hslider("v:DeMoD Exciter/[1]Excite Freq [unit:Hz]
    [tooltip:Crossover — only frequencies above this are processed]
    [style:knob]",
    2000.0, 500.0, 8000.0, 10.0) : slew(0.05);

fold_thresh = hslider("v:DeMoD Exciter/[2]Fold Threshold
    [tooltip:Fold threshold — lower = more harmonic content generated]
    [style:knob]",
    0.4, 0.05, 1.0, 0.001) : slew(SLEW);

fold_stages = hslider("v:DeMoD Exciter/[3]Stages
    [tooltip:1 = single fold (bright), 2 = double fold (dense shimmer)]
    [style:knob]",
    1.0, 1.0, 2.0, 1.0);

excite_mix = hslider("v:DeMoD Exciter/[4]Mix
    [tooltip:Blend of excited harmonics into the output]
    [style:knob]",
    0.3, 0.0, 1.0, 0.001) : slew(SLEW);

// Presence peak: subtle resonant boost at 1.5x the excite frequency
// adds a formant-like peak that glues the new harmonics to the source
presence_db = hslider("v:DeMoD Exciter/[5]Presence [unit:dB]
    [tooltip:Resonant peak at 1.5x excite frequency for harmonic glue]
    [style:knob]",
    2.0, 0.0, 9.0, 0.1) : slew(SLEW);

output_db = hslider("v:DeMoD Exciter/[6]Output [unit:dB]
    [tooltip:Output level]
    [style:knob]",
    0.0, -12.0, 6.0, 0.1) : slew(SLEW) : ba.db2linear;

bypass = checkbox("v:DeMoD Exciter/[0]Bypass");
bp     = bypass : si.smooth(ba.tau2pole(0.003));


// ─── excite band isolation ────────────────────────────────────
//  2nd order highpass isolates the excite band.
//  Low band is preserved untouched and summed back at the end.

high_band(x) = fi.highpass(2, excite_freq, x);
low_band(x)  = fi.lowpass(2, excite_freq, x);


// ─── fold processor ──────────────────────────────────────────
//  Applied to the isolated high band only.

fold_process(x) = select2(fold_stages > 1.5,
    single_fold(fold_thresh, x),
    double_fold(fold_thresh, x));


// ─── presence peak ───────────────────────────────────────────
//  Subtle resonant peak at 1.5x excite_freq. Helps generated
//  harmonics blend with the dry signal rather than sitting on top.
//  Bandwidth = excite_freq / 2 in Hz for consistent Q across sweep.

presence_freq  = excite_freq * 1.5;
presence_bw    = excite_freq * 0.5;

presence_peak(x) = fi.peak_eq(presence_db, presence_freq, presence_bw, x);


// ─── full mono exciter chain ──────────────────────────────────

exciter(x) =
    low_band(x)
  + ( high_band(x) : fold_process : *(excite_mix)
    + high_band(x) : *(1.0 - excite_mix) )
  : presence_peak;


// ─── stereo process ───────────────────────────────────────────

process(L, R) = out_L * output_db, out_R * output_db
with {
    wet_L = exciter(L);
    wet_R = exciter(R);
    out_L = wet_L * (1.0 - bp) + L * bp;
    out_R = wet_R * (1.0 - bp) + R * bp;
};
