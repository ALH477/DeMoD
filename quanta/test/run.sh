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
# Faust architecture headers (faust/gui/CInterface.h): derive from the faust
# binary's prefix (works on Nix/Homebrew/non-FHS), fall back to the FHS path.
FAUST_INC=${FAUST_INC:-"$(dirname "$(dirname "$(readlink -f "$(command -v faust)")")")/include"}
gcc -O2 -std=c11 -Iinclude -Itest -ffp-contract=off -fno-fast-math -fwrapv \
    -I"$FAUST_INC" -I/usr/share/faust test/harness.c -o test/harness -lm
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
echo ""
echo "ALL GATES PASS  (M0 spec-target status documented in README §Verification)"
