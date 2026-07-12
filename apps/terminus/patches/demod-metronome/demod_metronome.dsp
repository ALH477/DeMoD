// ============================================================
//  DeMoD Metronome — click/accent practice generator
//  (c) 2026 DeMoD LLC.
// ============================================================
import("stdfaust.lib");

declare name        "DeMoD Metronome";
declare version     "1.0.0";
declare author      "DeMoD LLC";
declare license     "LicenseRef-PolyForm-Shield-1.0.0";
declare description "Practice metronome: BPM click with an accented downbeat every N beats (0 inputs, generates audio)";

bpm    = hslider("[0] BPM [style:knob]", 120, 40, 240, 1) : si.smoo;
beats  = hslider("[1] Beats [style:knob]", 4, 1, 8, 1);
click  = hslider("[2] Click [unit:Hz][scale:log][style:knob]", 1000, 400, 3000, 1) : si.smoo;
accent = hslider("[3] Accent [style:knob]", 0.7, 0.0, 1.0, 0.01) : si.smoo;
level  = hslider("[4] Level [style:knob]", 0.6, 0.0, 1.0, 0.01) : si.smoo;

beatHz = bpm / 60.0;
barHz  = beatHz / max(1.0, beats);
bp     = os.phasor(1.0, barHz) * beats;          // 0..beats across one bar
frac   = bp - int(bp);                            // 0..1 within each beat
trig   = frac < frac';                            // 1-sample pulse on each beat
acc    = int(bp) < 1;                             // downbeat (first beat)

env    = trig : en.ar(0.0005, 0.045);
freq   = select2(acc, click, click * 1.5);        // accent rings higher
amp    = select2(acc, 1.0 - accent * 0.6, 1.0);   // non-accent beats quieter
sig    = os.osc(freq) * env * amp * level;

process = sig <: _, _;
