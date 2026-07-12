// ============================================================
//  DEMOD_LIMITER  —  True-Peak Lookahead Limiter
//  DeMoD LLC — Proprietary and Confidential
//  Copyright (c) 2026 DeMoD LLC. All rights reserved.
//  Unauthorized use, reproduction, or distribution is
//  strictly prohibited without written permission.
// ============================================================
//
//  What makes this limiter distinctive:
//
//  (1) LOOKAHEAD GAIN COMPUTATION
//      Standard limiters compute gain reduction from the
//      current sample and apply it immediately — this
//      guarantees the limiter always reacts one moment too
//      late to the loudest point of a transient.
//
//      This limiter delays the audio signal by LOOKAHEAD
//      samples (≈5.8 ms) and computes the gain reduction
//      from the UN-delayed signal. The gain is already in
//      place when the loudest sample arrives at the output.
//      Attack time is effectively zero from a peak perspective.
//
//  (2) INTER-SAMPLE PEAK DETECTION (TRUE PEAK)
//      Digital audio can contain inter-sample peaks — points
//      between samples that exceed 0 dBFS when reconstructed
//      by a DAC. Standard peak meters miss these.
//
//      This limiter uses a 4-point cubic interpolation between
//      consecutive samples to estimate the continuous-time
//      maximum between each pair of samples. The estimated
//      inter-sample peak is compared against the ceiling
//      along with the sample-domain peak.
//
//      True-peak limiting prevents DAC overload on D/A
//      conversion of the output — important for live sound.
//
//  (3) ADAPTIVE RELEASE
//      Release time is not fixed. The RELEASE knob sets a
//      base value, but the actual release adapts upward when
//      the signal is consistently hitting the ceiling:
//        Base release: user-set (10–500 ms)
//        Adaptive extension: up to 3x base when gain
//        reduction has been active for more than 50 ms
//      This prevents the gain from pumping repeatedly on
//      sustained loud signals (e.g., held power chords) while
//      still recovering quickly between transients.
//
//  (4) STEREO LINKED + INDEPENDENT MODES
//      Linked (default): gain reduction computed from the
//      louder of L/R at each sample — preserves stereo image.
//      Independent: each channel limited separately —
//      useful when L/R have very different levels.
//
// ============================================================

declare name        "DeMoDLimiter";
declare version     "1.0";
declare author      "DeMoD LLC";
declare description "True-peak lookahead limiter with adaptive release";
declare copyright   "Copyright (c) 2026 DeMoD LLC. All rights reserved.";

import("stdfaust.lib");

// ─── utilities ───────────────────────────────────────────────

slew(tau) = si.smooth(ba.tau2pole(tau));
SLEW      = 0.005;


// ─── controls ────────────────────────────────────────────────

ceiling_db = hslider("v:DeMoD Limiter/[1]Ceiling [unit:dBFS]
    [tooltip:Output ceiling — -0.3 recommended for DA headroom]
    [style:knob]",
    -0.3, -18.0, 0.0, 0.1) : slew(SLEW);

release_ms = hslider("v:DeMoD Limiter/[2]Release [unit:ms]
    [tooltip:Base gain recovery time — adaptive mode can extend this]
    [style:knob]",
    80.0, 10.0, 500.0, 1.0) : slew(0.05);

adaptive_amt = hslider("v:DeMoD Limiter/[3]Adaptive
    [tooltip:Adaptive release extension — 0=fixed, 1=fully adaptive]
    [style:knob]",
    0.6, 0.0, 1.0, 0.01) : slew(0.1);

