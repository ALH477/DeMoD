#!/usr/bin/env python3
# Beat-Opus prototype: minimum-phase harmonic+noise vocoder.
# Validates the two big bandwidth wins vs the current QSP (92 kbps):
#   (1) NO stored phases  -> minimum-phase derived from the spectral envelope
#   (2) envelope-based amplitudes (smooth cepstral env) instead of per-harmonic amps
# Synthesis is continuous-phase (fundamental phase accumulator + min-phase offsets),
# so voiced segments are coherent. Reports MCD + a coded-bitrate estimate + audio.
import numpy as np, struct, sys, subprocess

SR=48000
def rd_wav(p):
    d=open(p,'rb').read(); i=d.find(b'data'); n=struct.unpack('<I',d[i+4:i+8])[0]
    return np.frombuffer(d[i+8:i+8+n],dtype='<i2').astype(np.float64)/32768.0
def wr_wav(p,x):
    x=np.clip(x,-1,1); b=(x*32767).astype('<i2').tobytes()
    open(p,'wb').write(b'RIFF'+struct.pack('<I',36+len(b))+b'WAVEfmt '+struct.pack('<IHHIIHH',16,1,1,SR,SR*2,2,16)+b'data'+struct.pack('<I',len(b))+b)

x=rd_wav(sys.argv[1] if len(sys.argv)>1 else 'test/speech/clean_src.wav')
N=len(x)
W=1024; H=480; NF=1024                     # 10 ms hop -> 100 fps
win=np.hanning(W)
fmin,fmax=70,400
NAP=5                                       # aperiodicity bands

def f0_frame(fr):
    fr=fr-fr.mean(); e0=np.dot(fr,fr)
    if e0<1e-6: return 0.0,0.0
    lo,hi=int(SR/fmax),int(SR/fmin)
    best,blag=0.0,0
    for lag in range(lo,hi):
        a=fr[:-lag]; b=fr[lag:]; d=np.dot(a,a)*np.dot(b,b)
        if d>0:
            v=np.dot(a,b)/np.sqrt(d)
            if v>best: best,blag=v,lag
    return (SR/blag if blag else 0.0), best

