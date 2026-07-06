#!/usr/bin/env bash
# demod-quanta end-to-end verification loop (spec §7.4)
set -e
cd "$(dirname "$0")/.."
K=${K:-400}
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
    -I/usr/share/faust test/harness.c -o test/harness -lm
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
    -I/usr/share/faust test/harness.c -o test/br_harness -lm
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
echo ""
echo "ALL GATES PASS  (M0 spec-target status documented in README §Verification)"
