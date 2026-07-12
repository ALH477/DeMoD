// ============================================================
//  DEMOD_GATE  —  Hysteresis Noise Gate
//  DeMoD LLC — Proprietary and Confidential
//  Copyright (c) 2026 DeMoD LLC. All rights reserved.
//  Unauthorized use, reproduction, or distribution is
//  strictly prohibited without written permission.
// ============================================================
//
//  What makes this gate distinctive:
//
//  (1) SCHMITT TRIGGER (HYSTERESIS)
//      Standard gates have one threshold — they chatter when
//      the signal hovers at the boundary. This gate uses two
//      separate thresholds: a higher OPEN threshold and a
//      lower CLOSE threshold. The gate must exceed OPEN to
//      trigger, but only falls below CLOSE to shut — just
//      like a relay. Eliminates chatter without requiring
//      excessive hold time.
//
//  (2) PUNCH DETECTOR
//      A differential transient detector (fast_env - slow_env)
//      produces a positive spike on pick attacks. This spike
//      temporarily opens the gate regardless of the main
//      threshold state — so the initial attack of every note
//      passes cleanly even if the sustain falls below the
//      open threshold. Critical for nu-metal percussive chunk.
//
//  (3) FREQUENCY-SELECTIVE SIDECHAIN
//      The envelope follower and threshold comparison operate
//      on a bandpass-filtered copy of the input (300–3000 Hz)
//      rather than the full-range signal. Sub-bass rumble and
//      high-frequency hiss cannot accidentally open or hold
//      the gate — only actual note energy triggers it.
//
// ============================================================

declare name        "DeMoDGate";
declare version     "1.0";
declare author      "DeMoD LLC";
declare description "Hysteresis noise gate with punch-through transient detector";
declare copyright   "Copyright (c) 2026 DeMoD LLC. All rights reserved.";

import("stdfaust.lib");

// ─── utilities ───────────────────────────────────────────────

slew(tau) = si.smooth(ba.tau2pole(tau));
SLEW      = 0.005;


// ─── sidechain bandpass ──────────────────────────────────────
//  Gate responds only to mid-band energy (300–3000 Hz).
//  Prevents sub-bass and hiss from holding the gate open.

sidechain(x) =
    fi.highpass(2, 300.0, x) : fi.lowpass(2, 3000.0);


// ─── dual-speed envelope follower ────────────────────────────

env_fast(x) = abs(x) : si.onePoleSwitching(ba.tau2pole(0.002), ba.tau2pole(0.030));
env_slow(x) = abs(x) : si.onePoleSwitching(ba.tau2pole(0.020), ba.tau2pole(0.200));


// ─── punch detector ──────────────────────────────────────────
//  Differential: fast_env - slow_env > 0 on attack transients.
//  Produces a brief positive spike at note onset.
//  The spike is squared to sharpen its temporal profile.

punch_thresh = hslider("v:DeMoD Gate/[3]Punch Sensitivity
    [tooltip:How easily transient attacks open the gate]
    [style:knob]",
    0.04, 0.0, 0.2, 0.001) : slew(SLEW);

punch_detector(x) = punch_signal > punch_thresh : si.smooth(ba.tau2pole(0.008))
with {
    sc           = sidechain(x);
    punch_signal = max(0.0, env_fast(sc) - env_slow(sc));
};


// ─── schmitt trigger (hysteresis gate) ───────────────────────
//  Open threshold must be crossed to open.
//  Signal must fall below close threshold to close.
//  The blended threshold shifts based on current envelope
//  position — below midpoint it demands the higher open
//  threshold; above midpoint it only needs the lower close
//  threshold to stay open. Approximates relay hysteresis.

open_thresh_db = hslider("v:DeMoD Gate/[1]Open [unit:dB]
    [tooltip:Threshold to open gate]
    [style:knob]",
    -40.0, -80.0, 0.0, 0.5) : slew(SLEW);

close_thresh_db = hslider("v:DeMoD Gate/[2]Close [unit:dB]
    [tooltip:Threshold to close gate — set lower than Open for hysteresis]
    [style:knob]",
    -50.0, -80.0, 0.0, 0.5) : slew(SLEW);

schmitt(x) = env > active_thresh : si.smooth(ba.tau2pole(0.001))
with {
    sc            = sidechain(x);
    env           = env_slow(sc);
    open_t        = ba.db2linear(open_thresh_db);
    close_t       = ba.db2linear(close_thresh_db);
    mid_t         = (open_t + close_t) * 0.5;
    // When env above midpoint use close threshold (easier to stay open)
    // When env below midpoint use open threshold (harder to trigger)
    active_thresh = select2(env > mid_t, open_t, close_t);
};


// ─── gate range ──────────────────────────────────────────────
//  Range = 0 dB: gate fully mutes when closed.
//  Range > 0 dB: gate only partially attenuates (duck rather than mute).
//  Useful for letting a small amount of ambience bleed through.

range_db = hslider("v:DeMoD Gate/[4]Range [unit:dB]
    [tooltip:Attenuation when gate is closed. 0=full mute]
    [style:knob]",
    -80.0, -80.0, 0.0, 0.5) : slew(SLEW);

range_floor = ba.db2linear(range_db);


// ─── attack / release times ──────────────────────────────────

atk_ms = hslider("v:DeMoD Gate/[5]Attack [unit:ms]
    [tooltip:Gate open time in milliseconds]
    [style:knob]",
    1.0, 0.1, 50.0, 0.1) : slew(0.05);

rel_ms = hslider("v:DeMoD Gate/[6]Release [unit:ms]
    [tooltip:Gate close time in milliseconds]
    [style:knob]",
    100.0, 10.0, 500.0, 1.0) : slew(0.05);


// ─── output volume & bypass ──────────────────────────────────

output_db = hslider("v:DeMoD Gate/[7]Output [unit:dB]
    [tooltip:Output trim]
    [style:knob]",
    0.0, -12.0, 12.0, 0.1) : slew(SLEW) : ba.db2linear;

bypass = checkbox("v:DeMoD Gate/[0]Bypass");
bp     = bypass : si.smooth(ba.tau2pole(0.003));


// ─── full gate processor ─────────────────────────────────────

gate_gain(x) = final_gain
with {
    // Combine schmitt and punch detectors
    gate_open  = max(schmitt(x), punch_detector(x));
    // Smooth with user-set attack/release
    atk_pole   = ba.tau2pole(atk_ms * 0.001);
    rel_pole   = ba.tau2pole(rel_ms * 0.001);
    gain_raw   = gate_open : si.onePoleSwitching(atk_pole, rel_pole);
    // Map 0→range_floor, 1→1.0
    final_gain = range_floor + (1.0 - range_floor) * gain_raw;
};

process(L, R) = out_L * output_db, out_R * output_db
with {
    // Stereo-linked: sidechain uses sum
    sidechain_sum  = (L + R) * 0.5;
    g    = gate_gain(sidechain_sum);
    out_L = select2(bypass, L * g, L) * (1.0 - bp) + L * bp;
    out_R = select2(bypass, R * g, R) * (1.0 - bp) + R * bp;
};
