<!-- SPDX-License-Identifier: MPL-2.0 -->
# AGENTS.md — working in the DeMoD repo

Orientation for AI coding agents (and humans). Read this first; it is the fast path to being
productive here without tripping the sharp edges. Deep references are linked at the bottom.

## What this repo is

A **pure software-rendered GUI framework** (C11 + SDL2 + Lua, **no GPU** — the framebuffer is a
`uint32_t*` ARGB buffer drawn scanline-by-scanline) plus everything built on it:

- **Framework** — `src/`, `include/`, `examples/`. Apps are Lua scripts against the `dm.*` API.
- **Companion-shell SDK + apps** — `shell/` (surface manager + telemetry provider + theme + touch),
  and the shells `auto/` (car head unit), `dash/` (telemetry dashboard), `gcs/` (drone GCS), `rov/`
  (AUV/ROV console). Each = its own theme + provider + surfaces on the SDK.
- **Audio stack** — `audio-stack/` (`demod-rt` engine + Haskell orchestrator + IPC). Driven over a
  control socket; **separate program**, not linked into the UI.
- **Quanta codec** — `quanta/` (analysis-to-synthesis: matching-pursuit analyzer → `.qsc` score →
  pure static Faust `.dsp` freeze + a Lua score-browser panel). **Separate program**; standalone CLIs.
- **Remote transport** — `dm.dcf` (`src/ipc/dm_dcf.c`), a 17-byte HydraMesh frame over UDP/WebSocket;
  `audio-stack/bridge/` relays it. Powers the remote/browser clients.
- **Browser client** — the framework compiles to WASM (`CMakeLists.txt` emscripten path, `web/`).
- **MCP server** — `mcp/demod_mcp_server.py`, exposes build/render/test/engine-control as agent tools.

## Golden commands (use these — they wrap every incantation)

```bash
./dev check            # build + EVERY test CI runs (+ obd2). THE pre-push gate. Run it before finishing.
./dev run <target>     # auto|dash|gcs|rov|mcp or an examples/ name (from the working tree)
./dev shot <target> [frame]   # headless render -> a PNG you can inspect (no display needed)
./dev test <name|all>  # font|loopback|ws_loopback|engine_e2e|obd2|smoke
./dev build [dcf]      # ./demod-ui (dcf adds dm.dcf); ./dev doctor · fmt|lint · watch · compiledb
```

`./dev` has zero deps and **auto-enters `nix develop`** if the toolchain isn't on PATH. Raw equivalents:
`make` / `make DCF=1` / `make test`; `nix run .#{auto,dash,gcs,rov,quanta,mcp,check,dev}`; `nix build .#{default,quanta}`.

