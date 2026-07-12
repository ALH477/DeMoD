// ============================================================
//  demod-cab — guitar speaker-cabinet voicing
//  Copyright (c) 2026 DeMoD LLC. All rights reserved.
// ============================================================
//
//  A lightweight cabinet emulation: a selectable voicing (4x12 / 2x12 / 1x12 /
//  combo) shaped from a high-pass, a low-mid body bump, a presence dip, and a
//  high rolloff — the broad strokes of a mic'd guitar cab without a heavy IR.
//  (True user-IR convolution needs engine soundfile support — see
//  docs/ENGINE_CONTRACTS.md.)
declare name "DeMoD Cab";
import("stdfaust.lib");
sk = library("demod_skill.lib");

cab = nentry("[0] Cab", 0, 0, 3, 1); // 0:4x12 1:2x12 2:1x12 3:combo
level = hslider("[1] Level", 0.8, 0.0, 1.0, 0.01) : sk.dezip;
mix = hslider("[2] Mix", 1.0, 0.0, 1.0, 0.01) : sk.dezip;

// voice(hp, body, presence, lp) — a cab voicing from a few biquads
voice(hp, fb, fp, lp) = fi.highpass(2, hp)
	: fi.peak_eq_cq(4.0, fb, 1.2)
	: fi.peak_eq_cq(-6.0, fp, 1.0)
	: fi.lowpass(2, lp);

cabbed = _
	<: voice(80, 100, 2500, 4500), voice(90, 120, 2600, 5000), voice(100, 140, 2700, 5500), voice(120, 160, 2800, 6000)
	: ba.selectn(4, int(cab)) : *(level) : sk.dcblock;

process = _ <: (_ : *(1.0 - mix)), (cabbed : *(mix)) :> _;
