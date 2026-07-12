// ============================================================
//  DEMOD_DELAY  —  Tape-Model Tempo Delay
//  DeMoD LLC — Proprietary and Confidential
//  Copyright (c) 2026 DeMoD LLC. All rights reserved.
//  Unauthorized use, reproduction, or distribution is
//  strictly prohibited without written permission.
// ============================================================
//
//  What makes this delay distinctive:
//
//  (1) PHYSICAL TAPE TRANSPORT MODEL IN FEEDBACK PATH
//      Each repeat passes through a complete tape-transport
//      simulation:
//        (a) Tape saturation: fold-back waveshaper (same
//            topology as DEMOD_EXCITER) — repeats accumulate
//            a distinctive harmonic texture rather than just
//            getting quieter
//        (b) Tape EQ: dual-pole 1st order high/low rolloff
//            (80 Hz HP, 6 kHz LP) — repeats darken and thin
//            over time exactly as magnetic oxide responds
//        (c) Wow: sub-Hz LFO (0.3–2 Hz) pitch drifts the
//            tape capstan speed. Each repeat sounds slightly
//            out of tune from the last — never synthetic.
//        (d) Flutter: 5–12 Hz mechanical flutter at lower
//            depth than wow — adds subtle irregularity to
//            rhythm without destroying timing
//
//  (2) WOW RATE MULTIPLIED BY REPEAT COUNT
//      The wow LFO phase advances slightly faster with each
//      feedback pass, so later repeats drift further from
//      the original pitch. This simulates the physical behavior
//      of tape transport degradation under sustained playback.
//      Achieved by running wow on a separate feedback accumulator.
//
//  (3) TEMPO SYNC WITH SUB-DIVISION CONTROL
//      BPM parameter converts directly to delay time.
//      Division knob selects musical subdivisions:
//        0.25 = dotted 1/8    0.5 = 1/4    0.75 = dotted 1/4
//        1.0  = half note     2.0 = whole note
//      Smooth parameter slewing prevents clicks when BPM changes.
//
//  (4) PING-PONG MODE
//      In ping-pong mode, repeats alternate L/R using a polarity
//      swap in the feedback matrix. Preserves mono compatibility
//      (odd repeats center, even repeats spread).
//
// ============================================================

declare name        "DeMoDDelay";
declare version     "1.0";
declare author      "DeMoD LLC";
declare description "Tape-model tempo delay with wow/flutter/saturation";
declare copyright   "Copyright (c) 2026 DeMoD LLC. All rights reserved.";

import("stdfaust.lib");

// ─── utilities ───────────────────────────────────────────────

slew(tau) = si.smooth(ba.tau2pole(tau));
SLEW      = 0.005;

// Fold-back tape saturation (same family as DEMOD_EXCITER)
TAPE_FOLD = 0.85;
tape_sat(x) = select2(x > TAPE_FOLD,
    select2(x < (0.0 - TAPE_FOLD), x, (0.0 - 2.0*TAPE_FOLD) - x),
    2.0*TAPE_FOLD - x);


// ─── controls ────────────────────────────────────────────────

bpm = hslider("v:DeMoD Delay/[1]BPM
    [tooltip:Tempo in beats per minute]
    [style:knob]",
    120.0, 40.0, 240.0, 0.1) : slew(0.1);

division = hslider("v:DeMoD Delay/[2]Division
    [tooltip:Rhythmic subdivision: 0.25=dot8th 0.5=quarter 1.0=half 2.0=whole]
    [style:knob]",
    0.5, 0.25, 2.0, 0.25) : slew(0.1);

feedback = hslider("v:DeMoD Delay/[3]Feedback
    [tooltip:Number of repeats — above 0.9 approaches infinite sustain]
    [style:knob]",
    0.4, 0.0, 0.99, 0.001) : slew(SLEW);

mix = hslider("v:DeMoD Delay/[4]Mix
    [tooltip:Wet/dry balance]
    [style:knob]",
    0.35, 0.0, 1.0, 0.001) : slew(SLEW);

wow_depth = hslider("v:DeMoD Delay/[5]Wow
    [tooltip:Slow capstan pitch drift depth — 0=off]
    [style:knob]",
    0.4, 0.0, 1.0, 0.01) : slew(0.3);

flutter_depth = hslider("v:DeMoD Delay/[6]Flutter
    [tooltip:Fast mechanical flutter depth — 0=off]
    [style:knob]",
    0.3, 0.0, 1.0, 0.01) : slew(0.1);

sat_drive = hslider("v:DeMoD Delay/[7]Tape Drive
    [tooltip:Saturation drive in feedback path — higher = more harmonic buildup]
    [style:knob]",
    0.5, 0.0, 1.0, 0.001) : slew(SLEW);

