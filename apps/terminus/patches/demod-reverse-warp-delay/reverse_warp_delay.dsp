import("stdfaust.lib");

// ═══════════════════════════════════════════════════════════════════
//  R E V E R S E   D E L A Y  ×  D Y N A M I C   W A R P
//
//  Standard reverse delay where the playback head is continuously
//  displaced by two modulators simultaneously:
//
//  UNIQUE TWIST 1 — ENVELOPE → PITCH:
//    The reverse read-head offset is scaled by the input signal's
//    instantaneous amplitude. Louder transients physically push
//    the reversed echo earlier in the buffer, which manifests
//    as an upward pitch-glide on each reverse repeat. Quiet
//    passages reverse cleanly; loud ones shimmer and stretch.
//
//  UNIQUE TWIST 2 — DECAYING DARKNESS FEEDBACK:
//    The feedback path passes through a 2nd-order low-pass whose
//    cutoff is set by the "Darkness" knob. Each repeat loses
//    high-frequency energy, mimicking analog tape aging — so the
//    reverse tail degrades from crisp to ghostly over time.
//
//  The combination produces: reversed echoes that pitch-glide
//  with dynamics and fade into a warm, dark smear — great for
//  ambient, post-rock, and experimental sound design.
// ═══════════════════════════════════════════════════════════════════

// ── Buffer ceiling (2 s @ 96 kHz, safe for all common SRs) ────────
MAXBUF = 192001;

// ── UI Parameters ─────────────────────────────────────────────────
delMs    = hslider("v:Reverse Delay/[1] Delay Time [ms]
                   [tooltip: Length of each reversed chunk]",
                   500, 50, 1500, 1);

fb       = hslider("v:Reverse Delay/[2] Feedback
                   [tooltip: How much of each repeat feeds back]",
                   0.42, 0.0, 0.92, 0.01);

drywet   = hslider("v:Reverse Delay/[3] Dry-Wet
                   [tooltip: 0 = full dry, 1 = full wet]",
                   0.5, 0.0, 1.0, 0.01);

warpRate = hslider("v:Warp/[4] Warp Rate [Hz]
                   [tooltip: Speed of LFO that wobbles the read head]",
                   0.18, 0.01, 3.0, 0.01);

warpDpth = hslider("v:Warp/[5] Warp Depth
                   [tooltip: Amplitude of read-head wobble (0–1)]",
                   0.12, 0.0, 0.45, 0.001);

envAmt   = hslider("v:Warp/[6] Env → Pitch
                   [tooltip: How much input loudness shifts reverse pitch]",
                   0.25, 0.0, 1.0, 0.01);

darkness = hslider("v:Warp/[7] Darkness
                   [tooltip: How aggressively each repeat loses highs]",
                   0.55, 0.0, 1.0, 0.01);

// ── Derived values ────────────────────────────────────────────────
// Integer chunk size, clamped to [1, MAXBUF-1]
delN = int(delMs * float(ma.SR) / 1000.0) : max(1) : min(MAXBUF - 1);

// Low-pass cutoff for feedback darkening: 300 Hz (dark) → 20 kHz (bright)
fbCutoff = 20000.0 * pow(1.0 - darkness, 1.6) + 300.0;

// ── Envelope follower: 30 ms attack/release ───────────────────────
envFollow(x) = abs(x) : si.smooth(ba.tau2pole(0.03));

// ── Reverse delay kernel ──────────────────────────────────────────
//
//  Write pointer:  phase = ba.time mod delN  (advances 0 → delN-1)
//  Reverse read:   base  = (delN-1) - phase  (retreats delN-1 → 0)
//  Modulation:     warpLFO + envMod shift the read head in samples,
//                  which Doppler-shifts the playback frequency.
//
revDelay(x) = rwtable(MAXBUF, 0.0, wIdx, x, rIdx)
with {
    phase   = int(ba.time) % delN;
    wIdx    = phase;

    // LFO warp: sinusoidal wobble, half-chunk amplitude at depth=1
    warpLFO = os.osc(warpRate) * warpDpth * (float(delN) * 0.5);

    // Envelope warp: 8% of chunk length at max envAmt
    envMod  = envFollow(x) * envAmt * (float(delN) * 0.08);

    // Base reverse position + both modulators, clamped to valid range
    rIdx = int(
               (float(delN - 1 - phase) + warpLFO + envMod)
               : max(0.0) : min(float(delN - 1))
           );
};

// ── Feedback darkening filter ──────────────────────────────────────
darkPass = fi.lowpass(2, fbCutoff);

// ── Main process (stereo-compatible: runs each channel separately) ─
process(x) = x * (1.0 - drywet) + wet * drywet
with {
    // Feedback loop:
    //   (input + fb*previous_output) → reverse → darken → output
    wet = (+(x) : revDelay : darkPass) ~ *(fb);
};
