#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-DeMoD-Commercial
# lsf.py — LPC <-> LSF (line spectral frequencies) for the quanta speech codec's
# envelope coding. LSFs are THE low-bitrate envelope representation (Codec2/MELP/AMR):
# an all-pole formant model whose parameters quantize far better than raw cepstrum.
# Path: log-magnitude envelope -> power spectrum -> autocorrelation -> Levinson-Durbin
# -> LPC -> LSF (quantize/VQ) -> LPC -> log-magnitude envelope.
import numpy as np

def levinson(r, order):
    """Levinson-Durbin: autocorrelation r[0..order] -> LPC a[0..order] (a[0]=1), residual e."""
    a=[1.0]+[0.0]*order; e=float(r[0]) if r[0]>0 else 1e-9
    for i in range(1,order+1):
        acc=r[i]
        for j in range(1,i): acc+=a[j]*r[i-j]
        k=-acc/e if e>1e-12 else 0.0
        k=max(-0.999,min(0.999,k))                       # clamp reflection coeff (stability)
        anew=a[:]
        for j in range(1,i): anew[j]=a[j]+k*a[i-j]
        anew[i]=k; a=anew; e*=(1.0-k*k)
        if e<=0: e=1e-9
    return np.array(a), e

def env_to_lpc(env_log, NF, order):
    """log-magnitude envelope (NF//2+1) -> LPC (a, gain) via autocorrelation + Levinson."""
    logpow=2.0*env_log
    P=np.exp(np.concatenate([logpow, logpow[-2:0:-1]]))  # symmetric power spectrum, len NF
    r=np.fft.ifft(P).real[:order+1]
    r[0]*=1.0001                                         # tiny white floor (well-conditioned)
    a,e=levinson(r, order)
    return a, np.sqrt(max(e,1e-12))/NF                   # gain (IDFT scale folded in)

def lpc_to_env(a, gain, NF):
    """LPC (a, gain) -> log-magnitude envelope (NF//2+1). log|H| = log g - log|A(e^jw)|."""
    w=np.linspace(0,np.pi,NF//2+1)
    A=np.zeros(NF//2+1, complex)
    for k,ak in enumerate(a): A+=ak*np.exp(-1j*w*k)
    return np.log(gain+1e-30) - np.log(np.abs(A)+1e-12)

def lpc_to_lsf(a):
    """LPC a[0..p] -> p LSFs in (0,pi), ascending. Roots of the symmetric/antisymmetric
    P/Q polynomials lie on the unit circle; their angles are the LSFs."""
    p=len(a)-1; A=np.asarray(a,float); Ar=A[::-1]
    P=np.concatenate([A,[0.0]])+np.concatenate([[0.0],Ar])   # A(z)+z^-(p+1)A(1/z)
    Q=np.concatenate([A,[0.0]])-np.concatenate([[0.0],Ar])   # A(z)-z^-(p+1)A(1/z)
    def angles(poly):
        r=np.roots(poly); r=r[np.imag(r)>=0]
        w=np.angle(r); w=w[(w>1e-4)&(w<np.pi-1e-4)]           # drop trivial z=+-1 roots
        return w
    lsf=np.sort(np.concatenate([angles(P),angles(Q)]))
    if len(lsf)<p:                                            # pad (rare, ill-conditioned frame)
        lsf=np.concatenate([lsf, np.linspace(0.1,np.pi-0.1,p)[len(lsf):]])
    return lsf[:p]

def lsf_to_lpc(lsf):
    """p LSFs -> LPC a[0..p] (a[0]=1). Rebuild P,Q from unit-circle roots; A=(P+Q)/2."""
    lsf=np.sort(np.asarray(lsf,float)); p=len(lsf)
    wp=lsf[0::2]; wq=lsf[1::2]                                # interleave P/Q
    Prts=np.concatenate([np.exp(1j*wp),np.exp(-1j*wp),[-1.0]])
    Qrts=np.concatenate([np.exp(1j*wq),np.exp(-1j*wq),[ 1.0]])
    P=np.real(np.poly(Prts)); Q=np.real(np.poly(Qrts))
    a=0.5*(P+Q)
    return a[:p+1]

if __name__=='__main__':
    # round-trip self-test on a synthetic formant envelope
    import sys; sys.path.insert(0,'tools'); import qvoc
    NF=256; order=int(sys.argv[1]) if len(sys.argv)>1 else 12
    x,sr=qvoc.read_wav('test/speech/bench/m1_suntzu_8k.wav'); a=qvoc.analyze(x,sr)
    errs=[]; lsferr=[]
    for i in range(0,len(a['env']),10):
        env=a['env'][i]
        lp,g=env_to_lpc(env,NF,order); e2=lpc_to_env(lp,g,NF)
        # shift-invariant compare (LPC gain sets level; compare shape)
        d=(env-env.mean())-(e2-e2.mean()); errs.append(np.sqrt(np.mean(d**2)))
        lsf=lpc_to_lsf(lp); lp2=lsf_to_lpc(lsf); lsferr.append(np.max(np.abs(lp-lp2)))
    print(f"order={order}: env shape RMS err {np.mean(errs):.3f} nats | LPC->LSF->LPC max err {np.mean(lsferr):.2e}")
