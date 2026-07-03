# DeMoD UI

> A pure software-rendered GUI framework in C11 and Lua. No GPU. No web view. Every pixel drawn by hand.

![License: MPL-2.0](https://img.shields.io/badge/license-MPL--2.0-00F5D4.svg)
![C11](https://img.shields.io/badge/C-11-8B5CF6.svg)
![Lua 5.4](https://img.shields.io/badge/Lua-5.4-FFD94C.svg)
![GPU](https://img.shields.io/badge/GPU-none-FF4C6A.svg)
![deps](https://img.shields.io/badge/deps-SDL2%20only-4CFF82.svg)

DeMoD UI paints its own pixels. There is no OpenGL, no Vulkan, no shader, no browser engine hiding in the basement. The framebuffer is a flat `uint32_t*` of ARGB8888, and every rectangle, every glyph, every glowing scope trace gets rasterized one scanline at a time in plain C. SDL2 shows up for exactly three jobs: open a window, read input, blit the finished buffer. That is the whole contract with the outside world.

You script the interface in Lua. The same script runs on a 320 pixel panel wired inside a guitar and on a 1080p desktop, because this thing was built to survive on hardware that has no business running a GUI.

This is the open foundation. It is the renderer and the widget layer underneath DeMoD's instruments, carved out and licensed so you can build your own thing on it.

## Why this exists

Modern UI got heavy. A button should not need a 200MB runtime, a compositor, and three layers of abstraction to light up. Embedded panels, kiosks, instruments, and weird little screens deserve software that respects the silicon.

So the rules here are simple:

- **No GPU.** Everything is CPU rasterization. It runs the same on a board with no graphics driver and on your workstation.
- **One real dependency.** SDL2 for the window and input. Lua 5.4 for scripting. That is it.
- **Deterministic and small.** Software rendering with a fixed font and integer math. What you draw is what you get, frame after frame.
- **Phosphor on glass.** Scope traces, CRT glow, and Sierpinski geometry, faked with stacked primitives because there is no shader to do it for you. The look is a side effect of the constraints, and it owns it.

If you have ever wanted to write a real interface the way you write a demo, this is for you.

## Quickstart

```bash
nix develop          # drop into the dev shell (SDL2, Lua, toolchain)
make                 # build ./demod-ui
make run             # hello world
```

No Nix? You need SDL2, Lua 5.4, pkg-config, and a C compiler:

```bash
make
./demod-ui examples/hello.lua
```

A minimal app is a Lua script. The framework hands you a root widget; you hang things off it:

```lua
local root = dm.root()
root:set_layout("vbox", 16, 32)

local label = dm.label("hi", "Hello, world!")
label:set_fg(0x00, 0xF5, 0xD4)
root:add_child(label)

local btn = dm.button("go", "Click Me")
btn:on_click(function() dm.find("hi"):set_text("clicked"); dm.redraw() end)
root:add_child(btn)
```

Run any script by passing it as `argv[1]`:

```bash
./demod-ui path/to/your_app.lua
```

## The Lua API

### Widgets

```lua
dm.panel(id)                       -- container
dm.label(id, text)                 -- text
dm.button(id, text)                -- clickable
dm.slider(id, min, max, value)     -- value slider
dm.toggle(id, initial)             -- on/off
dm.text_input(id, placeholder)     -- text field
dm.progress(id, value)             -- progress bar
dm.control(id)                     -- encoder-native card list (great for knob-only UIs)
dm.viz(id)                         -- layered node-graph for diagrams
```

```lua
widget:set_bounds(x, y, w, h)
widget:set_layout("vbox" | "hbox" | "grid", spacing, padding, cols)
widget:add_child(child)
widget:on_click(fn) / widget:on_change(fn)
widget:set_text(s) / widget:get_value() / widget:set_value(v)
widget:set_bg(r, g, b [, a]) / widget:set_fg(r, g, b [, a])
widget:show() / widget:hide() / widget:enable() / widget:disable()
```

### Application

```lua
dm.root()        -- the root widget
dm.find("id")    -- look up a widget
dm.redraw()      -- request a frame
dm.quit()        -- exit
dm.time()        -- seconds since start
dm.dt()          -- delta time
```

### Drawing straight to the framebuffer

Valid inside the `on_draw` overlay pass. This is where the phosphor lives.

```lua
dm.draw.rect(x, y, w, h, r, g, b [, a])
dm.draw.circle(cx, cy, radius, r, g, b [, a])
dm.draw.line(x0, y0, x1, y1, r, g, b [, a])
dm.draw.text(x, y, "string", r, g, b [, a])
dm.draw.gradient_v(x, y, w, h, r1,g1,b1, r2,g2,b2)
```

### Callbacks

```lua
function on_update(dt)   -- every frame, with delta time
function on_draw()       -- after the widget tree, for overlays
```

### Palette

A built-in set of color constants. They are just colors. Use them, ignore them, or bring your own.

```lua
dm.color.turquoise   -- {0x00, 0xF5, 0xD4}
dm.color.violet      -- {0x8B, 0x5C, 0xF6}
dm.color.black       -- {0x0A, 0x0A, 0x0F}
dm.color.white       -- {0xE8, 0xE8, 0xF0}
dm.color.red         -- {0xFF, 0x4C, 0x6A}
dm.color.green       -- {0x4C, 0xFF, 0x82}
dm.color.yellow      -- {0xFF, 0xD9, 0x4C}
```

## How it fits together

```
+--------------------------------------------+
|  Lua scripts (widgets, logic, drawing)     |
+--------------------------------------------+
|  Lua bindings (the dm.* API)               |
+--------------------------------------------+
|  Widget system (retained tree, events)     |
+--------------------------------------------+
|  Framebuffer (primitives, blitting, font)  |
+--------------------------------------------+
|  SDL2 (window, input, present)             |
+--------------------------------------------+
```

The framebuffer is a `uint32_t*` ARGB8888 buffer. Drawing is scanline math in C. Text is a fixed 8x16 bitmap font; ASCII 32 to 126 is compiled in, and all other Unicode is handled by an optional glyph blob (see *International text* below). There is no clip region and no rounded-rect in hardware, so effects like glow and frosted glass are stacked low-alpha primitives. The constraints are the aesthetic.

## International text (UTF-8 / CJK)

Strings are UTF-8 everywhere. ASCII renders from the compiled-in 8x16 face with no
setup. Everything beyond ASCII — Latin-extended, Greek, Cyrillic, CJK, …— renders from
a runtime glyph blob built from [GNU Unifont](https://unifoundry.com/unifont/) (OFL-1.1),
with halfwidth (8px) and fullwidth (16px) advances. `dm.draw.text` / `dm.draw.text_width`
are codepoint-correct; missing glyphs draw a tofu box.

```bash
make font          # fetch Unifont + build the full-BMP blob -> ~/.local/share/demod/unifont.dmf
make font-subset   # smaller: Latin/Greek/Cyrillic + CJK only
```

The engine looks for the blob at `$DEMOD_FONT`, then `~/.local/share/demod/unifont.dmf`,
then `./unifont.dmf`; without one, non-ASCII degrades to tofu boxes. Prebuilt `unifont.dmf`
blobs are attached to releases.

## Audio stack (optional)

`audio-stack/` holds a real-time audio backend the framework can drive over a socket +
shared memory: **demod-rt** (a C JACK engine) and **demod-orchestrator** (a Haskell
supervisor). They are **separate programs** — the framework does not depend on them, and
they run headless without any UI. They are **GPLv3-only OR commercial**, a different
license from the MPL framework; see `audio-stack/README.md` and `LICENSING.md`.

## Remote engine over UDP (DCF / HydraMesh, optional)

By default the UI and engine share a machine (local socket + `/dev/shm`). They can also be
**split across a network** — engine on a VM or a wired offloader, UI on your workstation —
over UDP via [HydraMesh](https://github.com/ALH477/HydraMesh)'s DCF protocol. The engine is
**unmodified**; two small pieces carry it:

- `dm.dcf` — a UDP client binding in the framework, built with **`make DCF=1`** (opt-in; the
  default build is unchanged and stays MPL). Flake output `demod-ui-dcf`.
- `demod-remote-bridge` (`audio-stack/bridge/`) — an engine-side relay: DCF control ops →
  the local control socket, and the meters shm → DCF telemetry. Flake output `demod-remote-bridge`.

These + the vendored codecs (`third_party/hydramesh/`) are **LGPL-3.0**. A headless
end-to-end proof is `audio-stack/bridge/test/loopback.sh` (drives `examples/dcf_loopback.lua`).

## Examples

```bash
make run            # examples/hello.lua          minimal panel, label, button
make run-launcher   # examples/card_launcher.lua  encoder-native card list (dm.control)
make run-dsp        # examples/dsp_panel.lua       every built-in widget in one panel
make run-studio     # examples/dsp_studio.lua      knobs, VU, waveform, XY pad
make run-viz        # examples/systems_viz.lua     layered node-graph (dm.viz)
```

Copy one and start editing. That is the intended workflow.

## Custom widgets in C

The C API is open for embedding and extending. Include `<demod/demod_ui.h>`, link the framework, and implement the `DmWidgetVT` vtable:

```c
static void my_draw(DmWidget *w, DmFramebuffer *fb, const DmTheme *theme) {
    dm_fb_fill_rounded_rect(fb, w->abs_bounds, 8, DM_TURQUOISE);
}

static const DmWidgetVT my_widget_vt = {
    .type_name = "my_widget",
    .draw      = my_draw,
    .event     = my_event,  /* optional */
};

DmWidget *my_widget_create(const char *id) {
    return dm_widget_create(&my_widget_vt, id);
}
```

## Layout

```
demod-ui/                 # the framework — MPL-2.0
  include/demod/          public headers (framebuffer, widget, font, app, dm.* surface)
  src/
    core/                 rasterizer + the embedded 8x16 font + UTF-8/Unifont loader
    widgets/              built-in widgets + DSP widgets (knob, VU, waveform, XY pad)
    lua/                  the dm.* Lua bindings
    app/                  SDL2 main loop + event pump
    main.c                entry point
  examples/               start here
  tools/genfont.py        builds the Unifont glyph blob (make font)
  tests/                  UTF-8 font tests (make test)
  Makefile  flake.nix
  audio-stack/            optional real-time audio backend — GPLv3/commercial (see LICENSING.md)
    rt-audio/             demod-rt engine (C, JACK)
    orchestrator/         demod-orchestrator (Haskell)
    ipc/                  shared-memory + control-socket contract
```

## Contributing

Pull requests welcome. We use the Developer Certificate of Origin, so sign off your commits:

```bash
git commit -s
```

By contributing you agree your work ships under the project license (MPL-2.0, inbound equals outbound). No CLA, no copyright assignment. Keep the SPDX header on new source files, and do not relicense vendored code. See `CONTRIBUTING.md`.

## License

This repo has **two independently-licensed parts** — full details in `LICENSING.md`:

- **The framework** (everything except `audio-stack/`) is the **Mozilla Public License,
  v. 2.0** (`LICENSE`, SPDX `MPL-2.0`). File-level copyleft: drop it into a larger work
  alongside proprietary code; changes to MPL-covered files stay MPL. **Using only the
  framework never involves the GPL below.**
- **The audio stack** (`audio-stack/`) is **GPLv3-only OR commercial** (dual;
  `audio-stack/LICENSE`). It's a *separate program* (socket/shm IPC), so it doesn't
  relicense the framework.

Third-party components keep their own licenses (see `THIRD_PARTY_LICENSES.md`).

Build whatever you want on the framework, open or closed. That is the point.

## Brand and trade dress

The code is open. The brand is not. The MPL grants no rights to trademarks or trade dress (MPL-2.0 §2.3).

**"DeMoD" and "TERMINUS"** are trademarks of DeMoD LLC. The distinctive assembled look-and-feel of DeMoD's products (the oscilloscope-phosphor palette plus CRT treatment plus the Sierpinski-glow identity, taken as a whole) is reserved trade dress. Use the framework freely and make your own look from the generic primitives. Do not reuse the DeMoD or TERMINUS names, or reproduce DeMoD's assembled identity, to brand your product or imply endorsement. Details in `TRADEMARK.md`.

(c) 2026 DeMoD LLC.
