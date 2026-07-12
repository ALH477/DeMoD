declare name        "MYCELIUM";
declare version     "1.4";
declare author      "Organic DSP";
declare license     "MIT";

//==============================================================================
// MYCELIUM — Organic Bio-Resonant Mycelium Network
//
// CONCEPT / INSPIRATION:
//   Mycorrhizal networks are the vast underground fungal webs that silently
//   connect entire forest ecosystems — relaying chemical and electrical signals
//   through kilometres of interwoven hyphae. MYCELIUM maps this biology
//   directly onto audio signal processing: six resonant "nodes" (hyphal tips)
//   exchange vibrational energy through a chaos-modulated coupling matrix,
//   driven by a real-time Lorenz attractor so no two decays are ever identical.
//   A nonlinear tube-inspired waveshaper acts as the metabolic engine, injecting
//   harmonic nutrients that feed the entire resonator ecosystem. The result is
//   an effect that is, in the most literal sense, alive — it breathes, shifts,
//   and mutates with every sustained note.
//
// CORE SONIC PERSONALITY:
//   On percussive transients: a metallic crystalline bloom that breathes and
//   wanders micro-tonally before dissolving into the noise floor. On sustained
//   tones: lush evolving spectral clouds with phantom inter-resonator beating
//   and continuously shifting overtone halos. High Coupling pushes the network
//   toward shimmering near-feedback. Low Coupling yields pristine decay trails.
//   The Shimmer layer adds octave-and-fifth sympathetic resonances reminiscent
//   of prepared piano struck behind the bridge or bowed crotales.
//
// SUGGESTED MUSICAL CONTEXTS AND SWEET SPOTS:
//   Ambient / drone    : Drive 0.30, Chaos 0.20, Decay 3-5s,    Mix 0.80
//   Prepared piano     : Drive 0.50, Spread 0.60, Coupling 0.40, Decay 2s
//   Percussion bloom   : Drive 0.60, Decay 0.5s,  Chaos 0.30,   Coupling 0.50
//   Pad augmentation   : Drive 0.20, Decay 4s,    Chaos 0.15,   Shimmer 0.40
//   Chaotic landscapes : Drive 0.40, Chaos 0.50,  Coupling 0.65, Breathe 2Hz
//   Field recording FX : Drive 0.10, Spread 0.8,  Decay 6s,     Chaos 0.35
//==============================================================================

import("stdfaust.lib");

//──────────────────────────────────────────────────────────────────────────────
// PARAMETERS
//──────────────────────────────────────────────────────────────────────────────

drive    = vslider("v:MYCELIUM/Drive[style:knob]
[tooltip:Input saturation — tube-style asymmetric harmonic injection]",
             0.30, 0.0, 1.0, 0.01) : si.smoo;

rootFreq = vslider("v:MYCELIUM/Root Freq[style:knob][unit:Hz]
[tooltip:Fundamental anchor — six nodes fan out via golden-ratio intervals]",
             220.0, 40.0, 2000.0, 0.5) : si.smoo;

spread   = vslider("v:MYCELIUM/Spread[style:knob]
[tooltip:Golden-ratio spread — 0 unison  1 wide inharmonic constellation]",
             0.50, 0.0, 1.0, 0.01) : si.smoo;

decayT   = vslider("v:MYCELIUM/Decay[style:knob][unit:s]
[tooltip:Network ring-out — Q auto-scales so every node decays in exactly this time]",
             2.5, 0.05, 8.0, 0.01) : si.smoo;

chaosAmt = vslider("v:MYCELIUM/Chaos[style:knob]
[tooltip:Lorenz pitch modulation depth — organic micro-pitch drift unique to each note]",
             0.20, 0.0, 1.0, 0.01) : si.smoo;

coupling = vslider("v:MYCELIUM/Coupling[style:knob]
[tooltip:Cross-node energy transfer — high values approach shimmering self-oscillation]",
             0.25, 0.0, 0.70, 0.01) : si.smoo;

shimmer  = vslider("v:MYCELIUM/Shimmer[style:knob]
[tooltip:Sympathetic overtone layer — 2nd and 3rd harmonic resonant halos]",
             0.15, 0.0, 1.0, 0.01) : si.smoo;

breathe  = vslider("v:MYCELIUM/Breathe[style:knob][unit:Hz]
[tooltip:Lorenz evolution speed — slow glacial drift  fast flickering turbulence]",
             0.30, 0.01, 4.0, 0.01) : si.smoo;

toneCtrl = vslider("v:MYCELIUM/Tone[style:knob]
[tooltip:Spectral tilt — negative dark warm  positive bright airy]",
             0.0, -1.0, 1.0, 0.01) : si.smoo;

wetMix   = vslider("v:MYCELIUM/Mix[style:knob]
[tooltip:Dry-wet balance — 0 fully dry  1 fully wet]",
             0.70, 0.0, 1.0, 0.01) : si.smoo;