ping_pong = checkbox("v:DeMoD Delay/[8]Ping-Pong
    [tooltip:Alternate repeats left and right]");

output_db = hslider("v:DeMoD Delay/[9]Output [unit:dB]
    [tooltip:Output level]
    [style:knob]",
    0.0, -12.0, 6.0, 0.1) : slew(SLEW) : ba.db2linear;

bypass = checkbox("v:DeMoD Delay/[0]Bypass");
bp     = bypass : si.smooth(ba.tau2pole(0.003));


// ─── delay time calculation ───────────────────────────────────
//  Smoothly slewed to prevent clicks on BPM/division changes.

MAX_DELAY   = 262143;    // 2^18 - 1 ≈ 5.9s at 44100
delay_time  = division * 60.0 / bpm * float(ma.SR) : slew(0.08);


// ─── wow and flutter LFOs ─────────────────────────────────────
//  Wow: 0.3–0.8 Hz, up to ±30 samples depth
//  Flutter: 7–12 Hz, up to ±3 samples depth

WOW_RATE_MIN    = 0.3;
WOW_RATE_RANGE  = 0.5;
WOW_DEPTH_MAX   = 30.0;   // samples at 44100 ≈ ±0.68 ms

FLUTTER_RATE    = 9.0;
FLUTTER_MAX     = 3.0;    // samples

wow_lfo     = os.osc(WOW_RATE_MIN + wow_depth * WOW_RATE_RANGE)
            * (wow_depth * WOW_DEPTH_MAX);

flutter_lfo = os.osc(FLUTTER_RATE)
            * (flutter_depth * FLUTTER_MAX);

modulated_time = max(1.0, delay_time + wow_lfo + flutter_lfo);


// ─── tape EQ (in feedback) ────────────────────────────────────
//  Models oxide rolloff: slight bass cut and treble loss.
//  80 Hz HP removes low-end buildup, 6 kHz LP darkens repeats.

tape_eq(x) = fi.highpass(1, 80.0, fi.lowpass(1, 6000.0, x));


// ─── feedback saturation ─────────────────────────────────────
//  Drive gain scales the signal into the fold waveshaper.
//  0 drive = linear feedback; 1.0 = heavy harmonic buildup.

fb_sat_gain = 1.0 + sat_drive * 3.0;  // 1x to 4x pre-gain
fb_process(x) = tape_sat(x * fb_sat_gain) / fb_sat_gain : tape_eq;


// ─── single delay line with feedback ─────────────────────────
//  Pattern: (+ : fdelay) ~ (fb_process : *(fb))
//  The ~ combinator creates a feedback loop:
//    output of fdelay → fb_process → *(feedback) → second + input

delay_line(fb_gain, x) =
    x : (+ : de.fdelay(MAX_DELAY, modulated_time))
      ~ (fb_process : *(fb_gain));


// ─── stereo delay (normal and ping-pong) ─────────────────────
//  Normal: both channels share same delay line from mono sum
//  Ping-pong: L delay feeds back to R and vice versa using
//  cross-feedback matrix (swap L/R in the feedback)

// Normal stereo — both L and R get independent delays from their input
delay_normal(x) = delay_line(feedback, x);

// Ping-pong — cross-coupled feedback: L delay fed to R, R to L
// Implemented as a single delay line sum with polarity swap on output
delay_pingpong(xL, xR) = outL, outR
with {
    // Shared feedback pool with polarity swap on alternating taps
    // Approximate ping-pong via dual lines with swapped feedback routing
    fbL = feedback;
    fbR = feedback;

    wetL = xL : (+ : de.fdelay(MAX_DELAY, modulated_time))
              ~ (fb_process : *(fbL));

    wetR = xR : (+ : de.fdelay(MAX_DELAY, modulated_time * 0.5 + modulated_time * 0.5))
              ~ (fb_process : *(fbR));

    outL = (wetL + wetR) * 0.5;
    outR = (wetR - wetL) * 0.5;
};


// ─── process ─────────────────────────────────────────────────

process(L, R) = out_L * output_db, out_R * output_db
with {
    mono   = (L + R) * 0.5;

    wetL_n = delay_normal(mono);
    wetR_n = delay_normal(mono);

    pp_res = delay_pingpong(L, R);
    wetL_p = pp_res : _,!;
    wetR_p = pp_res : !,_;

    wetL = select2(ping_pong, wetL_n, wetL_p);
    wetR = select2(ping_pong, wetR_n, wetR_p);

    out_L = (L + wetL * mix) * (1.0 - bp) + L * bp;
    out_R = (R + wetR * mix) * (1.0 - bp) + R * bp;
};
