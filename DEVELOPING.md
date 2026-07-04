<!-- SPDX-License-Identifier: MPL-2.0 -->
# Developing DeMoD

The short version: **`./dev`** wraps the whole loop, and **`./dev check`** is the one command to run
before you push.

```bash
./dev check                 # build + every test CI runs (+ obd2). the pre-push gate.
./dev run auto              # run a shell app from the working tree (auto|dash|gcs|rov|mcp|example)
./dev shot dsp_studio 60    # headless render -> a PNG (no display needed)
./dev test loopback         # one test (font|loopback|ws_loopback|engine_e2e|obd2|smoke|all)
./dev build [dcf]           # build ./demod-ui (dcf = with the dm.dcf transport)
./dev fmt | lint            # stylua + clang-format (advisory)
```

`./dev` has **zero dependencies** and **auto-enters `nix develop`** when the C toolchain isn't on your
PATH — so a fresh `git clone` + `./dev check` works if you have Nix. Without Nix, install SDL2 + Lua 5.4
+ a C compiler + pkg-config first (then `./dev` runs directly).

## Build systems

| System | When | Command |
|--------|------|---------|
| **Makefile** (canonical) | the framework binary | `make` → `./demod-ui`; `make DCF=1` adds `dm.dcf`; `make test`, `make font`, `make clean` |
| **CMake** (additive) | macOS/Windows client + WASM | `cmake -S . -B build -DDEMOD_DCF=ON`; WASM: `emcmake cmake -S . -B build-wasm && cmake --build build-wasm` |
| **Nix flake** | reproducible builds + the audio stack | `nix build .#{default,demod-rt,demod-orchestrator,demod-ui-dcf,demod-remote-bridge,dcf-ws-bridge,appimage}` |

> **Note:** `make DCF=1` after a plain `make` used to silently leave `dm.dcf` absent (stale objects). The
> Makefile now tracks the `DCF`/`LOCAL_DSP`/`STEAM` flag set (`.build-tag`) and recompiles when it
> changes, so you no longer need `make clean` when toggling — and `./dev` always builds correctly.

## Running from a working tree

`nix run .#{auto,dash,gcs,rov,mcp,check}` runs the store-built versions. To run from your **checkout**,
use `./dev run <target>` (it builds `DCF=1` and sets the env below). Or set the env yourself:

| Var | For | Default |
|-----|-----|---------|
| `DEMOD_SHELL_DIR` | shell apps — the SDK dir | derived from the app dir |
| `DEMOD_{AUTO,DASH,GCS,ROV}_DIR` | the app's own dir | the `main.lua` script dir |
| `DEMOD_SURFACE=n` | deep-link a surface (for `./dev shot`) | 1 |
| `DEMOD_DCF_HOST` / `_PORT` | attach a live DCF mesh | unset → simulator |
| `DEMOD_SHOT` / `_FRAME` / `_QUIT` | headless framebuffer dump (PPM) | — / 90 / 1 |
| `DEMOD_CAMERA_DEV` / `_TEST` / `_FRAME` | auto rear camera (see `docs/automotive-compliance.md`) | off unless set |
| `DEMOD_OBD_DEV`, `DEMOD_MEDIA_DIR`, `DEMOD_REVERSE` | auto OBD / media / reverse | see `auto/README.md` |

## Testing

There's no single "test suite" file — tests are focused scripts, all run by `./dev test` / `./dev check`:
`make test` (font/decode, display-free), `audio-stack/bridge/test/{loopback,ws_loopback,engine_e2e}.sh`
(the DCF transport + real-engine E2E; `engine_e2e` self-skips without JACK/RT), `auto/test/obd2_selftest.sh`
(mock ELM327 → OBD reader), and a headless render smoke over the examples. `./dev check` mirrors
`.github/workflows/ci.yml` exactly, plus obd2. *(A `busted` Lua unit layer is a noted future gap.)*

## Formatting

Advisory: `stylua.toml` (Lua) + `.clang-format` (C) + `.editorconfig`. `./dev fmt` applies them; `./dev
lint` checks. Neither gates `./dev check` or CI — format when you like; `./dev fmt` before a PR is nice.

## Layout & licenses

- **Framework** (repo root, `src/`, `shell/`, `auto/`/`dash/`/`gcs/`/`rov/`, `examples/`) — **MPL-2.0**.
  `dm.dcf` (`src/ipc/dm_dcf.c`) is **LGPL-3.0**.
- **Audio stack** (`audio-stack/` — `demod-rt` + orchestrator + IPC) — **GPLv3-only OR commercial**
  (the DEMOD DUAL LICENSE). Separate program over socket/shm IPC; see [`LICENSING.md`](LICENSING.md).
- Every file carries an SPDX header (CI-relevant; `CONTRIBUTING.md`).

## The MCP server (drive the repo from an AI agent)

`mcp/demod_mcp_server.py` exposes build/render/test/engine-control as MCP tools — `nix run .#mcp`, or
`claude mcp add demod -- python3 "$PWD/mcp/demod_mcp_server.py"`. See [`mcp/README.md`](mcp/README.md).
