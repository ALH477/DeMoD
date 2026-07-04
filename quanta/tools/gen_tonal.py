#!/usr/bin/env python3
"""M0 acceptance corpus: pure tonal strikes (glockenspiel-class)."""
import numpy as np, struct
SR, DUR = 48000, 3.0
N = int(SR*DUR); t = np.arange(N)/SR
x = np.zeros(N)
def strike(t0, f0, partials, amps, taus, gain):
    global x
    for r, a, tau in zip(partials, amps, taus):
        tt = t - t0; env = np.where(tt >= 0, np.exp(-np.maximum(tt,0)/tau), 0.0)
        x += gain*a*env*np.sin(2*np.pi*f0*r*np.maximum(tt,0))
strike(0.20,  880.0, [1,2.76,5.40,8.93], [1,.55,.30,.15], [.9,.45,.25,.15], 0.45)
strike(1.20, 1046.5, [1,2.76,5.40],      [1,.50,.25],     [.8,.40,.20],     0.40)
strike(2.10,  660.0, [1,2.76,5.40,8.93], [1,.55,.30,.15], [.9,.45,.25,.15], 0.35)
x *= 0.6/np.max(np.abs(x))
x.astype('<f8').tofile('test/tonal.f64')
d = x.astype('<f4').tobytes()
with open('test/tonal.wav','wb') as f:
    f.write(b'RIFF'+struct.pack('<I',36+len(d))+b'WAVEfmt '+struct.pack('<IHHIIHH',16,3,1,SR,SR*4,4,32)+b'data'+struct.pack('<I',len(d))+d)
print(f"gen_tonal: {N} samples -> test/tonal.wav")
