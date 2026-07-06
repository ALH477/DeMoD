#!/usr/bin/env python3
# Train LSF MSVQ codebooks and evaluate the coded codec on the HELD-OUT bench clips.
# Training LSF vectors are derived from the cached 200k LibriSpeech cepstra
# (reconstruct envelope shape -> LSF), so no re-extraction. Eval computes LSFs
# directly from the disjoint LibriVox bench envelopes. Runs in the nix env.
import sys, glob, numpy as np
sys.path.insert(0,'tools'); import qvoc, qcodec
from pesq import pesq

order=int(sys.argv[1]) if len(sys.argv)>1 else 16
sizes=eval(sys.argv[2]) if len(sys.argv)>2 else [1024,1024,256]
NMAX=int(sys.argv[3]) if len(sys.argv)>3 else 40000
NF=qvoc._params(8000)[1]
envbits=sum(int(round(np.log2(s))) for s in sizes)
RESF='test/speech/lsf_result.txt'
def log(s):
    print(s, flush=True)
    open(RESF,'a').write(s+'\n')
open(RESF,'w').write('')
log(f"LSF order={order} MSVQ={sizes} ({envbits} env bits)")

C=np.load('test/speech/train/cepstra_8000_K24.npy')
step=max(1,len(C)//NMAX)
L=np.array([qcodec._lsf_vec(qcodec._env_from_vec(c,NF,24),NF,order) for c in C[::step]])
lsfmean=L.mean(0)
log(f"train: {len(L)} LSF vectors (dim {L.shape[1]}) from LibriSpeech")
cbs=qcodec.train_msvq(L-lsfmean, sizes)

clips=sorted(glob.glob('test/speech/bench/*_8k.wav')); ps=[]; bps=[]
for c in clips:
    x,sr=qvoc.read_wav(c)
    meta,bits,bp=qcodec.encode_lsf(x,sr,cbs,lsfmean,fps=50,order=order)
    y=qcodec.decode_lsf(meta); n=min(len(x),len(y))
    ps.append(pesq(sr,x[:n],y[:n],'nb')); bps.append(bp)
    log(f"  {c.split('/')[-1]:16s} {bp:6.0f} bps  PESQ {ps[-1]:.3f}")
log(f"HELD-OUT MEAN: {np.mean(bps):.0f} bps  PESQ {np.mean(ps):.3f}  "
      f"(cepstrum-VQ was 1.83-1.92; Codec2 2400=2.434,1300=2.100,700C=2.035)")
np.savez(f'test/speech/vq_lsf_o{order}.npz', lsfmean=lsfmean, *cbs)
log(f"saved -> test/speech/vq_lsf_o{order}.npz")
