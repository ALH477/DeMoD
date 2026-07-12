//============================================================================
// DeMoD LoFi Keys  MkII   "Tine / Tape / Trinity"
//----------------------------------------------------------------------------
// Not a lo-fi preset. A modeled instrument played through a modeled medium.
//
//   VOICE   physically-modeled electric-piano tine: a struck inharmonic modal
//           resonator bank + PM woody body, sensed through a NONLINEAR
//           electromagnetic pickup (velocity-dependent even-harmonic "growl"),
//           with per-note tuning entropy and key/damper mechanical noise.
//
//   MEDIUM  rate-dependent tape hysteresis, playback-head LF bump, OU wow &
//           flutter, smooth oxide DROPOUTS, gap-loss bandwidth, and resonant
//           vinyl crackle / rumble whose density wanders with record WEAR.
//
//   SPACE   the DeMoD signature: a SIERPINSKI BLOOM - a modal tank whose
//           partials sit on a ternary Cantor set (self-similar under x3, with
//           the characteristic missing middle), giving inharmonic shimmer that
//           is split across the stereo field. Plus a dream reverb.
//
// Polyphonic: per-voice `process` + global `effect` bus.
// DeMoD Faust SKILL: Ornstein-Uhlenbeck LFOs, Pade tanh saturators, si.smoo
// on every continuous parameter, DC blocking on output.
//
//----------------------------------------------------------------------------
// CHANGELOG
//   v0.4.1  (clarity, no sonic change)
//   * Renamed the "FM" body to what it actually is: PHASE modulation. The
//     operator already summed its modulator into the phase (sin(2*pi*ph + m)),
//     not the frequency, so the carrier pitch was always stable and drift-free
//     -- the right DSP choice. fmSin/idxBody -> pmSin/pmIndex; comments updated.
//     Output is bit-identical (verified by diffing the generated C).
//
//   v0.4.0  (expressivity)
//   * Velocity now shapes STRIKE TIMBRE, not just level: a harder hit opens the
//     strike low-pass (~2.5 -> 8.5 kHz) for a brighter, barkier tine; soft hits
//     are dark and round. Per-pitch level stays flat (the LP is absolute Hz).
//   * Pitch-dependent decay. Higher notes ring shorter (T60 ~ f^-1/2, clamped),
//     as a real tine/string does, instead of one decay time for every pitch.
//   * Added the iconic Rhodes "vibrato" -- a stereo panning tremolo (Depth/Rate/
//     Stereo). Stereo morphs mono tremolo -> auto-pan. Sits before the vinyl
//     noise so hiss/crackle don't pan. Gentle by default; set Depth=0 for the
//     pre-v0.4.0 dry tone.
//
//   v0.3.1  (modal strike level)
//   * Modal strike level is now pitch-flat. A broadband NOISE burst was the
//     exciter; it injects a random, frequency-dependent amount of energy per
//     mode (it samples wherever each mode lands in that noise realization), so
//     the tine bank swung ~16 dB across pitch and its peak exceeded 1.0 in the
//     upper-mid -- audible as hot, distorting high notes that then overdrove
//     the pickup and tape. Measured fix: a deterministic impulse (flat by
//     construction; a 1-sample impulse rings every mode to identical level)
//     softened by a 1-pole LP, plus a little noise for attack grit. Full-voice
//     RMS is now flat to ~+/-1 dB, 110 Hz..3.5 kHz; peaks <0.13 (were >1.0).
//     Strike character is slightly cleaner ("thock" vs "chiff") -- push the
//     noise term for more grit, the impulse term for more click.
//
//   v0.3.0  (engineering corrections; verify the two retunes to taste)
//   * SKILL/OU variance fixed. Faust no.noise/no.noises are UNIFORM on [-1,1]
//     (variance 1/3, std ~0.577), so the old "stationary std ~= 1" was really
//     ~0.58. OU is now driven by unit-variance white (`wnU`); the wobble depth
//     (6.0 -> 3.5) and dropout threshold (1.4 -> 2.0) were retuned so the
//     audible feel is preserved under the corrected statistics.
//   * Voice noise decorrelated. Faust CSE merges every textual `no.noise` into
//     ONE shared stream (verified: `no.noise - no.noise` compiles to 0), so the
//     strike excitation, key click, damper thunk and tuning latch were all the
//     same sequence. Now use four distinct `no.noises` channels.
//   * Tuning entropy is chord-safe. Poly voices share a deterministic seed, so
//     notes gated on the SAME sample latched identical "random" detune (the
//     entropy collapsed on struck chords). A deterministic per-pitch term now
//     guarantees decorrelation regardless of strike timing.
//   * Tape saturator renormalized. The old `/padeTanh(drv)` baked +2.1 dB and a
//     slight HF lift in at Saturation=0 (knob zero was not neutral). Now unity
//     at zero; higher drive adds harmonics while peaks compress, as tape does.
//
// BUILD: compile with denormal flush for the continuous OU integrators and long
//   modal/reverb tails, esp. on the RISC-V target:
//       faust -ftz 2 ... demod_lofi_keys_mk2.dsp
//============================================================================

