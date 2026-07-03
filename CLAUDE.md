# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

DeMoD UI is a pure software-rendered GUI framework written in C11. The framebuffer is a `uint32_t*` ARGB8888 pixel buffer; **all drawing is scanline-by-scanline in C** (`src/core/framebuffer.c`). There is no GPU path — no OpenGL, Vulkan, or shaders. SDL2 is used only for window creation, input, and blitting the final buffer to screen via a streaming texture. Applications are written in Lua against the `dm.*` API. The design target is embedded Linux panels, kiosks, and instruments — small displays with encoder/limited input — but the same scripts run unchanged on a desktop.

## Build & run

```bash
nix develop          # dev shell with SDL2, Lua 5.4, gcc, gdb, valgrind
make                 # build ./demod-ui
make run             # examples/hello.lua
make run-dsp         # examples/dsp_panel.lua
make run-studio      # examples/dsp_studio.lua
make run-viz         # examples/systems_viz.lua  (layered node-graph demo)
make run-launcher    # examples/card_launcher.lua  (encoder-native card list)
make clean
./demod-ui path/to/script.lua   # run any Lua app; argv[1] is the entry script
```

Manual builds need SDL2, Lua 5.4, pkg-config, GCC/Clang. The Makefile auto-detects Lua via `pkg-config lua5.4` then falls back to `lua`.

There is **no test suite, linter, or formatter** configured, and this is **not a git repository**. Verify changes by building and running the relevant example. `valgrind ./demod-ui examples/hello.lua` is the standard way to check the C layer for leaks/overruns.

## Architecture: the layered stack

```
Lua scripts (app logic, widget tree)   examples/*.lua
  ↓ dm.* API
Lua bindings                           src/lua/lua_bindings.c
  ↓
Widget system (retained tree, events)  src/widgets/widgets.c, dsp_widgets.c + include/demod/widget.h
  ↓
Framebuffer (primitives, font, blit)   src/core/framebuffer.c, font.c
  ↓
SDL2 app (window, input, main loop)    src/app/app.c
```

Headers live in `include/demod/`; `demod_ui.h` is the umbrella include. Every `.c` must be added to `SRCS` in the Makefile to be compiled.

### Frame model (important)

The main loop in `app.c` is **event-driven, not free-running**. It only re-renders when `app->needs_redraw` is set — by an SDL input event, a resize, or an explicit request. Each frame it calls the Lua globals `on_update(dt)` (always) and `on_draw()` (only when redrawing, after the widget tree is painted). Consequences:

- For **animation**, you must call `dm.redraw()` at the end of `on_update()`, otherwise the screen freezes between input events.
- `dm.draw.*` calls write directly to the framebuffer and are valid **only inside `on_draw()`**, which fires after the widget tree renders (use it for overlays).
- The loop sleeps to hit `target_fps` (default 60).

### Widget system

Retained-mode tree of `DmWidget` (see `include/demod/widget.h`). Each widget is the base struct plus a `void *data` block owned by its concrete type, and a `const DmWidgetVT *vt` with `draw` / `event` / `layout` / `destroy` function pointers. Bounds are stored relative to parent (`bounds`) and resolved to `abs_bounds` by `dm_widget_compute_abs_bounds`. Layout types: `NONE` (manual), `VBOX`, `HBOX`, `GRID`. A widget with 0 width/height is only auto-sized if its parent has a layout set — otherwise it is invisible.

Core widgets (panel, label, button, slider, toggle, text_input, progress) are in `widgets.c`. DSP widgets (knob, vu_meter, waveform, dropdown, scroll_panel, xy_pad) are in `dsp_widgets.c`. The framebuffer exposes more than rectangles: triangles (incl. gradient), **Sierpinski fractals** (`dm_fb_sierpinski`, `_glow`), thick lines, arrows, and beziers — these power `systems_viz.lua`.

### Lua bridge

`dm_lua_register` (bottom of `lua_bindings.c`) builds the global `dm` table from `dm_funcs`, the `dm.draw` subtable from `draw_funcs`, and the `dm.color` palette. The `DmApp*` is stashed in the Lua registry and retrieved via `get_app(L)`. Widgets created from Lua hold a `lua_ref`; C-side callbacks (`on_click`, `on_change`) route back into Lua through `lua_callback_trampoline`.

## Adding a new widget (full path)

A widget is not usable from Lua until all of these are done:

1. **Declare** the data struct + `dm_<name>_create()` and accessors in `include/demod/widget.h`.
2. **Implement** the vtable (`draw`, optional `event`/`layout`/`destroy`) and constructor in `src/widgets/widgets.c` or `src/widgets/dsp_widgets.c`. Drawing must go through `dm_fb_*` primitives and read colors from the passed `DmTheme`.
3. **Bind** it: add an `l_<name>` constructor function and an entry in the `dm_funcs[]` table in `src/lua/lua_bindings.c` (and any methods to `widget_methods[]`).
4. If you created a new `.c` file, add it to `SRCS` in the Makefile.

## Visual identity (must be followed)

DeMoD apps use a fixed "oscilloscope phosphor on CRT glass" palette — dark backgrounds, glowing accents. The canonical colors are defined three places that must stay in sync: C macros in `framebuffer.h` (`DM_TURQUOISE` etc.), the `DmTheme` returned by `dm_theme_default()`, and the `dm.color` table in `lua_bindings.c`.

| Token | Hex | Usage |
|-------|-----|-------|
| Turquoise | `#00F5D4` | primary accent, data flow, active |
| Violet | `#8B5CF6` | secondary accent, control flow, headers |
| Deep Black | `#0A0A0F` | background |
| Dark Gray | `#1A1A2E` | panel backgrounds |
| Mid Gray | `#2A2A3E` | borders, tracks |
| White | `#E8E8F0` | primary text |
| Red `#FF4C6A` · Green `#4CFF82` · Yellow `#FFD94C` | | error · success · warning |

## Reference

`SKILL.md` is an in-repo authoring guide with the full Lua API reference, copy-paste patterns (minimal app, DSP panel, Sierpinski drawing, layouts), and a "Common Mistakes" list — consult it when writing or reviewing Lua apps. `README.md` covers the same API at a higher level.
