#!/usr/bin/env python3
"""Deterministic test source: tonal strikes + transients + noise bed."""
import numpy as np, struct, sys
SR, DUR = 48000, 3.0
N = int(SR*DUR); t = np.arange(N)/SR
x = np.zeros(N)
def strike(t0, f0, partials, amps, taus, gain):
    global x
    for r, a, tau in zip(partials, amps, taus):
        tt = t - t0; env = np.where(tt >= 0, np.exp(-np.maximum(tt,0)/tau), 0.0)
        x += gain*a*env*np.sin(2*np.pi*f0*r*np.maximum(tt,0))
strike(0.20,  880.0, [1,2.76,5.40,8.93], [1,.55,.30,.15], [.9,.45,.25,.15], 0.45)
strike(1.60, 1046.5, [1,2.76,5.40],      [1,.50,.25],     [.8,.40,.20],     0.40)
strike(0.70, 1800.0, [1,1.6],            [1,.6],          [.015,.010],      0.50)  # woodblock
strike(2.30,  660.0, [1,2.76,5.40,8.93], [1,.55,.30,.15], [.9,.45,.25,.15], 0.35)
rng = np.random.default_rng(1477)
nz = rng.standard_normal(N)
b = np.zeros(N); acc = 0.0
for i in range(N): acc += 0.02*(nz[i]-acc); b[i] = acc          # gentle LP
x += b * (10**(-38/20)) / (np.sqrt(np.mean(b**2))+1e-12)
click = int(1.50*SR); x[click:click+96] += 0.5*np.hanning(96)*rng.standard_normal(96)
x *= 0.6/np.max(np.abs(x))
x.astype('<f8').tofile('test/src.f64')
d = x.astype('<f4').tobytes()
with open('test/src.wav','wb') as f:
    f.write(b'RIFF'+struct.pack('<I',36+len(d))+b'WAVEfmt '+struct.pack('<IHHIIHH',16,3,1,SR,SR*4,4,32)+b'data'+struct.pack('<I',len(d))+d)
print(f"gen_test: {N} samples @ {SR} -> test/src.wav")