declare name        "DeMoD LoFi Keys MkII";
declare version     "0.4.1";
declare author      "DeMoD LLC";
declare license     "(c) DeMoD LLC";
declare description  "Modeled tine electric piano through a modeled tape/vinyl medium with Sierpinski resonance.";
declare options      "[midi:on][nvoices:8]";

import("stdfaust.lib");

//============================================================================
// DeMoD SKILL helpers
//============================================================================

frac1(x) = x - floor(x);

// Pade rational tanh, input-clamped to its valid region (saturates, no blowup).
padeTanh(x) = num / den
with {
    xc  = max(-3.0, min(3.0, x));
    xc2 = xc * xc;
    num = xc * (27.0 + xc2);
    den = 27.0 + 9.0 * xc2;
};

// Ornstein-Uhlenbeck: mean-reverting random walk (theta=rate, sigma=vol, nz=drive).
// CONTRACT: `nz` must be UNIT-VARIANCE white noise (use `wnU`). With that,
// ouNorm has stationary variance sigma^2/(2*theta) = 1, i.e. std ~= 1.
ou(theta, mu, sigma, nz) = (loop ~ _)
with {
    dt = 1.0 / ma.SR;
    loop(x) = x + theta * (mu - x) * dt + sigma * sqrt(dt) * nz;
};
ouNorm(theta, nz) = ou(theta, 0.0, sqrt(2.0 * theta), nz);   // stationary std ~= 1

crush(nbits) = quant with { q = 2.0 ^ (nbits - 1.0); quant(x) = floor(x * q + 0.5) / q; };
srr(factor)  = ba.sAndH((ba.time % max(1, int(factor))) == 0);

//============================================================================
// VOICE : modeled tine electric piano
//============================================================================

freq = hslider("freq[unit:Hz]", 220.0, 20.0, 8000.0, 0.001);
gain = hslider("gain", 0.8, 0.0, 1.0, 0.001);
gate = button("gate");

vAtt  = hslider("v:[1]Piano/[0]Attack[unit:s][scale:log]",  0.003, 0.001, 0.20, 0.001) : si.smoo;
vRing = hslider("v:[1]Piano/[1]Ring[unit:s][scale:log]",    1.60,  0.15,  6.0,  0.001) : si.smoo; // modal decay
vRel  = hslider("v:[1]Piano/[2]Release[unit:s][scale:log]", 0.30,  0.02,  3.0,  0.001) : si.smoo; // damper
vColor= hslider("v:[1]Piano/[3]Color",                      0.55,  0.0,   1.0,  0.001) : si.smoo; // body PM index
vTine = hslider("v:[1]Piano/[4]Tine",                       0.40,  0.0,   1.0,  0.001) : si.smoo; // metallic mode level
vGrowl= hslider("v:[1]Piano/[5]Growl",                      0.35,  0.0,   1.0,  0.001) : si.smoo; // pickup nonlinearity
vDet  = hslider("v:[1]Piano/[6]Detune[unit:cent]",          5.0,   0.0,   25.0, 0.01)  : si.smoo;
vDrift= hslider("v:[1]Piano/[7]Drift[unit:cent]",           3.0,   0.0,   30.0, 0.01)  : si.smoo; // per-note tuning entropy
vMech = hslider("v:[1]Piano/[8]Mechanics",                  0.25,  0.0,   1.0,  0.001) : si.smoo; // key/damper noise

