#!/usr/bin/env python3
"""Verification metrics (spec §7.4): null test + LSD/SNR vs source.

LSD methodology notes:
- Spectra are floored at -80 dB relative to the per-frame peak (of either
  signal), so empty bins of synthetic sources cannot dominate the metric.
- The source is passed through the identical output DC blocker
  (y = x - x' + 0.995*y') before comparison: the blocker is part of the
  artifact's output stage (SKILL v2), not modeling error.
Usage:
  metrics.py null a.f64 b.f64            (gate: peak <= -120 dBFS)
  metrics.py lsd  src.f64 ren.f64 [gate] (optional gate on active-frame LSD, dB)
"""
import numpy as np, sys

def load(p): return np.fromfile(p, dtype='<f8')
def dbfs(v): return 20*np.log10(max(v, 1e-30))

def dcb(x):
    y = np.empty_like(x); x1 = 0.0; y1 = 0.0
    for i in range(len(x)):
        y1 = x[i] - x1 + 0.995*y1; x1 = x[i]; y[i] = y1
    return y

cmd = sys.argv[1]
if cmd == 'null':
    a, b = load(sys.argv[2]), load(sys.argv[3])
    n = min(len(a), len(b)); d = a[:n]-b[:n]
    pk  = dbfs(float(np.max(np.abs(d))))
    rms = dbfs(float(np.sqrt(np.mean(d**2))))
    exact = np.array_equal(a[:n], b[:n])
    print(f"null: peak {pk:+.1f} dBFS  rms {rms:+.1f} dBFS  bit-exact={exact}")
    gate = -float(sys.argv[4]) if len(sys.argv) > 4 else -120.0
    sys.exit(0 if pk <= gate else 1)

if cmd == 'lsd':
    s, r = load(sys.argv[2]), load(sys.argv[3])
    n = min(len(s), len(r)); s, r = dcb(s[:n]), r[:n]
    W, H, FLOOR = 2048, 512, 10**(-80/20)
    w = np.hanning(W); acc = []; act = []
    for i in range(0, n-W, H):
        S = np.abs(np.fft.rfft(s[i:i+W]*w))
        R = np.abs(np.fft.rfft(r[i:i+W]*w))
        fl = max(float(S.max()), float(R.max()), 1e-12) * FLOOR
        S = np.maximum(S, fl); R = np.maximum(R, fl)
        v = float(np.sqrt(np.mean((20*np.log10(S)-20*np.log10(R))**2)))
        acc.append(v)
        if np.sqrt(np.mean(s[i:i+W]**2)) > 1e-3: act.append(v)
    lsd  = float(np.mean(acc))
    alsd = float(np.mean(act)) if act else float('nan')
    snr  = 10*np.log10(float(np.sum(s**2))/(float(np.sum((s-r)**2))+1e-300))
    print(f"lsd: {lsd:.2f} dB (all)  {alsd:.2f} dB (active)  snr: {snr:+.2f} dB"
          f"  [dcb-compensated, floor -80 dB re frame peak]")
    if len(sys.argv) > 4:
        gate = float(sys.argv[4])
        ok = alsd <= gate
        print(f"gate: active-frame LSD {'<=' if ok else '>'} {gate} dB -> {'PASS' if ok else 'FAIL'}")
        sys.exit(0 if ok else 1)
