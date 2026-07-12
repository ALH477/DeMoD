// ============================================================
//  DeMoD Boost — clean boost / treble booster
//  (c) 2026 DeMoD LLC.
// ============================================================
import("stdfaust.lib");

declare name        "DeMoD Boost";
declare version     "1.0.0";
declare author      "DeMoD LLC";
declare license     "LicenseRef-PolyForm-Shield-1.0.0";
declare description "Clean boost + treble booster: gain, a high shelf and a Rangemaster-style low-cut that sets the treble-boost character, with gentle germanium edge";

boost  = hslider("[0] Boost [unit:dB][style:knob]", 6, 0, 24, 0.1) : ba.db2linear : si.smoo;
treble = hslider("[1] Treble [unit:dB][style:knob]", 3, -6, 12, 0.1) : si.smoo;
range  = hslider("[2] Range [style:knob]", 0.3, 0.0, 1.0, 0.01) : si.smoo;   // low-cut → treble-booster
level  = hslider("[3] Level [unit:dB][style:knob]", 0, -12, 6, 0.1) : ba.db2linear : si.smoo;

sat(x)   = x * (27.0 + x * x) / (27.0 + 9.0 * x * x);   // gentle germanium edge at high gain
shape(x) = x : fi.highpass(1, 30.0 + range * 600.0)
             : *(boost)
             : fi.highshelf(3, treble, 2000)
             : sat;

process(L, R) = shape(L) * level, shape(R) * level;
