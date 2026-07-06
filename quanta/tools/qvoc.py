#!/usr/bin/env python3
# qvoc — demod-quanta harmonic minimum-phase vocoder (beat-MELPe track).
# Sample-rate-parameterized reference (Python) for both 8 kHz narrowband (Codec2
# head-to-head) and 48 kHz wideband (showcase). Extended through the plan phases:
#   P1 mixed excitation (de-buzz), P2 VQ coding. Analysis is offline (libm ok);
#   synthesis is continuous fundamental-phase harmonics with minimum-phase offsets
#   from a cepstral spectral envelope + envelope-shaped aperiodic noise.
import numpy as np, struct

def read_wav(p):
    d=open(p,'rb').read(); i=d.find(b'fmt ')
    ch,sr=struct.unpack('<HI', d[i+10:i+16]); bits=struct.unpack('<H', d[i+22:i+24])[0]
    j=d.find(b'data'); n=struct.unpack('<I', d[j+4:j+8])[0]; body=d[j+8:j+8+n]
    if bits==16: x=np.frombuffer(body,dtype='<i2').astype(np.float64)/32768.0
    else:        x=np.frombuffer(body,dtype='<f4').astype(np.float64)
    if ch>1: x=x.reshape(-1,ch).mean(1)
    return x, sr

def write_wav(p, x, sr):
    x=np.clip(x,-1,1); b=(x*32767).astype('<i2').tobytes()
    open(p,'wb').write(b'RIFF'+struct.pack('<I',36+len(b))+b'WAVEfmt '
        +struct.pack('<IHHIIHH',16,1,1,sr,sr*2,2,16)+b'data'+struct.pack('<I',len(b))+b)

def _params(sr):
    # 10 ms hop, ~21 ms analysis window rounded up to a power of two.
    H=max(8,int(round(0.010*sr)))
    NF=1;
    while NF < int(0.021*sr): NF<<=1
    return H, NF

def f0_track(x, sr, H, NF, fmin=70, fmax=400, vthr=0.55):
    W=NF; win=np.hanning(W); frames=range(0,len(x)-W,H)
    lo,hi=int(sr/fmax),int(sr/fmin)
    f0s=[]; conf=[]
    for i in frames:
        fr=x[i:i+W]-np.mean(x[i:i+W]); e0=np.dot(fr,fr)
        if e0<1e-6: f0s.append(0.0); conf.append(0.0); continue
        best,blag=0.0,0
        for lag in range(lo,hi):
            a=fr[:-lag]; b=fr[lag:]; d=np.dot(a,a)*np.dot(b,b)
            if d>0:
                v=np.dot(a,b)/np.sqrt(d)
                if v>best: best,blag=v,lag
        f0s.append(sr/blag if blag else 0.0); conf.append(best)
    f0s=np.array(f0s); conf=np.array(conf)
    voiced=(conf>=vthr)&(f0s>=fmin)&(f0s<=fmax)
    # octave snap to local median, median-7 smooth, gap/blip cleanup
    def lmed(a,i,h,m):
        lo2=max(0,i-h); w=a[lo2:i+h+1][m[lo2:i+h+1]]; return float(np.median(w)) if len(w) else 0.0
    fc=f0s.copy()
    for i in range(len(f0s)):
        if voiced[i]:
            mm=lmed(f0s,i,3,voiced)
            if mm>0:
                if f0s[i]>1.6*mm: fc[i]=f0s[i]/2
                elif f0s[i]<0.62*mm: fc[i]=f0s[i]*2
    fs=fc.copy()
    for i in range(len(fc)):
        if voiced[i]:
            mm=lmed(fc,i,3,voiced)
            if mm>0: fs[i]=mm
    for i in range(1,len(fs)-1):
        if not voiced[i] and voiced[i-1] and voiced[i+1]:
            voiced[i]=True; fs[i]=0.5*(fs[i-1]+fs[i+1])
        if voiced[i] and not voiced[i-1] and not voiced[i+1]:
            voiced[i]=False; fs[i]=0.0
    return fs, voiced

# bandpass-voicing band edges as fractions of Nyquist (MELP-style: 0-.125-.25-.5-.75-1)
BV_EDGES = np.array([0.0, 0.125, 0.25, 0.5, 0.75, 1.0])
NB = len(BV_EDGES)-1