**Definition of done:** `./dev check` is green; new files carry an `SPDX-License-Identifier` header;
changes are additive (don't reformat the tree — lint is advisory). Verify UI changes with `./dev shot`
(use `DEMOD_SURFACE=n` to deep-link a surface). Never claim a test passed without running it.

## Architecture you must know

- **The focus field.** One global input funnel: `on_nav(action)` where action ∈ `prev|next|activate|
  back|tab|tab_prev|wet`. Every input (keyboard, encoder, gamepad, touch) routes into it. The pointer
  is sugar, never required — build for encoder-first.
- **Frame model (event-driven, not free-running).** The loop re-renders only when redraw is requested.
  Each frame calls Lua globals `on_update(dt)` (always) and `on_draw()` (when redrawing, after the
  widget tree paints). Therefore: **`dm.draw.*` is valid ONLY inside `on_draw()`**, and for animation
  you MUST call `dm.redraw()` in `on_update()` or the screen freezes between inputs.
- **Shell SDK.** A shell app supplies `{surfaces, provider, palettes, config}` to `shell.run()`. A
  surface is `{name, draw(ctx), nav?, zones?(ctx), update?}`; a provider is `{update, status, read}`
  (the pattern: a helper writes a KV state file, the provider tails it, with a sim fallback). See
  `shell/README.md`.
- **Widgets.** Retained tree of `DmWidget` (`include/demod/widget.h`); core in `src/widgets/widgets.c`,
  DSP widgets in `dsp_widgets.c`. A new widget isn't usable from Lua until: struct+constructor in the
  header, vtable+ctor in a widgets `.c`, an `l_<name>` binding in `src/lua/lua_bindings.c`, and the new
  `.c` added to `SRCS` in the `Makefile`.

## The Lua API

`SKILL.md` is the authoritative `dm.*` reference + copy-paste patterns + a "Common Mistakes" list —
consult it when writing Lua. `meta/dm.lua` + `.luarc.json` give your editor completion for `dm`
(lua-language-server is in the dev shell). Key surfaces: `dm.draw.{rect,circle,line,thick_line,text,
text_width,gradient_v,blit,...}` (colors are r,g,b,a integers), widgets (`dm.button/knob/vu_meter/
dropdown/scroll_panel/...`), `dm.dcf.{open,ping,send,poll,poll_event,status}`, `dm.ctl_*` (engine),
`dm.{width,height,redraw,nav,exec,root,find,color}`.

## Framebuffer constraints (why the code looks the way it does)

No GPU, no rounded-rect, no clip region, no font scaling beyond integer factors. **Drawn strings must
be ASCII 32–126** — the fixed 8×16 font renders `◄ ► ▸ —` and other box-drawing/arrows as **blank**;
use `[< >]`, `>`, `-`. "Glow"/"frosted glass" is faked with stacked low-alpha primitives. Measure text
with `dm.draw.text_width` — never `#s * 8` (breaks on UTF-8).

## Licensing & IP — get this right

Multi-license by layer (full map in `LICENSING.md`); **every file has an SPDX header**:

- **Framework + shells** (root, `src/`, `shell/`, `auto|dash|gcs|rov/`, `examples/`) — **MPL-2.0**.
- **`dm.dcf`** (`src/ipc/dm_dcf.c`, `audio-stack/bridge/`, the vendored HydraMesh headers) — **LGPL-3.0**.
- **Audio stack** (`audio-stack/` engine + orchestrator + IPC) — **GPLv3-only OR commercial** (the
  DEMOD DUAL LICENSE). The MPL UI talks to it only over socket/shm (separate programs) so the UI stays
  MPL; a product that *ships* the engine picks GPLv3 (offer source) or the commercial license (see
  `docs/automotive-compliance.md`).
- **Quanta codec** (`quanta/` analyzer + render + freeze + QSC format) — **GPLv3-only OR commercial**
  (the same DEMOD DUAL LICENSE); its `ui/quanta_panel.lua` is **MPL-2.0**. Standalone program.

**Reserved trade dress.** The *assembled* DeMoD/TERMINUS look — the oscilloscope-phosphor palette +
CRT scanlines/vignette/pulse + Sierpinski-glow + 8×16 phosphor type + blade/coverflow shell, **as a
combination** — is reserved. The open framework ships generic primitives (palette constants, the
Sierpinski primitive); the FOSS shell apps (`auto` etc.) each use their **own neutral palette** on
purpose. When building a new app, give it its own look — do not reproduce the reserved combination as a
product identity, and don't move CRT polish/themes/boot identity into the open framework.

## Safety (the vehicle work)

`auto/` and `docs/vehicle-feasibility.md` are explicit: **DeMoD is the companion / telemetry / HMI
layer, never the safety-critical control loop.** OBD/CAN access is **read-only** (no emissions writes).
The shell's motion-lockout + non-preemptible rear-camera are safety features — keep them intact; see
`docs/automotive-compliance.md`.

## Gotchas that will bite you

- `dm.draw.*` outside `on_draw()` does nothing; forgetting `dm.redraw()` freezes animation.
- Non-ASCII in a *drawn* string renders blank (see above).
- Shells need the **DCF build** (`make DCF=1`) for `dm.dcf`; `./dev run/shot` handle it. (The old
  `make DCF=1`-after-`make` stale-object trap is fixed — the Makefile tracks the flag set.)
- Multi-file Lua apps resolve siblings via `debug.getinfo` / `DEMOD_*_DIR` env; `./dev run` sets them.
- Headless test recipe: `SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy DEMOD_SHOT=x.ppm DEMOD_SHOT_FRAME=n
  ./demod-ui <script>` — or just `./dev shot`.
- `engine_e2e` / real-engine tests need JACK + RT privileges; they **self-skip** otherwise.

## Deeper references

`DEVELOPING.md` (the dev loop, env-var table, build systems) · `SKILL.md` (Lua API + patterns) ·
`CLAUDE.md` (framework internals) · `LICENSING.md` · `README.md` · per-dir READMEs (`shell/`, `auto/`,
`mcp/`, `audio-stack/bridge/test/`) · `docs/` (remote-client, browser-client, vehicle-feasibility,
automotive-compliance). The MCP server (`mcp/`) lets an agent build/render/test/drive the engine as tools.
