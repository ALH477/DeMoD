#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-DeMoD-Commercial
# qunits.py — Quanta acoustic-UNIT segment vocoder (sub-MELPe bitrate).
# Bypasses per-frame envelope coding: bake vowel/consonant-like acoustic units into an
# inventory, then transmit unit-index + prosody (pitch/duration/energy) instead of a
# spectrum every frame. A unit spans many frames, so the bitrate collapses to ~200-600 bps.
#
# A UNIT = a variable-length (~40-140 ms) prosody-normalised acoustic segment, stored as an
# LSF trajectory resampled to a fixed number of sub-frames (+ a voicing subpattern). Reuses
# qvoc (analysis/synthesis) and lsf (LSF distance) — see tools/qvoc.py, tools/lsf.py.
#
# Phase U0 here: analysis -> LSF frames -> segmentation -> cluster into an inventory codebook.
import numpy as np, sys, os
HERE=os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0,HERE)
import qvoc, lsf

LPC_ORDER=16
NSUB=5                     # sub-frames a unit's LSF trajectory is resampled to (fixed-len)

def analyze_lsf(x, sr, order=LPC_ORDER):
    """qvoc analysis + per-frame LSF trajectory + energy contour."""
    a=qvoc.analyze(x,sr); NF=a['NF']
    L=np.array([lsf.lpc_to_lsf(lsf.env_to_lpc(a['env'][i],NF,order)[0]) for i in range(len(a['env']))])
    en=qvoc.frame_rms(x,a['H'])[:len(L)]
    return dict(env=a['env'],lsf=L,f0=a['f0'][:len(L)],voiced=a['voiced'][:len(L)],
                bvoi=a['bvoi'][:len(L)],en=en,H=a['H'],NF=NF,order=order,sr=sr,N=len(x))

