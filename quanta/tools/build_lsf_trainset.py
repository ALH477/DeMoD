#!/usr/bin/env python3
# Extract LSF training vectors from a speech corpus at a target sample rate, directly
# from the spectral envelope (env -> LPC -> LSF), for the wideband (16 kHz) codec.
# Skips f0 tracking (envelope only = fast).  usage: root SR order MAXV
import numpy as np, glob, os, sys, subprocess, random
sys.path.insert(0,'tools'); import qvoc, lsf
root=sys.argv[1]; SR=int(sys.argv[2]); order=int(sys.argv[3]); MAXV=int(sys.argv[4])
H,NF=qvoc._params(SR); W=NF; win=np.hanning(W); lifter=max(20,int(NF*0.12))

def lsf_vecs(x):
    out=[]
    for i in range(0,len(x)-W,H*2):
        X=np.fft.rfft(x[i:i+W]*win,NF); mag=np.abs(X)
        if mag.max()<=1e-3: continue
        logm=np.log(np.maximum(mag,mag.max()*1e-4))
        full=np.concatenate([logm,logm[-2:0:-1]]); cep=np.fft.ifft(full).real
        lift=np.zeros_like(cep); lift[:lifter]=1; lift[-lifter+1:]=1
        env=np.fft.fft(cep*lift).real[:NF//2+1]
        a,_=lsf.env_to_lpc(env,NF,order); out.append(lsf.lpc_to_lsf(a))
    return out

flacs=sorted(glob.glob(os.path.join(root,'**','*.flac'),recursive=True))
random.seed(1); random.shuffle(flacs)
V=[]; nf=0
for f in flacs:
    subprocess.run(['ffmpeg','-nostdin','-y','-i',f,'-ar',str(SR),'-ac','1','/tmp/_ls.wav'],
                   stderr=subprocess.DEVNULL,stdout=subprocess.DEVNULL)
    try: x,_=qvoc.read_wav('/tmp/_ls.wav')
    except Exception: continue
    V.extend(lsf_vecs(x)); nf+=1
    if len(V)>=MAXV: break
    if nf%80==0: print(f"  {nf} files, {len(V)} LSF vectors",flush=True)
V=np.array(V[:MAXV])
out=f'test/speech/train/lsf_{SR}_o{order}.npy'; np.save(out,V)
print(f"saved {len(V)} LSF vectors (dim {V.shape[1]}) @ {SR} Hz -> {out}")
