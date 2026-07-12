// ============================================================
//  DeMoD Drone — tunable practice drone
//  (c) 2026 DeMoD LLC.
// ============================================================
import("stdfaust.lib");

declare name        "DeMoD Drone";
declare version     "1.0.0";
declare author      "DeMoD LLC";
declare license     "LicenseRef-PolyForm-Shield-1.0.0";
declare description "Tunable drone: detuned root with optional fifth and octave and a saw↔mellow timbre (0 inputs, generates audio)";

root   = hslider("[0] Root [unit:Hz][scale:log][style:knob]", 110, 40, 440, 0.1) : si.smoo;
fifth  = hslider("[1] Fifth [style:knob]", 0.6, 0.0, 1.0, 0.01) : si.smoo;
octave = hslider("[2] Octave [style:knob]", 0.4, 0.0, 1.0, 0.01) : si.smoo;
detune = hslider("[3] Detune [unit:cents][style:knob]", 6, 0.0, 30.0, 0.1) : si.smoo;
timbre = hslider("[4] Timbre [style:knob]", 0.5, 0.0, 1.0, 0.01) : si.smoo;
level  = hslider("[5] Level [style:knob]", 0.5, 0.0, 1.0, 0.01) : si.smoo;

// two detuned saws per partial
voice(f) = (os.sawtooth(f * dn) + os.sawtooth(f * up)) * 0.5
with {
    r  = pow(2.0, detune / 1200.0);
    dn = 2.0 - r;     // ≈ 1 - (r-1)
    up = r;
};

mello(x) = x : fi.lowpass(2, 180 + timbre * 6000);

process = sig, sig
with {
    raw = voice(root) + voice(root * 1.5) * fifth + voice(root * 2.0) * octave;
    sig = (raw : mello) * level * 0.22;
};
