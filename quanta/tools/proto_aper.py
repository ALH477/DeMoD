#!/usr/bin/env python3
# Prototype / de-risk experiment for the speech aperiodicity rewrite.
# We reuse the GOOD C harmonic synthesis (real_h.f64 = --no-noise render) and only
# prototype the NOISE model in Python (libm free here — this is a reference, not the
# freezable decoder). Question: what is the achievable ceiling, and where is it lost?
#
#   src         = source speech
#   harm        = C harmonic-only render (already excellent 150 Hz-8 kHz)
#   resid       = src - harm  (true aperiodic + fit error)
#
# Experiments (NMR reported by tools/perceptual.py on written f64):
#   E0 harm only                          (baseline, no noise)
#   E1 harm + resid                       (perfect residual — upper bound)
#   E2 harm + |STFT(resid)| random-phase  (full-res noise substitution ceiling)
#   E3 harm + E2 but only ABOVE per-frame MVF-ish (harmonic region kept clean)
#   E4 harm + E2 but time-envelope-preserved randomized phase
import numpy as np, sys, subprocess

SR=48000
src=np.fromfile('test/speech/real.f64')
harm=np.fromfile('test/speech/real_h.f64')
n=min(len(src),len(harm)); src,harm=src[:n],harm[:n]
resid=src-harm

W,H=1024,256
win=np.hanning(W).astype(np.float64)
def stft(x):
    frames=[]
    for i in range(0,len(x)-W,H): frames.append(np.fft.rfft(x[i:i+W]*win))
    return np.array(frames)
def istft(S,length):
    y=np.zeros(length); ws=np.zeros(length)
    for j,Fr in enumerate(S):
        i=j*H; seg=np.fft.irfft(Fr,W)*win
        y[i:i+W]+=seg; ws[i:i+W]+=win*win
    ws[ws<1e-9]=1; return y/ws

rng=np.random.default_rng(3)
S=stft(resid)
mag=np.abs(S)

# E2: random phase, same magnitude (ideal full-res noise substitution)
ph=rng.uniform(-np.pi,np.pi,mag.shape)
E2=istft(mag*np.exp(1j*ph),n)

# E4: preserve the per-frame temporal envelope by keeping DC-ish structure —
#     randomize phase but re-inject the original short-time energy per frame (already
#     preserved by magnitude). Additionally modulate to match residual's local RMS.
env=np.sqrt(np.maximum(np.mean(resid[:len(E2)]**2),1e-12))
E4=E2*(np.sqrt(np.maximum((resid[:len(E2)]**2),0)).clip(0)+0)  # placeholder, refined below

def nmr(a,name):
    a.astype('<f8').tofile('test/speech/_p.f64')
    out=subprocess.run(['python3','tools/perceptual.py','nmr','test/speech/real.f64','test/speech/_p.f64','48000'],
                       capture_output=True,text=True).stdout.strip()
    print(f"{name:34s} {out}")

nmr(harm,                         "E0 harm only")
nmr(harm+resid,                   "E1 harm + true resid (upper bound)")
nmr(harm+E2,                      "E2 harm + full-res random-phase noise")