def _band_voicing(fr, win, NF, sr, f0):
    """per-band normalized autocorrelation at the pitch lag -> voicing strength [0,1].
    High = periodic (harmonic), low = aperiodic (noise). The MELP mixed-excitation cue."""
    if f0<1: return np.zeros(NB)
    T=int(round(sr/f0))
    X=np.fft.rfft(fr*win, NF); freqs=np.fft.rfftfreq(NF,1/sr); edges=BV_EDGES*(sr/2)
    v=np.zeros(NB)
    for b in range(NB):
        m=(freqs>=edges[b])&(freqs<edges[b+1])
        Sb=np.zeros_like(X); Sb[m]=X[m]
        sb=np.fft.irfft(Sb, NF)
        if T<len(sb)-8:
            a=sb[:-T]; c=sb[T:]; d=np.dot(a,a)*np.dot(c,c)
            if d>1e-12: v[b]=np.clip(np.dot(a,c)/np.sqrt(d),0,1)
    return v

def analyze(x, sr, lifter=None):
    H,NF=_params(sr); W=NF; win=np.hanning(W)
    if lifter is None: lifter=max(20,int(NF*0.12))     # ~ formant-resolving
    f0s,voiced=f0_track(x,sr,H,NF)
    env=[]; bvoi=[]; nf=len(f0s)
    for idx,i in enumerate(range(0,len(x)-W,H)):
        fr=x[i:i+W]
        X=np.fft.rfft(fr*win, NF); mag=np.abs(X)
        logm=np.log(np.maximum(mag,mag.max()*1e-4))
        full=np.concatenate([logm,logm[-2:0:-1]]); cep=np.fft.ifft(full).real
        lift=np.zeros_like(cep); lift[:lifter]=1; lift[-lifter+1:]=1
        env.append(np.fft.fft(cep*lift).real[:NF//2+1])
        bvoi.append(_band_voicing(fr, win, NF, sr, f0s[idx] if voiced[idx] else 0.0))
    env=np.array(env[:nf]); bvoi=np.array(bvoi[:nf])
    f0s=f0s[:len(env)]; voiced=voiced[:len(env)]
    return dict(sr=sr,H=H,NF=NF,env=env,f0=f0s,voiced=voiced,bvoi=bvoi,N=len(x))

def _minphase_theta(envlog, NF):
    full=np.concatenate([envlog,envlog[-2:0:-1]]); c=np.fft.ifft(full).real
    wnd=np.zeros_like(c); n=len(c); wnd[0]=1; wnd[1:n//2]=2; wnd[n//2]=1
    return np.angle(np.exp(np.fft.fft(c*wnd)))[:NF//2+1]

def _postfilter(env, sr, NF, alpha):
    """adaptive spectral enhancement (MELP/Codec2-style): unsharp-mask the log-envelope
    to deepen formant valleys / sharpen peaks. Perceptual (raises PESQ) at a small MCD
    cost; costs no bits (decoder-side). width ~ 600 Hz."""
    if alpha<=0: return env
    w=max(3,int(600.0/(sr/2)*(NF//2))|1); k=np.ones(w)/w
    sm=np.array([np.convolve(e,k,'same') for e in env])
    return env + alpha*(env - sm)

def synth(a, seed=0, pf_alpha=0.10, disp=0.0, mix=0.15, vpow=0.5, ntilt=0.5, hfmax=7500.0):
    sr,H,NF,env,f0s,voiced,N=a['sr'],a['H'],a['NF'],a['env'],a['f0'],a['voiced'],a['N']
    bvoi=a['bvoi']
    env=_postfilter(env, sr, NF, pf_alpha)                # spectral enhancement postfilter
    theta=np.array([_minphase_theta(e,NF) for e in env]); nf=len(env)
    if disp>0:   # fixed pulse-dispersion phase (de-buzz): spreads the glottal pulse in
                 # time without adding noise; consistent every frame so harmonics stay
                 # phase-coherent across frames (a fixed "glottal pulse shape").
        dphi=disp*np.random.default_rng(1234).standard_normal(NF//2+1)
        theta=theta+dphi[None,:]
    frq=np.fft.rfftfreq(NF,1/sr); gain=2.0/np.sum(np.hanning(NF))
    bcent=((BV_EDGES[:-1]+BV_EDGES[1:])/2)*(sr/2)          # band-voicing centers (Hz)
    out=np.zeros(N); rng=np.random.default_rng(seed); Phi=0.0
    nwin=np.hanning(2*H)
    def Vat(fi, freqs):   # per-frequency voicing strength (mixed-excitation split)
        return np.interp(freqs, bcent, bvoi[fi], left=bvoi[fi][0], right=bvoi[fi][-1])
    def ei(fi,freqs):
        b=np.clip(freqs/(sr/2)*(NF//2),0,NF//2-1e-6); b0=b.astype(int); fr=b-b0
        le=env[fi,b0]+fr*(env[fi,b0+1]-env[fi,b0]); th=theta[fi,b0]+fr*(theta[fi,b0+1]-theta[fi,b0])
        return le,th
    for idx in range(nf-1):
        i0=idx*H; nseg=min(H,N-i0)
        if nseg<=0: break
        tt=np.arange(nseg)/H; f0a,f0b=f0s[idx],f0s[idx+1]
        nn=rng.standard_normal(2*H)
        Sn=np.fft.rfft(nn*nwin,NF)*np.exp(env[idx])       # full env-shaped noise spectrum
        ncal=1.0
        if voiced[idx] and f0a>1 and f0b>1:
            phi=Phi+np.cumsum(2*np.pi*(f0a*(1-tt)+f0b*tt)/sr)
            K=int(min(sr*0.45,hfmax)/max(f0a,f0b,1)); ks=np.arange(1,K+1)
            le0,th0=ei(idx,ks*f0a); le1,th1=ei(idx+1,ks*f0b)
            Afull0=np.exp(le0)*gain                        # full (V=1) harmonic amps
            # MIXED EXCITATION: periodic part scaled by sqrt(V_band)
            Vk0=np.clip(Vat(idx,ks*f0a),0,1)**vpow; Vk1=np.clip(Vat(idx+1,ks*f0b),0,1)**vpow
            A0=Afull0*Vk0; A1=np.exp(le1)*gain*Vk1
            A=A0[None,:]*(1-tt[:,None])+A1[None,:]*tt[:,None]
            TH=th0[None,:]*(1-tt[:,None])+th1[None,:]*tt[:,None]
            out[i0:i0+nseg]+=np.sum(A*np.sin(ks[None,:]*phi[:,None]+TH),axis=1)
            Phi=phi[-1]
            # frame-adaptive calibration: make V=0 noise carry the SAME power the V=1
            # harmonics would, so the sqrt(V)/sqrt(1-V) split is energy-conserving.
            Ph=0.5*np.sum(Afull0**2)                       # full harmonic power
            nfull=np.fft.irfft(Sn,NF)[:2*H]; Pn=np.mean(nfull**2)+1e-20
            ncal=np.sqrt(Ph/Pn)
            # aperiodic (breath) part: sqrt(1-V), tilted down at HF so voiced speech
            # doesn't gain the 1.5-4 kHz "extra noise" (unvoiced frames keep full HF).
            tilt=np.clip(1.0-ntilt*(frq/(sr/2)),0.25,1.0)
            Sn=Sn*np.sqrt(np.clip(1.0-Vat(idx,frq),0,1))*tilt
        seg=np.fft.irfft(Sn,NF)[:2*H]*ncal*(mix if voiced[idx] else 1.0)
        b0=i0-H//2
        for j in range(2*H):
            p=b0+j
            if 0<=p<N: out[p]+=seg[j]
    return out

def frame_rms(x, H):
    return np.array([np.sqrt(np.mean(x[i:i+H]**2)) for i in range(0,len(x)-H,H)])

def apply_gain(y, target_rms, H):
    """scale synthesis so each frame matches a target RMS contour (the stored gain)."""
    N=len(y)
    ey=np.array([np.sqrt(np.mean(y[i:i+H]**2)) for i in range(0,N-H,H)])
    m=min(len(ey),len(target_rms)); ey=ey[:m]; tr=target_rms[:m]
    g=np.clip(np.where(ey>1e-6,tr/(ey+1e-9),1.0),0,8)
    gs=np.interp(np.arange(N),np.arange(len(g))*H+H/2,g,left=g[0] if len(g) else 1,right=g[-1] if len(g) else 1)
    return y*gs

def energy_match(x, y, H):
    """apply the SOURCE frame-energy contour (uncompressed reference path)."""
    n=min(len(x),len(y))
    return apply_gain(y[:n], frame_rms(x, H), H)

def code(x, sr, **kw):
    """full analysis->synthesis (uncompressed reference); returns (y, analysis)."""
    a=analyze(x,sr); y=synth(a, **kw); return energy_match(x, y, a['H']), a

if __name__=='__main__':
    import sys
    x,sr=read_wav(sys.argv[1]); y,a=code(x,sr)
    write_wav(sys.argv[2], y, sr)
    print(f"qvoc: {sys.argv[1]} @ {sr} Hz -> {sys.argv[2]}  ({len(a['f0'])} frames)")
