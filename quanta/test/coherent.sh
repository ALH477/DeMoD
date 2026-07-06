#!/usr/bin/env bash
# demod-quanta coherent-residual gate (Track B, bit-transparent tier). Proves the
# noise-substitution ceiling is broken: --coherent stores the true post-atom residual so
# the decoder — AND the frozen static .dsp — null the ORIGINAL recording, not just the
# reference player. Needs: faust, gcc, python3+numpy (+ffmpeg/curl on first run to fetch
# the CC0 clip). Run from repo root after `make all`.
#   G1  coherent render nulls SOURCE       <= -100 dBFS  (16-bit residual → ~-114)
#   G2  frozen .dsp nulls the C render      <= -120 dBFS  (determinism holds for the tier)
#   G3  frozen .dsp nulls the SOURCE        <= -100 dBFS  (a bit-transparent decoder-as-.dsp)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
BIN=bin; SRC="${1:-test/music/aria_hires.wav}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

if [ ! -f "$SRC" ]; then
  echo "[coh] fetching 96k/24 CC0 clip (Open Goldberg Aria) -> $SRC"; mkdir -p "$(dirname "$SRC")"
  URL="https://archive.org/download/OpenGoldbergVariations/Kimiko%20Ishizaka%20-%20J.S.%20Bach-%20-Open-%20Goldberg%20Variations%2C%20BWV%20988%20%28Piano%29%20-%2001%20Aria.flac"
  curl -fsSL --retry 3 "$URL" -o "$WORK/aria.flac"
  nix run nixpkgs#ffmpeg -- -hide_banner -nostdin -y -ss 15 -t 10 -i "$WORK/aria.flac" -ar 96000 -ac 2 -c:a pcm_s24le "$SRC" 2>/dev/null
fi
SR=$(python3 -c "import wave;print(wave.open('$SRC').getframerate())")
# mono reference (unambiguous null-vs-source)
nix run nixpkgs#ffmpeg -- -hide_banner -nostdin -y -i "$SRC" -ac 1 -c:a pcm_s24le "$WORK/mono.wav" 2>/dev/null
python3 - "$WORK/mono.wav" "$WORK/src.f64" <<'PY'
import sys,wave,numpy as np
w=wave.open(sys.argv[1]);n=w.getnframes();b=np.frombuffer(w.readframes(n),np.uint8).reshape(-1,3).astype(np.int32)
a=(b[:,0]|b[:,1]<<8|b[:,2]<<16);a=np.where(a&0x800000,a-(1<<24),a)/8388608.0
a.astype('<f8').tofile(sys.argv[2])
PY

echo "[coh] encode --coherent (16-bit residual) @ transparent preset"
$BIN/quanta-analyzer "$WORK/mono.wav" -o "$WORK/c.qsc" --quality 10 --coherent >/dev/null 2>&1
$BIN/quanta-render   "$WORK/c.qsc" --raw "$WORK/dec.f64" >/dev/null 2>&1

echo "[coh] freeze -> Faust -> C"
$BIN/quanta-freeze "$WORK/c.qsc" -o "$WORK/c.dsp" --verify >/dev/null 2>&1
N=$(( $(stat -c%s "$WORK/dec.f64") / 8 ))
FINC="$(dirname "$(dirname "$(readlink -f "$(command -v faust)")")")/include"
[ -f "$FINC/faust/gui/CInterface.h" ] || FINC=/usr/share/faust
faust -lang c -double -cn quanta -a arch/minimal_c.arch "$WORK/c.dsp" -o "$WORK/gen.c" >/dev/null 2>&1
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
"$WORK/uh" "$N" "$SR" "$WORK/faust.f64"

g(){ python3 tools/metrics.py null "$1" "$2" -999 | sed -n 's/.*peak \([-+0-9.]*\) dBFS.*/\1/p'; }
D1=$(g "$WORK/src.f64" "$WORK/dec.f64")     # coherent render vs source
D2=$(g "$WORK/dec.f64" "$WORK/faust.f64")   # frozen vs render
D3=$(g "$WORK/src.f64" "$WORK/faust.f64")   # frozen vs source
python3 - "$D1" "$D2" "$D3" <<'PY'
import sys
d1,d2,d3=(float(x) for x in sys.argv[1:4])
print(f"  G1 coherent render vs SOURCE : {d1:+.1f} dBFS  (<= -100) -> {'PASS' if d1<=-100 else 'FAIL'}")
print(f"  G2 frozen .dsp vs C render   : {d2:+.1f} dBFS  (<= -120) -> {'PASS' if d2<=-120 else 'FAIL'}")
print(f"  G3 frozen .dsp vs SOURCE     : {d3:+.1f} dBFS  (<= -100) -> {'PASS' if d3<=-100 else 'FAIL'}")
sys.exit(0 if (d1<=-100 and d2<=-120 and d3<=-100) else 1)
PY
echo "[coh] PASS — noise-substitution ceiling broken; decoder-as-.dsp is bit-transparent"
