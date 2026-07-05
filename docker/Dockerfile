# SPDX-License-Identifier: MPL-2.0
# demod-quanta / DeMoD — SOFT-REAL-TIME DEVELOPMENT container (fat dev image).
#
#   ┌──────────────────────────────────────────────────────────────────────┐
#   │  ⚠  NOT REPRESENTATIVE OF REAL HARDWARE.                              │
#   │  No PREEMPT_RT kernel, no isolcpus, no guaranteed SCHED_FIFO/mlock.   │
#   │  The engine's 1.33 ms (64-sample @ 48 kHz) budget is NOT met here —  │
#   │  expect much higher latency, jitter, and xruns than a real machine.  │
#   │  The HLS monitor is a 24 kbps compressed stream, not full fidelity.   │
#   │  Build / wiring / functional testing only. Never for latency or      │
#   │  throughput measurement or production audio.                         │
#   └──────────────────────────────────────────────────────────────────────┘
#
# Builds (via the pinned flake, exact CI parity): the Quanta codec CLIs, the
# demod-rt engine + Haskell orchestrator, the DCF UDP + WebSocket bridges, the
# DCF-Audio caster, HydraMesh's dcf-ffmpeg/dcf-radio (browser-playable HLS of the
# engine's DCF-Audio monitor), and the WASM UI. The entrypoint boots a soft-RT
# appliance, casts a live HLS monitor, and hosts the browser UI.
#
# Build context is the REPO ROOT (see docker/compose.yaml `context: ..`).
# A slim, distributable runtime image is available separately as a pure-Nix build:
#   nix build .#docker-runtime && docker load < result
FROM nixos/nix:latest

ENV NIX_CONFIG="experimental-features = nix-command flakes"
WORKDIR /work

# Copy the tree (.dockerignore keeps out .git, build-*, result*, out/ — which
# also makes /work a plain "path:" flake so nix builds every file present).
COPY . /work

# Runtime tools the entrypoint needs on PATH that aren't in the nixos/nix base
# image: jackd (dummy backend), python3 (static server), tini (PID 1). The base
# image already ships bash, coreutils, and curl (used by HEALTHCHECK) in its own
# profile — reinstalling those would collide on their files, so we don't.
RUN nix profile install \
      nixpkgs#jack2 nixpkgs#python3 nixpkgs#tini

# Build the DeMoD components into named result links the entrypoint references.
# dcf-ffmpeg / dcf-radio come from the HydraMesh flake input (see flake.nix).
# --no-write-lock-file: use the committed flake.lock verbatim, so every component
# is built against the SAME nixpkgs. Without it, nix can re-lock mid-build and the
# locally-built caster ends up against a newer glibc than the cache-substituted
# engine binaries — its ELF interpreter then isn't in the image (cannot execute).
ARG NIXBUILD="nix build --no-write-lock-file"
RUN $NIXBUILD .#quanta              -o result-quanta \
 && $NIXBUILD .#demod-rt            -o result-rt \
 && $NIXBUILD .#demod-orchestrator  -o result-orch \
 && $NIXBUILD .#demod-remote-bridge -o result-bridge \
 && $NIXBUILD .#dcf-ws-bridge       -o result-wsb \
 && $NIXBUILD .#demod-dcf-audiocast -o result-cast \
 && $NIXBUILD .#dcf-radio           -o result-radio \
 && ln -sfn "$($NIXBUILD --no-link --print-out-paths '.#dcf-ffmpeg^bin')" result-ffmpeg \
 && result-cast/bin/demod-dcf-audiocast --help >/dev/null \
 && result-ffmpeg/bin/ffmpeg -version >/dev/null

# Build the browser UI to WebAssembly (pages.yml recipe) with the DCF client
# path enabled so the hosted UI can join the mesh via the ws bridge; drop the
# artifacts next to web/index.html. (Impure: emscripten's SDL2 port needs the
# network, so this can't be a sandboxed nix build — hence a `nix shell` step.)
RUN nix shell nixpkgs#emscripten nixpkgs#cmake nixpkgs#gnumake --command bash -eu -c '\
      export EM_CACHE=/tmp/emcache; \
      emcmake cmake -S . -B build-wasm -DCMAKE_BUILD_TYPE=Release -DDEMOD_DCF=ON; \
      cmake --build build-wasm -j' \
 && cp build-wasm/demod-ui.js build-wasm/demod-ui.wasm build-wasm/demod-ui.data web/

RUN chmod +x docker/entrypoint.sh

# OCI image metadata (mirrors flake.nix `ociLabels`).
LABEL org.opencontainers.image.title="DeMoD dev appliance" \
      org.opencontainers.image.description="Soft-real-time DeMoD audio engine + Quanta codec + WASM UI + HydraMesh DCF-Audio HLS monitor. DEV/soft-RT only — not representative of real hardware." \
      org.opencontainers.image.source="https://github.com/ALH477/DeMoD" \
      org.opencontainers.image.licenses="MPL-2.0 AND GPL-3.0-only AND LGPL-3.0-only" \
      org.opencontainers.image.version="0.2.0" \
      com.demod.soft-rt="true"

# 8080 = WASM UI + HLS monitor (HTTP) · 7000 = dcf-ws-bridge (WebSocket) ·
# 47000/udp = DCF mesh (native demod-ui-dcf target).
EXPOSE 8080 7000 47000/udp

# A static /healthz file is served from web/; curl it to gate readiness.
HEALTHCHECK --interval=15s --timeout=3s --start-period=90s --retries=5 \
  CMD curl -fsS "http://localhost:${HTTP_PORT:-8080}/healthz" || exit 1

ENV DEMOD_DCF_PORT=47000 \
    DEMOD_DCF_BIND=0.0.0.0 \
    DEMOD_CONTROL_SOCK=/run/demod/control.sock \
    JACK_PERIOD=1024 \
    HTTP_PORT=8080 \
    WS_PORT=7000 \
    OUT=/out

# tini as PID 1 for correct signal forwarding + zombie reaping. bash is invoked
# explicitly so the script runs regardless of whether /usr/bin/env is present.
ENTRYPOINT ["tini", "--", "bash", "/work/docker/entrypoint.sh"]
CMD ["serve"]
