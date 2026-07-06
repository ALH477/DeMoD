#!/usr/bin/env python3
# Parameter sweep for qvoc synthesis (pf_alpha, disp) — PESQ over the bench corpus,
# in ONE nix-env invocation (amortizes startup). Prints mean PESQ per param combo.
import sys, glob, os, numpy as np
sys.path.insert(0,'tools'); import qvoc
from pesq import pesq
clips=sorted(glob.glob('test/speech/bench/*_8k.wav'))
xs=[qvoc.read_wav(c) for c in clips]
anas=[qvoc.analyze(x,sr) for x,sr in xs]
combos=eval(sys.argv[1]) if len(sys.argv)>1 else [dict(pf_alpha=0.3,disp=d) for d in (0,0.4,0.8,1.5,2.5)]
print(f"{'params':32s} {'meanPESQ':>9s}")
for cb in combos:
    ps=[]
    for (x,sr),a in zip(xs,anas):
        y=qvoc.synth(a, **cb); y=qvoc.energy_match(x,y,a['H'])
        n=min(len(x),len(y))
        try: ps.append(pesq(sr, x[:n], y[:n], 'nb'))
        except Exception: pass
    print(f"{str(cb):32s} {np.mean(ps):9.3f}")
