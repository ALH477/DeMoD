declare name        "TempoEcho";
declare author      "DeMoD Audio Systems";
declare description "Tap-tempo ping-pong delay · BPM subdivision · Padé feedback · HF decay";
declare version     "1.0";
declare license     "GPL-3.0";

// ┌──────────────────────────────────────────────────────────────────────────┐
// │  TempoEcho — Tap-Tempo Ping-Pong Delay                                   │
// │  DeMoD Audio Systems                                                      │
// │                                                                            │
// │  Architecture:                                                             │
// │    · Two independent delay lines: L (direct) and R (offset)              │
// │    · Cross-feedback: y_L feeds into y_R input and vice versa             │
// │    · Padé sat + 1-pole LP in feedback loop (tape echo model)             │
// │    · BPM sync with musical subdivision selector                           │
// │    · de.sdelay for click-free delay time changes                         │
// │                                                                            │
// │  Mathematics:                                                              │
// │    Ping-pong equations:                                                    │
// │      y_L[n] = x[n] + fbk · sat(LP(y_R[n − D_R]))                        │
// │      y_R[n] = x[n] + fbk · sat(LP(y_L[n − D_L]))                        │
// │                                                                            │
// │    BPM sync:                                                               │
// │      D_L = (60/BPM) · (1/div_L) · SR   (samples)                        │
// │      D_R = (60/BPM) · (1/div_R) · SR                                    │
// │                                                                            │
// │    Feedback HF loss (tape echo model):                                    │
// │      H_fb(z) = (1−α)/(1−α·z⁻¹),  α = exp(−2π·tone_fc/SR)             │
// │      Each reflection loses HF → echoes get progressively darker          │
// └──────────────────────────────────────────────────────────────────────────┘

import("stdfaust.lib");


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  UI PARAMETERS                                                           ║
// ╚══════════════════════════════════════════════════════════════════════════╝

bpm     = hslider("h:TempoEcho/[1] BPM",               120.0,  40.0, 240.0, 0.1) : si.smoo;
div_L   = hslider("h:TempoEcho/[2] Div L",               4.0,   1.0,  16.0, 1.0) : int;
div_R   = hslider("h:TempoEcho/[3] Div R",               6.0,   1.0,  16.0, 1.0) : int;
fbk     = hslider("h:TempoEcho/[4] Feedback",            0.5,   0.0,   0.97,0.01): si.smoo;
tone    = hslider("h:TempoEcho/[5] Tone [unit:Hz]",    4000.0, 500.0,12000.0,1.0): si.smoo;
wmix    = hslider("h:TempoEcho/[6] Mix",                 0.4,   0.0,   1.0, 0.01): si.smoo;
out_g   = hslider("h:TempoEcho/[7] Gain [unit:dB]",      0.0, -12.0,   6.0, 0.1)
          : ba.db2linear : si.smoo;


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  CONSTANTS                                                               ║
// ╚══════════════════════════════════════════════════════════════════════════╝

MAX_DELAY_S = 2.0;
MAXD        = int(MAX_DELAY_S * 192000.0) + 64;


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  PADÉ SATURATOR                                                         ║
// ╚══════════════════════════════════════════════════════════════════════════╝

sat(x) = x * (27.0 + x*x) / (27.0 + 9.0*x*x);


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  DELAY TIMES                                                            ║
// ║  D = (60/BPM) / division * SR  samples                                 ║
// ╚══════════════════════════════════════════════════════════════════════════╝

dSampL = (60.0 / bpm) / float(div_L) * float(ma.SR)
       : max(1.0) : min(float(MAXD) - 1.0);
dSampR = (60.0 / bpm) / float(div_R) * float(ma.SR)
       : max(1.0) : min(float(MAXD) - 1.0);


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  FEEDBACK HF LOSS (tape echo model)                                    ║
// ║  1-pole LP: α = exp(−2π·tone/SR)                                       ║
// ╚══════════════════════════════════════════════════════════════════════════╝

toneAlpha = exp(-2.0 * ma.PI * tone / float(ma.SR));
toneLP(x) = x * (1.0 - toneAlpha) : fi.pole(toneAlpha);


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  PING-PONG DELAY CORE                                                   ║
// ║                                                                          ║
// ║  Two delay lines with crossed feedback.                                 ║
// ║  de.sdelay: smooth delay — no clicks when BPM or division changes.      ║
// ║  Each delay reads from the OTHER channel's output (ping-pong).          ║
// ╚══════════════════════════════════════════════════════════════════════════╝

// cross-coupled ping-pong: yL = tapL(L + fbk·yR), yR = tapR(R + fbk·yL)
pingpong(x) = (x <: _, _) : loop
with {
    tapL = de.sdelay(MAXD, 512, dSampL) : toneLP : sat;
    tapR = de.sdelay(MAXD, 512, dSampR) : toneLP : sat;
    loop = ( (+ : tapL), (+ : tapR) ) ~ ( \(l, r).(fbk * r, fbk * l) );
};


// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  PROCESS                                                                 ║
// ╚══════════════════════════════════════════════════════════════════════════╝

process = _ <:
    ( pingpong : *(wmix), *(wmix) ),
    ( _, _     : *(1.0-wmix), *(1.0-wmix) )
    :> *(out_g), *(out_g);
