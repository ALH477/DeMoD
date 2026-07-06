#!/usr/bin/env python3
# Train the predictive (DPCM) LSF-VQ codebook on frame-to-frame residuals and evaluate
# the coded codec on the HELD-OUT bench clips. Compares to non-predictive LSF (2.04) +
# Codec2. Results persisted to test/speech/pred_result.txt.
import sys, glob, numpy as np
sys.path.insert(0,'tools'); import qvoc, qcodec
from pesq import pesq

order=int(sys.argv[1]) if len(sys.argv)>1 else 16
RESF='test/speech/pred_result.txt'
def log(s): print(s,flush=True); open(RESF,'a').write(s+'\n')
open(RESF,'w').write('')

R=np.load(f'test/speech/train/lsfres_8000_o{order}.npy'); rm=R.mean(0)
log(f"predictive LSF-VQ order={order}: {len(R)} residual vectors, residual std {R.std():.3f}")
clips=sorted(glob.glob('test/speech/bench/*_8k.wav'))
def ev(cbs,fps):
    ps=[];bps=[]
    for c in clips:
        x,sr=qvoc.read_wav(c); meta,bits,bp=qcodec.encode_lsf_pred(x,sr,cbs,rm,fps=fps,order=order)
        y=qcodec.decode_lsf_pred(meta); n=min(len(x),len(y)); ps.append(pesq(sr,x[:n],y[:n],'nb')); bps.append(bp)
    return np.mean(bps),np.mean(ps)
for sizes in ([512,256],[1024,512],[1024,1024,256]):
    cbs=qcodec.train_msvq(R-rm,sizes); eb=sum(int(round(np.log2(s))) for s in sizes)
    for fps in (50,33):
        b,p=ev(cbs,fps); log(f"  MSVQ={sizes} ({eb}b) fps={fps}: {b:.0f} bps  held-out PESQ {p:.3f}")
    np.savez(f'test/speech/vq_lsfpred_o{order}_{eb}b.npz', resmean=rm, *cbs)
log("(non-pred LSF was 2.04@2593bps; Codec2 700=2.035 1300=2.100@1400 2400=2.434)")
