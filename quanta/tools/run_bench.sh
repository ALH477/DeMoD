#!/usr/bin/env bash
# Run the beat-MELPe scoreboard (qvoc vs Codec2) inside a nix env with pesq + codec2.
set -eu
exec nix shell --impure --expr 'with builtins.getFlake "nixpkgs"; let p = legacyPackages.x86_64-linux; in p.buildEnv { name="qbench"; paths=[ (p.python3.withPackages(ps: with ps; [ pesq numpy ])) p.codec2 ]; }' \
  --command python3 tools/bench_speech.py "$@"