//──────────────────────────────────────────────────────────────────────────────
// LORENZ CHAOTIC MODULATOR
//
// The correct FAUST pattern for a 3-state autonomous chaotic generator:
//
// lorenzStep(xp,yp,zp) -> (xn,yn,zn): 3-in 3-out step function.
// (lorenzStep ~ si.bus(3)): all 3 outputs fed back as the 3 inputs,
// leaving 0 external inputs and 3 external outputs — a pure generator.
// The internal kick impulse perturbs the system off the origin at t=0.
//──────────────────────────────────────────────────────────────────────────────

lorenzStep(xp, yp, zp) = xn, yn, zn
with {
  dt = max(1e-7, breathe) / float(ma.SR);
  k  = (1.0 - 1') * 0.001;
  xn = xp + dt * 10.0 * (yp - xp) + k;
  yn = yp + dt * (xp * (28.0 - zp) - yp);
  zn = zp + dt * (xp * yp - (8.0 / 3.0) * zp);
};

// lorenzStep has 3 ins, 3 outs. ~ si.bus(3) feeds all 3 outputs back
// as the 3 inputs -> 0 external inputs, 3 external outputs. Pure generator.
// The kick impulse inside lorenzStep escapes the fixed point at the origin.
// lx/ly/lz select individual axes; FAUST CSE shares the single instance.
lx = (lorenzStep ~ si.bus(3)) : (_, !, !);
ly = (lorenzStep ~ si.bus(3)) : (!, _, !);
lz = (lorenzStep ~ si.bus(3)) : (!, !, _);

//──────────────────────────────────────────────────────────────────────────────
// NONLINEAR WAVESHAPER
//──────────────────────────────────────────────────────────────────────────────

softclip(x)   = x / (1.0 + abs(x));
tubeSat(d, x) = softclip((1.0 + d * 14.0) * x + d * 0.05 * x * x);

//──────────────────────────────────────────────────────────────────────────────
// RESONATOR NODES
//
// fi.resonbp(freq, Q) is a processor; signal arrives via ':'.
// Q = pi * f * T60 gives consistent decay time across all pitches.
// Chaos modulation scales linearly with the attractor value (range ~+-15)
// giving +-2% pitch drift at full Chaos depth.
//──────────────────────────────────────────────────────────────────────────────

phi = 1.6180339887;

nodeQ(f)       = max(0.5, ma.PI * f * decayT);
nodeF(f, cmod) = max(20.0, min(18000.0, f * (1.0 + chaosAmt * 0.0013 * cmod)));

resonNode(f, cmod) = fi.resonbp(nodeF(f, cmod), nodeQ(f));

nf0 = rootFreq;
nf1 = rootFreq * pow(phi,  spread * 0.618);
nf2 = rootFreq * pow(phi,  spread * 1.000);
nf3 = rootFreq * pow(phi, -spread * 0.618);
nf4 = rootFreq * pow(phi,  spread * 1.618);
nf5 = rootFreq * pow(phi, -spread * 1.000);

shimF2 = max(20.0, min(18000.0, rootFreq * 2.0));
shimF3 = max(20.0, min(18000.0, rootFreq * 3.0));
shimQ2 = max(0.5, nodeQ(rootFreq) * 0.70);
shimQ3 = max(0.5, nodeQ(rootFreq) * 0.50);

shimBank = _ <: (fi.resonbp(shimF2, shimQ2), fi.resonbp(shimF3, shimQ3)) :> *(0.5);

//──────────────────────────────────────────────────────────────────────────────
// RESONATOR BANK
//──────────────────────────────────────────────────────────────────────────────

resoBank =
  _ <: ( resonNode(nf0, lx)
       , resonNode(nf1, ly)
       , resonNode(nf2, lz)
       , resonNode(nf3, lx)
       , resonNode(nf4, ly)
       , resonNode(nf5, lz)
       , (*(shimmer) : shimBank)
       ) :> *(1.0 / 6.0);

//──────────────────────────────────────────────────────────────────────────────
// COUPLING FEEDBACK NETWORK
//──────────────────────────────────────────────────────────────────────────────

fbCutoff = max(80.0, min(18000.0, rootFreq * 3.0));
fbGain   = coupling * 0.97;
fbProc   = fi.lowpass(2, fbCutoff) : *(fbGain);

resonNetwork = +~(resoBank : fbProc) : resoBank;

//──────────────────────────────────────────────────────────────────────────────
// SPECTRAL TILT FILTER
//──────────────────────────────────────────────────────────────────────────────

tcNeg = max(0.0, min(1.0, 0.0 - toneCtrl));
tcPos = max(0.0, min(1.0, toneCtrl));
lpCut = max(200.0, min(20000.0, 20000.0 * pow(10.0, tcNeg * (-1.7))));
hpCut = max(10.0,  min(2000.0,  10.0    * pow(100.0, tcPos)));

tiltFilter = fi.lowpass(1, lpCut) : fi.highpass(1, hpCut);

//──────────────────────────────────────────────────────────────────────────────
// MAIN PROCESS
//──────────────────────────────────────────────────────────────────────────────

wetChain = tubeSat(drive) : resonNetwork : tiltFilter;

process  = _ <: ( *(1.0 - wetMix)
                , (wetChain : *(wetMix))
                ) :> _;
