// ============================================================
//  DeMoD Swell — auto volume-swell / "slow gear"
//  (c) 2026 DeMoD LLC.
// ============================================================
import("stdfaust.lib");

declare name        "DeMoD Swell";
declare version     "1.0.0";
declare author      "DeMoD LLC";
declare license     "LicenseRef-PolyForm-Shield-1.0.0";
declare description "Auto volume-swell: each note fades in over the attack time (violining/slow-gear)";

sens    = hslider("[0] Sensitivity [unit:dB][style:knob]", -40, -60, -12, 0.5) : ba.db2linear;
attack  = hslider("[1] Attack [unit:s][style:knob]", 0.6, 0.05, 3.0, 0.01);
release = hslider("[2] Release [unit:s][style:knob]", 0.25, 0.02, 2.0, 0.01);
depth   = hslider("[3] Depth [style:knob]", 1.0, 0.0, 1.0, 0.01) : si.smoo;
outg    = hslider("[4] Output [unit:dB][style:knob]", 0, -12, 6, 0.1) : ba.db2linear : si.smoo;

process(L, R) = L * g * outg, R * g * outg
with {
    mono  = (L + R) * 0.5;
    e     = mono : an.amp_follower(0.005);
    gate  = e > sens;                                   // 1 while a note rings
    // slow rise (attack), quicker fall (release) — the swell envelope
    swell = gate : si.onePoleSwitching(ba.tau2pole(attack), ba.tau2pole(release));
    g     = 1.0 - depth + depth * swell;                // depth=0 → unity (bypass)
};
