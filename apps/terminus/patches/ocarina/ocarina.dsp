//==============================================================================
//  DeMoD Ocarina  —  ocarina.dsp
//------------------------------------------------------------------------------
//  Physical model of the classic Italian transverse (Budrio-style) ocarina,
//  an Alto-C vessel flute, after Giuseppe Donati (Budrio, 1853).
//
//  This is NOT a noise-excited resonator. It is a genuine self-sustained
//  air-reed oscillator: a steady breath pressure drives a jet that interacts
//  with the labium and feeds energy into the Helmholtz cavity resonance through
//  a delayed, saturating feedback loop. Pitch emerges from the physics of the
//  loop (cavity resonance + jet-convection phase), not from filtering noise.
//
//  ── ACOUSTIC MODEL ─────────────────────────────────────────────────────────
//  The ocarina is a Helmholtz resonator (Donati's own description). Its pitch
//  is set by the ratio of the *summed open-hole area* to the cavity volume:
//
//        f0 = (c / 2pi) * sqrt( SUM(A_open) / (V * L_eff) )                 (1)
//
//  Unlike a tube, hole *position* is irrelevant — only the total open area
//  matters (Kobayashi/Miyamoto et al., compressible LES, arXiv:0911.3567,
//  arXiv:1005.3413). In this synth each MIDI note IS a fingering: the played
//  frequency `freq` is the target Helmholtz frequency f0 of (1), so we drive
//  the cavity resonator directly at `freq`. The physical constant in (1) is
//  kept in the comments for documentation; the synth needs only f0.
//
//  ── EXCITATION (jet drive, Verge/Fabre/Auvray formalism) ───────────────────
//  Bernoulli jet velocity from blowing pressure dP:
//        U_j = sqrt( 2 dP / rho )                                           (2)
//  Convection speed of jet perturbations and the convection delay across the
//  flue-to-labium distance W:
//        c_p = 0.4 * U_j ,   tau = W / c_p                                  (3)
//  Acoustic velocity u at the flue exit seeds a transverse jet displacement
//  eta0 = (h/U_j) u, convected and exponentially amplified to the labium:
//        eta(W,t) = exp(alpha W) * eta0(t - tau) ,  alpha ~ 0.3/h           (4)
//  At the labium the jet position relative to the edge produces a dipole
//  source through an ODD, SATURATING nonlinearity (the jet swings fully to one
//  side — this is what bounds the limit-cycle amplitude):
//        p_src ~ d/dt[ tanh( (eta - y0)/b ) ]                              (5)
//  plus a nonlinear vortex-shedding loss ~ u^2 sign(u). The self-oscillation
//  condition is the loop phase balance arg(Y) + pi/2 - w*tau = 2*m*pi: the
//  jet transit is ~ a quarter/half period at resonance, supplying the energy.
//
//  In the digital model the loop is: cavity-resonator output -> jet convection
//  delay -> saturating jet nonlinearity (energy in) - vortex loss -> back into
//  the resonator. Small-signal loop gain > 1 makes a seed grow; the tanh
//  compresses it to a stable limit cycle. The resonator sits AFTER the
//  nonlinearity inside the loop, so it band-limits the fed-back harmonics and
//  suppresses in-loop aliasing for free. Breath sets U_j -> tau (real jet
//  timbre/detune) and the loop gain (threshold + brightness), reproducing the
//  ocarina's "needs minimum pressure to speak" and "pitch rises with breath".
//
//  ── DeMoD SKILL STANDARD (non-negotiable) ──────────────────────────────────
//    * Ornstein-Uhlenbeck LFOs via sk.ouLFO (analytically normalized
//      sqrt(3 SR/pi rate) pre-scale) for vibrato / tremolo / breath flutter /
//      micro-pitch entropy.
//    * Pade [3,2] rational-tanh saturator via sk.pade32 as the odd
//      nonlinearity (jet drive + voicing + output seatbelt).
//    * sk.dezip / sk.dezipTau on every continuous control, tiered:
//      5 ms breath, 10 ms pitch, 40 ms general.
//    * sk.dcblock on OUTPUT only — explicitly OUTSIDE the oscillation loop
//      (a DC blocker inside the loop would kill the low-frequency loop
//      dynamics and de-tune the resonance).
//
//  ── DSP PITFALLS HANDLED ────────────────────────────────────────────────────
//    * Division-by-velocity blow-up (eqs 3,4): jet velocity is floored at
//      U_MIN, so tau and the coupling never diverge at low breath. The whole
//      drive is gated below threshold so the model is SILENT, not divergent,
//      at zero breath.
//    * Unbounded exp amplification: exp(alpha W) is a finite geometric factor
//      folded into the (tuned, marginal) loop gain — no open-ended exp.
//    * Feedback runaway: resonator poles |p|<1 by construction; net loop gain
//      is marginal and the smooth tanh (not a hard clip) sets the limit cycle.
//    * In-loop nonlinearity aliasing: resonator follows the nonlinearity in the
//      loop and band-limits it; voicing harmonics stay < Nyquist/3.
//    * Fractional-delay detuning: interpolated delay on the convection path;
//      the high-Q resonator anchors pitch so delay error is not pitch-critical.
//    * Denormal stall: an infinitesimal DC term is injected into the loop.
//    * Parameter-smoothing clicks: tiered si.smoo before all expensive maps.
//==============================================================================

