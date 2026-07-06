#!/usr/bin/env python3
# qcodec — quantizing codec layer over qvoc (beat-MELPe Phase 2).
# Encodes the vocoder parameters at a target frame rate with fixed bit allocation,
# reports the MEASURED bitrate, and decodes (stored gain, no source access) so PESQ
# reflects the real coded quality. Envelope is the low-quefrency cepstrum (the
# compact, VQ-friendly shape); gain/f0/voicing/band-voicing coded scalar for now
# (VQ codebooks are the next step to push the envelope bits down).
import numpy as np, sys
sys.path.insert(0,'tools'); import qvoc

def _cepstrum(env, NF, K):
    full=np.concatenate([env, env[-2:0:-1]]); c=np.fft.ifft(full).real
    return c[:K].copy()
def _env_from_cep(c, NF):
    full=np.zeros(NF); K=len(c); full[:K]=c; full[NF-K+1:]=c[1:][::-1]
    return np.fft.fft(full).real[:NF//2+1]

class Q:  # uniform scalar quantizer over [lo,hi] with n bits
    def __init__(s,lo,hi,bits): s.lo=lo; s.hi=hi; s.n=(1<<bits)-1; s.bits=bits
    def enc(s,v): return int(np.clip(round((np.clip(v,s.lo,s.hi)-s.lo)/(s.hi-s.lo)*s.n),0,s.n))
    def dec(s,i): return s.lo + i/s.n*(s.hi-s.lo)

# ---- multi-stage vector quantization of the (std-normalized) cepstrum ----
def train_msvq(vecs, sizes, iters=15, seed=0):
    """LBG/k-means multi-stage VQ. vecs: (n,dim). Returns list of codebooks.
    minit='points' (random seeding) is far faster than '++' for large n, fine here."""
    from scipy.cluster.vq import kmeans2
    res=vecs.copy(); cbs=[]
    for si,sz in enumerate(sizes):
        cb,lbl=kmeans2(res, sz, minit='points', iter=iters, seed=seed+si)
        cbs.append(cb); res=res-cb[lbl]                    # residual to next stage
    return cbs
def msvq_enc(v, cbs):
    idx=[]; r=v.copy()
    for cb in cbs:
        i=int(np.argmin(((cb-r)**2).sum(1))); idx.append(i); r=r-cb[i]
    return idx
def msvq_dec(idx, cbs):
    return sum(cb[i] for cb,i in zip(cbs, idx))

# corpus-measured per-coefficient std of c1.. (sets quantizer range = 4*std, so bits
# aren't wasted on an oversized range) and a matching bit profile.
CEP_STD  = [0.41,0.22,0.22,0.17,0.13,0.15,0.13,0.11,0.11,0.09,0.09,0.08,
            0.07,0.07,0.07,0.07,0.07,0.07,0.07,0.06,0.06,0.06,0.06,0.06]
CEPBITS  = [5,5,5,4,4,4,4,4,3,3,3,3,3,3,3,3,2,2,2,2,2,2,2,2]

def encode(x, sr, fps=50, K=20, cepbits=None, bv_bits=2, f0_bits=7, gain_bits=6):
    cepbits = (cepbits or CEPBITS)[:K-1]
    a=qvoc.analyze(x, sr); H=a['H']; NF=a['NF']
    g=qvoc.frame_rms(x, H)                                  # per-analysis-frame gain
    nf=min(len(a['f0']), len(g))
    D=max(1,int(round((sr/H)/fps)))                        # decimation factor
    idxs=list(range(0,nf,D))
    Qf0=Q(np.log2(70),np.log2(400),f0_bits); Qg=Q(-9,0,gain_bits); Qbv=Q(0,1,bv_bits)
    Qc=[Q(-4*CEP_STD[k],4*CEP_STD[k],cepbits[k]) for k in range(len(cepbits))]
    stream=[]; bits=0
    for i in idxs:
        v=int(a['voiced'][i]); bits+=1
        if v:
            stream_f0=Qf0.enc(np.log2(np.clip(a['f0'][i],70,400))); bits+=f0_bits
        else: stream_f0=0
        gi=Qg.enc(np.log10(g[i]+1e-9)); bits+=gain_bits
        bvi=[Qbv.enc(a['bvoi'][i][b]) for b in range(qvoc.NB)]; bits+=qvoc.NB*bv_bits
        cep=_cepstrum(a['env'][i],NF,K)
        ci=[Qc[k].enc(cep[k+1]) for k in range(len(cepbits))]; bits+=sum(cepbits)
        stream.append((v,stream_f0,gi,bvi,ci))
    meta=dict(sr=sr,H=H,NF=NF,N=len(x),nf=nf,D=D,idxs=idxs,K=K,cepbits=cepbits,
              Qf0=Qf0,Qg=Qg,Qbv=Qbv,Qc=Qc,stream=stream)
    dur=len(x)/sr
    return meta, bits, bits/dur

def decode(meta):
    H,NF,N,nf,D=meta['H'],meta['NF'],meta['N'],meta['nf'],meta['D']
    idxs=meta['idxs']; Qf0,Qg,Qbv,Qc=meta['Qf0'],meta['Qg'],meta['Qbv'],meta['Qc']
    K=meta['K']; cb=meta['cepbits']
    # dequantize decimated frames
    df0=[]; dv=[]; dg=[]; dbv=[]; denv=[]
    for (v,f0i,gi,bvi,ci) in meta['stream']:
        dv.append(v); df0.append(2**Qf0.dec(f0i) if v else 0.0)
        dg.append(10**Qg.dec(gi))
        dbv.append([Qbv.dec(bvi[b]) for b in range(qvoc.NB)])
        cep=np.zeros(K)
        for k in range(len(cb)): cep[k+1]=Qc[k].dec(ci[k])
        denv.append(_env_from_cep(cep,NF))
    # interpolate decimated -> full analysis-frame rate
    xi=np.array(idxs); full=np.arange(nf)
    def itp(arr): return np.interp(full,xi,arr)
    f0f=itp(np.array(df0)); gf=itp(np.array(dg))
    vf=itp(np.array(dv,float))>0.5
    bvf=np.stack([itp(np.array([b[k] for b in dbv])) for k in range(qvoc.NB)],1)
    envf=np.stack([itp(np.array([e[j] for e in denv])) for j in range(NF//2+1)],1)
    a=dict(sr=meta['sr'],H=H,NF=NF,env=envf,f0=f0f,voiced=vf,bvoi=bvf,N=N)
    y=qvoc.synth(a)
    return qvoc.apply_gain(y, gf, H)

def _cep_vec(env, NF, K):
    c=_cepstrum(env,NF,K); return c[1:K]/np.array(CEP_STD[:K-1])
def _env_from_vec(vec, NF, K):
    c=np.zeros(K); c[1:K]=vec*np.array(CEP_STD[:K-1]); return _env_from_cep(c,NF)

def encode_vq(x, sr, cbs, fps=50, K=24, f0_bits=7, gain_bits=6, bv_bits=2):
    a=qvoc.analyze(x,sr); H=a['H']; NF=a['NF']; g=qvoc.frame_rms(x,H)
    nf=min(len(a['f0']),len(g)); D=max(1,int(round((sr/H)/fps))); idxs=list(range(0,nf,D))
    Qf0=Q(np.log2(70),np.log2(400),f0_bits); Qg=Q(-9,0,gain_bits); Qbv=Q(0,1,bv_bits)
    vqbits=sum(int(round(np.log2(len(cb)))) for cb in cbs)
    stream=[]; bits=0
    for i in idxs:
        v=int(a['voiced'][i])
        f0i=Qf0.enc(np.log2(np.clip(a['f0'][i],70,400))) if v else 0
        gi=Qg.enc(np.log10(g[i]+1e-9))
        bvi=[Qbv.enc(a['bvoi'][i][b]) for b in range(qvoc.NB)]
        vidx=msvq_enc(_cep_vec(a['env'][i],NF,K), cbs)
        bits += 1+f0_bits+gain_bits+qvoc.NB*bv_bits+vqbits
        stream.append((v,f0i,gi,bvi,vidx))
    meta=dict(sr=sr,H=H,NF=NF,N=len(x),nf=nf,idxs=idxs,K=K,cbs=cbs,
              Qf0=Qf0,Qg=Qg,Qbv=Qbv,stream=stream)
    return meta, bits, bits/(len(x)/sr)

def decode_vq(meta):
    H,NF,N,nf=meta['H'],meta['NF'],meta['N'],meta['nf']; idxs=meta['idxs']; K=meta['K']
    Qf0,Qg,Qbv,cbs=meta['Qf0'],meta['Qg'],meta['Qbv'],meta['cbs']
    df0=[];dv=[];dg=[];dbv=[];denv=[]
    for (v,f0i,gi,bvi,vidx) in meta['stream']:
        dv.append(v); df0.append(2**Qf0.dec(f0i) if v else 0.0); dg.append(10**Qg.dec(gi))
        dbv.append([Qbv.dec(bvi[b]) for b in range(qvoc.NB)])
        denv.append(_env_from_vec(msvq_dec(vidx,cbs),NF,K))
    xi=np.array(idxs); full=np.arange(nf); itp=lambda arr: np.interp(full,xi,arr)
    a=dict(sr=meta['sr'],H=H,NF=NF,f0=itp(np.array(df0)),
           voiced=itp(np.array(dv,float))>0.5,
           bvoi=np.stack([itp(np.array([b[k] for b in dbv])) for k in range(qvoc.NB)],1),
           env=np.stack([itp(np.array([e[j] for e in denv])) for j in range(NF//2+1)],1),N=N)
    return qvoc.apply_gain(qvoc.synth(a), itp(np.array(dg)), H)

def _sidebits(a,i,g,Qf0,Qg,Qbv,f0_bits,gain_bits,bv_bits):
    v=int(a['voiced'][i])
    f0i=Qf0.enc(np.log2(np.clip(a['f0'][i],70,400))) if v else 0
    gi=Qg.enc(np.log10(g[i]+1e-9)); bvi=[Qbv.enc(a['bvoi'][i][b]) for b in range(qvoc.NB)]
    return v,f0i,gi,bvi, 1+f0_bits+gain_bits+qvoc.NB*bv_bits

def collect_cepstra(clips, K):
    v=[]
    for c in clips:
        x,sr=qvoc.read_wav(c); a=qvoc.analyze(x,sr)
        for i in range(len(a['env'])): v.append(_cep_vec(a['env'][i],a['NF'],K))
    return np.array(v)

# ---- LSF envelope path (the low-bitrate-friendly representation) ----
import lsf as _lsf
LPC_ORDER=16
def _lsf_vec(env, NF, order=LPC_ORDER):
    a,_=_lsf.env_to_lpc(env, NF, order); return _lsf.lpc_to_lsf(a)
def _env_from_lsf(v, NF, order=LPC_ORDER):
    return _lsf.lpc_to_env(_lsf.lsf_to_lpc(v), 1.0, NF)

def encode_lsf(x, sr, cbs, lsfmean, fps=50, order=LPC_ORDER, f0_bits=7, gain_bits=6, bv_bits=2):
    a=qvoc.analyze(x,sr); H=a['H']; NF=a['NF']; g=qvoc.frame_rms(x,H)
    nf=min(len(a['f0']),len(g)); D=max(1,int(round((sr/H)/fps))); idxs=list(range(0,nf,D))
    Qf0=Q(np.log2(70),np.log2(400),f0_bits); Qg=Q(-9,0,gain_bits); Qbv=Q(0,1,bv_bits)
    vqbits=sum(int(round(np.log2(len(cb)))) for cb in cbs); stream=[]; bits=0
    for i in idxs:
        v=int(a['voiced'][i])
        f0i=Qf0.enc(np.log2(np.clip(a['f0'][i],70,400))) if v else 0
        gi=Qg.enc(np.log10(g[i]+1e-9))
        bvi=[Qbv.enc(a['bvoi'][i][b]) for b in range(qvoc.NB)]
        vidx=msvq_enc(_lsf_vec(a['env'][i],NF,order)-lsfmean, cbs)
        bits += 1+f0_bits+gain_bits+qvoc.NB*bv_bits+vqbits
        stream.append((v,f0i,gi,bvi,vidx))
    meta=dict(sr=sr,H=H,NF=NF,N=len(x),nf=nf,idxs=idxs,order=order,cbs=cbs,lsfmean=lsfmean,
              Qf0=Qf0,Qg=Qg,Qbv=Qbv,stream=stream)
    return meta, bits, bits/(len(x)/sr)

def decode_lsf(meta):
    H,NF,N,nf=meta['H'],meta['NF'],meta['N'],meta['nf']; idxs=meta['idxs']; order=meta['order']
    Qf0,Qg,Qbv,cbs,lm=meta['Qf0'],meta['Qg'],meta['Qbv'],meta['cbs'],meta['lsfmean']
    df0=[];dv=[];dg=[];dbv=[];denv=[]
    for (v,f0i,gi,bvi,vidx) in meta['stream']:
        dv.append(v); df0.append(2**Qf0.dec(f0i) if v else 0.0); dg.append(10**Qg.dec(gi))
        dbv.append([Qbv.dec(bvi[b]) for b in range(qvoc.NB)])
        lsfv=np.sort(msvq_dec(vidx,cbs)+lm); denv.append(_env_from_lsf(lsfv,NF,order))
    xi=np.array(idxs); full=np.arange(nf); itp=lambda arr: np.interp(full,xi,arr)
    a=dict(sr=meta['sr'],H=H,NF=NF,f0=itp(np.array(df0)),
           voiced=itp(np.array(dv,float))>0.5,
           bvoi=np.stack([itp(np.array([b[k] for b in dbv])) for k in range(qvoc.NB)],1),
           env=np.stack([itp(np.array([e[j] for e in denv])) for j in range(NF//2+1)],1),N=N)
    return qvoc.apply_gain(qvoc.synth(a), itp(np.array(dg)), H)

# ---- PREDICTIVE LSF-VQ (DPCM): code lsf[t]-prev, closed-loop. LSFs barely change
#      frame-to-frame, so the residual is small -> far fewer envelope bits. ----
def encode_lsf_pred(x, sr, cbs, resmean, fps=50, order=LPC_ORDER, f0_bits=7, gain_bits=6, bv_bits=2):
    a=qvoc.analyze(x,sr); H=a['H']; NF=a['NF']; g=qvoc.frame_rms(x,H)
    nf=min(len(a['f0']),len(g)); D=max(1,int(round((sr/H)/fps))); idxs=list(range(0,nf,D))
    Qf0=Q(np.log2(70),np.log2(400),f0_bits); Qg=Q(-9,0,gain_bits); Qbv=Q(0,1,bv_bits)
    vqbits=sum(int(round(np.log2(len(cb)))) for cb in cbs); stream=[]; bits=0; prev=None
    for i in idxs:
        lsf=_lsf_vec(a['env'][i],NF,order)
        pred = prev if prev is not None else lsf*0.0
        vidx=msvq_enc(lsf-pred-resmean, cbs)             # VQ the (mean-removed) residual
        prev = pred + resmean + msvq_dec(vidx,cbs)       # closed-loop reconstructed lsf
        vv,f0i,gi,bvi,sb=_sidebits(a,i,g,Qf0,Qg,Qbv,f0_bits,gain_bits,bv_bits)
        bits += sb+vqbits; stream.append((vv,f0i,gi,bvi,vidx))
    meta=dict(sr=sr,H=H,NF=NF,N=len(x),nf=nf,idxs=idxs,order=order,cbs=cbs,resmean=resmean,
              Qf0=Qf0,Qg=Qg,Qbv=Qbv,stream=stream)
    return meta, bits, bits/(len(x)/sr)

def decode_lsf_pred(meta):
    H,NF,N,nf=meta['H'],meta['NF'],meta['N'],meta['nf']; idxs=meta['idxs']; order=meta['order']
    Qf0,Qg,Qbv,cbs,rm=meta['Qf0'],meta['Qg'],meta['Qbv'],meta['cbs'],meta['resmean']
    df0=[];dv=[];dg=[];dbv=[];denv=[]; prev=None
    for (v,f0i,gi,bvi,vidx) in meta['stream']:
        pred = prev if prev is not None else 0.0
        lsf = pred + rm + msvq_dec(vidx,cbs); prev=lsf
        dv.append(v); df0.append(2**Qf0.dec(f0i) if v else 0.0); dg.append(10**Qg.dec(gi))
        dbv.append([Qbv.dec(bvi[b]) for b in range(qvoc.NB)])
        denv.append(_env_from_lsf(np.sort(lsf),NF,order))
    xi=np.array(idxs); full=np.arange(nf); itp=lambda arr: np.interp(full,xi,arr)
    a=dict(sr=meta['sr'],H=H,NF=NF,f0=itp(np.array(df0)),
           voiced=itp(np.array(dv,float))>0.5,
           bvoi=np.stack([itp(np.array([b[k] for b in dbv])) for k in range(qvoc.NB)],1),
           env=np.stack([itp(np.array([e[j] for e in denv])) for j in range(NF//2+1)],1),N=N)
    return qvoc.apply_gain(qvoc.synth(a), itp(np.array(dg)), H)

def collect_lsf_residuals(clips, order, fps):
    """sequential decimated frame-to-frame LSF residuals, for training the DPCM codebook."""
    res=[]
    for c in clips:
        x,sr=qvoc.read_wav(c); a=qvoc.analyze(x,sr); NF=a['NF']
        D=max(1,int(round((sr/a['H'])/fps))); prev=None
        for i in range(0,len(a['env']),D):
            lsf=_lsf_vec(a['env'][i],NF,order)
            if prev is not None: res.append(lsf-prev)
            prev=lsf
    return np.array(res)

if __name__=='__main__':
    x,sr=qvoc.read_wav(sys.argv[1])
    meta,bits,bps=encode(x,sr, fps=int(sys.argv[3]) if len(sys.argv)>3 else 50)
    y=decode(meta)
    qvoc.write_wav(sys.argv[2], y, sr)
    print(f"qcodec: {sys.argv[1]} -> {sys.argv[2]}  {bits} bits  {bps:.0f} bps")
