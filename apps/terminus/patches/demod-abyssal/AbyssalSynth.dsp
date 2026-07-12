declare name        "AbyssalSynth";
declare author      "Gemini (DeMoD Reference)";
declare description "Lofi underwater synth with OU pitch drift and saturated hydro-reflections";
declare version     "1.3";
declare license     "GPL-3.0";

// ┌──────────────────────────────────────────────────────────────────────────┐
// │  AbyssalSynth — Underwater Simulation                                     │
// │  Architecture:                                                             │
// │    · OU Process Pitch Drift (Tape/Current Simulation)                      │
// │    · Saturated Feedback Delay (Hydro-Reflections)                          │
// │    · Butterworth LP Cascade (Acoustic Water Absorption)                    │
// └──────────────────────────────────────────────────────────────────────────┘

import("stdfaust.lib");

// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  UI PARAMETERS                                                           ║
// ╚══════════════════════════════════════════════════════════════════════════╝

// All UI parameters are piped through si.smoo to prevent zipper noise.
f       = hslider("v:Synth/[1] Freq [unit:Hz]", 220, 40, 2000, 0.01) : si.smoo;
gate    = button("v:Synth/[2] Gate");
gain    = hslider("v:Synth/[3] Gain [unit:dB]", -12, -60, 0, 0.1) : ba.db2linear : si.smoo;

w_rate  = hslider("v:Lofi/[1] Current Rate [unit:Hz]", 0.3, 0.01, 4.0, 0.01) : si.smoo;
w_depth = hslider("v:Lofi/[2] Drift Depth", 0.25, 0.0, 1.0, 0.01) : si.smoo;

cutoff  = hslider("v:Water/[1] Water Cutoff [unit:Hz]", 400, 50, 4000, 1) : si.smoo;
res     = hslider("v:Water/[2] Pressure (Q)", 1.0, 0.5, 5.0, 0.01) : si.smoo;

fbk     = hslider("v:Reflections/[1] Feedback", 0.6, 0.0, 0.97, 0.01) : si.smoo;
dtime   = hslider("v:Reflections/[2] Delay [unit:ms]", 250, 1, 1000, 1) : *(0.001) : si.smoo;

// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  COMPONENTS                                                              ║
// ╚══════════════════════════════════════════════════════════════════════════╝

// --- Padé [3/2] tanh Approximant ---
// Provides smooth saturation for feedback paths to prevent runaway.
sat(x) = x * (27.0 + x*x) / (27.0 + 9.0*x*x);

// --- Ornstein-Uhlenbeck Stochastic Drift ---
// Corrected Implementation: _ ~ step creates a 0-input/1-output generator.
ouDrift(theta, sigma) = _ ~ step
with {
    alp  = exp(0.0 - theta / float(ma.SR));
    sigd = sigma * sqrt(1.0 - alp * alp);
    step(s) = s * alp + no.noise * sigd;
};

// --- Bandwidth-Limited Hydro-Delay ---
// H(z) = delay line with saturation and 2kHz LP in feedback.
hydroDelay(d, g) = (+ : de.fdelay(MAXD, d_samp)) ~ (lp_feed : *(g) : sat)
with {
    MAXD = int(2.0 * 192000); // 2.0s buffer at max 192kHz SR.
    d_samp = d * ma.SR;
    lp_feed = fi.lowpass(1, 2000); 
};

// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  PROCESS                                                                 ║
// ╚══════════════════════════════════════════════════════════════════════════╝

// 1. Calculate frequency with OU drift.
pitch_mod = ouDrift(w_rate, w_depth);
mod_freq  = f * pow(2.0, pitch_mod / 12.0);

// 2. Oscillator Source
// Using os.square instead of the contested 'pulse' name for a rich, filtered tone.
source = (os.triangle(mod_freq)*0.6 + os.square(mod_freq)*0.4) * en.adsr(0.1, 0.3, 0.5, 1.0, gate);

// 3. Signal Chain
// Source -> 4-pole Lowpass -> Delay -> Gain -> DC Block.
process = source 
          : fi.lowpass(4, cutoff)              
          : hydroDelay(dtime, fbk)             
          : *(gain)                            
          : fi.dcblockerat(35.0)               
          <: _,_;