# --- analysis ---
frames=range(0,N-W,H)
env=[]; f0s=[]; vflag=[]; ap=[]
for i in frames:
    fr=x[i:i+W]
    f0,conf=f0_frame(fr)
    voiced = conf>0.55 and fmin<=f0<=fmax
    X=np.fft.rfft(fr*win, NF); mag=np.abs(X)
    logm=np.log(np.maximum(mag,mag.max()*1e-4))
    # cepstral-smoothed envelope (liftered)
    full=np.concatenate([logm,logm[-2:0:-1]])
    cep=np.fft.ifft(full).real
    lift=np.zeros_like(cep); L=int(sys.argv[2]) if len(sys.argv)>2 else 60; lift[:L]=1; lift[-L+1:]=1
    envlog=np.fft.fft(cep*lift).real[:NF//2+1]
    env.append(envlog)
    # aperiodicity: per band, ratio of (spectrum below envelope) energy — crude proxy
    apb=[]
    edges=np.linspace(0,NF//2+1,NAP+1).astype(int)
    for b in range(NAP):
        sl=slice(edges[b],edges[b+1])
        resid=np.maximum(0.0, np.exp(envlog[sl])-mag[sl])   # how much env exceeds obs (nulls)
        apb.append(float(np.mean((mag[sl]/ (np.exp(envlog[sl])+1e-9)))))  # obs/env ~ 1 periodic, <1 aperiodic dips
    ap.append(np.clip(apb,0,1))
    f0s.append(f0 if voiced else 0.0); vflag.append(voiced)
env=np.array(env); f0s=np.array(f0s); vflag=np.array(vflag,bool); ap=np.array(ap)
nf=len(f0s)
frq=np.fft.rfftfreq(NF,1/SR)

# --- f0 post-processing: octave correction + median smoothing + voicing cleanup ---
def lmed(a,i,h,mask):
    lo=max(0,i-h); w=a[lo:i+h+1][mask[lo:i+h+1]]; return float(np.median(w)) if len(w) else 0.0
f0c=f0s.copy()
for i in range(nf):                                   # octave snap to local median
    if vflag[i]:
        m=lmed(f0s,i,3,vflag)
        if m>0:
            if   f0s[i]>1.6*m: f0c[i]=f0s[i]/2
            elif f0s[i]<0.62*m: f0c[i]=f0s[i]*2
f0sm=f0c.copy()
for i in range(nf):                                   # median-7 smooth
    if vflag[i]:
        m=lmed(f0c,i,3,vflag)
        if m>0: f0sm[i]=m
f0s=f0sm
for i in range(1,nf-1):                               # fill isolated unvoiced gaps
    if not vflag[i] and vflag[i-1] and vflag[i+1]:
        vflag[i]=True; f0s[i]=0.5*(f0s[i-1]+f0s[i+1])
for i in range(1,nf-1):                               # drop isolated voiced blips
    if vflag[i] and not vflag[i-1] and not vflag[i+1]:
        vflag[i]=False; f0s[i]=0.0

def minphase_theta(envlog):
    """minimum-phase spectrum phase from a log-magnitude envelope."""
    full=np.concatenate([envlog,envlog[-2:0:-1]])
    c=np.fft.ifft(full).real
    wnd=np.zeros_like(c); n=len(c); wnd[0]=1; wnd[1:n//2]=2; wnd[n//2]=1
    Hm=np.exp(np.fft.fft(c*wnd))
    return np.angle(Hm[:NF//2+1])

theta=np.array([minphase_theta(e) for e in env])

# --- synthesis: continuous fundamental phase + min-phase harmonic offsets + noise ---
# vectorized per-frame. amp/theta sampled from the envelope at k*f0 (log-lin interp).
out=np.zeros(N); rng=np.random.default_rng(0)
gain = 2.0/np.sum(win)
def env_interp(fi, freqs):          # log-env + min-phase theta at arbitrary freqs
    b=np.clip(freqs/(SR/2)*(NF//2),0,NF//2-1e-6); b0=b.astype(int); fr=b-b0
    le=env[fi,b0]+fr*(env[fi,b0+1]-env[fi,b0]); th=theta[fi,b0]+fr*(theta[fi,b0+1]-theta[fi,b0])
    return le,th
Phi=0.0
# Binary-ish excitation for legibility: voiced = clean min-phase harmonics (+ a small
# HF-only breath so it isn't robotic); unvoiced = full envelope-shaped noise.
apf_voiced = np.clip((frq-4000.0)/6000.0, 0.0, 0.35)   # breath only above 4 kHz, gentle
nwin=np.hanning(2*H)
for idx in range(nf-1):
    i0=idx*H; f0a,f0b=f0s[idx],f0s[idx+1]; va=vflag[idx]
    nseg=min(H, N-i0)
    if nseg<=0: break
    tt=np.arange(nseg)/H
    if va and f0a>1 and f0b>1:
        phinc=2*np.pi*(f0a*(1-tt)+f0b*tt)/SR
        phi=Phi+np.cumsum(phinc)
        Kmax=int(min(SR*0.45,5500)/max(f0a,f0b,1))
        ks=np.arange(1,Kmax+1)
        le0,th0=env_interp(idx,ks*f0a); le1,th1=env_interp(idx+1,ks*f0b)
        A0=np.exp(le0)*gain; A1=np.exp(le1)*gain
        A=A0[None,:]*(1-tt[:,None])+A1[None,:]*tt[:,None]
        TH=th0[None,:]*(1-tt[:,None])+th1[None,:]*tt[:,None]
        out[i0:i0+nseg]+=np.sum(A*np.sin(ks[None,:]*phi[:,None]+TH), axis=1)
        Phi=phi[-1]
        apscale=apf_voiced                              # HF breath only
    else:
        apscale=np.ones(NF//2+1)                        # fully aperiodic (consonants)
    # noise: white -> shape by envelope*aperiodicity, 50%-overlap OLA
    nn=rng.standard_normal(2*H)
    seg=np.fft.irfft(np.fft.rfft(nn*nwin, NF)*np.exp(env[idx])*apscale, NF)[:2*H]
    a=i0-H//2
    for j in range(2*H):
        p=a+j
        if 0<=p<N: out[p]+=seg[j]

# per-frame energy matching (represents a stored per-frame gain, ~1 coeff/frame):
# scale synthesis to the source frame-energy contour (smoothed) so levels track.
esrc=np.array([np.sqrt(np.mean(x[i:i+H]**2)) for i in range(0,N-H,H)])
esyn=np.array([np.sqrt(np.mean(out[i:i+H]**2)) for i in range(0,N-H,H)])
g=np.where(esyn>1e-6, esrc/(esyn+1e-9), 1.0); g=np.clip(g,0,8)
# smooth the gain a touch and apply sample-wise (interp between frame centers)
gs=np.interp(np.arange(N), np.arange(len(g))*H+H/2, g, left=g[0], right=g[-1])
out*=gs
wr_wav('test/speech/vocoder_minphase.wav', out)
out.astype('<f8').tofile('/tmp/voc.f64'); x.astype('<f8').tofile('/tmp/vocsrc.f64')

# MCD
o=subprocess.run(['python3','tools/mcd.py','/tmp/vocsrc.f64','/tmp/voc.f64','48000'],capture_output=True,text=True).stdout.strip()
print("MCD:", o.replace('mcd: ',''))
# bitrate estimate: envelope(24 mel-cep ~5b) + f0(7b) + voiced(1b) + 5 AP bands(4b) per 10ms frame
bits_per_frame = 24*5 + 7 + 1 + NAP*4
kbps = bits_per_frame*100/1000
print(f"est coded bitrate (100 fps, 24 env-coeff@5b + f0 + {NAP}AP, NO phases): {kbps:.1f} kbps")
print("wrote test/speech/vocoder_minphase.wav")
