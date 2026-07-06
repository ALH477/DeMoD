#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-DeMoD-Commercial
# transparency.py — HONEST source-transparency report for the Quanta music codec (Track B1).
#
# The frozen .dsp nulls the C player to ~-260 dBFS (a DETERMINISM claim, spec §12).
# THIS tool asks a different, harder question: how close is the codec output to the
# ORIGINAL RECORDING? That is the audiophile "transparency" claim, and it is bounded by
# the model, not by float precision. We report it three ways and do NOT hide the ceiling:
#
#   1. null-vs-source (waveform):   peak/rms of (src-dec). For Quanta's noise-SUBSTITUTION
#      residual this is EXPECTED to be poor — the residual reproduces the spectral
#      envelope with a *different* random phase realization, so a sample-difference metric
#      punishes inaudible decorrelation. Reported for honesty, NOT as the headline.
#   2. NMR (perceptual.py):         masking-weighted audibility. THE headline metric.
#      median < 0 dB => error sits under the masking threshold (inaudible).
#   3. LSD (metrics.py):            log-spectral distance, envelope fidelity in dB.
#
# Usage: transparency.py <src.f64> <dec.f64> <sr> [label]
import sys, subprocess, numpy as np, os
HERE=os.path.dirname(os.path.abspath(__file__))
def load(p): return np.fromfile(p,dtype='<f8')

def null(src,dec):
    n=min(len(src),len(dec)); d=src[:n]-dec[:n]; ref=np.sqrt(np.mean(src[:n]**2))+1e-30
    pk=20*np.log10(np.max(np.abs(d))/ (np.max(np.abs(src[:n]))+1e-30) +1e-300)
    rms=20*np.log10((np.sqrt(np.mean(d**2))+1e-30)/ref)
    return pk,rms

def run(mod,*a):
    r=subprocess.run([sys.executable,os.path.join(HERE,mod),*map(str,a)],capture_output=True,text=True)
    return (r.stdout+r.stderr).strip()

if __name__=='__main__':
    if len(sys.argv)<4: print("usage: transparency.py <src.f64> <dec.f64> <sr> [label]");sys.exit(2)
    srcp,decp,sr=sys.argv[1],sys.argv[2],int(sys.argv[3])
    label=sys.argv[4] if len(sys.argv)>4 else os.path.basename(decp)
    src,dec=load(srcp),load(decp)
    pk,rms=null(src,dec)
    nmr=run('perceptual.py','nmr',srcp,decp,sr)
    lsd=run('metrics.py','lsd',srcp,decp)
    print(f"── {label}  ({sr} Hz, {min(len(src),len(dec))/sr:.1f}s) ──")
    print(f"   null-vs-source : peak {pk:+6.1f} dBFS   rms {rms:+6.1f} dBFS   (waveform; noise-substitution ⇒ expected poor)")
    print(f"   NMR (perceptual): {nmr.replace('nmr: ','')}")
    print(f"   LSD            : {lsd.replace('lsd ','').replace('active-frame ','')}")
