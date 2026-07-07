#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-DeMoD-Commercial
# quanta-play — hear a frozen master. Compiles a frozen quanta .dsp with arch/player.arch
# into a self-contained standalone player and streams it in real time to the first available
# system sink (pw-play -> aplay -> ffplay). The player itself has zero audio-library deps;
# the sink does the device I/O. Uses f32 so the format matches unambiguously across sinks.
#
#   bash tools/quanta-play.sh <frozen.dsp> [seconds]
#
# With no sink present it writes raw f32 to ./play.f32 and prints the format to play it later.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DSP="${1:?usage: quanta-play <frozen.dsp> [seconds]}"
SECS="${2:-}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

FINC="$(dirname "$(dirname "$(readlink -f "$(command -v faust)")")")/include"
[ -f "$FINC/faust/gui/CInterface.h" ] || FINC=/usr/share/faust

# the frozen master carries its own rate + channel count (spec §7 / arch/player.arch)
SR=$(grep -oE 'declare samplerate "[0-9]+"' "$DSP" | grep -oE '[0-9]+' | head -1 || echo 48000)
CH=$(grep -oE 'channels=[0-9]+' "$DSP" | grep -oE '[0-9]+' | head -1 || echo 1)

echo "quanta-play: compiling $DSP -> standalone player ($SR Hz, ${CH}ch)..." >&2
faust -lang c -double -cn quanta -a "$ROOT/arch/player.arch" "$DSP" -o "$WORK/p.c" >/dev/null 2>&1
gcc -O2 -std=c11 -I"$ROOT/include" -ffp-contract=off -fno-fast-math -fwrapv -I"$FINC" \
    "$WORK/p.c" -o "$WORK/play" -lm

ARGS=(--f32); [ -n "$SECS" ] && ARGS+=(--seconds "$SECS")

if command -v pw-play >/dev/null 2>&1; then
  echo "quanta-play: streaming -> pw-play" >&2
  "$WORK/play" "${ARGS[@]}" | pw-play --rate "$SR" --channels "$CH" --format f32 --raw -
elif command -v aplay >/dev/null 2>&1; then
  echo "quanta-play: streaming -> aplay" >&2
  "$WORK/play" "${ARGS[@]}" | aplay -q -f FLOAT_LE -r "$SR" -c "$CH" -t raw
elif command -v ffplay >/dev/null 2>&1; then
  LAY=mono; [ "$CH" = 2 ] && LAY=stereo
  echo "quanta-play: streaming -> ffplay" >&2
  "$WORK/play" "${ARGS[@]}" | ffplay -hide_banner -loglevel error -autoexit -f f32le -ar "$SR" -ch_layout "$LAY" -i -
else
  "$WORK/play" "${ARGS[@]}" -o play.f32
  echo "quanta-play: no system player found; wrote ./play.f32" >&2
  echo "  play it with: ffplay -f f32le -ar $SR -ch_layout $([ "$CH" = 2 ] && echo stereo || echo mono) -i play.f32" >&2
fi
