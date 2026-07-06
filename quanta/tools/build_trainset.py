#!/usr/bin/env python3
# Extract envelope-cepstrum training vectors from a large speech corpus (LibriSpeech
# flac tree) for VQ codebook training. VQ needs only the spectral ENVELOPE, so we skip
# f0 tracking entirely (fast). Vectors are the std-normalized c1..cK-1 that qcodec
# quantizes, extracted with the SAME window/lifter as qvoc.analyze so they match.
# Held-out discipline: this corpus (LibriSpeech readers) is disjoint from the 4
# test/speech/bench LibriVox clips, so evaluation never sees training data.
import numpy as np, glob, os, sys, subprocess, random
sys.path.insert(0,'tools'); import qvoc, qcodec

SR=int(sys.argv[2]) if len(sys.argv)>2 else 8000
K=int(sys.argv[3]) if len(sys.argv)>3 else 24
MAXV=int(sys.argv[4]) if len(sys.argv)>4 else 200000
root=sys.argv[1]                                            # dir with *.flac somewhere below
H,NF=qvoc._params(SR); W=NF; win=np.hanning(W)
lifter=max(20,int(NF*0.12)); cs=np.array(qcodec.CEP_STD[:K-1])

def cepstra(x):
    out=[]
    for i in range(0,len(x)-W,H*2):                         # every 2 frames (decorrelate)
        X=np.fft.rfft(x[i:i+W]*win,NF); mag=np.abs(X)
        logm=np.log(np.maximum(mag,mag.max()*1e-4))
        full=np.concatenate([logm,logm[-2:0:-1]]); cep=np.fft.ifft(full).real
        lift=np.zeros_like(cep); lift[:lifter]=1; lift[-lifter+1:]=1
        env=np.fft.fft(cep*lift).real[:NF//2+1]
        c=qcodec._cepstrum(env,NF,K)
        if mag.max()>1e-3: out.append(c[1:K]/cs)
    return out

flacs=sorted(glob.glob(os.path.join(root,'**','*.flac'), recursive=True))
random.seed(0); random.shuffle(flacs)
print(f"{len(flacs)} flac files; extracting to <= {MAXV} vectors @ {SR} Hz")
V=[]; nf=0
for f in flacs:
    tmp='/tmp/_ls.wav'
    subprocess.run(['ffmpeg','-nostdin','-y','-i',f,'-ar',str(SR),'-ac','1',tmp],
                   stderr=subprocess.DEVNULL,stdout=subprocess.DEVNULL)
    try: x,_=qvoc.read_wav(tmp)
    except Exception: continue
    V.extend(cepstra(x)); nf+=1
    if len(V)>=MAXV: break
    if nf%100==0: print(f"  {nf} files, {len(V)} vectors")
V=np.array(V[:MAXV])
out=f'test/speech/train/cepstra_{SR}_K{K}.npy'; np.save(out, V)
print(f"saved {len(V)} vectors -> {out}")
