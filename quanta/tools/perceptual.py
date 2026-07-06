#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-DeMoD-Commercial
# perceptual.py — objective perceptual distortion for the Quanta codec.
#
# Implements NMR (Noise-to-Mask Ratio), the masking-weighted error metric that
# perceptual audio codecs are actually tuned against. Unlike LSD (tools/metrics.py),
# which weights every spectral bin equally, NMR asks the audibility question: is the
# reconstruction error BELOW the auditory masking threshold set by the signal?
#   NMR(band) = noise_energy(band) / masking_threshold(band)
#   NMR < 0 dB  => error is masked (inaudible);  NMR > 0 dB => audible distortion.
#
# This is a documented, music-appropriate OBJECTIVE PROXY — not a calibrated MOS.
# The masking model is a simplified Bark-band spread (Schroeder-style triangular
# spreading + a constant masking offset + the absolute threshold of hearing). It is
# deliberately dependency-light (pure numpy, no scipy/ViSQOL/PESQ) so it runs in the
# same devshell as the rest of the gate suite. Reference = source; test = codec out.
#
# Usage:
#   perceptual.py nmr <ref.f64> <test.f64> [sr] [gate_db]
#     prints median/mean frame NMR (dB) and % audible frames; exits nonzero if
#     median NMR exceeds gate_db (when given).
import sys, numpy as np

SR_DEFAULT = 48000
NFFT = 2048
HOP  = 512
MASK_OFFSET_DB = 14.5     # signal-to-mask margin (how far below the signal the mask sits)

def load(p): return np.fromfile(p, dtype='<f8')

def hz_to_bark(f):
    return 13.0*np.arctan(0.00076*f) + 3.5*np.arctan((f/7500.0)**2)

def abs_threshold_db(f):
    # Terhardt absolute threshold of hearing (dB SPL), floored; f in Hz.
    f = np.maximum(f, 20.0)/1000.0
    return (3.64*f**-0.8 - 6.5*np.exp(-0.6*(f-3.3)**2) + 1e-3*f**4)

def band_map(sr, nbands=25):
    freqs = np.fft.rfftfreq(NFFT, 1.0/sr)
    z = hz_to_bark(freqs)
    zmax = hz_to_bark(sr/2.0)
    idx = np.clip((z/zmax*nbands).astype(int), 0, nbands-1)
    # per-band centre freq for ATH
    fc = np.array([freqs[idx==b].mean() if np.any(idx==b) else 0.0 for b in range(nbands)])
    return idx, fc, nbands

def spread(E, nbands):
    # simple triangular spreading across Bark bands (downward + upward masking).
    out = np.zeros_like(E)
    for b in range(nbands):
        for c in range(nbands):
            dz = c - b
            # slopes: +25 dB/Bark up toward higher bands is unmasked; use -27/+ -10 dB/Bark
            sl = (-27.0*dz) if dz >= 0 else (10.0*dz)   # dB
            out[c] += E[b]*10.0**(sl/10.0)
    return out

def nmr(ref, test, sr):
    n = min(len(ref), len(test))
    ref, test = ref[:n], test[:n]
    idx, fc, nb = band_map(sr)
    ath_lin = 10.0**(abs_threshold_db(fc)/10.0)
    win = np.hanning(NFFT)
    frame_nmr = []
    for i in range(0, n-NFFT, HOP):
        s = ref[i:i+NFFT]
        if np.sqrt(np.mean(s*s)) < 1e-4:            # skip silence
            continue
        # MAGNITUDE-domain error: Quanta's residual is a noise-SUBSTITUTION model
        # (reproduces the spectral envelope with a different random realization), so
        # a waveform-difference metric would wrongly punish perceptually-inaudible
        # phase decorrelation. Compare |spectra| per band instead — masked-envelope
        # distortion, the right question for a parametric residual.
        Rm = np.abs(np.fft.rfft(s*win))
        Tm = np.abs(np.fft.rfft(test[i:i+NFFT]*win))
        R  = Rm*Rm                                  # signal power, for the mask
        N  = (Rm - Tm)**2                           # per-bin magnitude error power
        Eb = np.array([R[idx==b].sum() for b in range(nb)])
        Nb = np.array([N[idx==b].sum() for b in range(nb)])
        mask = spread(Eb, nb)*10.0**(-MASK_OFFSET_DB/10.0)
        # per-band NMR averaged over bands that actually carry signal (> -50 dB re
        # the loudest band). Avoids both the silent-band blow-up of a plain per-band
        # mean and the loud-band swamping of an energy-weighted sum.
        band_nmr = 10.0*np.log10(Nb/(mask+1e-30) + 1e-30)
        aud = Eb > (Eb.max()*1e-5 + 1e-30)
        if aud.any():
            frame_nmr.append(float(np.mean(band_nmr[aud])))
    if not frame_nmr:
        return None
    a = np.array(frame_nmr)
    return dict(median=float(np.median(a)), mean=float(np.mean(a)),
                audible_pct=float(100.0*np.mean(a > 0.0)), frames=len(a))

if __name__ == '__main__':
    if len(sys.argv) < 4 or sys.argv[1] != 'nmr':
        print("usage: perceptual.py nmr <ref.f64> <test.f64> [sr] [gate_db]", file=sys.stderr)
        sys.exit(2)
    ref, test = load(sys.argv[2]), load(sys.argv[3])
    sr = int(sys.argv[4]) if len(sys.argv) > 4 else SR_DEFAULT
    r = nmr(ref, test, sr)
    if r is None:
        print("nmr: no active frames"); sys.exit(0)
    print(f"nmr: median {r['median']:+.2f} dB  mean {r['mean']:+.2f} dB  "
          f"audible {r['audible_pct']:.1f}% of {r['frames']} frames  "
          f"(<0 dB = masked/inaudible)")
    if len(sys.argv) > 5:
        gate = float(sys.argv[5])
        print(f"gate P: median NMR <= {gate:+.1f} dB -> {'PASS' if r['median']<=gate else 'FAIL'}")
        sys.exit(0 if r['median'] <= gate else 1)
