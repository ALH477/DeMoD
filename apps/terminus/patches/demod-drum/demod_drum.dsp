declare name        "DeMoD Drum";
declare version     "1.0";
declare author      "DeMoD LLC";
declare license     "GPL-3.0";
declare description "Circular membrane drum via Bessel modal synthesis";

import("stdfaust.lib");

// ================================================================
//  DEMOD CIRCULAR MEMBRANE DRUM SYNTHESIZER
//
//  Governing PDE (damped 2D wave equation on disk):
//    ∂²z/∂t² + 2γ·∂z/∂t = c²·∇²z,   z(R,θ,t) = 0   (Dirichlet BC)
//
//  Eigenfunctions:   z_mn = J_m(α_mn·r/R)·cos(mθ)·e^{-γt}·sin(ω_mn·t)
//  Eigenfrequencies: ω_mn = (c/R)·α_mn
//  Wave speed:       c = √(T/σ)
//
//  Mode amplitudes (strike projection integral):
//    A_mn = ∫ V(r,θ)·J_m(k_mn·r)·cos(mθ) dA
//         → J_m(α_mn · r_strike) · cos(m · θ_strike)
//
//  Key physics:
//    1. Inharmonicity: α_mn ratios (1.593, 2.136, 2.295...) non-integer
//    2. Center strike: J_m(0)=0 for m>0 → only axisymmetric modes fire
//    3. Air coupling: acoustic mass load depresses ω_01
//    4. Damping: γ_mn ∝ α_mn → higher modes decay faster
//
//  8 x 2-pole modal resonators (reson filter bank)
//  Modes: (0,1)(1,1)(2,1)(0,2)(3,1)(1,2)(2,2)(0,3)
// ================================================================

// ---- MIDI-compatible host controls ----
freq   = hslider("freq[unit:Hz][style:knob]",  60.0, 20.0, 2000.0, 0.1);
gain   = hslider("gain[style:knob]",            0.8,  0.0,  1.0,   0.01);
gate   = button("gate");

// ---- Physical parameters ----
damp   = vslider("v:Drum/[0]Damping
[tooltip:Viscoelastic loss γ; scales all modal decay rates]",
                  0.15, 0.001, 1.0,  0.001) : si.smoo;
t60b   = vslider("v:Drum/[1]Decay [s]
[tooltip:T60 of fundamental (0,1) mode at low damping]",
                  1.5,  0.05,  8.0,  0.01)  : si.smoo;
airld  = vslider("v:Drum/[2]Air Load
[tooltip:Acoustic mass loading from enclosed shell volume; lowers ω_01]",
                  0.05, 0.0,   0.4,  0.001) : si.smoo;
mbal   = vslider("v:Drum/[3]Overtones
[tooltip:Amplitude scale for all modes above fundamental]",
                  0.6,  0.0,   1.0,  0.001) : si.smoo;
vol    = vslider("v:Drum/[4]Volume",
                  0.8,  0.0,   1.0,  0.01)  : si.smoo;

// ---- Strike position ----
sr     = vslider("v:Strike/[0]Radius
[tooltip:0=center (m>0 nulled), 0.8=near rim (full spectrum)]",
                  0.3, 0.0, 0.95, 0.001) : si.smoo;
sth    = vslider("v:Strike/[1]Angle  (0..1 = 0..2π)
[tooltip:Azimuthal position; weights cos(mθ) for diametric modes]",
                  0.0, 0.0, 1.0,  0.001) : si.smoo;

// ================================================================
// Derived physics
// ================================================================

// Air mass loading: Rayleigh integral shifts effective surface density
// up → ω_01 drops proportionally (~28% of loading fraction here)
f01    = freq * (1.0 - airld * 0.28);
th_rad = sth * 2.0 * ma.PI;

// Modal frequency ratio
f_mn(alpha)   = f01 * alpha / 2.4048;

// T60 per mode: γ_mn ∝ α_mn (bending + radiation losses scale with ω)
t60_mn(alpha) = max(0.005,
    t60b * pow(2.4048 / alpha, 1.5) * (1.0 - damp * 0.95));

// ================================================================
// Bessel function approximations  J_m(α_mn · r_strike)
// ================================================================
// Strategy:
//   x ≤ 2.5  →  polynomial series (A&S §9.1.10), arg clamped for stability
//   x > 2.5  →  Debye asymptotic (DLMF 10.17.3):
//               J_m(x) ≈ √(2/πx) · cos(x − mπ/2 − π/4)
// Discontinuity at x=2.5 is perceptually inaudible.
// ----------------------------------------------------------------

// Asymptotic: guarded against x=0 (center strike on m>0 modes)
jm_asym(m, x) = sqrt(2.0 / (ma.PI * max(x, 0.000001)))
              * cos(x - float(m) * ma.PI * 0.5 - ma.PI * 0.25);

