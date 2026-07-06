#!/usr/bin/env python3
# Synthetic voiced probe for HNM copy-synthesis (Gate H1): a pitch glide with
# several harmonics + light shaped noise. The glide is the point — it exercises
# harmonic phase coherence across the pitch track, which MQ synthesis must hold.
import numpy as np, struct, sys
SR, DUR = 48000, 1.5
N = int(SR*DUR); t = np.arange(N)/SR
def wav(name, x):
    x = (x/(np.max(np.abs(x))+1e-9)*0.6).astype('<f4').tobytes()
    with open(name,'wb') as f:
        f.write(b'RIFF'+struct.pack('<I',36+len(x))+b'WAVEfmt '+struct.pack('<IHHIIHH',16,3,1,SR,SR*4,4,32)+b'data'+struct.pack('<I',len(x))+x)
rng = np.random.default_rng(11)
# f0 glides 120 -> 165 Hz (sine-eased); continuous instantaneous phase.
f0 = 120 + 45*(0.5-0.5*np.cos(np.pi*t/DUR))
phi = 2*np.pi*np.cumsum(f0)/SR
x = np.zeros(N)
for k in range(1, 13):                    # 12 harmonics, 1/k rolloff, fixed rel phase
    if np.all(k*f0 < 5500):
        x += (1.0/k)*np.sin(k*phi + 0.3*k)
# breathy noise floor, band-limited-ish
nz = rng.standard_normal(N); a=0.0; b=np.zeros(N)
for i in range(N): a += 0.02*(nz[i]-a); b[i]=a
x += 0.04*b
wav(sys.argv[1] if len(sys.argv)>1 else 'test/speech/voice.wav', x)
print("voice probe written")
