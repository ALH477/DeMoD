#!/usr/bin/env python3
# bench_speech.py — beat-MELPe scoreboard. Runs our qvoc vocoder and Codec2 over the
# public-domain multi-speaker set (test/speech/bench/*_8k.wav) and tabulates
# PESQ (MOS-LQO) + MCD + bitrate. The head-to-head that defines "beat it".
#
# Must run inside a nix env providing python-with-pesq AND codec2, e.g.:
#   nix shell --impure --expr 'with builtins.getFlake "nixpkgs";
#     legacyPackages.x86_64-linux.python3.withPackages(ps: with ps;[pesq numpy])' \
#     nixpkgs#codec2 --command python3 tools/bench_speech.py
import sys, os, glob, subprocess, tempfile, numpy as np
sys.path.insert(0,'tools'); import qvoc, mcd
from pesq import pesq

def wr_raw(x, p): (np.clip(x,-1,1)*32767).astype('<i2').tofile(p)
def rd_raw(p):    return np.fromfile(p,dtype='<i2').astype(np.float64)/32768.0

def scores(ref, deg, sr):
    n=min(len(ref),len(deg)); r,d=ref[:n],deg[:n]
    try: p=pesq(sr, r, d, 'nb' if sr==8000 else 'wb')
    except Exception: p=float('nan')
    r.astype('<f8').tofile('/tmp/_r.f64'); d.astype('<f8').tofile('/tmp/_d.f64')
    o=subprocess.run(['python3','tools/mcd.py','/tmp/_r.f64','/tmp/_d.f64',str(sr)],
                     capture_output=True,text=True).stdout
    m=float(o.split('mcd:')[1].split('dB')[0]) if 'mcd:' in o else float('nan')
    return p, m

C2_MODES=['2400','1300','700C']; C2_BPS={'2400':2400,'1300':1400,'700C':700}
clips=sorted(glob.glob('test/speech/bench/*_8k.wav'))
print(f"{'clip':11s} {'codec':10s} {'bitrate':>8s} {'PESQ':>6s} {'MCD':>6s}")
print('-'*46)
agg={}
for clip in clips:
    name=os.path.basename(clip).replace('_8k.wav','')
    x,sr=qvoc.read_wav(clip)               # 8 kHz
    dur=len(x)/sr
    # --- ours (uncompressed reference quality) ---
    y,_=qvoc.code(x,sr)
    p,m=scores(x,y,sr)
    print(f"{name:11s} {'qvoc':10s} {'(uncmp)':>8s} {p:6.3f} {m:6.2f}")
    agg.setdefault('qvoc',[]).append((p,m))
    # --- codec2 ---
    wr_raw(x,'/tmp/_in.raw')
    for mode in C2_MODES:
        subprocess.run(f'c2enc {mode} /tmp/_in.raw /tmp/_c.bin',shell=True,stderr=subprocess.DEVNULL)
        subprocess.run(f'c2dec {mode} /tmp/_c.bin /tmp/_c.raw',shell=True,stderr=subprocess.DEVNULL)
        deg=rd_raw('/tmp/_c.raw'); p,m=scores(x,deg,sr)
        print(f"{'':11s} {'c2 '+mode:10s} {C2_BPS[mode]:8d} {p:6.3f} {m:6.2f}")
        agg.setdefault('c2 '+mode,[]).append((p,m))
print('-'*46)
print("MEAN over %d clips:" % len(clips))
for k in ['qvoc']+['c2 '+m for m in C2_MODES]:
    a=np.array(agg[k]); print(f"  {k:10s} PESQ {a[:,0].mean():.3f}  MCD {a[:,1].mean():.2f}")
