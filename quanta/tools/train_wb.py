#!/usr/bin/env python3
# Wideband (16 kHz) showcase: train the 16 kHz LSF-VQ codec and run the head-to-head
# against Codec2. Codec2 is narrowband (8 kHz) by construction, so it is scored by
# upsampling its 8 kHz output to 16 kHz — the 4-8 kHz band it structurally cannot
# carry is exactly our advantage. Scored with WIDEBAND PESQ against the 16 kHz source.
import sys, glob, os, subprocess, numpy as np
sys.path.insert(0,'tools'); import qvoc, qcodec
from pesq import pesq
from scipy.signal import resample_poly

SR=16000; order=24; sizes=eval(sys.argv[1]) if len(sys.argv)>1 else [1024,1024,256]
RESF='test/speech/wb_result.txt'
def log(s): print(s,flush=True); open(RESF,'a').write(s+'\n')
open(RESF,'w').write('')

L=np.load(f'test/speech/train/lsf_{SR}_o{order}.npy'); lm=L.mean(0)
log(f"16 kHz WIDEBAND showcase — LSF order={order}, MSVQ={sizes} "
    f"({sum(int(round(np.log2(s))) for s in sizes)} env bits), {len(L)} train vectors")
cbs=qcodec.train_msvq(L-lm, sizes)
np.savez(f'test/speech/vq_lsf16_o{order}.npz', lsfmean=lm, *cbs)

log(f"{'clip':11s} {'OURS(wb) 16k':>14s} {'Codec2 8k->16k':>15s}")
log('-'*44)
op=[]; cp=[]; ob=[]
for c in sorted(glob.glob('test/speech/bench/*_16k.wav')):
    name=os.path.basename(c).replace('_16k.wav','')
    ref,_=qvoc.read_wav(c)                                  # 16 kHz reference
    meta,bits,bp=qcodec.encode_lsf(ref,SR,cbs,lm,fps=50,order=order)
    y=qcodec.decode_lsf(meta); n=min(len(ref),len(y))
    po=pesq(SR,ref[:n],y[:n],'wb'); op.append(po); ob.append(bp)
    # Codec2 @2400 on the 8 kHz version, then upsample 8k->16k
    x8,_=qvoc.read_wav(c.replace('_16k.wav','_8k.wav'))
    (np.clip(x8,-1,1)*32767).astype('<i2').tofile('/tmp/in.raw')
    subprocess.run('c2enc 2400 /tmp/in.raw /tmp/c.bin && c2dec 2400 /tmp/c.bin /tmp/c.raw',
                   shell=True,stderr=subprocess.DEVNULL)
    c8=np.fromfile('/tmp/c.raw',dtype='<i2').astype(float)/32768
    c16=resample_poly(c8,2,1); m=min(len(ref),len(c16))
    pc=pesq(SR,ref[:m],c16[:m],'wb'); cp.append(pc)
    log(f"{name:11s} {po:7.3f} @{bp:5.0f}bps  {pc:7.3f} @ 2400bps")
log('-'*44)
log(f"MEAN wideband PESQ:  OURS {np.mean(op):.3f} @ {np.mean(ob):.0f} bps   "
    f"Codec2(nb) {np.mean(cp):.3f} @ 2400 bps")
log(f"=> our wideband advantage: {np.mean(op)-np.mean(cp):+.3f} PESQ")
