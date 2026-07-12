declare name "DeMoD Sierpinski FX";
declare author "DeMoD + Grok";
declare version "4.0";
declare description "Argent Metal Edition — Industrial fractal effect with Sierpinski gating";

import("stdfaust.lib");

process(x) = vgroup("DeMoD Sierpinski FX v4.0 Argent Metal", output)
with {

    bypass      = checkbox("[0] Bypass");
    drywet      = hslider("[1] Dry/Wet",   0.72, 0.0, 1.0, 0.01) : si.smoo;
    intensity   = hslider("[2] Intensity", 0.85, 0.0, 1.0, 0.01) : si.smoo;
    feedback    = hslider("[3] Feedback",  0.52, 0.0, 0.98, 0.01) : si.smoo;
    bpm         = hslider("[4] BPM",       96.0, 60.0, 180.0, 1.0);
    master_gain = hslider("[5] Master Gain [unit:dB]", 0.0, -12.0, 12.0, 0.1)
                    : ba.db2linear : si.smoo;

    // ── Sierpinski gate: bitwise AND of counter with right-shifted self ────────
    step         = (os.phasor((bpm / 60.0) * 16.0, 0) * 65536) : int;
    sier_gate(d) = ((step & (step >> d)) == 0) : si.smoo;

    // ── Chaos LFO ─────────────────────────────────────────────────────────────
    chaos_lfo = os.lf_saw(0.618 * bpm / 60.0) * 0.5 + 0.5;

    // ── Argent Distortion ─────────────────────────────────────────────────────
    argent_dist(s) = ef.cubicnl(0.9 * intensity, 0.4, s)
                   : fi.highpass(1, 180)
                   : fi.highpass(1, 180)
                   : fi.highpass(1, 180)
                   : fi.highpass(1, 180)
                   : *(1.0 + 0.6 * sier_gate(4));

    // ── Sierpinski amplitude sculpting ────────────────────────────────────────
    // Three gating layers at different fractal depths multiply the signal,
    // carving the Sierpinski pattern directly into the amplitude envelope
    sier_sculpt(s) = s
        : *(0.4 + 0.6 * sier_gate(3))
        : *(0.6 + 0.4 * sier_gate(5))
        : *(0.7 + 0.3 * sier_gate(7));

    // ── Simple feedback comb — no de.fdelay, no tap math ─────────────────────
    // ba.sAndH freezes delay time on gate edges for glitchy metal texture
    comb_time = ba.sAndH(sier_gate(2), chaos_lfo) * 0.08 * ma.SR + 256.0;
    comb(s)   = s : de.delay(131072, int(comb_time))
                  : *(feedback * sier_gate(2))
                  : +(s);

    // ── Swept highpass shimmer via fi.highpass with LFO-driven cutoff ─────────
    shimmer_fc(s) = s
        : fi.highpass(2, 800.0  + chaos_lfo * 1200.0 * intensity)
        : fi.highpass(2, 400.0  + chaos_lfo *  600.0 * intensity);

    // ── Full Argent Metal chain ───────────────────────────────────────────────
    argent_metal(s) = s
        : argent_dist
        : sier_sculpt
        : comb
        : shimmer_fc
        : *(1.1);

    // ── Output routing ────────────────────────────────────────────────────────
    wet     = argent_metal(x);
    blended = x * (1.0 - drywet) + wet * drywet;
    output  = select2(bypass, blended, x) * master_gain;
};
