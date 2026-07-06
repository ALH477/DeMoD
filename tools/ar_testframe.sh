#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# ar_testframe.sh — write a synthetic 640x360 RGBA frame for the dm.ar demo.
# This stands in for the real out-of-process decoder (ffmpeg v4l2/GStreamer),
# so ar_hud.lua and the headless screenshot test need no camera. With --loop it
# keeps rewriting the file so a live (windowed) run animates.
#
# Usage:
#   tools/ar_testframe.sh [OUT]            # one frame -> OUT (default /tmp/demod-ar.rgba)
#   tools/ar_testframe.sh [OUT] --loop     # rewrite ~10 fps until interrupted
#
# Copyright (c) 2026 DeMoD LLC. Licensed under the Mozilla Public License, v. 2.0.
set -euo pipefail

OUT="${1:-/tmp/demod-ar.rgba}"
LOOP="${2:-}"
W=640
H=360

gen_ffmpeg() {  # $1 = frame index (unused; static test pattern)
  ffmpeg -loglevel error -y -f lavfi -i "testsrc=size=${W}x${H}:rate=1" \
    -frames:v 1 -pix_fmt rgba -f rawvideo "$OUT.tmp"
  mv -f "$OUT.tmp" "$OUT"
}

gen_python() {  # $1 = frame index (animates the gradient phase)
  python3 - "$OUT" "$W" "$H" "${1:-0}" <<'PY'
import sys, struct
out, w, h, phase = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4])
buf = bytearray(w * h * 4)
for y in range(h):
    for x in range(w):
        i = (y * w + x) * 4
        buf[i]   = (x * 255 // w + phase * 8) & 0xFF          # R sweeps X
        buf[i+1] = (y * 255 // h) & 0xFF                       # G sweeps Y
        buf[i+2] = ((x ^ y) + phase * 4) & 0xFF                # B moire
        buf[i+3] = 255
tmp = out + ".tmp"
with open(tmp, "wb") as f:
    f.write(buf)
import os
os.replace(tmp, out)
PY
}

gen() {
  if command -v ffmpeg >/dev/null 2>&1; then
    gen_ffmpeg "$1"
  elif command -v python3 >/dev/null 2>&1; then
    gen_python "$1"
  else
    echo "ar_testframe.sh: need ffmpeg or python3" >&2
    exit 1
  fi
}

if [ "$LOOP" = "--loop" ]; then
  echo "ar_testframe.sh: writing $OUT (${W}x${H}) ~10fps; Ctrl-C to stop"
  i=0
  while true; do
    gen "$i"
    i=$((i + 1))
    sleep 0.1
  done
else
  gen 0
  echo "ar_testframe.sh: wrote $OUT (${W}x${H} RGBA, $((W * H * 4)) bytes)"
fi
