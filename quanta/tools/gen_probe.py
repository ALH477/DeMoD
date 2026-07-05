#!/usr/bin/env python3
# Diverse probe signals to test residual-trim signal-stability.
import numpy as np, struct, sys
SR, DUR = 48000, 2.0
N = int(SR*DUR); t = np.arange(N)/SR
def wav(name, x):
    x = (x/ (np.max(np.abs(x))+1e-9) * 0.6).astype('<f4').tobytes()
    with open(name,'wb') as f:
        f.write(b'RIFF'+struct.pack('<I',36+len(x))+b'WAVEfmt '+struct.pack('<IHHIIHH',16,3,1,SR,SR*4,4,32)+b'data'+struct.pack('<I',len(x))+x)
rng = np.random.default_rng(7)
# 1: white-ish noise bed (all-residual, no tonal)
wav('test/probe_noise.wav', rng.standard_normal(N))
# 2: pink-ish (LP noise) — spectrally tilted residual
nz = rng.standard_normal(N); b=np.zeros(N); a=0.0
for i in range(N): a += 0.01*(nz[i]-a); b[i]=a
wav('test/probe_pink.wav', b)
# 3: bandlimited hiss around 2 kHz (narrow residual)
car = np.sin(2*np.pi*2000*t); wav('test/probe_band.wav', car*rng.standard_normal(N))
# 4: sustained tone + broadband hiss (mixed)
wav('test/probe_mix.wav', 0.7*np.sin(2*np.pi*440*t)+0.3*rng.standard_normal(N))
print("probes written")