declare name        "DeMoD Ocarina";
declare version     "1.1.0";
declare author      "DeMoD LLC";
declare license     "DeMoD Commercial Source License / BSD-3 (community)";
declare description "Self-oscillating jet-drive Helmholtz model of the Italian transverse (Budrio) Alto-C ocarina.";
declare options     "[midi:on]";

import("stdfaust.lib");
sk = library("demod_skill.lib");

//==============================================================================
//  0.  CONSTANTS
//==============================================================================
SR       = ma.SR;
PI       = ma.PI;
TWOPI    = 2.0 * PI;

// Physical constants ----------------------------------------------------------
C_SOUND  = 343.0;          // speed of sound [m/s] @ ~20 C
RHO      = 1.2;            // air density   [kg/m^3]

// Alto-C Italian transverse ocarina geometry (dossier; maker-measured proxies)
H_WIND   = 0.0013;         // windway height (flue channel)        ~1.3 mm
W_MOUTH  = 0.0080;         // flue-exit -> labium jet travel       ~8 mm
DP_MAX   = 900.0;          // blowing pressure at full breath      [Pa]
U_MIN    = 3.0;            // jet-velocity floor (anti-blow-up)    [m/s]

// Loop / numeric constants ----------------------------------------------------
MAXDEL   = 4096;           // max convection delay line [samples] (covers low breath)
DENORM   = 1.0e-20;        // denormal guard injected into the loop
SEED_LVL = 1.0e-4;         // startup seed amplitude (dwarfed by the limit cycle)

OUT_TRIM = 0.45;              // post-oscillator gain (headroom before voicing)
G0_MIN   = 0.95;              // minimum small-signal loop gain (below oscillation threshold)
G0_MAX   = 1.85;              // maximum small-signal loop gain (hard blow, rich tone)

// sk.dezip tiers (SKILL-mandated smoothing) ----------------------------------
smBreath = sk.dezipTau(0.005);   // 5 ms  — breath / pressure
smPitch  = sk.dezipTau(0.010);   // 10 ms — pitch / fingering
smGen    = sk.dezipTau(0.040);   // 40 ms — general controls

//==============================================================================
//  1.  SATURATOR  —  now delegated to sk.pade32 (Pade [3,2] rational tanh,
//      x(105+10x²)/(105+45x²+x⁴)), imported from demod_skill.lib.
//      Same formula as before; the library version adds an analytic
//      antiderivative (pade32F1) for ADAA if needed.
//==============================================================================

