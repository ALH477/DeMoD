#!/usr/bin/env bash
# demod-quanta Track-B1 gate: HONEST hi-res source-transparency proof.
# Analyzes a 96 kHz / 24-bit CC0 clip at the transparent preset, measures how close
# the codec gets to the ORIGINAL recording (null-vs-source + NMR + LSD), and confirms
# the frozen .dsp still nulls the C player at hi-res. Needs: faust, gcc, python3+numpy,
# and (to fetch the clip on first run) `nix run nixpkgs#ffmpeg`. Run from repo root.
#
# The honest gates (see docs — the noise-substitution residual caps WAVEFORM transparency):
#   G1  NMR median < 0 dB          (perceptually masked / "transparent-leaning")
#   G2  frozen .dsp vs C player <= -120 dBFS at 96 kHz (hi-res determinism holds)
# SNR/LSD-vs-source are REPORTED, not gated: they plateau at the residual floor by design.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
BIN=bin; SRC="${1:-test/music/aria_hires.wav}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

if [ ! -f "$SRC" ]; then
  echo "[b1] fetching 96k/24 CC0 clip (Open Goldberg Aria, public domain) -> $SRC"
  mkdir -p "$(dirname "$SRC")"
  URL="https://archive.org/download/OpenGoldbergVariations/Kimiko%20Ishizaka%20-%20J.S.%20Bach-%20-Open-%20Goldberg%20Variations%2C%20BWV%20988%20%28Piano%29%20-%2001%20Aria.flac"
  curl -fsSL --retry 3 "$URL" -o "$WORK/aria.flac"
  nix run nixpkgs#ffmpeg -- -hide_banner -nostdin -y -ss 15 -t 10 -i "$WORK/aria.flac" \
      -ar 96000 -ac 2 -c:a pcm_s24le "$SRC" 2>/dev/null
fi
SR=$(python3 -c "import wave;print(wave.open('$SRC').getframerate())")
echo "[b1] source: $SRC (${SR} Hz)"

# mono reference for unambiguous source-fidelity numbers
nix run nixpkgs#ffmpeg -- -hide_banner -nostdin -y -i "$SRC" -ac 1 -c:a pcm_s24le "$WORK/mono.wav" 2>/dev/null
python3 - "$WORK/mono.wav" "$WORK/src.f64" <<'PY'
import sys,wave,numpy as np
w=wave.open(sys.argv[1]);n=w.getnframes();b=np.frombuffer(w.readframes(n),np.uint8).reshape(-1,3).astype(np.int32)
a=(b[:,0]|b[:,1]<<8|b[:,2]<<16);a=np.where(a&0x800000,a-(1<<24),a)/8388608.0
a.astype('<f8').tofile(sys.argv[2])
PY

echo "[b1] analyze @ transparent preset (--quality 10)"
$BIN/quanta-analyzer "$WORK/mono.wav" -o "$WORK/t.qsc" --quality 10 >/dev/null 2>&1
$BIN/quanta-render   "$WORK/t.qsc" --raw "$WORK/dec.f64" >/dev/null 2>&1

echo "[b1] ── source-transparency (honest) ──"
python3 tools/transparency.py "$WORK/src.f64" "$WORK/dec.f64" "$SR" "transparent preset"
NMED=$(python3 tools/perceptual.py nmr "$WORK/src.f64" "$WORK/dec.f64" "$SR" | sed -n 's/.*median \([-+0-9.]*\).*/\1/p')

echo "[b1] ── hi-res determinism: frozen .dsp vs C player ──"
$BIN/quanta-freeze "$WORK/t.qsc" -o "$WORK/t.dsp" --verify >/dev/null 2>&1
N=$(( $(stat -c%s "$WORK/dec.f64") / 8 ))
FINC="$(dirname "$(dirname "$(readlink -f "$(command -v faust)")")")/include"
[ -f "$FINC/faust/gui/CInterface.h" ] || FINC=/usr/share/faust
faust -lang c -double -cn quanta -a arch/minimal_c.arch "$WORK/t.dsp" -o "$WORK/gen.c" >/dev/null 2>&1
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
NULLDB=$(python3 tools/metrics.py null "$WORK/dec.f64" "$WORK/faust.f64" | sed -n 's/.*peak \([-+0-9.]*\) dBFS.*/\1/p')

echo "[b1] ── gates ──"
python3 - "$NMED" "$NULLDB" <<'PY'
import sys
nmed,nulldb=float(sys.argv[1]),float(sys.argv[2])
g1 = nmed < 0.0
g2 = nulldb <= -120.0
print(f"  G1 perceptual (NMR median {nmed:+.2f} dB < 0)         -> {'PASS' if g1 else 'FAIL'}")
print(f"  G2 hi-res determinism (null {nulldb:+.1f} dBFS <= -120) -> {'PASS' if g2 else 'FAIL'}")
sys.exit(0 if (g1 and g2) else 1)
PY
echo "[b1] PASS"
