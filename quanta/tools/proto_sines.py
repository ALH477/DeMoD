#!/usr/bin/env python3
# De-risk experiment 2: is a general SINUSOIDAL model (arbitrary peak-tracked
# partials, not strict k*f0 harmonics) the path below the +5 NMR wall?
# Per-hop: FFT -> pick top-N spectral peaks (parabolic freq/amp/phase refine) ->
# reconstruct each as a constant sinusoid over the synthesis frame -> OLA.
# This is a crude stand-in for MQ track synthesis (our C engine does the real thing);
# it establishes the CEILING of the sinusoidal representation vs peak count.
import numpy as np, subprocess
SR=48000
src=np.fromfile('test/speech/real.f64'); N=len(src)
W,H=2048,512
win=np.hanning(W).astype(np.float64)
# analysis-synthesis window for OLA (Hann, 75% overlap -> COLA)
def resynth(npeaks):
    y=np.zeros(N); ws=np.zeros(N)
    for i in range(0,N-W,H):
        seg=src[i:i+W]*win
        F=np.fft.rfft(seg); mag=np.abs(F); phi=np.angle(F)
        # local maxima
        pk=[]
        for b in range(2,len(mag)-2):
            if mag[b]>mag[b-1] and mag[b]>=mag[b+1]:
                pk.append(b)
        pk.sort(key=lambda b:-mag[b]); pk=pk[:npeaks]
        rec=np.zeros(W)
        t=np.arange(W)-W/2
        for b in pk:
            # parabolic interpolation for true bin/freq/amp
            a0,a1,a2=mag[b-1],mag[b],mag[b+1]
            d=0.5*(a0-a2)/(a0-2*a1+a2+1e-30); d=np.clip(d,-0.5,0.5)
            binf=b+d; freq=binf*SR/W
            amp=a1-0.25*(a0-a2)*d
            amp=amp/np.sum(win)*2       # window/amp normalization
            ph=phi[b]
            rec+=amp*np.cos(2*np.pi*freq*t/SR+ph)
        y[i:i+W]+=rec*win; ws[i:i+W]+=win*win
    ws[ws<1e-9]=1; return y/ws
def nmr(a,name):
    a.astype('<f8').tofile('test/speech/_s.f64')
    o=subprocess.run(['python3','tools/perceptual.py','nmr','test/speech/real.f64','test/speech/_s.f64','48000'],
                     capture_output=True,text=True).stdout.strip()
    snr=10*np.log10(np.sum(src**2)/(np.sum((src[:len(a)]-a[:len(src)])**2)+1e-30))
    print(f"{name:22s} {o}  | SNR {snr:+.1f} dB")
for np_ in (20,40,80,160):
    nmr(resynth(np_), f"sines N={np_}")
