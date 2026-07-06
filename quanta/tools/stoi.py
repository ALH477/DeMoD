#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-DeMoD-Commercial
# stoi.py — Short-Time Objective Intelligibility (Taal et al. 2011). The right metric for
# a concatenative/segment vocoder: it scores whether the WORDS survive, not fidelity, so
# it doesn't punish the "synthetic" timbre the way PESQ does. ~0.9+ = highly intelligible,
# ~0.5 = borderline. Needs scipy (resample). Usage: stoi.py ref.f64 deg.f64 [sr]
import numpy as np, sys
from scipy.signal import resample_poly

FS=10000; N_FRAME=256; K=512; J=15; MN=30; BETA=-15.0; DYN=40.0

def _thirdoct(fs, nfft, num_bands, min_cf):
    f=np.linspace(0,fs,nfft+1)[:nfft//2+1]
    k=np.arange(num_bands)
    cf=min_cf*2.0**(k/3.0)
    fl=min_cf*2.0**((k-0.5)/3.0); fh=min_cf*2.0**((k+0.5)/3.0)
    A=np.zeros((num_bands,len(f)))
    for i in range(num_bands):
        A[i]=((f>=fl[i])&(f<fh[i])).astype(float)
    return A

def _stft(x):
    w=np.hanning(N_FRAME+2)[1:-1]
    frames=range(0,len(x)-N_FRAME,N_FRAME//2)
    return np.array([np.fft.rfft(x[i:i+N_FRAME]*w,K) for i in frames])

def stoi(ref, deg, fs):
    if fs!=FS:
        ref=resample_poly(ref,FS,fs); deg=resample_poly(deg,FS,fs)
    n=min(len(ref),len(deg)); ref=ref[:n]; deg=deg[:n]
    # remove silent frames (per clean energy, 40 dB range)
    w=np.hanning(N_FRAME+2)[1:-1]; fr=range(0,n-N_FRAME,N_FRAME//2)
    e=np.array([20*np.log10(np.linalg.norm(ref[i:i+N_FRAME]*w)+1e-12) for i in fr])
    keep=e>(e.max()-DYN)
    Xr=_stft(ref)[keep]; Xd=_stft(deg)[keep]
    if len(Xr)<MN: return float('nan')
    H=_thirdoct(FS,K,J,150.0)
    Tr=np.sqrt(H@ (np.abs(Xr.T)**2))   # (J, nframes) clean 1/3-oct energies
    Td=np.sqrt(H@ (np.abs(Xd.T)**2))
    cor=[]
    for m in range(MN,Tr.shape[1]):
        xr=Tr[:,m-MN:m]; xd=Td[:,m-MN:m]
        # normalize + clip degraded to clean per band
        alpha=np.linalg.norm(xr,axis=1,keepdims=True)/(np.linalg.norm(xd,axis=1,keepdims=True)+1e-12)
        xdn=xd*alpha
        c=10**(-BETA/20.0)
        xdn=np.minimum(xdn, xr*(1+10**(BETA/20.0)))   # clipping
        xr0=xr-xr.mean(1,keepdims=True); xd0=xdn-xdn.mean(1,keepdims=True)
        d=(xr0*xd0).sum(1)/(np.linalg.norm(xr0,axis=1)*np.linalg.norm(xd0,axis=1)+1e-12)
        cor.append(d.mean())
    return float(np.mean(cor)) if cor else float('nan')

if __name__=='__main__':
    ref=np.fromfile(sys.argv[1],dtype='<f8'); deg=np.fromfile(sys.argv[2],dtype='<f8')
    sr=int(sys.argv[3]) if len(sys.argv)>3 else 8000
    print(f"stoi: {stoi(ref,deg,sr):.3f}  (1.0=perfect, ~0.9 highly intelligible, ~0.5 borderline)")
