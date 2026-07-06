#!/usr/bin/env python3
# Train the cepstrum MSVQ codebooks and evaluate the coded codec vs Codec2.
# HELD-OUT DISCIPLINE: train on the big LibriSpeech-derived vector set
# (test/speech/train/cepstra_*.npy) if present; ALWAYS evaluate on the disjoint
# test/speech/bench/*_8k.wav LibriVox clips (never seen in training). Runs inside the
# nix env (scipy for k-means, pesq for MOS). Codebooks saved to test/speech/vq_cepK*.npz.
import sys, glob, os, numpy as np
sys.path.insert(0,'tools'); import qvoc, qcodec
from pesq import pesq

K=int(sys.argv[1]) if len(sys.argv)>1 else 24
sizes=eval(sys.argv[2]) if len(sys.argv)>2 else [1024,1024,256]   # 10+10+8 = 28 env bits
fps=int(sys.argv[3]) if len(sys.argv)>3 else 50
envbits=sum(int(round(np.log2(s))) for s in sizes)
print(f"K={K} MSVQ={sizes} ({envbits} env bits) fps={fps}")

trainf=f'test/speech/train/cepstra_8000_K{K}.npy'
if os.path.exists(trainf):
    V=np.load(trainf); print(f"train: {len(V)} vectors from {trainf} (LibriSpeech, held-out from bench)")
else:
    V=qcodec.collect_cepstra(sorted(glob.glob('test/speech/bench/*_8k.wav')), K)
    print(f"train: {len(V)} vectors from bench (NO held-out set — fallback)")
cbs=qcodec.train_msvq(V, sizes)

clips=sorted(glob.glob('test/speech/bench/*_8k.wav'))
ps=[]; bps=[]
for c in clips:
    x,sr=qvoc.read_wav(c)
    meta,bits,bp=qcodec.encode_vq(x,sr,cbs,fps=fps,K=K)
    y=qcodec.decode_vq(meta); n=min(len(x),len(y))
    ps.append(pesq(sr,x[:n],y[:n],'nb')); bps.append(bp)
    print(f"  {c.split('/')[-1]:16s} {bp:6.0f} bps  PESQ {ps[-1]:.3f}")
print(f"MEAN (held-out): {np.mean(bps):.0f} bps  PESQ {np.mean(ps):.3f}   "
      f"(Codec2 2400=2.434, 1300=2.100, 700C=2.035)")
np.savez(f'test/speech/vq_cepK{K}.npz', *cbs)
print(f"saved -> test/speech/vq_cepK{K}.npz")
