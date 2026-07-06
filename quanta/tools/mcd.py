#!/usr/bin/env python3
"""Mel/real-cepstral distortion (MCD) — the standard phase-independent vocoder metric.

Why MCD and not NMR for speech copy-synthesis: NMR (tools/perceptual.py) is a
magnitude-masking metric whose OLA re-analysis makes it acutely phase-sensitive, so
ANY parametric vocoder (which discards exact STFT phase by design) floors at ~+6-9 dB
NMR regardless of quality. MCD compares the smooth log-magnitude spectral ENVELOPE
frame by frame, independent of phase — how WORLD/STRAIGHT-class vocoders are judged.

Implementation notes:
- Features are the low-quefrency real cepstrum of the floored log-magnitude spectrum
  (coeffs 1..N-1; c0 = level/gain is dropped). Keeping only low quefrency compares the
  spectral ENVELOPE, not harmonic fine structure — so a sinusoidal synth's deep
  inter-harmonic nulls don't unfairly inflate the score.
- The per-frame magnitude floor is RELATIVE (-45 dB re frame peak). Calibration:
  additive noise at -30/-18/-12 dB SNR -> MCD ~0.1/0.7/1.1 dB; source vs itself = 0.
- Two orthogonal numbers: MCD over RECONSTRUCTED frames (envelope accuracy) and
  COVERAGE (fraction of source-active frames the synth actually fills, not >10 dB
  quieter) — a model that drops consonants/transitions is caught on coverage, not
  hidden by masking the way NMR hides it.

  MCD = (10/ln10) * sqrt( 2 * sum_{k>=1} (c_ref[k] - c_syn[k])^2 )   [per frame]

Usage:
  mcd.py ref.f64 syn.f64 [sr] [mcd_gate_dB] [coverage_gate_frac]
"""
import numpy as np, sys

def load(p): return np.fromfile(p, dtype='<f8')

def cepstra(x, sr, W=1024, H=256, ncep=25, floordb=-45.0):
    w = np.hanning(W); c=[]; en=[]
    for i in range(0, len(x)-W, H):
        X = np.abs(np.fft.rfft(x[i:i+W]*w))
        fl = max(float(X.max()), 1e-30) * 10**(floordb/20)      # relative floor
        lm = np.log(np.maximum(X, fl))
        rc = np.fft.irfft(lm)                                    # real cepstrum
        c.append(rc[:ncep].copy())                              # low quefrency = envelope
        en.append(float(np.mean(x[i:i+W]**2)))
    return np.array(c), np.array(en)

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("usage: mcd.py ref.f64 syn.f64 [sr] [mcd_gate] [cov_gate]"); sys.exit(2)
    ref, syn = load(sys.argv[1]), load(sys.argv[2])
    sr = int(sys.argv[3]) if len(sys.argv) > 3 else 48000
    n = min(len(ref), len(syn)); ref, syn = ref[:n], syn[:n]
    cr, en = cepstra(ref, sr); cs, es = cepstra(syn, sr)
    m = min(len(cr), len(cs)); cr, cs, en, es = cr[:m], cs[:m], en[:m], es[:m]
    act = en > np.max(en) * 10**(-40/10)                         # source-active frames
    lvl = 10.0*np.log10((es+1e-30)/(en+1e-30))
    both = act & (lvl > -10.0)                                   # reconstructed (not dropped)
    d = cr[:,1:] - cs[:,1:]                                      # drop c0 (level/gain)
    per = (10.0/np.log(10.0))*np.sqrt(2.0*np.sum(d**2, axis=1))
    mcd_both = float(np.mean(per[both])) if np.any(both) else float('nan')
    cov = float(np.mean(both[act])) if np.any(act) else 0.0
    print(f"mcd: {mcd_both:.3f} dB (reconstructed)  coverage {100*cov:.1f}% "
          f"of {int(np.sum(act))} source-active frames")
    if len(sys.argv) > 4:
        gate = float(sys.argv[4]); covgate = float(sys.argv[5]) if len(sys.argv)>5 else 0.90
        ok = (mcd_both <= gate) and (cov >= covgate)
        print(f"gate H1: MCD {mcd_both:.2f}<={gate} AND coverage {100*cov:.1f}%>={100*covgate:.0f}% "
              f"-> {'PASS' if ok else 'FAIL'}")
        sys.exit(0 if ok else 1)