def segment(A, min_ms=45, max_ms=140, thr_pctl=70):
    """Split into units at LSF spectral-change peaks + voiced/unvoiced transitions,
    bounded to [min_ms, max_ms]. Returns list of (start,end) frame indices."""
    L=A['lsf']; voiced=A['voiced']; sr=A['sr']; H=A['H']; n=len(L)
    d=np.concatenate([[0.0], np.sqrt(np.sum(np.diff(L,axis=0)**2,axis=1))])
    thr=np.percentile(d,thr_pctl)
    minf=max(2,int(min_ms/1000*sr/H)); maxf=max(minf+1,int(max_ms/1000*sr/H))
    bounds=[0]; last=0
    for t in range(1,n):
        gap=t-last
        vtrans = voiced[t]!=voiced[t-1]
        peak = d[t]>=thr and d[t]>=d[t-1] and (t+1>=n or d[t]>=d[t+1])
        if (vtrans and gap>=minf//2) or (peak and gap>=minf) or gap>=maxf:
            bounds.append(t); last=t
    if bounds[-1]!=n: bounds.append(n)
    return [(bounds[i],bounds[i+1]) for i in range(len(bounds)-1)]

def unit_traj(A, seg, nsub=NSUB):
    """Resample a segment's LSF trajectory + voicing to nsub sub-frames (fixed-length)."""
    s,e=seg; L=A['lsf'][s:e]; V=A['voiced'][s:e].astype(float)
    if len(L)<1: L=A['lsf'][s:s+1]; V=A['voiced'][s:s+1].astype(float)
    idx=np.linspace(0,len(L)-1,nsub)
    Lr=np.array([L[int(round(i))] for i in idx])        # (nsub, order)
    Vr=np.array([V[int(round(i))] for i in idx])        # (nsub,)
    return Lr, Vr

def build_inventory(clips, K=192, order=LPC_ORDER, nsub=NSUB, cluster=True):
    """Segment all clips into unit LSF-trajectories. cluster=True: k-means to K codewords
    (compact, but centroids blur phones). cluster=False: keep the ACTUAL segments as the
    inventory (true unit-selection — crisper phones, id costs log2(#segments) bits)."""
    vecs=[]; vpat=[]
    for c in clips:
        x,sr=qvoc.read_wav(c); A=analyze_lsf(x,sr,order)
        for seg in segment(A):
            Lr,Vr=unit_traj(A,seg,nsub); vecs.append(Lr.flatten()); vpat.append(Vr)
    vecs=np.array(vecs); vpat=np.array(vpat)
    if cluster:
        from qcodec import train_msvq
        cb=train_msvq(vecs,[K])[0]
        lbl=np.array([int(np.argmin(((cb-v)**2).sum(1))) for v in vecs])
        vc=np.array([vpat[lbl==k].mean(0) if np.any(lbl==k) else np.ones(nsub) for k in range(K)])
    else:
        cb=vecs; vc=vpat; K=len(vecs)                  # inventory = the real segments
    return dict(cb=cb, vpat=(vc>0.5), order=order, nsub=nsub, K=K), len(vecs)

# ---------- U1 encoder: WAV -> quantized unit stream ----------
def _q(v,lo,hi,bits): n=(1<<bits)-1; return int(np.clip(round((np.clip(v,lo,hi)-lo)/(hi-lo)*n),0,n))
def _dq(i,lo,hi,bits): n=(1<<bits)-1; return lo+i/n*(hi-lo)
IDBITS=lambda K:int(np.ceil(np.log2(K))); DURB=4; PITB=6; ENGB=4

def _rs(a, n):  # resample 1-D array to n points
    if len(a)==0: return np.zeros(n)
    return np.interp(np.linspace(0,len(a)-1,n), np.arange(len(a)), a)

def encode(A, inv):
    idb=IDBITS(inv['K']); ns=inv['nsub']; stream=[]; bits=0
    for seg in segment(A):
        s,e=seg; Lr,_=unit_traj(A,seg,ns)
        uid=int(np.argmin(((inv['cb']-Lr.flatten())**2).sum(1)))
        dur=(e-s)*A['H']/A['sr']*1000
        vseg=A['voiced'][s:e]; f0s=A['f0'][s:e]
        vf=f0s[vseg] if np.any(vseg) else np.array([120.0])
        p0,p1=float(vf[0]),float(vf[-1])                 # pitch contour (start,end)
        econ=_rs(A['en'][s:e], ns); vcon=(_rs(vseg.astype(float),ns)>0.5).astype(int)
        di=_q(dur,20,160,DURB)
        pi0=_q(np.log2(np.clip(p0,70,400)),np.log2(70),np.log2(400),PITB)
        pi1=_q(np.log2(np.clip(p1,70,400)),np.log2(70),np.log2(400),PITB)
        ei=[_q(np.log10(v+1e-9),-4,0,3) for v in econ]    # energy contour (nsub x 3b)
        stream.append((uid,di,pi0,pi1,ei,list(vcon)))
        bits += idb+DURB+2*PITB+ns*3+ns                   # id+dur+2pitch+energy+voicing
    return stream, bits, bits/(A['N']/A['sr'])

# ---------- U2 decoder: unit stream -> WAV ----------
def decode(stream, inv, sr, smooth=3):
    H,NF=qvoc._params(sr); order=inv['order']; ns=inv['nsub']
    Lf=[]; f0=[]; vo=[]; bv=[]; gain=[]
    bv_voiced=np.clip(np.linspace(0.75,0.2,qvoc.NB),0,1)     # default voiced band-voicing
    for (uid,di,pi0,pi1,ei,vcon) in stream:
        dur=_dq(di,20,160,DURB)
        p0=2**_dq(pi0,np.log2(70),np.log2(400),PITB); p1=2**_dq(pi1,np.log2(70),np.log2(400),PITB)
        econ=np.array([10**_dq(q,-4,0,3) for q in ei]); vc=np.array(vcon)
        cw=inv['cb'][uid].reshape(ns,order); nfr=max(1,int(round(dur/1000*sr/H)))
        for j in range(nfr):
            t=(j/(nfr-1)) if nfr>1 else 0.0; si=t*(ns-1); s0=int(si); f=si-s0
            Lf.append(np.sort(cw[s0]*(1-f)+cw[min(s0+1,ns-1)]*f))
            uv = bool(vc[int(round(t*(ns-1)))])           # voicing contour
            f0.append((p0*(1-t)+p1*t) if uv else 0.0); vo.append(uv)
            bv.append(bv_voiced if uv else np.zeros(qvoc.NB))
            gain.append(econ[s0]*(1-f)+econ[min(s0+1,ns-1)]*f)   # energy contour
    Lf=np.array(Lf)
    # smooth the LSF trajectory across time (kills unit-join clicks / abrupt formant jumps)
    if smooth>1 and len(Lf)>smooth:
        k=np.ones(smooth)/smooth
        Lf=np.stack([np.convolve(Lf[:,c],k,'same') for c in range(Lf.shape[1])],1)
        Lf=np.sort(Lf,axis=1)
    env=np.array([lsf.lpc_to_env(lsf.lsf_to_lpc(L),1.0,NF) for L in Lf])
    N=len(env)*H
    a=dict(sr=sr,H=H,NF=NF,env=env,f0=np.array(f0),voiced=np.array(vo),bvoi=np.array(bv),N=N)
    return qvoc.apply_gain(qvoc.synth(a), np.array(gain), H)

# ---------- .qinv / .qspu writers (byte-match include/qspu.h) ----------
import struct, zlib
class _BW:
    def __init__(s): s.b=bytearray([0]); s.byte=0; s.bit=0
    def put1(s,v):
        if v: s.b[s.byte]|=(0x80>>s.bit)
        s.bit+=1
        if s.bit==8: s.bit=0; s.byte+=1; s.b.append(0)
    def putn(s,v,n):
        for i in range(n-1,-1,-1): s.put1((v>>i)&1)
    def bytes(s): return bytes(s.b[:s.byte+(1 if s.bit else 0)])
def _be(v,n): return v.to_bytes(n,'big')

def write_qinv(path, inv, sr):
    K,order,nsub=inv['K'],inv['order'],inv['nsub']
    h=b'QINV'+_be(sr,4)+_be(K,4)+_be(order,4)+_be(nsub,4)
    h+=_be(zlib.crc32(h)&0xffffffff,4)
    cb=np.asarray(inv['cb'],dtype='<f4').tobytes()
    vp=np.asarray(inv['vpat'],dtype=np.uint8).tobytes()
    open(path,'wb').write(h+cb+vp)

def write_qspu(path, stream, inv, sr, source_len):
    idb=IDBITS(inv['K']); nsub=inv['nsub']
    w=_BW()
    for (uid,di,pi0,pi1,ei,vcon) in stream:
        w.putn(uid,idb); w.putn(di,DURB); w.putn(pi0,PITB); w.putn(pi1,PITB)
        for e in ei: w.putn(int(e),3)
        for v in vcon: w.put1(int(v)&1)
    body=w.bytes()
    h=b'QSPU'+_be(sr,4)+_be(source_len,8)+_be(len(stream),4)+_be(nsub,4)+_be(idb,4)
    h+=_be(zlib.crc32(h)&0xffffffff,4)
    open(path,'wb').write(h+body+_be(zlib.crc32(body)&0xffffffff,4))

if __name__=='__main__':
    import glob
    clips=sorted(glob.glob(sys.argv[1])) if len(sys.argv)>1 else sorted(glob.glob('test/speech/bench/*_8k.wav'))
    # quick segmentation stats (no clustering — numpy only)
    tot_units=0; tot_sec=0; lens=[]
    for c in clips:
        x,sr=qvoc.read_wav(c); A=analyze_lsf(x,sr); segs=segment(A)
        tot_units+=len(segs); tot_sec+=len(x)/sr
        lens+=[ (e-s)*A['H']/sr*1000 for s,e in segs ]
    print(f"{len(clips)} clips, {tot_sec:.1f}s: {tot_units} units = {tot_units/tot_sec:.1f} units/s")
    print(f"  unit length ms: min {min(lens):.0f} median {np.median(lens):.0f} max {max(lens):.0f}")
    print(f"  => at ~21 bits/unit, bitrate ~ {tot_units/tot_sec*21:.0f} bps")
