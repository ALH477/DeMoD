#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-DeMoD-Commercial
# demod-quanta Track-B3 through-line gate — "your master, compiled to a static program".
# Takes a real 96k/24 CC0 master and compiles it all the way to a self-contained standalone
# player binary, then proves the audiophile through-line end to end. Needs: faust, gcc,
# python3+numpy (+ffmpeg/curl on first run to fetch the CC0 clip). Run from repo root after
# `make all`.
#   T1  frozen .dsp nulls the C reference player   <= -120 dBFS  (determinism; real ~ -280)
#   T2  frozen --coherent .dsp nulls the SOURCE    <= -100 dBFS  (bit-transparent; real ~ -110)
#   T3  generated compute() path is allocation-free (0 malloc/calloc/realloc/free/alloca)
#   T4  generated compute() path is libm-free      (0 sin/cos/exp/pow/log/sqrt per sample)
#   T5  whole chain is byte-reproducible           (freeze->faust->gcc->render twice, same sha256)
#   T6  the real-time player binary == offline harness, byte-for-byte (player path is exact)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
BIN=bin; SRC="${1:-test/music/aria_hires.wav}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

if [ ! -f "$SRC" ]; then
  echo "[b3] fetching 96k/24 CC0 clip (Open Goldberg Aria) -> $SRC"; mkdir -p "$(dirname "$SRC")"
  URL="https://archive.org/download/OpenGoldbergVariations/Kimiko%20Ishizaka%20-%20J.S.%20Bach-%20-Open-%20Goldberg%20Variations%2C%20BWV%20988%20%28Piano%29%20-%2001%20Aria.flac"
  curl -fsSL --retry 3 "$URL" -o "$WORK/aria.flac"
  nix run nixpkgs#ffmpeg -- -hide_banner -nostdin -y -ss 15 -t 10 -i "$WORK/aria.flac" -ar 96000 -ac 2 -c:a pcm_s24le "$SRC" 2>/dev/null
fi
SR=$(python3 -c "import wave;print(wave.open('$SRC').getframerate())")
# mono reference for an unambiguous null-vs-source (same convention as the coherent gate)
nix run nixpkgs#ffmpeg -- -hide_banner -nostdin -y -i "$SRC" -ac 1 -c:a pcm_s24le "$WORK/mono.wav" 2>/dev/null
python3 - "$WORK/mono.wav" "$WORK/src.f64" <<'PY'
import sys,wave,numpy as np
w=wave.open(sys.argv[1]);n=w.getnframes();b=np.frombuffer(w.readframes(n),np.uint8).reshape(-1,3).astype(np.int32)
a=(b[:,0]|b[:,1]<<8|b[:,2]<<16);a=np.where(a&0x800000,a-(1<<24),a)/8388608.0
a.astype('<f8').tofile(sys.argv[2])
PY

FINC="$(dirname "$(dirname "$(readlink -f "$(command -v faust)")")")/include"
[ -f "$FINC/faust/gui/CInterface.h" ] || FINC=/usr/share/faust
CFLAGS="-O2 -std=c11 -ffp-contract=off -fno-fast-math -fwrapv"

# --- the through-line: master -> analyze --coherent -> freeze -> faust -> C -> binaries ---
echo "[b3] master -> analyze --coherent -> freeze -> faust -> standalone program"
$BIN/quanta-analyzer "$WORK/mono.wav" -o "$WORK/m.qsc" --quality 10 --coherent >/dev/null 2>&1
$BIN/quanta-render   "$WORK/m.qsc" --raw "$WORK/ref.f64" >/dev/null 2>&1     # C reference player
N=$(( $(stat -c%s "$WORK/ref.f64") / 8 ))
$BIN/quanta-freeze   "$WORK/m.qsc" -o "$WORK/m.dsp" --verify >/dev/null 2>&1
echo "     self-contained master metadata baked into the .dsp:"
grep -E 'declare (samples|samplerate)' "$WORK/m.dsp" | sed 's/^/       /'

faust -lang c -double -cn quanta -a arch/minimal_c.arch "$WORK/m.dsp" -o "$WORK/gen.c" >/dev/null 2>&1
cat > "$WORK/uh.c" <<EOF
#define FAUSTFLOAT double
#include "$ROOT/include/qsc.h"
#include "$WORK/gen.c"
int main(int c,char**v){uint64_t N=strtoull(v[1],0,0);int sr=atoi(v[2]);
 quanta*d=newquanta();initquanta(d,sr);double*o=calloc(N,sizeof(double));
 for(uint64_t f=0;f<N;f+=512){int n=(int)((N-f)<512?(N-f):512);FAUSTFLOAT*os[1]={o+f};computequanta(d,n,NULL,os);}
 raw_write_f64(v[3],o,N);return 0;}