//==============================================================================
//  2.  ORNSTEIN-UHLENBECK LFO  —  now delegated to sk.ouLFO (demod_skill.lib).
//      Same formula: white noise pre-scaled by sqrt(3 SR/(pi rate)), 1-pole
//      low-passed, soft-clipped through pade32. Unit output variance.
//      `nz` is a DECORRELATED white-noise stream (no.noises bank).
//==============================================================================

// Decorrelated white-noise bank (one stream per modulator)
NZN      = 8;
nzVib    = no.noises(NZN, 0);
nzTrem   = no.noises(NZN, 1);
nzFlut   = no.noises(NZN, 2);
nzEntr   = no.noises(NZN, 3);
nzBreath = no.noises(NZN, 4);   // broadband breath turbulence
nzChiff  = no.noises(NZN, 5);   // articulation chiff
nzSeedL  = no.noises(NZN, 6);   // loop startup seed
nzBreaR  = no.noises(NZN, 7);   // right-channel breath (stereo decorrelation)

//==============================================================================
//  3.  CONTROL SURFACE  (MIDI-mapped; DeMoD UI Lua surface drives the same IDs)
//==============================================================================
// --- Note / performance (auto-mapped by faust2jack -midi) --------------------
freq   = hslider("h:[0]Performance/[0]freq[unit:Hz][tooltip:Played pitch = target Helmholtz frequency]", 523.25, 80.0, 2200.0, 0.001);
gate   = button ("h:[0]Performance/[1]gate[tooltip:Note on/off]");
gain   = hslider("h:[0]Performance/[2]gain[tooltip:Note velocity]", 0.85, 0.0, 1.0, 0.001);
breathCC = hslider("h:[0]Performance/[3]breath[midi:ctrl 2][tooltip:Breath controller (CC2)]", 0.0, 0.0, 1.0, 0.001);
bendSemi = hslider("h:[0]Performance/[4]bend[midi:pitchwheel][tooltip:Pitch bend, semitones]", 0.0, -2.0, 2.0, 0.001);

// --- Embouchure / jet physics ------------------------------------------------
loopG  = hslider("h:[1]Embouchure/[0]pressure_gain[tooltip:Loop gain scaler (blowing strength -> oscillation)]", 2.0, 0.5, 4.0, 0.001);
drvB   = hslider("h:[1]Embouchure/[1]jet_drive[tooltip:Jet nonlinearity depth (timbre/edge)]", 1.2, 0.3, 3.0, 0.001);
lossC  = hslider("h:[1]Embouchure/[2]vortex_loss[tooltip:Nonlinear vortex-shedding loss]", 0.05, 0.0, 0.5, 0.001);

// --- Resonator (Helmholtz cavity) --------------------------------------------
qRes   = hslider("h:[2]Cavity/[0]resonance[tooltip:Cavity Q — higher = purer/stronger pitch anchor]", 28.0, 6.0, 60.0, 0.01);
voiceM = hslider("h:[2]Cavity/[1]voicing[tooltip:Harmonic voicing (Italian brightness)]", 0.12, 0.0, 0.6, 0.001);

// --- Breath behaviour --------------------------------------------------------
bThr   = hslider("h:[3]Breath/[0]threshold[tooltip:Minimum breath to speak]", 0.18, 0.0, 0.6, 0.001);
bPitch = hslider("h:[3]Breath/[1]breath_pitch[tooltip:Pitch rise with breath, semitones]", 0.6, 0.0, 2.0, 0.001);
brthLv = hslider("h:[3]Breath/[2]breath_noise[tooltip:Air/breath sound level]", 0.06, 0.0, 0.3, 0.001);
attMs  = hslider("h:[3]Breath/[3]attack_ms[tooltip:Keyboard attack (chiff onset)]", 18.0, 1.0, 200.0, 0.1) * 0.001;
relMs  = hslider("h:[3]Breath/[4]release_ms[tooltip:Keyboard release]", 90.0, 5.0, 600.0, 0.1) * 0.001;

