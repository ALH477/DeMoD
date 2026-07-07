#!/usr/bin/env bash
# demod-quanta end-to-end verification loop (spec §7.4)
set -e
cd "$(dirname "$0")/.."
K=${K:-400}
# Faust runtime headers (CInterface.h): Nix puts them at $faust/include, system
# installs at /usr/share/faust. Resolve portably instead of hardcoding one.
FINC="$(dirname "$(dirname "$(readlink -f "$(command -v faust)")")")/include"
[ -f "$FINC/faust/gui/CInterface.h" ] || FINC=/usr/share/faust
echo "== [1/7] test sources =="
python3 tools/gen_test.py
python3 tools/gen_tonal.py
echo "== [2/7] analyze hybrid corpus (K=$K) =="
bin/quanta-analyzer test/src.wav -o test/score.qsc --k $K --snr 40
echo "== [3/7] reference render =="
bin/quanta-render test/score.qsc --raw test/ref.f64 --wav test/ref.wav
echo "== [4/7] freeze -> Faust -> C -> render =="
bin/quanta-freeze test/score.qsc -o test/out.dsp --verify
faust -lang c -double -cn quanta -a arch/minimal_c.arch test/out.dsp -o test/gen.c
gcc -O2 -std=c11 -Iinclude -Itest -ffp-contract=off -fno-fast-math -fwrapv \
    -I"$FINC" test/harness.c -o test/harness -lm
N=$(python3 -c "import numpy;print(len(numpy.fromfile('test/src.f64',dtype='<f8')))")
./test/harness $N 48000 test/fst.f64 test/fst.wav
echo "== [5/7] NULL GATE: frozen Faust vs reference player (<= -120 dBFS) =="
python3 tools/metrics.py null test/ref.f64 test/fst.f64
echo "== [6/7] hybrid corpus fidelity (report) =="
python3 tools/metrics.py lsd test/src.f64 test/ref.f64
echo "== [7/7] M0 TONAL GATE (spec target 1.0 dB; v0.1 regression gate 1.6) =="
bin/quanta-analyzer test/tonal.wav -o test/tonal.qsc --k 2048 --snr 45
bin/quanta-render test/tonal.qsc --g2 0 --raw test/tonal_m0.f64
python3 tools/metrics.py lsd test/tonal.f64 test/tonal_m0.f64 1.6

echo "== [8/9] STREAMING PROFILE: encode -> QSS + QSC bridge =="
bin/quanta-stream test/tonal.wav -o test/tonal.qss --qsc test/tonal_br.qsc --mode near --rate 1200
echo "== [9/9] STREAMING GATES: stream-decode==render (bit-exact) & bridge freezes =="
bin/quanta-render test/tonal_br.qsc --raw test/sd_ref.f64
bin/quanta-stream-decode test/tonal.qss --raw test/sd_out.f64
echo "-- gate A: streaming decoder vs reference renderer (<= -300 dBFS) --"
python3 tools/metrics.py null test/sd_ref.f64 test/sd_out.f64 300
echo "-- gate B: QSS bridge -> frozen Faust nulls (<= -120 dBFS) --"
bin/quanta-freeze test/tonal_br.qsc -o test/br.dsp --verify >/dev/null
faust -lang c -double -cn quanta -a arch/minimal_c.arch test/br.dsp -o test/gen.c
gcc -O2 -std=c11 -Iinclude -Itest -ffp-contract=off -fno-fast-math -fwrapv \
    -I"$FINC" test/harness.c -o test/br_harness -lm