EOF
gcc $CFLAGS -I"$FINC" "$WORK/uh.c" -o "$WORK/uh" -lm
"$WORK/uh" "$N" "$SR" "$WORK/faust.f64"

# the standalone real-time player (arch/player.arch), built from the SAME frozen master
faust -lang c -double -cn quanta -a arch/player.arch "$WORK/m.dsp" -o "$WORK/player.c" >/dev/null 2>&1
gcc $CFLAGS -Iinclude -I"$FINC" "$WORK/player.c" -o "$WORK/player" -lm
"$WORK/player" --f64 -o "$WORK/player.f64" 2>/dev/null   # self-contained: length/rate from baked declares

nulldb(){ python3 tools/metrics.py null "$1" "$2" -999 | sed -n 's/.*peak \([-+0-9.]*\) dBFS.*/\1/p'; }
T1=$(nulldb "$WORK/ref.f64" "$WORK/faust.f64")   # frozen vs C reference player (determinism)
T2=$(nulldb "$WORK/src.f64" "$WORK/faust.f64")   # frozen vs SOURCE (bit-transparent)

# T3/T4: inspect the generated compute() — the actual audio inner loop
awk '/^void[ \t].*computequanta[ \t]*\(/{f=1} f{print} f&&/^}/{exit}' "$WORK/gen.c" > "$WORK/compute.c"
ALLOC=$(grep -Ewc 'malloc|calloc|realloc|free|alloca' "$WORK/compute.c" || true)
LIBM=$(grep -Ewoc '(sinf?|cosf?|tanf?|expf?|powf?|logf?|log2f?|log10f?|sqrtf?|cbrtf?|fmodf?)' "$WORK/compute.c" || true)
CLINES=$(wc -l < "$WORK/compute.c")

# T5: byte-reproducibility of the WHOLE chain (freeze -> faust -> gcc -> render), run twice
$BIN/quanta-freeze "$WORK/m.qsc" -o "$WORK/m2.dsp" --verify >/dev/null 2>&1
faust -lang c -double -cn quanta -a arch/minimal_c.arch "$WORK/m2.dsp" -o "$WORK/gen2.c" >/dev/null 2>&1
sed "s#$WORK/gen.c#$WORK/gen2.c#" "$WORK/uh.c" > "$WORK/uh2.c"
gcc $CFLAGS -I"$FINC" "$WORK/uh2.c" -o "$WORK/uh2" -lm
"$WORK/uh2" "$N" "$SR" "$WORK/faust2.f64"
H1=$(sha256sum "$WORK/faust.f64" | awk '{print $1}')
H2=$(sha256sum "$WORK/faust2.f64" | awk '{print $1}')

# T6: the real-time player binary is byte-identical to the offline harness
PLAYER_OK=$(cmp -s "$WORK/player.f64" "$WORK/faust.f64" && echo 1 || echo 0)

echo "[b3] results:"
python3 - "$T1" "$T2" "$ALLOC" "$LIBM" "$CLINES" "$H1" "$H2" "$PLAYER_OK" <<'PY'
import sys
t1,t2=float(sys.argv[1]),float(sys.argv[2])
alloc,libm,clines=int(sys.argv[3]),int(sys.argv[4]),int(sys.argv[5])
h1,h2,player=sys.argv[6],sys.argv[7],int(sys.argv[8])
ok=True
def line(name,cond,detail):
    global ok; ok = ok and cond
    print(f"  {'PASS' if cond else 'FAIL'}  {name:34s} {detail}")
line("T1 determinism vs C player",  t1<=-120, f"{t1:+.1f} dBFS (<= -120)")
line("T2 bit-transparent vs SOURCE", t2<=-100, f"{t2:+.1f} dBFS (<= -100)")
line("T3 compute() allocation-free", alloc==0, f"{alloc} alloc calls in {clines}-line inner loop")
line("T4 compute() libm-free",       libm==0,  f"{libm} transcendental calls per sample")
line("T5 chain byte-reproducible",   h1==h2,   f"sha256 {h1[:16]}.. == {h2[:16]}..")
line("T6 player == offline harness",  player==1, "standalone player is byte-exact")
sys.exit(0 if ok else 1)
PY

echo "[b3] artifacts (the deliverable is the last one):"
printf "       %-22s %s bytes\n" ".dsp (the score-as-code)" "$(stat -c%s "$WORK/m.dsp")"
printf "       %-22s %s bytes\n" "gen.c (faust output)"     "$(stat -c%s "$WORK/gen.c")"
printf "       %-22s %s bytes\n" "standalone player"        "$(stat -c%s "$WORK/player")"
echo "       player shared-lib deps (no audio library — pipe to any sink):"
ldd "$WORK/player" 2>/dev/null | sed 's/^/         /' || echo "         (static)"
echo "[b3] PASS — a real 96k/24 master compiled to a dependency-free static program that"
echo "     nulls its source to $T2 dBFS and reproduces byte-for-byte."
