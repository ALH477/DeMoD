#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# media.sh — a tiny out-of-engine music player for DeMoD Auto's MEDIA surface.
# Plays a folder of audio files (pw-play -> ffplay -> aplay), takes commands over
# a FIFO ($DEMOD_MEDIA_CMD), and writes now-playing state to a KV file
# ($DEMOD_MEDIA_STATE) the UI tails. DEMOD_AUDIO=dummy simulates (no real output),
# for headless use. Not through the rig FX — a plain default-sink player.
# Copyright (c) 2026 DeMoD LLC. MPL-2.0; see LICENSE.
set -u

DIR="${DEMOD_MEDIA_DIR:-$HOME/Music}"
STATE="${DEMOD_MEDIA_STATE:-/tmp/demod-media.kv}"
CMD="${DEMOD_MEDIA_CMD:-/tmp/demod-media.cmd}"
AUDIO="${DEMOD_AUDIO:-auto}"

shopt -s nullglob nocaseglob
mapfile -t TRACKS < <(ls -1 "$DIR"/*.{mp3,flac,wav,ogg,m4a,opus} 2>/dev/null)
N=${#TRACKS[@]}
idx=0; playing=0; PID=""

wrap() { [ "$N" -gt 0 ] && echo $(( ($1 % N + N) % N )) || echo 0; }

play_file() {  # background the actual player; echo 'done' to the FIFO when it ends
  if [ "$AUDIO" = dummy ] || [ "$N" -eq 0 ]; then sleep 3
  elif command -v pw-play >/dev/null 2>&1; then pw-play "$1"
  elif command -v ffplay  >/dev/null 2>&1; then ffplay -nodisp -autoexit -loglevel quiet "$1"
  elif command -v aplay   >/dev/null 2>&1; then aplay -q "$1"
  else sleep 3; fi
}

stop_player() { [ -n "$PID" ] && kill "$PID" 2>/dev/null; PID=""; }

start() {
  stop_player
  playing=1
  ( play_file "${TRACKS[$idx]:-}"; echo done > "$CMD" ) &
  PID=$!
}

write_state() {
  local title="(no media)"
  [ "$N" -gt 0 ] && title="$(basename "${TRACKS[$idx]}")"
  printf 'title=%s index=%s count=%s playing=%s\n' \
    "${title// /_}" "$((idx + 1))" "$N" "$playing" > "$STATE.tmp"
  mv "$STATE.tmp" "$STATE"
}

[ -p "$CMD" ] || { rm -f "$CMD"; mkfifo "$CMD"; }
exec 3<>"$CMD"                     # hold the FIFO open (no EOF between writers)
trap 'stop_player; exec 3>&-; rm -f "$CMD"' EXIT

write_state
[ "$N" -gt 0 ] && start && write_state

while read -r c <&3; do
  case "$c" in
    play)         start ;;
    toggle)       if [ "$playing" = 1 ]; then stop_player; playing=0; else start; fi ;;
    pause|stop)   stop_player; playing=0 ;;
    next)         idx=$(wrap $((idx + 1))); start ;;
    prev)         idx=$(wrap $((idx - 1))); start ;;
    done)         idx=$(wrap $((idx + 1))); start ;;   # track ended -> advance
    quit)         break ;;
    *)            : ;;
  esac
  write_state
done
