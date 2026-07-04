<!-- SPDX-License-Identifier: MPL-2.0 -->
# DeMoD UI — WebAssembly host

Runs the **real** C/SDL2/Lua framework in a browser on a `<canvas>` via
Emscripten. Additive to the tree: the native Makefile + native CMake builds are
byte-unchanged (everything is `#ifdef __EMSCRIPTEN__` / `if(EMSCRIPTEN)` gated).

## Build

Emscripten is provided through Nix. **Set a writable `EM_CACHE` first** (the Nix
emscripten package ships a read-only cache):

```bash
cd ~/demod-ui
nix shell nixpkgs#emscripten --command bash -c '
  export EM_CACHE=$(mktemp -d)
  emcmake cmake -S . -B build-wasm
  cmake --build build-wasm -j
'
```

Outputs land in `build-wasm/`:

- `demod-ui.js`   — Emscripten glue / runtime
- `demod-ui.wasm` — the compiled framework (C + Lua 5.4.7 built from source)
- `demod-ui.data` — MEMFS preload (the `examples/dsp_studio.lua` example, mapped
  to the MEMFS path `main.lua`, which is `main.c`'s default entry with no argv)

`build-wasm/` is gitignored (`build*/`).

## Serve

WASM/MEMFS cannot load from `file://` — serve over HTTP. Point the page at the
build output (or copy `demod-ui.{js,wasm,data}` next to `index.html`):

```bash
# option A: copy artifacts next to index.html, then serve web/
cp build-wasm/demod-ui.js build-wasm/demod-ui.wasm build-wasm/demod-ui.data web/
python3 -m http.server -d web 8080
# open http://localhost:8080/

# option B: serve the repo root and load web/index.html after editing its
#           <script src> to ../build-wasm/demod-ui.js
python3 -m http.server 8080

# option C: emscripten's own server (auto-opens a browser)
nix shell nixpkgs#emscripten --command emrun build-wasm/demod-ui.js
```

Click the canvas to give it keyboard focus (arrows / enter / esc funnel into the
same `on_nav` grammar as the device).

## Notes / scope

- **Phase A** only: no DCF/UDP transport (`dm_dcf.c` is excluded), so this is the
  offline UI. Local IPC (control socket, param/meter shm), MIDI, and the serial
  encoder compile to their existing off-platform no-op stubs.
- StreamDB runs its inline-flush, no-threads path (no pthreads in the browser).
- To ship a different Lua entry, change the `--preload-file …@main.lua` mapping
  in `CMakeLists.txt` (the `if(EMSCRIPTEN)` branch) and rebuild.