NB=$(python3 -c "import numpy;print(len(numpy.fromfile('test/sd_ref.f64',dtype='<f8')))")
./test/br_harness $NB 48000 test/br_fst.f64 /dev/null
python3 tools/metrics.py null test/sd_ref.f64 test/br_fst.f64
echo "-- gate C: corrupt-packet resilience (CRC re-anchor) --"
python3 - <<'PYEOF'
d=bytearray(open('test/tonal.qss','rb').read()); d[len(d)//2]^=0xFF
open('test/tonal_bad.qss','wb').write(d)
PYEOF
bin/quanta-stream-decode test/tonal_bad.qss --raw /dev/null 2>&1 | grep -q "bad-packets 1" \
  && echo "gate C: dropped corrupt packet, re-anchored -> PASS" || (echo "gate C FAIL"; exit 1)
echo "-- gate D: qbits / qss2 codec round-trip --"
cat > test/codec_selftest.c <<'CEOF'
#include "qbits.h"
#include <stdio.h>
int main(void){ int ok=qbits_selftest(); printf("qbits roundtrip (Rice+escape): %s\n", ok?"PASS":"FAIL"); return ok?0:1; }
CEOF
gcc -O2 -std=c11 -Iinclude test/codec_selftest.c -o test/codec_selftest -lm && ./test/codec_selftest
echo "-- gate E: coded bitrate <= 120 kbps & atoms near offline --"
KB=$(bin/quanta-stream test/tonal.wav -o test/e.qss --qsc test/e.qsc --mode near --rate 1200 2>&1 | grep -oE "[0-9.]+ kbps" | grep -oE "[0-9.]+")
bin/quanta-analyzer test/tonal.wav -o test/eoff.qsc --k 2048 --snr 45 >/dev/null 2>&1
bin/quanta-render test/eoff.qsc --g2 0 --raw test/eoff.f64 >/dev/null 2>&1
bin/quanta-render test/e.qsc --g2 0 --raw test/estream.f64 >/dev/null 2>&1
python3 - "$KB" <<'PYEOF'
import sys, numpy as np
import numpy.fft as ft
kb=float(sys.argv[1])
def lsd(pa,pb):
    a=np.fromfile(pa); b=np.fromfile(pb); n=min(len(a),len(b)); H=1024; acc=[]
    for i in range(0,n-H,H):
        A=np.abs(ft.rfft(a[i:i+H]))+1e-9; B=np.abs(ft.rfft(b[i:i+H]))+1e-9
        d=20*np.log10(A/B); acc.append(np.sqrt(np.mean(d*d)))
    return float(np.median(acc))
off=lsd('test/eoff.f64','test/tonal.f64'); st=lsd('test/estream.f64','test/tonal.f64')
print(f"coded bitrate {kb:.1f} kbps (near) ; atoms-only LSD offline {off:.2f} dB vs streaming {st:.2f} dB")
ok = kb<=120.0 and st<=off+2.0
print("gate E:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
PYEOF
echo "== [F] TONAL-RESIDUAL GATE: residual-on tracks atoms-only on tonal; beats residual-off on broadband =="
bin/quanta-render test/tonal.qsc        --raw test/f_ton_on.f64  >/dev/null 2>&1
bin/quanta-render test/tonal.qsc --g2 0 --raw test/f_ton_off.f64 >/dev/null 2>&1
bin/quanta-render test/score.qsc        --raw test/f_brd_on.f64  >/dev/null 2>&1
bin/quanta-render test/score.qsc --g2 0 --raw test/f_brd_off.f64 >/dev/null 2>&1
# use the project's canonical active-LSD (metrics.py: 2048/Hann, -80 dB floor, DC-blocker compensated)
_al(){ python3 tools/metrics.py lsd "$1" "$2" 2>/dev/null | grep -oE "[0-9.]+ dB \(active\)" | grep -oE "^[0-9.]+"; }
FT_ON=$(_al test/tonal.f64 test/f_ton_on.f64);  FT_OFF=$(_al test/tonal.f64 test/f_ton_off.f64)
FB_ON=$(_al test/src.f64   test/f_brd_on.f64);  FB_OFF=$(_al test/src.f64   test/f_brd_off.f64)
python3 - "$FT_ON" "$FT_OFF" "$FB_ON" "$FB_OFF" <<'PYEOF'
import sys
ton_on, ton_off, brd_on, brd_off = (float(x) for x in sys.argv[1:5])
print(f"  tonal: residual-on {ton_on:.2f} dB vs atoms-only {ton_off:.2f} dB (delta {ton_on-ton_off:+.2f}, need <= 1.0)")
print(f"  broadband: residual-on {brd_on:.2f} dB vs residual-off {brd_off:.2f} dB (need on < off)")
ok = (ton_on-ton_off) <= 1.0 and brd_on < brd_off
print("gate F:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
PYEOF
echo "== [P] PERCEPTUAL GATE (NMR): residual stays perceptually transparent on tonal content =="
# relative regression gate (NMR is an uncalibrated proxy; an absolute MOS/transparency
# threshold needs a listening study — see docs/FIDELITY.md). Reuses Gate F's renders.
PON=$( python3 tools/perceptual.py nmr test/tonal.f64 test/f_ton_on.f64  48000 | sed -n 's/.*median \([-+0-9.]*\).*/\1/p')
POFF=$(python3 tools/perceptual.py nmr test/tonal.f64 test/f_ton_off.f64 48000 | sed -n 's/.*median \([-+0-9.]*\).*/\1/p')
python3 - "$PON" "$POFF" <<'PYEOF'
import sys
on, off = float(sys.argv[1]), float(sys.argv[2])
print(f"  tonal NMR: residual-on {on:+.2f} dB vs atoms-only {off:+.2f} dB (need on <= off+0.5 and on < 0 = masked)")
ok = on <= off + 0.5 and on < 0.0
print("gate P:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
PYEOF
echo "== [Z] COMPRESSION GATE: quanta-pack .qsz round-trips deterministically, shrinks, stays near-transparent =="
bin/quanta-pack compress   test/score.qsc test/score.qsz  2>test/z.log
bin/quanta-pack decompress test/score.qsz test/score_rt.qsc  >/dev/null 2>&1
bin/quanta-pack decompress test/score.qsz test/score_rt2.qsc >/dev/null 2>&1
cmp -s test/score_rt.qsc test/score_rt2.qsc || { echo "gate Z FAIL: decompress not deterministic"; exit 1; }
bin/quanta-render test/score.qsc    --raw test/z_orig.f64 >/dev/null 2>&1
bin/quanta-render test/score_rt.qsc --raw test/z_pack.f64 >/dev/null 2>&1
ZRATIO=$(sed -n 's/.* \([0-9.]*\)x .*/\1/p' test/z.log)
ZO=$(python3 tools/perceptual.py nmr test/src.f64 test/z_orig.f64 48000 | sed -n 's/.*median \([-+0-9.]*\).*/\1/p')
ZP=$(python3 tools/perceptual.py nmr test/src.f64 test/z_pack.f64 48000 | sed -n 's/.*median \([-+0-9.]*\).*/\1/p')
python3 - "$ZRATIO" "$ZO" "$ZP" <<'PYEOF'
import sys
ratio, o, p = float(sys.argv[1]), float(sys.argv[2]), float(sys.argv[3])
print(f"  ratio {ratio:.2f}x ; render NMR orig {o:+.2f} dB vs packed {p:+.2f} dB (need ratio > 1.5 and |delta| <= 0.5)")
ok = ratio > 1.5 and abs(p-o) <= 0.5
print("gate Z:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
PYEOF
echo "== [S] STEREO GATE: mid/side encode->decode->frozen-Faust nulls (<= -120 dBFS); image preserved =="
python3 - <<'PYEOF'
import numpy as np, struct
sr=48000; n=48000; t=np.arange(n)/sr
L=0.3*np.sin(2*np.pi*440*t)+0.10*np.sin(2*np.pi*880*t)
R=0.3*np.sin(2*np.pi*443*t)+0.10*np.sin(2*np.pi*660*t)   # L != R -> genuine side channel
il=np.empty(2*n); il[0::2]=L; il[1::2]=R
d=(np.clip(il,-1,1)*32767).astype('<i2').tobytes()
hdr=b'RIFF'+struct.pack('<I',36+len(d))+b'WAVEfmt '+struct.pack('<IHHIIHH',16,1,2,sr,sr*4,4,16)+b'data'+struct.pack('<I',len(d))
open('test/stereo.wav','wb').write(hdr+d)
PYEOF
bin/quanta-analyzer test/stereo.wav -o test/stereo.qsc --k 2048 --snr 45 --stereo >/dev/null 2>&1
bin/quanta-render test/stereo.qsc --raw test/stereo_ref.f64 >/dev/null 2>&1
bin/quanta-freeze test/stereo.qsc -o test/stereo.dsp --verify >/dev/null 2>&1
faust -lang c -double -cn quanta -a arch/minimal_c.arch test/stereo.dsp -o test/gen.c >/dev/null 2>&1
gcc -O2 -std=c11 -Iinclude -Itest -ffp-contract=off -fno-fast-math -fwrapv \
    -I"$FINC" test/harness.c -o test/stereo_harness -lm
./test/stereo_harness 48000 48000 test/stereo_fst.f64 /dev/null >/dev/null 2>&1
echo "-- stereo null: frozen Faust vs stereo render (interleaved L,R) --"
python3 tools/metrics.py null test/stereo_ref.f64 test/stereo_fst.f64
python3 - <<'PYEOF'
import numpy as np, sys
ref=np.fromfile('test/stereo_ref.f64'); L=ref[0::2]; R=ref[1::2]
srms=np.sqrt(np.mean((0.5*(L-R))**2))
print(f"  decoded side RMS {srms:.4f}  (>0 => stereo image present, not mono-collapsed)")
sys.exit(0 if srms>1e-3 else 1)
PYEOF
echo "gate S: PASS"
echo "== [I] INSTRUMENT GATE: score transforms preserve determinism; pitch transposes atoms =="
bin/quanta-score pitch   test/score.qsc test/score_up.qsc   12  >/dev/null 2>&1
bin/quanta-score density test/score.qsc test/score_thin.qsc 0.5 >/dev/null 2>&1
bin/quanta-render test/score_up.qsc --raw test/i_ref.f64 >/dev/null 2>&1
bin/quanta-freeze test/score_up.qsc -o test/i.dsp --verify >/dev/null 2>&1
faust -lang c -double -cn quanta -a arch/minimal_c.arch test/i.dsp -o test/gen.c >/dev/null 2>&1
gcc -O2 -std=c11 -Iinclude -Itest -ffp-contract=off -fno-fast-math -fwrapv \
    -I"$FINC" test/harness.c -o test/i_h -lm
NB=$(python3 -c "import struct;print(struct.unpack('>Q',open('test/score_up.qsc','rb').read()[12:20])[0])")
./test/i_h "$NB" 48000 test/i_fst.f64 /dev/null >/dev/null 2>&1
echo "-- determinism: frozen transformed-score vs its render (<= -120 dBFS) --"
python3 tools/metrics.py null test/i_ref.f64 test/i_fst.f64
bin/quanta-score  pitch test/score.qsc test/score_dn.qsc -12 >/dev/null 2>&1
bin/quanta-render test/score.qsc    --g2 0 --raw test/i_a0.f64 >/dev/null 2>&1
bin/quanta-render test/score_dn.qsc --g2 0 --raw test/i_a1.f64 >/dev/null 2>&1   # down an octave (no aliasing)
python3 - <<'PYEOF'
import numpy as np, numpy.fft as ft, struct, sys
def cen(p):
    x=np.fromfile(p); X=np.abs(ft.rfft(x*np.hanning(len(x))))+1e-12; f=np.fft.rfftfreq(len(x),1/48000)
    return float(np.sum(f*X)/np.sum(X))
r=cen('test/i_a1.f64')/cen('test/i_a0.f64')
na=struct.unpack('>I',open('test/score.qsc','rb').read()[20:24])[0]
nt=struct.unpack('>I',open('test/score_thin.qsc','rb').read()[20:24])[0]
print(f"  pitch -12st atoms centroid ratio {r:.2f} (need < 0.7) ; density 50% {na}->{nt} atoms (need < {na})")
sys.exit(0 if r<0.7 and nt<na else 1)
PYEOF
echo "-- lossless Lua score round-trip (atoms bit-exact) --"
bin/quanta-score export test/score.qsc test/score.lua      >/dev/null 2>&1
bin/quanta-score import test/score.lua test/score_rt.qsc   >/dev/null 2>&1
bin/quanta-render test/score.qsc    --g2 0 --raw test/i_ao.f64 >/dev/null 2>&1
bin/quanta-render test/score_rt.qsc        --raw test/i_rt.f64 >/dev/null 2>&1
python3 tools/metrics.py null test/i_ao.f64 test/i_rt.f64 250

# --- B2 studio transforms: each edited score must still freeze-null vs its own render ---
freeze_null(){  # $1=score.qsc  $2=tag ; nulls frozen .dsp vs C render (<= -120 dBFS)
  bin/quanta-render "$1" --raw test/${2}_r.f64 >/dev/null 2>&1
  bin/quanta-freeze "$1" -o test/${2}.dsp --verify >/dev/null 2>&1
  faust -lang c -double -cn quanta -a arch/minimal_c.arch test/${2}.dsp -o test/gen.c >/dev/null 2>&1
  gcc -O2 -std=c11 -Iinclude -Itest -ffp-contract=off -fno-fast-math -fwrapv \
      -I"$FINC" test/harness.c -o test/${2}_h -lm
  local NB; NB=$(python3 -c "import struct;print(struct.unpack('>Q',open('$1','rb').read()[12:20])[0])")
  ./test/${2}_h "$NB" 48000 test/${2}_f.f64 /dev/null >/dev/null 2>&1
  python3 tools/metrics.py null test/${2}_r.f64 test/${2}_f.f64
}

echo "-- stretch: true time-stretch (onset+dur) holds pitch, freezes null --"
bin/quanta-score stretch test/score.qsc test/score_st.qsc 1.5 --keep-transients >/dev/null 2>&1
freeze_null test/score_st.qsc st
bin/quanta-render test/score_st.qsc --g2 0 --raw test/st_a.f64 >/dev/null 2>&1
python3 - <<'PYEOF'
import numpy as np, numpy.fft as ft, struct, sys
def cen(p):
    x=np.fromfile(p); X=np.abs(ft.rfft(x*np.hanning(len(x))))+1e-12; f=np.fft.rfftfreq(len(x),1/48000)
    return float(np.sum(f*X)/np.sum(X))
L =struct.unpack('>Q',open('test/score_st.qsc','rb').read()[12:20])[0]
L0=struct.unpack('>Q',open('test/score.qsc','rb').read()[12:20])[0]
r=cen('test/st_a.f64')/cen('test/i_a0.f64')
print(f"  stretch len {L0}->{L} (need ~1.5x) ; pitch centroid ratio {r:.2f} (need 0.8-1.2)")
sys.exit(0 if abs(L/L0-1.5)<0.02 and 0.8<r<1.2 else 1)
PYEOF

echo "-- pitch --formant: spectral envelope held vs naive transpose --"
# use -12 (down an octave, no aliasing — cf. the naive-pitch check above) so the
# comparison is clean; assert the formant version keeps the centroid CLOSER to the
# original (|log ratio| smaller) than a naive transpose.
bin/quanta-score pitch test/score.qsc test/score_fp.qsc -12 --formant >/dev/null 2>&1
freeze_null test/score_fp.qsc fp
bin/quanta-render test/score_dn.qsc --g2 0 --raw test/pn_a.f64 >/dev/null 2>&1  # score_dn = naive -12
bin/quanta-render test/score_fp.qsc --g2 0 --raw test/fp_a.f64 >/dev/null 2>&1
python3 - <<'PYEOF'
import numpy as np, numpy.fft as ft, sys
def cen(p):
    x=np.fromfile(p); X=np.abs(ft.rfft(x*np.hanning(len(x))))+1e-12; f=np.fft.rfftfreq(len(x),1/48000)
    return float(np.sum(f*X)/np.sum(X))
c0=cen('test/i_a0.f64'); naive=cen('test/pn_a.f64')/c0; form=cen('test/fp_a.f64')/c0
print(f"  -12st centroid ratio: naive {naive:.2f}, formant {form:.2f} "
      f"(|log| {abs(np.log(naive)):.2f} vs {abs(np.log(form)):.2f}; formant must be closer to 1.0)")
sys.exit(0 if abs(np.log(form)) < abs(np.log(naive)) else 1)
PYEOF
# per-frame variant (--formant-dyn) must also freeze null-clean
bin/quanta-score pitch test/score.qsc test/score_fpd.qsc -12 --formant-dyn >/dev/null 2>&1
freeze_null test/score_fpd.qsc fpd

echo "-- eq: spectral-region gain drops in-band energy, freezes null --"
bin/quanta-score eq test/score.qsc test/score_eq.qsc --lo 2000 --hi 6000 --gain -12 >/dev/null 2>&1
freeze_null test/score_eq.qsc eq
bin/quanta-render test/score_eq.qsc --g2 0 --raw test/eq_a.f64 >/dev/null 2>&1
python3 - <<'PYEOF'
import numpy as np, numpy.fft as ft, sys
def spec(p):
    x=np.fromfile(p); return np.fft.rfftfreq(len(x),1/48000), np.abs(ft.rfft(x*np.hanning(len(x))))+1e-12
f,X0=spec('test/i_a0.f64'); _,Xe=spec('test/eq_a.f64'); b=(f>=2000)&(f<=6000)
d=10*np.log10(np.sum(Xe[b]**2)/np.sum(X0[b]**2))
print(f"  eq 2-6k in-band energy {d:.1f} dB (need < -6)")
sys.exit(0 if d < -6 else 1)
PYEOF

echo "-- width: mid/side widen scales the side channel, freezes null --"
bin/quanta-score width test/stereo.qsc test/stereo_w.qsc 1.5 >/dev/null 2>&1
freeze_null test/stereo_w.qsc sw
python3 - <<'PYEOF'
import numpy as np, sys
def side(p):
    x=np.fromfile(p); return np.sqrt(np.mean((0.5*(x[0::2]-x[1::2]))**2))
s0=side('test/stereo_ref.f64'); s1=side('test/sw_r.f64')
print(f"  side RMS {s0:.4f} -> {s1:.4f} (width 1.5 => wider)")
sys.exit(0 if s1 > s0*1.05 else 1)
PYEOF

echo "-- edit strips the coherent (bit-transparent) layer --"
bin/quanta-analyzer test/src.wav -o test/score_c.qsc --k $K --snr 40 --coherent --cbits 12 >/dev/null 2>&1
bin/quanta-score gain test/score_c.qsc test/score_cg.qsc -1 >/dev/null 2>&1
python3 - <<'PYEOF'
import struct, sys
f0=struct.unpack('>H',open('test/score_c.qsc','rb').read()[6:8])[0]
f1=struct.unpack('>H',open('test/score_cg.qsc','rb').read()[6:8])[0]
print(f"  flags {f0:#06x} -> {f1:#06x} (CRES bit2 must clear on edit)")
sys.exit(0 if (f0 & 0x4) and not (f1 & 0x4) else 1)
PYEOF
echo "gate I: PASS"
echo "== [V] BITSTREAM v1 GATE: canonical QSS2 stream + decode reproduce the frozen reference vectors =="
bin/quanta-stream test/tonal.wav -o test/canon.qss --lat-scale 1280 --active 2560 --rate 1200 --hop 512 --seed 0xDEC0DE >/dev/null 2>&1
bin/quanta-stream-decode test/canon.qss --raw test/canon.f64 >/dev/null 2>&1
GQSS=f647c1ebab6f406c4e5a44003ee0cec0973918a98381a01731a3b69d756bfb86   # frozen v1 (this reference build)
GF64=688a2b989a2979d834a8ca92ee7e9d26bc6e3f0bfc2d081880b915b375208ab5
QS=$(sha256sum test/canon.qss | awk '{print $1}'); FS=$(sha256sum test/canon.f64 | awk '{print $1}')
echo "  .qss ${QS:0:16}.. (frozen ${GQSS:0:16}..) ; decode .f64 ${FS:0:16}.. (frozen ${GF64:0:16}..)"
if [ "$QS" = "$GQSS" ] && [ "$FS" = "$GF64" ]; then echo "gate V: PASS"
else echo "gate V: FAIL — bitstream changed; if intentional, re-freeze the golden vectors"; exit 1; fi

echo "== [Fz] FUZZ GATE: QSS packet reader survives malformed input (ASan + UBSan, no crash/OOB/UB) =="
gcc -O1 -g -std=c11 -Iinclude -fsanitize=address,undefined -fno-omit-frame-pointer test/fuzz.c -o test/fuzz -lm
ASAN_OPTIONS=abort_on_error=1 UBSAN_OPTIONS=halt_on_error=1 ./test/fuzz test/canon.qss 20000
echo "gate Fz: PASS"
echo ""
echo "ALL GATES PASS  (M0 spec-target status documented in README §Verification)"
