#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-DeMoD-Commercial
# fetch_speech_bench.sh — public-domain multi-speaker speech test set for the
# beat-MELPe benchmark (tools/bench_speech.py). LibriVox recordings are public
# domain (CC0-equivalent). We do NOT vendor audio; fetch on demand and trim short
# clips. Each clip is produced at 48 kHz mono (70 Hz high-passed to kill DC/rumble)
# AND 8 kHz mono (for the Codec2 narrowband head-to-head). Provenance in CREDITS.md.
set -eu
OUT=test/speech/bench
mkdir -p "$OUT"
FF="nix run nixpkgs#ffmpeg --"
BASE=https://archive.org/download

# id|file|speaker|start|dur
CLIPS=(
  "art_of_war_librivox|art_of_war_01-02_sun_tzu.ogg|m1_suntzu|55|8"
  "adventures_holmes|adventureholmes_01_doyle.ogg|m2_holmes|50|8"
  "pride_and_prejudice_librivox|prideandprejudice_01-03_austen.ogg|f1_austen|40|8"
  "jane_eyre_librivox|jane_eyre_01_bronte.ogg|f2_bronte|45|8"
)
: > "$OUT/CREDITS.md"
{ echo "# Speech benchmark corpus — provenance & license"; echo;
  echo "LibriVox recordings, **public domain**. Fetched by tools/fetch_speech_bench.sh."; echo; } >> "$OUT/CREDITS.md"

for c in "${CLIPS[@]}"; do
  IFS='|' read -r id file spk start dur <<<"$c"
  echo ">> $spk  <- $id/$file (${start}s +${dur}s)"
  tmp="$OUT/.$spk.ogg"
  if curl -fsSL "$BASE/$id/$file" -o "$tmp"; then
    # 48 kHz mono, 70 Hz high-pass (DC/rumble), light peak-normalize
    $FF -nostdin -y -ss "$start" -t "$dur" -i "$tmp" -af "highpass=f=70,dynaudnorm=p=0.9" \
        -ar 48000 -ac 1 -c:a pcm_s16le "$OUT/$spk.wav" 2>/dev/null
    # 8 kHz mono for Codec2 head-to-head
    $FF -nostdin -y -i "$OUT/$spk.wav" -ar 8000 -ac 1 -c:a pcm_s16le "$OUT/${spk}_8k.wav" 2>/dev/null
    echo "- **$spk** — $id ($file), ${start}s+${dur}s. Public domain (LibriVox)." >> "$OUT/CREDITS.md"
    rm -f "$tmp"
  else echo "   download failed ($id) — skipped"; fi
done
echo ">> corpus:"; ls -1 "$OUT"/*.wav 2>/dev/null