// --- Modulation (OU) ---------------------------------------------------------
vibD   = hslider("h:[4]Vibrato/[0]depth[tooltip:Vibrato depth]", 0.010, 0.0, 0.05, 0.0001);
vibR   = hslider("h:[4]Vibrato/[1]rate_hz[tooltip:Vibrato rate]", 5.2, 0.5, 9.0, 0.01);
tremD  = hslider("h:[4]Vibrato/[2]tremolo[tooltip:Tremolo (amplitude flutter) depth]", 0.06, 0.0, 0.4, 0.001);
flutD  = hslider("h:[4]Vibrato/[3]breath_flutter[tooltip:Breath-pressure flutter]", 0.05, 0.0, 0.3, 0.001);
entrD  = hslider("h:[4]Vibrato/[4]tuning_drift[tooltip:Slow micro-pitch entropy (humanize)]", 0.004, 0.0, 0.03, 0.0001);

// --- Output ------------------------------------------------------------------
width  = hslider("h:[5]Output/[0]stereo_air[tooltip:Stereo width of breath air]", 0.5, 0.0, 1.0, 0.001);
master = hslider("h:[5]Output/[1]master[unit:dB][tooltip:Output level]", -6.0, -60.0, 6.0, 0.1) : ba.db2linear : smGen;

//==============================================================================
//  4.  BREATH / DRIVE
//      Unified breath: a breath controller (CC2) if present, otherwise a
//      gate-driven ASR envelope scaled by velocity (so a keyboard plays it).
//==============================================================================
gateEnv  = en.asr(attMs, 1.0, relMs, gate) * gain;     // keyboard breath shape
breathRaw = max(breathCC, gateEnv);                    // controller OR keyboard
flutter  = 1.0 + flutD * sk.ouLFO(0.9, nzFlut);              // slow OU breath flutter
breath   = (breathRaw : smBreath) * flutter : max(0.0);// smoothed live breath

// Above-threshold normalized breath that actually drives the oscillation
bActive  = max(0.0, breath - bThr) / max(0.001, 1.0 - bThr);

//==============================================================================
//  5.  JET KINEMATICS  (eqs 2-3, division-by-velocity made safe)
//==============================================================================
dP        = breath * DP_MAX;                            // blowing pressure [Pa]
uJet      = max(U_MIN, sqrt(2.0 * dP / RHO));           // Bernoulli, FLOORED
cConv     = 0.4 * uJet;                                 // convection speed
tauSec    = W_MOUTH / cConv;                            // convection delay [s]
tauSamp   = max(1.5, min(MAXDEL - 2.0, tauSec * SR)) : smBreath;  // [samples], safe

//==============================================================================
//  6.  PITCH  (resonator centre frequency)
//      f0 from MIDI (the fingering), * bend, * bounded breath-pitch rise,
//      * vibrato, * slow tuning entropy. Smoothed and clamped.
//==============================================================================
bendRatio   = ba.semi2ratio(bendSemi);
breathRise  = ba.semi2ratio(bPitch * bActive);          // pitch rises with breath
vibrato     = 1.0 + vibD  * sk.ouLFO(vibR, nzVib);
entropy     = 1.0 + entrD * sk.ouLFO(0.12, nzEntr);
fcTarget    = freq * bendRatio * breathRise * entropy : smPitch;
fc          = (fcTarget * vibrato) : max(20.0) : min(SR * 0.45);

