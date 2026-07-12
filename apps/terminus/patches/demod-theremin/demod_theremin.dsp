// ============================================================
//  DeMoD Theremin — pure-tone glide voice
//  (c) 2026 DeMoD LLC.
// ============================================================
import("stdfaust.lib");

declare name        "DeMoD Theremin";
declare version     "1.0.0";
declare author      "DeMoD LLC";
declare license     "LicenseRef-PolyForm-Shield-1.0.0";
declare options     "[nvoices:1]";
declare description "Theremin: portamento sine with vibrato and a smooth volume swell (monophonic)";

freq = hslider("freq [unit:Hz][hidden:1]", 440, 20, 8000, 0.01);
gain = hslider("gain [hidden:1]", 0.8, 0, 1, 0.01);
gate = button("gate [hidden:1]");

glide   = hslider("[0] Glide [unit:s][style:knob]", 0.08, 0.0, 0.5, 0.001) : si.smoo;
vibRate = hslider("[1] Vib Rate [unit:Hz][style:knob]", 5.5, 0.0, 9.0, 0.01) : si.smoo;
vibDep  = hslider("[2] Vib Depth [style:knob]", 0.4, 0.0, 1.0, 0.01) : si.smoo;
warmth  = hslider("[3] Warmth [style:knob]", 0.2, 0.0, 1.0, 0.01) : si.smoo;       // 2nd-harmonic
att     = hslider("[4] Attack [unit:s][style:knob]", 0.06, 0.005, 1.0, 0.001);
level   = hslider("[5] Level [style:knob]", 0.7, 0.0, 1.0, 0.01) : si.smoo;

voice = (os.osc(fv) + os.osc(fv * 2.0) * warmth * 0.4) * (amp * gain * level)
with {
    f   = freq : si.smooth(ba.tau2pole(glide + 1e-4));
    vib = os.osc(vibRate) * vibDep * 0.03;          // ±3% pitch
    fv  = f * (1.0 + vib);
    amp = en.asr(att, 1.0, att, gate);
};

process = voice <: _, _;
