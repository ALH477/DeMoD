#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# camera.sh — rear-camera capture for DeMoD Auto. Captures from a V4L2 device
# (USB/CSI) or a synthetic test source, and writes the latest frame as raw RGBA
# to $DEMOD_CAMERA_FRAME (atomic), which the CAMERA surface blits. Read-only
# capture; no vehicle-bus writes. Copyright (c) 2026 DeMoD LLC. MPL-2.0.
set -u

DEV="${DEMOD_CAMERA_DEV:-/dev/video0}"
FRAME="${DEMOD_CAMERA_FRAME:-/tmp/demod-camera.rgba}"
W=640; H=360

if [ "${DEMOD_CAMERA_TEST:-0}" = 1 ] || [ ! -e "$DEV" ]; then
  SRC=(-f lavfi -i "testsrc=size=${W}x${H}:rate=15")
else
  SRC=(-f v4l2 -i "$DEV")
fi

exec ffmpeg -hide_banner -loglevel error "${SRC[@]}" \
  -vf "scale=${W}:${H},format=rgba" -f rawvideo -pix_fmt rgba pipe:1 \
  | DEMOD_CAMERA_FRAME="$FRAME" python3 -c '
import os, sys
W, H = 640, 360
N = W * H * 4
FRAME = os.environ["DEMOD_CAMERA_FRAME"]
r = sys.stdin.buffer
while True:
    buf = r.read(N)
    if len(buf) < N:
        break
    tmp = FRAME + ".tmp"
    with open(tmp, "wb") as f:
        f.write(buf)
    os.replace(tmp, FRAME)   # atomic: the UI never blits a torn frame
'