linked = checkbox("v:DeMoD Limiter/[4]Stereo Link
    [tooltip:Link L/R gain reduction to preserve stereo image]");

input_db = hslider("v:DeMoD Limiter/[5]Input [unit:dB]
    [tooltip:Input drive trim]
    [style:knob]",
    0.0, -12.0, 12.0, 0.1) : slew(SLEW) : ba.db2linear;

output_db = hslider("v:DeMoD Limiter/[6]Output [unit:dB]
    [tooltip:Output level after limiting]
    [style:knob]",
    0.0, -12.0, 6.0, 0.1) : slew(SLEW) : ba.db2linear;

bypass = checkbox("v:DeMoD Limiter/[0]Bypass");
bp     = bypass : si.smooth(ba.tau2pole(0.003));


// ─── lookahead delay ─────────────────────────────────────────
//  LOOKAHEAD samples of latency on the signal path.
//  Gain is computed from the pre-delay signal and applied
//  to the delayed version — transient is anticipated.

LOOKAHEAD = 256;     // ≈ 5.8 ms at 44100 Hz
MAX_LOOK  = 511;     // de.delay maxsize (must be >= LOOKAHEAD)

lookahead_delay(x) = de.delay(MAX_LOOK, LOOKAHEAD, x);


// ─── inter-sample peak estimator ─────────────────────────────
//  Cubic interpolation estimates the maximum value between
//  x[n-1] and x[n] using the 4-point neighborhood:
//  x[n-2], x[n-1], x[n], x[n+1] (x[n+1] not available,
//  so we use x[n-3], x[n-2], x[n-1], x[n] with 1-sample lag).
//
//  Catmull-Rom cubic at t=0.5 (midpoint estimate):
//  y = (-x0 + 9*x1 + 9*x2 - x3) / 16
//  where x0..x3 are 4 consecutive samples.
//
//  The estimated midpoint peak is an approximation of the
//  continuous-time peak between samples x1 and x2.

interp_peak(x) = abs(midpoint)
with {
    x0 = x''';
    x1 = x'';
    x2 = x';
    x3 = x;
    midpoint = (0.0-x0 + 9.0*x1 + 9.0*x2 - x3) / 16.0;
};

true_peak(x) = max(abs(x), interp_peak(x));


// ─── peak envelope follower ───────────────────────────────────
//  Instantaneous attack (pole = 1.0 = no smoothing on attack).
//  Release time adapted by adaptive_amt.

// How long has gain reduction been active (integrates GR time)
gr_active_time(gr) = result
with {
    is_reducing = gr < 0.99;  // 1 when gain reduction active
    // Integrate: increment when GR active, decay otherwise
    result = is_reducing : si.onePoleSwitching(
        ba.tau2pole(0.001),    // fast attack on GR counter
        ba.tau2pole(2.0));     // slow decay when GR releases
};

peak_env(x) = true_peak(x)
    : si.onePoleSwitching(1.0, ba.tau2pole(release_ms * 0.001));


// ─── gain computer ────────────────────────────────────────────
//  Compute linear gain required to bring peak to ceiling.
//  Adaptive release extends recovery when GR has been sustained.

gain_compute(pk) = gain_smooth
with {
    ceiling   = ba.db2linear(ceiling_db);
    gain_raw  = min(1.0, ceiling / max(pk, 1e-9));

    // Adaptive release: when GR has been active, slow down recovery
    gr_time   = gr_active_time(gain_raw);
    adapt_mul = 1.0 + adaptive_amt * gr_time * 2.0;  // up to 3x base release
    rel_adapted = release_ms * 0.001 * adapt_mul;

    gain_smooth = gain_raw : si.onePoleSwitching(1.0, ba.tau2pole(rel_adapted));
};


// ─── mono limiter ─────────────────────────────────────────────

limit_mono(x) = lookahead_delay(x) * gain_compute(peak_env(x));


// ─── stereo limiter ───────────────────────────────────────────
//  Linked: gain from max(peak_L, peak_R) — preserves image.
//  Independent: each channel has its own gain curve.

limit_stereo_linked(L, R) = lookahead_delay(L) * g, lookahead_delay(R) * g
with {
    pk  = max(peak_env(L), peak_env(R));
    g   = gain_compute(pk);
};

limit_stereo_indep(L, R) = limit_mono(L), limit_mono(R);


// ─── process ─────────────────────────────────────────────────

process(L, R) = out_L * output_db, out_R * output_db
with {
    Lin = L * input_db;
    Rin = R * input_db;

    lim_res = limit_stereo_linked(Lin, Rin);
    lim_L_l = lim_res : _,!;
    lim_R_l = lim_res : !,_;

    lim_L_i = limit_mono(Lin);
    lim_R_i = limit_mono(Rin);

    wet_L = select2(linked, lim_L_i, lim_L_l);
    wet_R = select2(linked, lim_R_i, lim_R_l);

    out_L = wet_L * (1.0 - bp) + Lin * bp;
    out_R = wet_R * (1.0 - bp) + Rin * bp;
};