// Polynomial series, clamped input
j0_poly(x) = 1.0 - xc*xc*0.25 + xc*xc*xc*xc/64.0 - xc*xc*xc*xc*xc*xc/2304.0
             with { xc = min(x, 2.5); };
j1_poly(x) = xc * (0.5 - xc*xc/16.0 + xc*xc*xc*xc/384.0)
             with { xc = min(x, 2.5); };
j2_poly(x) = xc*xc * (0.125 - xc*xc/96.0 + xc*xc*xc*xc/3072.0)
             with { xc = min(x, 2.5); };

// Piecewise: select2(cond, s_when_false, s_when_true)
j0(x) = select2(x > 2.5, j0_poly(x), jm_asym(0, x));
j1(x) = select2(x > 2.5, j1_poly(x), jm_asym(1, x));
j2(x) = select2(x > 2.5, j2_poly(x), jm_asym(2, x));
j3(x) = jm_asym(3, x);   // m=3 min arg = 6.38·sr → always asymptotic

// ================================================================
// Strike amplitude projection
//   A_mn = J_m(α_mn · r_strike) · cos(m · θ_strike) · gain
//
//   sr=0: J_m(0) = δ_{m,0}  → pure fundamental tone (only m=0 rings)
//   sr→rim: full modal spectrum
//   θ_strike: weights the cos(mθ) pattern on m>0 diametric modes
// ================================================================
amp_mn(m, alpha, jm) = jm(alpha * sr) * cos(float(m) * th_rad) * gain;

// ================================================================
// 2-Pole Modal Resonator  (Reson / biquad)
//
//   H(z) = b0 / (1 + a1·z⁻¹ + a2·z⁻²)
//
//   Poles:  z± = r_p · e^{±j·θ_p}
//     r_p  = 0.001^{1/(T60·SR)}   (radius from T60)
//     θ_p  = 2π·f / SR             (angle from modal frequency)
//
//   Impulse response: r_p^n · sin((n+1)·θ_p)  ← decaying sinusoid @ f
//   b0 = sin(θ_p) normalizes peak to ≈ 1
//
//   Equivalent to pm.modeFilter(f, t60, 1.0) from physmodels.lib
// ================================================================
modalRes(f, t60) = fi.tf2(b0, 0.0, 0.0, a1, a2)
with {
    r_p  = pow(0.001, 1.0 / (t60 * float(ma.SR)));
    th_p = 2.0 * ma.PI * f / float(ma.SR);
    a1   = -2.0 * r_p * cos(th_p);
    a2   = r_p * r_p;
    b0   = sin(th_p);
};

// Gate → unit impulse on rising edge
impulse = gate : ba.impulsify;

// Mode constructor: impulse scaled by projection → resonator
mkMode(m, alpha, jm, scale) =
    impulse * (amp_mn(m, alpha, jm) * scale)
    : modalRes(f_mn(alpha), t60_mn(alpha));

// ================================================================
// Bessel zeros  α_mn  (DLMF Table 10.21.1)
//
//  Mode    α_mn    Freq ratio    Nodal geometry
//  ──────────────────────────────────────────────────────────
//  (0,1)   2.4048   1.000        no nodal lines (pure dome)
//  (1,1)   3.8317   1.593        1 nodal diameter
//  (2,1)   5.1356   2.136        2 nodal diameters  (X)
//  (0,2)   5.5201   2.295        1 nodal circle
//  (3,1)   6.3802   2.653        3 nodal diameters  (*)
//  (1,2)   7.0156   2.917        1 diameter + 1 circle
//  (2,2)   8.4172   3.500        2 diameters + 1 circle
//  (0,3)   8.6537   3.598        2 nodal circles
//
//  Inharmonicity: zero integer ratios → percussive, non-pitched timbre
// ================================================================

// m=0 axisymmetric: θ-independent, always excited regardless of strike angle
m01 = mkMode(0, 2.4048, j0, 1.0 );  // fundamental — never scaled down
m02 = mkMode(0, 5.5201, j0, mbal);
m03 = mkMode(0, 8.6537, j0, mbal);

// m=1 diametric
m11 = mkMode(1, 3.8317, j1, mbal);
m12 = mkMode(1, 7.0156, j1, mbal);

// m=2 diametric
m21 = mkMode(2, 5.1356, j2, mbal);
m22 = mkMode(2, 8.4172, j2, mbal);

// m=3 diametric
m31 = mkMode(3, 6.3802, j3, mbal);

// ================================================================
// Mix + output
// ================================================================
drum = (m01 + m02 + m03
      + m11 + m12
      + m21 + m22
      + m31) * (vol / 8.0);

process = drum <: _, _;
