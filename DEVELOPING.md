<!-- SPDX-License-Identifier: MPL-2.0 -->
# Developing DeMoD

The short version: **`./dev`** wraps the whole loop, and **`./dev check`** is the one command to run
before you push.

```bash
./dev check                 # build + every test CI runs (+ obd2). the pre-push gate.
./dev run auto              # run a shell app from the working tree (auto|dash|gcs|rov|mcp|terminus|example)
./dev shot dsp_studio 60    # headless render -> a PNG (no display needed)
./dev test loopback         # one test (font|loopback|ws_loopback|engine_e2e|obd2|smoke|all)
./dev build [dcf]           # build ./demod-ui (dcf = with the dm.dcf transport)
./dev fmt | lint [--all]    # stylua + clang-format (advisory; default = your changed files)
./dev doctor                # toolchain / tools / versions at a glance
./dev watch <target>        # rebuild + re-run on change   ·   ./dev compiledb (clangd)
```

`nix run .#dev -- <cmd>` and `nix run .#check` run the CLI without a checkout dir.

`./dev` has **zero dependencies** and **auto-enters `nix develop`** when the C toolchain isn't on your
PATH — so a fresh `git clone` + `./dev check` works if you have Nix. Without Nix, install SDL2 + Lua 5.4
+ a C compiler + pkg-config first (then `./dev` runs directly).

## Build systems

| System | When | Command |
|--------|------|---------|
| **Makefile** (canonical) | the framework binary | `make` → `./demod-ui`; `make DCF=1` adds `dm.dcf`; `make test`, `make font`, `make clean` |
| **CMake** (additive) | macOS/Windows client + WASM | `cmake -S . -B build -DDEMOD_DCF=ON`; WASM: `emcmake cmake -S . -B build-wasm && cmake --build build-wasm` |
| **Nix flake** | reproducible builds + the audio stack + the quanta codec | `nix build .#{default,demod-rt,demod-orchestrator,demod-ui-dcf,demod-remote-bridge,dcf-ws-bridge,quanta,appimage}` |

> **Note:** `make DCF=1` after a plain `make` used to silently leave `dm.dcf` absent (stale objects). The
> Makefile now tracks the `DCF`/`LOCAL_DSP`/`STEAM` flag set (`.build-tag`) and recompiles when it
> changes, so you no longer need `make clean` when toggling — and `./dev` always builds correctly.

## Running from a working tree

`nix run .#{auto,dash,gcs,rov,quanta,mcp,terminus,check}` runs the store-built versions. To run from your **checkout**,
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
(the DCF transport + real-engine E2E; `engine_e2e` self-skips without JACK/RT), `cd quanta && make test`
(the codec null + M0 tonal gates; needs `faust` + numpy, both in the devShell), `auto/test/obd2_selftest.sh`
(mock ELM327 → OBD reader), and a headless render smoke over the examples. `./dev check` mirrors
`.github/workflows/ci.yml` exactly, plus obd2. *(A `busted` Lua unit layer is a noted future gap.)*

## Editor / LSP

Out-of-the-box completion + diagnostics:
- **Lua** — `.luarc.json` + `meta/dm.lua` teach [lua-language-server](https://luals.github.io) the
  `dm` API and the framework's global callbacks (`on_nav`/`on_update`/`on_draw`…), so editing shells /
  examples gets completion and stops flagging `dm` as undefined. `lua-language-server` is in the dev shell.
- **C** — `.clangd` + `./dev compiledb` (writes `compile_commands.json` via `bear`) give clangd the real
  SDL2/Lua flags. `clang-format`/`clangd` come from `clang-tools` in the dev shell.

`./dev` gets `bash` tab-completion (subcommands + targets) in `nix develop`, and `./dev doctor` shows
your toolchain at a glance.

## Formatting

Advisory: `stylua.toml` (Lua) + `.clang-format` (C) + `.editorconfig`. `./dev fmt` applies them to your
**changed** files (`--all` for the whole tree); `./dev lint` checks. Neither gates `./dev check` or CI —
format when you like; `./dev fmt` before a PR is nice. (The tree isn't pre-formatted, so a first
whole-tree `./dev fmt --all` would be a large diff — keep it scoped to what you touch.)

## Layout & licenses

- **Framework** (repo root, `src/`, `shell/`, `auto/`/`dash/`/`gcs/`/`rov/`, `examples/`) — **MPL-2.0**.
  `dm.dcf` (`src/ipc/dm_dcf.c`) is **LGPL-3.0**.
- **Audio stack** (`audio-stack/` — `demod-rt` + orchestrator + IPC) — **GPLv3-only OR commercial**
  (the DEMOD DUAL LICENSE). Separate program over socket/shm IPC; see [`LICENSING.md`](LICENSING.md).
- **Quanta codec** (`quanta/` — analyzer + render + freeze + QSC) — **GPLv3-only OR commercial**
  (same DEMOD DUAL LICENSE); the `ui/` panel is **MPL-2.0**. Standalone CLIs; see [`LICENSING.md`](LICENSING.md).
- **TERMINUS** (`apps/terminus/` — home shell + DSP Studio + patches) — **PolyForm Shield 1.0.0**
  (source-available, non-commercial); see [`apps/terminus/README.md`](apps/terminus/README.md).
- Every file carries an SPDX header (CI-relevant; `CONTRIBUTING.md`).

## The MCP server (drive the repo from an AI agent)

`mcp/demod_mcp_server.py` exposes build/render/test/engine-control as MCP tools — `nix run .#mcp`, or
`claude mcp add demod -- python3 "$PWD/mcp/demod_mcp_server.py"`. See [`mcp/README.md`](mcp/README.md).