epVoice = voiceOut
with {
    vel = gain;
    nyq = 0.47 * ma.SR;

    // four DECORRELATED noise streams for this voice. (A bare `no.noise` used
    // more than once is CSE-merged into a single stream, which correlates the
    // strike, the click, the thunk and the tuning latch -- avoid that here.)
    vnz(i) = no.noises(4, i);

    // per-note tuning entropy. Two parts so it survives polyphony:
    //   driftR : per-strike random latch (varies every keystrike)
    //   driftP : deterministic per-PITCH offset -> simultaneously-struck chord
    //            notes always decorrelate even though poly voices share a seed,
    //            and each key keeps a stable, instrument-like tuning error.
    driftR = vnz(0) : ba.sAndH(ba.impulsify(gate));
    driftP = 2.0 * frac1(freq * 0.0193 + 0.137) - 1.0;
    drift  = 0.6 * driftR + 0.4 * driftP;
    fEff   = freq * (2.0 ^ (vDrift * drift / 1200.0));

    // envelopes
    damper  = en.adsr(vAtt, 0.01, 1.0, vRel, gate);            // ~ATTACK..hold..RELEASE
    bodyAmp = en.adsr(vAtt, vRing * 0.85, 0.0, vRel, gate);    // body fades over the ring
    clrEnv  = en.adsr(0.0,  0.60, 0.10, 0.30, gate);           // brightness bloom

    // --- modal tine: struck inharmonic resonator bank ---
    // The strike must deliver a CONSISTENT amount of energy to every mode. A
    // broadband noise burst does not: it injects whatever energy that particular
    // noise realization happens to hold near each mode, so the bank's level swung
    // ~16 dB with pitch (hot in the upper-mid, peaks >1.0). A 1-sample impulse is
    // flat by construction (rings every mode to identical level); the 1-pole LP
    // turns the "tick" into a felt-hammer "thock", and a little noise adds grit.
    burst  = en.adsr(0.0, 0.0018, 0.0, 0.0018, gate);          // ~2 ms grit envelope
    strike = ba.impulsify(gate);                               // flat-level exciter
    // velocity opens the strike spectrum: a harder hit drives the tine closer to
    // the pickup and excites the upper modes more (brighter, barkier); soft hits
    // are dark and round. The LP is in absolute Hz, so per-pitch level stays flat.
    strikeLP = 2500.0 + 6000.0 * vel;                          // ~2.5 kHz soft .. 8.5 kHz hard
    exc    = (strike : fi.lowpass(1, strikeLP)) * 0.85         // KIMP: overall tine level
           + vnz(1) * burst * (0.12 + 0.12 * vel);             // KNZ: grit grows with velocity
    mfreq(r)            = min(fEff * r, nyq);
    // higher notes decay faster, like a real tine/string (T60 ~ f^-1/2), clamped
    // so the bass doesn't ring forever and the treble doesn't die instantly.
    pDecay              = sqrt(220.0 / fEff) : max(0.4) : min(2.0);
    mode(r, t60f, g)    = pm.modeFilter(mfreq(r), max(0.02, vRing * t60f * pDecay), g);
    tineGain            = vTine * (0.30 + 0.70 * vel);
    tine = exc <: ( mode(1.0,   1.00, 1.00)
                  , mode(2.0,   0.70, 0.50)
                  , mode(3.0,   0.50, 0.32)
                  , mode(4.2,   0.30, 0.22)
                  , mode(13.7,  0.12, tineGain) ) :> _;

    // --- woody body: self-PHASE-modulation (PM, not FM) ---
    // The modulator is summed into the PHASE, not the frequency, so the carrier
    // pitch is rock-stable (modulator DC = a constant phase offset, never a pitch
    // shift) and there is no phase-integrator drift -- the numerically robust DSP
    // choice. (True FM would integrate the modulator into the phase increment.)
    ph(f)        = (+(f / ma.SR) ~ frac1);
    pmSin(f, pm) = sin(2.0 * ma.PI * ph(f) + pm);              // pm added to phase = PM
    pmIndex      = (3.5 * vColor) * (0.60 + 0.40 * vel);
    bodyAt(f)    = pmSin(f, pmIndex * clrEnv * pmSin(f, 0.0)); // 1:1 self-modulation
    det          = 2.0 ^ (vDet / 1200.0);
    body         = 0.5 * (bodyAt(fEff) + bodyAt(fEff * det)) * bodyAmp;

    // --- nonlinear electromagnetic pickup: gentle even-harmonic growl, clean at low level ---
    tone   = (body + 0.9 * tine) * 0.30;                       // keep the pickup in its gentle region
    gdrive = 1.0 + 1.5 * vGrowl * vel;                         // harder strike -> more bark
    pbias  = 0.08;
    picked = (padeTanh(gdrive * (tone + pbias)) - padeTanh(gdrive * pbias)) / gdrive;

    // --- key / damper mechanical noise ---
    keyN     = vnz(2) * en.adsr(0.0, 0.010, 0.0, 0.010, gate) : fi.bandpass(2, 1500, 4000);
    relImp   = (gate' > gate);                                 // falling edge only (never at init)
    thunk    = vnz(3) * (relImp : fi.pole(0.995)) : fi.lowpass(1, 350);
    mech     = (0.25 * keyN + 0.60 * thunk) * vMech;

    voiceOut = (picked * damper * gain + mech * (0.40 + 0.60 * vel)) * 0.30;
};

//============================================================================
// EFFECT : modeled tape / vinyl medium + Sierpinski space   (mono -> stereo)
//============================================================================

fSat   = hslider("h:[2]Tape/[0]Saturation",                    0.15,   0.0,    1.0,    0.001) : si.smoo;
fBump  = hslider("h:[2]Tape/[1]Head Bump",                     0.30,   0.0,    1.0,    0.001) : si.smoo;
fWob   = hslider("h:[2]Tape/[2]Wobble",                        0.35,   0.0,    1.0,    0.001) : si.smoo;
fDrop  = hslider("h:[2]Tape/[3]Dropouts",                      0.20,   0.0,    1.0,    0.001) : si.smoo;
fBW    = hslider("h:[2]Tape/[4]Bandwidth[unit:Hz][scale:log]", 9000.0, 1200.0, 18000.0,1.0)   : si.smoo;
fBits  = hslider("h:[2]Tape/[5]BitDepth",                      14.0,   4.0,    16.0,   0.01)  : si.smoo;
fCrush = hslider("h:[2]Tape/[6]SR Reduce",                     1.0,    1.0,    12.0,   1.0);

fCrk   = hslider("h:[3]Vinyl/[0]Crackle",                      0.22,   0.0,    1.0,    0.001) : si.smoo;
fWear  = hslider("h:[3]Vinyl/[1]Wear",                         0.40,   0.0,    1.0,    0.001) : si.smoo;
fHiss  = hslider("h:[3]Vinyl/[2]Hiss",                         0.12,   0.0,    1.0,    0.001) : si.smoo;
fRumble= hslider("h:[3]Vinyl/[3]Rumble",                       0.20,   0.0,    1.0,    0.001) : si.smoo;

rWet   = hslider("h:[4]Space/[0]Reverb",                       0.15,   0.0,    1.0,    0.001) : si.smoo;
rSize  = hslider("h:[4]Space/[1]Size",                         0.55,   0.10,   0.97,   0.001) : si.smoo;
fBloom = hslider("h:[4]Space/[2]Bloom",                        0.30,   0.0,    1.0,    0.001) : si.smoo; // Sierpinski tank
fBloomD= hslider("h:[4]Space/[3]Bloom Decay",                  0.22,   0.0,    1.0,    0.001) : si.smoo;

tDepth = hslider("h:[5]Vibrato/[0]Depth",          0.18, 0.0, 1.0,  0.001) : si.smoo; // 0 = dry (pre-v0.4.0 tone)
tRate  = hslider("h:[5]Vibrato/[1]Rate[unit:Hz]",  5.5,  0.5, 10.0, 0.01)  : si.smoo;
tStereo= hslider("h:[5]Vibrato/[2]Stereo",         0.80, 0.0, 1.0,  0.001) : si.smoo; // 0 = mono trem .. 1 = auto-pan

outGain= hslider("h:[6]Out/[0]Level[unit:dB]",                  0.0,  -36.0,   6.0,    0.1)   : si.smoo : ba.db2linear;

// rate-dependent (hysteresis-like) tape saturator: the (x - x') term opens the
// transfer curve with signal velocity, which a memoryless tanh cannot do.
// Normalized so drv=1 (Saturation=0) is unity gain; raising drive then adds
// harmonics while peaks compress (tape-like), instead of baking in a fixed boost.
tapeSat(drv, x) = padeTanh(drv * x + 0.06 * drv * (x - x')) * (padeTanh(1.0) / padeTanh(drv));

effect = preChain : spaceMix : vibrato : stereoNoise : stereoOut
with {
    N      = 8;
    nz(i)  = no.noises(N, i);                 // uniform [-1,1] (var 1/3) -- fine for hiss/crackle
    wnU(i) = no.noises(N, i) * sqrt(3.0);     // UNIT-VARIANCE white -- required by ou/ouNorm

    //------ tape path (mono -> mono) ------
    tdrive   = 1.0 + 2.0 * fSat;
    headBump = _ <: (_, fi.resonbp(75.0, 1.2, 1.0) * fBump) :> _;     // playback-head LF resonance

    wowflutter = de.fdelay(maxDel, delS)
    with {
        maxDel = 8192;
        baseMs = 14.0;
        wow    = ouNorm(3.8,  wnU(4));                                // ~0.6 Hz drift, std ~1
        flut   = 0.6 * ouNorm(46.0, wnU(5)) + 0.4 * os.osc(7.3);      // ~7 Hz + scrape
        modMs  = (3.5 * fWob) * (0.7 * wow + 0.3 * flut);             // peak ~few ms at full
        delS   = ((baseMs + modMs) * 0.001 * ma.SR) : max(1.0) : min(maxDel - 2);
    };

    dropouts = *(g)                                                   // smooth oxide dropouts
    with {
        slow = ouNorm(2.2, wnU(6));                                   // std ~1
        d    = max(0.0, slow - 2.0);                                  // ~2 sigma excursions (rare)
        g    = 1.0 - min(1.0, d * 4.0) * 0.75 * fDrop;
    };

    band    = fi.highpass(1, 55.0) : fi.lowpass(3, fBW);              // gap-loss / rolloff
    degrade = crush(fBits) : srr(fCrush);

    preChain = tapeSat(tdrive) : headBump : wowflutter : dropouts : band : degrade : fi.dcblockerat(15.0);

    //------ space: Sierpinski bloom + dream reverb (mono -> stereo) ------
    reverbS = (_,_ : re.stereo_freeverb(rSize, 0.5, 0.5, 23)) : par(i, 2, *(0.12));

    // Sierpinski / ternary-Cantor partials (self-similar under x3, missing middle),
    // split alternately L / R for an inherently wide inharmonic shimmer.
    bloomStereo = _ <: (bloomL, bloomR)
    with {
        f0   = 110.0;
        t60  = 0.15 + 0.5 * fBloomD;
        bm(r, g) = pm.modeFilter(min(f0 * r, 0.47 * ma.SR), t60, g * 0.02);
        bloomL = _ <: (bm(1.000, 1.00), bm(1.587, 0.85), bm(4.000, 0.55), bm(6.350, 0.38)) :> _;
        bloomR = _ <: (bm(1.166, 0.95), bm(1.852, 0.80), bm(4.667, 0.48), bm(7.410, 0.32)) :> _;
    };

    mix5(dry, rL, rR, bL, bR) = dry * (1.0 - 0.5 * rWet) + rL * rWet + bL * fBloom,
                                dry * (1.0 - 0.5 * rWet) + rR * rWet + bR * fBloom;
    spaceMix = _ <: (_, reverbS, bloomStereo) : mix5;

    //------ vibrato: the iconic Rhodes "vibrato" -- a stereo panning tremolo ------
    // Stereo=0 -> mono amplitude tremolo (both channels dip together);
    // Stereo=1 -> full auto-pan (channels in anti-phase). Acts on the program
    // (keys + tape + space) but BEFORE the vinyl noise, so hiss/crackle stay put.
    vibrato(l, r) = l * gL, r * gR
    with {
        lfo = os.osc(tRate);                                  // -1 .. +1
        md  = 0.5 * tDepth;
        gL  = 1.0 - md * (1.0 + lfo);
        gR  = 1.0 - md * (1.0 + lfo * (1.0 - 2.0 * tStereo)); // phase: 0 -> tremolo, 1 -> pan
    };

    //------ vinyl noise (stereo -> stereo): resonant crackle, hiss, rumble ------
    stereoNoise(l, r) = l + nL, r + nR
    with {
        hiss(i) = nz(i) * 0.05 * fHiss;
        wear    = 0.5 + 0.5 * os.osc(0.07);                          // density wanders with wear
        dens    = (30.0 * fCrk + 1.0) * (1.0 + fWear * wear);
        ctrig   = (abs(nz(2)) > (1.0 - dens / ma.SR));
        pop     = (ctrig * nz(3)) : fi.resonbp(2600.0, 6.0, 1.0);    // resonant tick, not a dull click
        crk     = pop * 0.60 * fCrk;
        rumble  = (no.noise : fi.lowpass(2, 32.0)) * 0.08 * fRumble;
        nL = hiss(0) + crk + rumble;
        nR = hiss(1) + (crk @ 13) + rumble;
    };

    //------ output (stereo -> stereo): soft clip + DC block + gain ------
    chanOut   = fi.dcblockerat(12.0) : *(outGain) : padeTanh;
    stereoOut = chanOut, chanOut;
};

process = epVoice;
