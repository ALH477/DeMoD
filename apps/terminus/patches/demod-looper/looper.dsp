// ============================================================
//  demod-looper — hold / overdub loop buffer
//  Copyright (c) 2026 DeMoD LLC. All rights reserved.
// ============================================================
//
//  A simple, glitch-tolerant looper built on a unity-feedback delay:
//    - Record:  capture the input into the loop (replaces).
//    - Overdub: add the input on top of the existing loop.
//    - Play:    gate the loop to the output (the dry input always passes).
//    - Clear:   wipe the buffer over one pass (feedback -> 0).
//    - Level:   loop playback level.
//    - Loop:    loop length in ms (sets the delay-line read point).
//
//  Controls are driven by the UI/footswitch via set_param (idx 0..5).
declare name "DeMoD Looper";
import("stdfaust.lib");
sk = library("demod_skill.lib");

rec = button("[0] Record");
overdub = button("[1] Overdub");
play = checkbox("[2] Play");
clr = button("[3] Clear");
level = hslider("[4] Level", 1.0, 0.0, 1.0, 0.01) : sk.dezip;
looplen = hslider("[5] Loop (ms)", 1000, 100, 8000, 1);

maxd = 524288; // ~10.9 s @ 48k (power of two)
d = min(maxd - 1, int(looplen / 1000.0 * ma.SR));
armed = min(1.0, rec + overdub); // write the input into the loop
hold = 1.0 - clr; // clear wipes the buffer over one pass

// feedback loop: input (when armed) recirculates through the delay at unity hold
loopbuf = *(armed) : (+ ~ (de.delay(maxd, d) : *(hold)));

process = _ <: (_, (loopbuf : *(play) : *(level) : sk.dcblock)) :> _;
