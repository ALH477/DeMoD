#!/usr/bin/env python3
# Clean ceiling test: sparse sinusoidal representation via peak-masked STFT.
# Phase-coherent (real STFT phases + proper ISTFT/COLA), so SNR is meaningful.
# Per frame keep the top-N magnitude peaks (each peak = its bin +/-1 neighbours),
# zero the rest, invert. Answers: how transparent is an N-partial sinusoidal model,
# and how many partials to get there? Compares against the current HNM (+5.67).
import numpy as np, subprocess
SR=48000
src=np.fromfile('test/speech/real.f64'); N=len(src)
W,H=1024,256
win=np.hanning(W).astype(np.float64)
def frames():
    return range(0,N-W,H)
def istft(S):
    y=np.zeros(N); ws=np.zeros(N)
    for j,i in enumerate(frames()):
        seg=np.fft.irfft(S[j],W)*win; y[i:i+W]+=seg; ws[i:i+W]+=win*win
    ws[ws<1e-9]=1; return y/ws
def sparse(npeaks, keep_noise=False):
    S=[]
    for i in frames():
        F=np.fft.rfft(src[i:i+W]*win); mag=np.abs(F)
        pk=[b for b in range(1,len(mag)-1) if mag[b]>mag[b-1] and mag[b]>=mag[b+1]]
        pk.sort(key=lambda b:-mag[b]); keep=set()
        for b in pk[:npeaks]:
            keep.update((b-1,b,b+1))
        M=np.zeros(len(F),dtype=complex)
        for b in keep:
            if 0<=b<len(F): M[b]=F[b]
        if keep_noise:
            # add phase-randomized version of the REST (non-peak bins)
            rest=F.copy()
            for b in keep:
                if 0<=b<len(F): rest[b]=0
            rng=np.random.default_rng(i)
            rest=np.abs(rest)*np.exp(1j*rng.uniform(-np.pi,np.pi,len(rest)))
            M=M+rest
        S.append(M)
    return istft(np.array(S))
def report(a,name):
    a.astype('<f8').tofile('test/speech/_q.f64')
    o=subprocess.run(['python3','tools/perceptual.py','nmr','test/speech/real.f64','test/speech/_q.f64','48000'],
                     capture_output=True,text=True).stdout.strip().replace('nmr: ','')
    m=min(len(a),len(src)); snr=10*np.log10(np.sum(src[:m]**2)/(np.sum((src[:m]-a[:m])**2)+1e-30))
    print(f"{name:26s} {o}  | SNR {snr:+.1f} dB")
for n_ in (20,40,80):
    report(sparse(n_), f"sparse sines N={n_}")
report(sparse(40,keep_noise=True), "sparse N=40 + rand noise")
report(sparse(80,keep_noise=True), "sparse N=80 + rand noise")
