#!/usr/bin/env bash
# demod-quanta unit-vocoder gate: full C pipeline (enroll -> encode -> render --det ->
# freeze -> Faust) + null test of the frozen .dsp against the C deterministic reference.
# Needs: faust (with -double), gcc, python3+numpy. Run from repo root (make all first).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
BIN=bin; B=test/speech/bench
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
NULL_GATE_DB=-120

echo "[unit] enroll inventory (k-means K=192) from bench corpus"
$BIN/quanta-unit-enroll -o "$WORK/inv.qinv" $B/f1_austen_8k.wav $B/f2_bronte_8k.wav \
    $B/m1_suntzu_8k.wav $B/m2_holmes_8k.wav --K 192
echo "[unit] encode + freeze a held clip"
$BIN/quanta-unit-encode "$WORK/inv.qinv" $B/m1_suntzu_8k.wav -o "$WORK/m1.qspu"
$BIN/quanta-unit-render "$WORK/inv.qinv" "$WORK/m1.qspu" --raw "$WORK/cref.f64" --det
$BIN/quanta-unit-freeze "$WORK/inv.qinv" "$WORK/m1.qspu" -o "$WORK/frozen.dsp" --golden "$WORK/golden.f64"

# golden (freeze-prep) must equal the standalone --det render bit-for-bit
if ! cmp -s "$WORK/cref.f64" "$WORK/golden.f64"; then
    echo "[unit] FAIL: --det render != freeze golden (determinism broken)"; exit 1; fi

N=$(( $(stat -c%s "$WORK/golden.f64") / 8 ))
echo "[unit] faust -double -> C, render $N samples"
FINC="$(dirname "$(dirname "$(readlink -f "$(command -v faust)")")")/include"
faust -lang c -double -cn quanta -a arch/minimal_c.arch "$WORK/frozen.dsp" -o "$WORK/gen.c"
cat > "$WORK/uh.c" <<EOF
#define FAUSTFLOAT double
#include "$ROOT/include/qsc.h"
#include "$WORK/gen.c"
int main(int c,char**v){uint64_t N=strtoull(v[1],0,0);int sr=atoi(v[2]);
 quanta*d=newquanta();initquanta(d,sr);double*o=calloc(N,sizeof(double));
 for(uint64_t f=0;f<N;f+=512){int n=(int)((N-f)<512?(N-f):512);FAUSTFLOAT*os[1]={o+f};computequanta(d,n,NULL,os);}
 raw_write_f64(v[3],o,N);return 0;}
EOF
gcc -O2 -std=c11 -ffp-contract=off -fno-fast-math -fwrapv -I"$FINC" "$WORK/uh.c" -o "$WORK/uh" -lm
"$WORK/uh" "$N" 8000 "$WORK/faust.f64"

python3 - "$WORK/golden.f64" "$WORK/faust.f64" "$NULL_GATE_DB" <<'PY'
import sys,numpy as np
g=np.fromfile(sys.argv[1],dtype='<f8'); f=np.fromfile(sys.argv[2],dtype='<f8'); gate=float(sys.argv[3])
m=min(len(g),len(f)); d=g[:m]-f[:m]; ref=np.max(np.abs(g[:m]))
db=20*np.log10(np.max(np.abs(d))/ref+1e-300)
print(f"[unit] NULL frozen.dsp vs C --det: {db:.1f} dBFS (gate <= {gate:.0f})")
sys.exit(0 if db<=gate else 1)
PY
echo "[unit] PASS"