//==============================================================================
//  7.  THE SELF-OSCILLATING JET-DRIVE LOOP
//------------------------------------------------------------------------------
//  The Helmholtz cavity is a LUMPED resonator: it has one mode and its
//  resonance sets the pitch. The core oscillation loop is therefore DELAY-FREE
//  (resonbp has 0 phase at fc, so the limit cycle lands exactly on fc); a
//  convection delay placed *inside* this loop would fight the cavity for phase
//  control and detune it. The jet supplies energy as a NEGATIVE RESISTANCE
//  (Re(Yj) < 0 in the dossier's network condition) that saturates with
//  amplitude — this both starts the oscillation and limits the limit cycle.
//
//  jetNorm(v): odd jet characteristic NORMALIZED to unit small-signal slope, so
//  `g0` alone is the small-signal loop gain (independent of how hard we drive
//  the saturation). We run g0 just above the Hopf bifurcation (g0 ~ 1.0 -> 1.9)
//  so the oscillation is a clean near-sinusoid at fc (the resonbp also
//  band-limits the jet harmonics -> negligible in-loop aliasing). driveDep
//  controls ONLY the harmonic richness / brightness (Italian voicing).
//
//  The physical jet convection (eqs 3-4) is preserved as a bounded PARALLEL
//  edge-tone colour (section 8) and as the explicit breath->pitch coupling
//  (section 6) — it shapes timbre and detune without destabilising tuning.
//==============================================================================
g0       = (G0_MIN + (loopG - 0.5) / 3.5 * (G0_MAX - G0_MIN) * bActive) : smBreath;
driveDep = (drvB * (0.7 + 0.5 * bActive)) : smBreath;   // saturation depth -> brightness

jetNorm(v) = (1.0 / driveDep) * sk.pade32(driveDep * v);// unit slope at v=0
loss(v)    = lossC * v * abs(v);                        // nonlinear vortex loss
jetSource(v) = g0 * jetNorm(v) - loss(v);               // negative resistance + loss

// One loop step: jet drive + seed (+ denormal guard) -> Helmholtz resonator.
// resonbp AFTER the nonlinearity band-limits the feedback (free anti-alias).
cavityStep(vFb, s) = (jetSource(vFb) + s + DENORM) : fi.resonbp(fc, qRes, 1.0);

// Close the loop: resonator output is fed back as vFb (1-sample delay via `~`).
oscillator = cavityStep ~ _;

// Seed: a tiny breath-gated noise to kick the limit cycle into existence.
seed     = nzSeedL * SEED_LVL * (bActive : smBreath);
voiceRaw = (seed : oscillator) * OUT_TRIM;

//==============================================================================
//  8.  VOICING + BREATH AIR + OUTPUT CHAIN
//      voicing: add a touch of saturated harmonic content (Italian brightness);
//      its partials sit < Nyquist/3 so aliasing is negligible.
//      breath air: decorrelated, breath-tracking noise (NOT a pitch source),
//      band-shaped and mixed post-loop for realism + stereo.
//      chiff: fast onset transient on note attack.
//==============================================================================
voiced   = voiceRaw + voiceM * sk.pade32(driveDep * voiceRaw);
tremolo  = 1.0 + tremD * sk.ouLFO(tremD : *(6.0) : +(3.5), nzTrem);  // OU tremolo (rate ~3.5-5.9 Hz)

// articulation chiff: short burst at the rising edge of gate
chiffTrig = gate > gate';
chiffEnv  = en.ar(0.002, 0.045, chiffTrig);
chiff     = (nzChiff : fi.bandpass(2, 1500.0, 5000.0)) * chiffEnv * 0.25;

// steady breath air, band-limited; left/right decorrelated for width
airL = (nzBreath : fi.bandpass(2, 1200.0, 7000.0)) * brthLv * (0.4 + 0.6 * bActive);
airR = (nzBreaR  : fi.bandpass(2, 1200.0, 7000.0)) * brthLv * (0.4 + 0.6 * bActive);

tone   = (voiced * tremolo + chiff) : max(-2.0) : min(2.0);
wetL   = (tone + width * airL) ;
wetR   = (tone + width * airR) ;

// DC block on OUTPUT ONLY (outside the loop), then master gain, then a gentle
// Pade seatbelt limiter (transparent at normal level, bounded under fault).
chain  = _ : sk.dcblock : *(master) : *(0.7) : sk.pade32 : *(1.0/0.7);

process = wetL, wetR : chain, chain;
