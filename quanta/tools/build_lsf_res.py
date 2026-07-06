#!/usr/bin/env python3
# Extract sequential frame-to-frame LSF RESIDUALS (at the codec's decimated rate) from
# a corpus, to train the predictive DPCM-VQ codebook. Envelope-only (fast).
#   usage: root SR order MAXV
import numpy as np, glob, os, sys, subprocess, random
sys.path.insert(0,'tools'); import qvoc, lsf
root=sys.argv[1]; SR=int(sys.argv[2]); order=int(sys.argv[3]); MAXV=int(sys.argv[4])
H,NF=qvoc._params(SR); W=NF; win=np.hanning(W); lifter=max(20,int(NF*0.12))

def seq(x):
    out=[]
    for i in range(0,len(x)-W,H*2):                      # 2 analysis frames = codec's 50 fps
        X=np.fft.rfft(x[i:i+W]*win,NF); mag=np.abs(X)
        if mag.max()<=1e-3: out.append(None); continue
        logm=np.log(np.maximum(mag,mag.max()*1e-4))
        full=np.concatenate([logm,logm[-2:0:-1]]); cep=np.fft.ifft(full).real
        lift=np.zeros_like(cep); lift[:lifter]=1; lift[-lifter+1:]=1
        env=np.fft.fft(cep*lift).real[:NF//2+1]
        a,_=lsf.env_to_lpc(env,NF,order); out.append(lsf.lpc_to_lsf(a))
    return out

flacs=sorted(glob.glob(os.path.join(root,'**','*.flac'),recursive=True))
random.seed(2); random.shuffle(flacs)
R=[]; nf=0
for f in flacs:
    subprocess.run(['ffmpeg','-nostdin','-y','-i',f,'-ar',str(SR),'-ac','1','/tmp/_ls.wav'],
                   stderr=subprocess.DEVNULL,stdout=subprocess.DEVNULL)
    try: x,_=qvoc.read_wav('/tmp/_ls.wav')
    except Exception: continue
    s=seq(x)
    for t in range(1,len(s)):
        if s[t] is not None and s[t-1] is not None: R.append(s[t]-s[t-1])
    nf+=1
    if len(R)>=MAXV: break
    if nf%80==0: print(f"  {nf} files, {len(R)} residuals",flush=True)
R=np.array(R[:MAXV])
out=f'test/speech/train/lsfres_{SR}_o{order}.npy'; np.save(out,R)
print(f"saved {len(R)} LSF residuals (dim {R.shape[1]}) @ {SR} Hz -> {out}  "
      f"(std {R.std():.3f} vs raw-LSF std ~0.3 => predictive gain)")
