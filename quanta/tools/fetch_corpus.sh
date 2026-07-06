#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-DeMoD-Commercial
# fetch_corpus.sh — build a small CC0 / public-domain real-music test corpus for the
# perceptual gate (tools/perceptual.py). We do NOT vendor audio into the repo; this
# script fetches vetted CC0 sources on demand and trims short clips with ffmpeg
# (via `nix run nixpkgs#ffmpeg`, so it needs no devshell change).
#
# Sources are chosen to be UNAMBIGUOUSLY CC0 / public-domain:
#   - Open Goldberg Variations, Kimiko Ishizaka (J.S. Bach) — released CC0.
#   - Well-Tempered Clavier, Kimiko Ishizaka — released CC0.
# Provenance + license for every clip is recorded in test/music/CREDITS.md.
#
# Usage:  bash tools/fetch_corpus.sh          # populate test/music/*.wav (48k stereo, ~6 s each)
set -eu
OUT=test/music
mkdir -p "$OUT"
FF="nix run nixpkgs#ffmpeg --"

# name|url|start|dur  (short excerpts only)
CLIPS=(
  "goldberg_aria|https://archive.org/download/OpenGoldbergVariations/01.Aria.flac|20|6"
  "goldberg_var1|https://archive.org/download/OpenGoldbergVariations/02.Variatio1a1Clav.flac|5|6"
  "wtc_prelude1|https://archive.org/download/TheWellTemperedClavierBook1/01.PreludeNo.1InCMajorBWV846.flac|8|6"
)

: > "$OUT/CREDITS.md"
{
  echo "# Perceptual test corpus — provenance & licenses"
  echo
  echo "Short excerpts, fetched by \`tools/fetch_corpus.sh\`. All sources CC0 / public domain."
  echo
} >> "$OUT/CREDITS.md"

for c in "${CLIPS[@]}"; do
  IFS='|' read -r name url start dur <<<"$c"
  echo ">> $name  <- $url  (${start}s +${dur}s)"
  tmp="$OUT/.$name.src"
  if curl -fsSL "$url" -o "$tmp"; then
    $FF -nostdin -y -ss "$start" -t "$dur" -i "$tmp" -ar 48000 -ac 2 -c:a pcm_s16le "$OUT/$name.wav" 2>/dev/null \
      && echo "- **$name.wav** — Open Goldberg / WTC (Kimiko Ishizaka), **CC0**. Source: $url (${start}s, ${dur}s)." >> "$OUT/CREDITS.md" \
      || echo "   ffmpeg trim failed for $name (skipped)"
    rm -f "$tmp"
  else
    echo "   download failed for $name (skipped — check the URL / network)"
  fi
done

echo ">> corpus in $OUT/ :"; ls -1 "$OUT"/*.wav 2>/dev/null || echo "   (none fetched — see messages above)"
