---
name: demod-ui
description: "Use this skill when creating applications, visualizations, GUIs, DSP interfaces, or interactive tools using the DeMoD UI framework (SDL2/framebuffer + Lua). Triggers: any request involving DeMoD, DeMoD UI, DeMoD widgets, Sierpinski rendering, DeMoD-style oscilloscope aesthetics, framebuffer-based GUIs, Lua widget scripting, or building interfaces for embedded Linux panels, kiosks, and instruments. Also use when extending the framework with new widgets, primitives, or Lua bindings. Do NOT use for general SDL2 or Lua questions unrelated to this framework."
---

# DeMoD UI Framework

Pure software-rendered SDL2 GUI framework with Lua widget scripting. Designed for embedded Linux panels, kiosks, and instruments; the same scripts also run on desktop.

## Architecture

```
┌──────────────────────────────────────────┐
│  Lua Scripts (app logic, widget defs)    │  ← You write this
├──────────────────────────────────────────┤
│  Lua Bindings (dm.* API)                 │  ← lua_bindings.c
├──────────────────────────────────────────┤
│  Widget System (retained tree, events)   │  ← widgets.c, dsp_widgets.c
├──────────────────────────────────────────┤
│  Framebuffer (primitives, font, blit)    │  ← framebuffer.c, font.c
├──────────────────────────────────────────┤
│  SDL2 (window, input, texture present)   │  ← app.c
└──────────────────────────────────────────┘
```

**No GPU. No shaders.** The framebuffer is a `uint32_t*` ARGB8888 pixel buffer. All drawing is scanline-by-scanline in C. SDL2 is used only for windowing, input, and blitting the final buffer via a streaming texture.

## Design Language

The DeMoD visual identity must be followed in all applications:

| Token | Value | Usage |
|-------|-------|-------|
| Turquoise | `#00F5D4` / `rgb(0,245,212)` | Primary accent, data flow, active states |
| Violet | `#8B5CF6` / `rgb(139,92,246)` | Secondary accent, control flow, headers |
| Deep Black | `#0A0A0F` | Background |
| Dark Gray | `#1A1A2E` | Panel backgrounds |
| Mid Gray | `#2A2A3E` | Borders, tracks |
| White | `#E8E8F0` | Primary text |
| Red | `#FF4C6A` | Errors, destructive |
| Green | `#4CFF82` | Success, active status |
| Yellow | `#FFD94C` | Warnings, in-progress |

Aesthetic: oscilloscope phosphor on CRT glass. Dark backgrounds, glowing accents, monospace type.

## Building

### Nix (recommended)
```bash
nix develop    # enter dev shell with SDL2, Lua 5.4, GCC, GDB, Valgrind
make           # build
make run       # run examples/hello.lua
make run-viz   # run the systems visualizer example
```

### Manual
Requires: SDL2, Lua 5.4, pkg-config, GCC/Clang.
```bash
make
./demod-ui examples/hello.lua
./demod-ui path/to/your/app.lua
```

## Lua API Reference

Every DeMoD application is a Lua script. The framework loads it, creates the root widget, and calls your `on_update(dt)` and `on_draw()` callbacks each frame.

### Application Lifecycle

```lua
-- These globals are called by the framework if defined:
function on_update(dt)   -- called every frame with delta time (seconds)
function on_draw()       -- called after widget tree draw (for custom overlays)
function on_nav(action)  -- "prev"|"next"|"activate"|"back"|"tab"|"tab_prev"|"wet"
function on_midi(status, d1, d2)  -- one parsed MIDI message (see MIDI input below)
```

### Input → one focus field
Every input source funnels into `on_nav(action)`: keyboard, USB serial encoder
(`DEMOD_ENCODER=`, `src/input/serial_encoder.c`), and **game controllers** (SDL
GameController, `src/input/gamepad.c`, auto-detected; `DEMOD_GAMEPAD=0` disables).
Default controller map: A=`activate`, B=`back`, X=`wet`; D-pad ▲/▼ + left stick = `prev`/`next`
(held repeats so values scrub + accelerate, following whatever button is bound to move); D-pad
◄/► + LB/RB = `tab_prev`/`tab`. Held keyboard ◄/►/▲/▼ also repeats `prev`/`next`. Remap at runtime
with `dm.gamepad_map(button, action)` (SDL button name → action string, `"none"` unbinds) — e.g.
a controller-remap settings page. (SDL enumerates controllers only under a real video driver, not
`SDL_VIDEODRIVER=dummy`.)

### MIDI input/output (`src/input/midi_input.c`)
Raw MIDI (running-status aware) is parsed in C and delivered to the global
`on_midi(status, d1, d2)`. Transport real-time bytes are forwarded as messages with `d1=d2=0`
(clock `0xF8`, start `0xFA`, continue `0xFB`, stop `0xFC`); other real-time/sysex are filtered.
Channel-voice consumers that mask `status & 0xF0` harmlessly ignore the `0xF0`-nibble transport bytes.

```lua
dm.midi_open(path)        -- add an input (ALSA rawmidi /dev/snd/midiC1D0, FIFO, or file). Idempotent;
                          --   up to 8 open at once. DEMOD_MIDI=a,b auto-opens (comma-separated).
dm.midi_close([path])     -- close one input by path, or ALL when omitted.
dm.midi_list()            -- → { {id="/dev/snd/midiC1D0", name="Arturia KeyStep"}, ... } (enumerate).
dm.midi_out_open(path)    -- open the optional output (controller LED feedback). DEMOD_MIDI_OUT= too.
dm.midi_send(status,d1,d2)-- send a raw message on the output (no-op without one).
```

The application layer wraps all of this in a shared **`midi/` subsystem** (one router owning
`on_midi`, with subscribe/clock/CC-learn/mapping) — apps subscribe rather than define `on_midi`.

### Widget Constructors

All constructors return a widget userdata with methods.

| Constructor | Returns | Notes |
|-------------|---------|-------|
| `dm.panel(id)` | container widget | Background + border, clips children |
| `dm.label(id, text)` | text display | Left/center/right align |
| `dm.button(id, text)` | clickable button | Hover/press states, `on_click` |
| `dm.slider(id, min, max, value)` | horizontal slider | `on_change`, `get_value()` |
| `dm.knob(id, label, min, max, value)` | rotary control | Vertical drag, scroll wheel |
| `dm.toggle(id, initial)` | on/off switch | `get_value()` returns bool |
| `dm.text_input(id, placeholder)` | text field | Cursor, backspace, arrows |
| `dm.progress(id, value)` | progress bar | 0.0–1.0 |
| `dm.vu_meter(id, channels)` | level meter | Peak hold, segmented |
| `dm.waveform(id, num_samples)` | oscilloscope | Ring buffer, zoom |
| `dm.dropdown(id, placeholder)` | select menu | `add_item()`, scrollable |
| `dm.xy_pad(id)` | 2D control surface | Trail history, crosshair |
| `dm.scroll_panel(id, content_w, content_h)` | scrollable container | Vertical scrollbar |

### Widget Methods

```lua
widget:set_bounds(x, y, w, h)              -- position relative to parent
widget:set_layout("vbox"|"hbox"|"grid", spacing, padding, cols)
widget:add_child(child)                     -- add to widget tree
widget:on_click(function(w) ... end)        -- click callback
widget:on_change(function(w) ... end)       -- value change callback
widget:set_text(text)                       -- label, button, text_input
widget:get_value()                          -- slider→number, toggle→bool, text_input→string
widget:set_value(v)                         -- slider, toggle, progress, knob
widget:set_bg(r, g, b [, a])               -- panel, button background
widget:set_fg(r, g, b [, a])               -- label, button text color
widget:show() / widget:hide()
widget:enable() / widget:disable()
widget:id()                                 -- returns the widget's id string
-- DSP widget methods:
widget:add_item(text)                       -- dropdown
widget:set_level(channel, level)            -- vu_meter (0.0–1.0)
widget:vu_update(dt)                        -- vu_meter peak decay
widget:push_sample(sample)                  -- waveform ring buffer
widget:set_format(fmt)                      -- knob printf format (e.g. "%.1f Hz")
widget:get_xy() → x, y                     -- xy_pad (returns two values)
widget:set_xy(x, y)                         -- xy_pad
widget:clear()                              -- waveform or dropdown
```

### Application State

```lua
dm.root()              -- returns the root widget (always a panel)
dm.find(id)            -- find widget by id in tree, or nil
dm.redraw()            -- request frame redraw
dm.quit()              -- exit the application
dm.time()              -- elapsed time in seconds (float)
dm.dt()                -- delta time of current frame
dm.mouse_x()           -- current mouse X position
dm.mouse_y()           -- current mouse Y position
dm.width()             -- framebuffer width
dm.height()            -- framebuffer height
```

### Drawing API (`dm.draw.*`)

Called from `on_draw()` to render custom overlays on top of the widget tree.

#### Basic Primitives
```lua
dm.draw.rect(x, y, w, h, r, g, b [, a])
dm.draw.circle(cx, cy, radius, r, g, b [, a])
dm.draw.line(x0, y0, x1, y1, r, g, b [, a])
dm.draw.text(x, y, string, r, g, b [, a])
dm.draw.gradient_v(x, y, w, h, r1,g1,b1, r2,g2,b2)
```

#### Triangles
```lua
dm.draw.triangle(x0,y0, x1,y1, x2,y2, r,g,b [,a])         -- filled
dm.draw.stroke_triangle(x0,y0, x1,y1, x2,y2, r,g,b [,a])   -- outline
```

#### Sierpinski Fractals
```lua
-- Table-based color API:
dm.draw.sierpinski(x0,y0, x1,y1, x2,y2, depth, {fill_r,g,b[,a]}, {stroke_r,g,b[,a]})
dm.draw.sierpinski_glow(x0,y0, x1,y1, x2,y2, depth, {fill}, {stroke}, {glow}, glow_radius)
-- depth: recursion depth (1-8, clamped)
-- glow_radius: number of concentric glow outlines
```

#### Lines & Arrows
```lua
dm.draw.thick_line(x0,y0, x1,y1, thickness, r,g,b [,a])
dm.draw.arrow(x0,y0, x1,y1, head_size, thickness, r,g,b [,a])
dm.draw.bezier(x0,y0, cx0,cy0, cx1,cy1, x1,y1, segments, r,g,b [,a])
dm.draw.arrow_bezier(x0,y0, cx0,cy0, cx1,cy1, x1,y1, segments, head_size, thickness, r,g,b [,a])
```

### Color Constants

```lua
dm.color.turquoise   -- {0x00, 0xF5, 0xD4}
dm.color.violet      -- {0x8B, 0x5C, 0xF6}
dm.color.black       -- {0x0A, 0x0A, 0x0F}
dm.color.dark_gray   -- {0x1A, 0x1A, 0x2E}
dm.color.white       -- {0xE8, 0xE8, 0xF0}
dm.color.red         -- {0xFF, 0x4C, 0x6A}
dm.color.green       -- {0x4C, 0xFF, 0x82}
dm.color.yellow      -- {0xFF, 0xD9, 0x4C}
```

## Patterns

### Minimal Application

```lua
local root = dm.root()
root:set_layout("vbox", 8, 16)

local label = dm.label("title", "Hello, DeMoD!")
label:set_fg(0x00, 0xF5, 0xD4)
label:set_bounds(0, 0, 0, 40)
root:add_child(label)

local btn = dm.button("go", "Click Me")
btn:set_bounds(0, 0, 200, 36)
btn:on_click(function(w)
    dm.find("title"):set_text("Clicked!")
    dm.redraw()
end)
root:add_child(btn)
```

### DSP Control Panel

```lua
-- Knob bank with value readout
local knob = dm.knob("freq", "Frequency", 20, 20000, 440)
knob:set_format("%.0f Hz")
knob:set_bounds(0, 0, 80, 100)
knob:on_change(function(w)
    dm.find("readout"):set_text(string.format("%.0f Hz", w:get_value()))
    dm.redraw()
end)
panel:add_child(knob)

-- VU meter with simulated levels
local vu = dm.vu_meter("output", 2)
vu:set_bounds(0, 0, 40, 120)
panel:add_child(vu)

function on_update(dt)
    vu:set_level(0, 0.5 + 0.3 * math.sin(dm.time() * 2))
    vu:set_level(1, 0.5 + 0.3 * math.cos(dm.time() * 2))
    vu:vu_update(dt)
    dm.redraw()
end
```

### Custom Drawing with Sierpinski

```lua
function on_draw()
    -- Gradient header bar
    dm.draw.gradient_v(0, 0, dm.width(), 3,
        0x00, 0xF5, 0xD4,   -- turquoise
        0x8B, 0x5C, 0xF6)   -- violet

    -- Glowing Sierpinski fractal
    local cx = dm.width() / 2
    dm.draw.sierpinski_glow(
        cx, 100,               -- apex
        cx - 120, 300,         -- bottom-left
        cx + 120, 300,         -- bottom-right
        3,                     -- depth
        {10, 20, 30, 200},     -- fill (dark)
        {0, 245, 212, 255},    -- stroke (turquoise)
        {0, 245, 212, 255},    -- glow color
        8)                     -- glow radius

    -- Arrow connecting two points
    dm.draw.arrow_bezier(
        100, 200,              -- start
        200, 150, 300, 250,    -- control points
        400, 200,              -- end
        24,                    -- bezier segments
        8,                     -- arrowhead size
        2,                     -- line thickness
        0x8B, 0x5C, 0xF6, 180) -- violet, semi-transparent
end
```

### Layout System

```lua
-- Vertical stack
panel:set_layout("vbox", 6, 8)    -- spacing=6, padding=8

-- Horizontal row
row:set_layout("hbox", 4, 4)

-- Grid (auto-columns)
grid:set_layout("grid", 4, 8, 3)  -- spacing=4, padding=8, columns=3

-- Children with height=0 get auto-sized by the layout.
-- Set explicit bounds when you need fixed sizing.
```

## C API (for extending the framework)

### Custom Widgets

Implement the `DmWidgetVT` vtable:

```c
static void my_draw(DmWidget *w, DmFramebuffer *fb, const DmTheme *theme) {
    dm_fb_fill_rounded_rect(fb, w->abs_bounds, 8, DM_TURQUOISE);
    dm_fb_draw_text_centered(fb, theme->font, w->abs_bounds, "Custom", DM_BLACK);
}

static bool my_event(DmWidget *w, DmEvent *e) {
    if (e->type == DM_EVENT_MOUSE_DOWN) {
        if (w->on_click) w->on_click(w, w->userdata);
        return true;
    }
    return false;
}

static const DmWidgetVT my_vt = {
    .type_name = "my_widget",
    .draw      = my_draw,
    .event     = my_event,   // optional
    .layout    = NULL,       // optional
    .destroy   = NULL,       // optional
};

DmWidget *my_widget_create(const char *id) {
    DmWidget *w = dm_widget_create(&my_vt, id);
    w->bounds.h = 40;
    w->flags |= DM_WIDGET_FOCUSABLE;
    return w;
}
```

### Framebuffer Primitives (C)

```c
// Lifecycle
DmFramebuffer *dm_fb_create(int w, int h);
void dm_fb_destroy(DmFramebuffer *fb);

// Basics
void dm_fb_clear(DmFramebuffer *fb, DmColor c);
void dm_fb_fill_rect(DmFramebuffer *fb, DmRect r, DmColor c);
void dm_fb_fill_rounded_rect(DmFramebuffer *fb, DmRect r, int radius, DmColor c);
void dm_fb_fill_circle(DmFramebuffer *fb, int cx, int cy, int radius, DmColor c);
void dm_fb_line(DmFramebuffer *fb, int x0, int y0, int x1, int y1, DmColor c);

// Triangles & Sierpinski
void dm_fb_fill_triangle(DmFramebuffer *fb, int x0,y0, x1,y1, x2,y2, DmColor c);
void dm_fb_sierpinski(DmFramebuffer *fb, int x0,y0, x1,y1, x2,y2,
                      int depth, DmColor fill, DmColor stroke);
void dm_fb_sierpinski_glow(DmFramebuffer *fb, int x0,y0, x1,y1, x2,y2,
                           int depth, DmColor fill, DmColor stroke,
                           DmColor glow, int glow_radius);

// Arrows & Curves
void dm_fb_thick_line(DmFramebuffer *fb, int x0,y0, x1,y1, int thickness, DmColor c);
void dm_fb_arrow(DmFramebuffer *fb, int x0,y0, x1,y1,
                 int head_size, int thickness, DmColor c);
void dm_fb_bezier(DmFramebuffer *fb, int x0,y0, cx0,cy0, cx1,cy1, x1,y1,
                  int segments, DmColor c);
void dm_fb_arrow_bezier(DmFramebuffer *fb, int x0,y0, cx0,cy0, cx1,cy1, x1,y1,
                        int segments, int head_size, int thickness, DmColor c);

// Gradients
void dm_fb_fill_rect_gradient_v(DmFramebuffer *fb, DmRect r, DmColor top, DmColor bot);

// Text
void dm_fb_draw_text(DmFramebuffer *fb, const DmFont *f, int x, int y,
                     const char *text, DmColor fg);
void dm_fb_draw_text_centered(DmFramebuffer *fb, const DmFont *f,
                              DmRect bounds, const char *text, DmColor fg);
```

### Color Macros (C)

```c
#define DM_TURQUOISE    dm_rgb(0x00, 0xF5, 0xD4)
#define DM_VIOLET       dm_rgb(0x8B, 0x5C, 0xF6)
#define DM_BLACK        dm_rgb(0x0A, 0x0A, 0x0F)
#define DM_WHITE        dm_rgb(0xE8, 0xE8, 0xF0)
// Also: DM_DARK_GRAY, DM_MID_GRAY, DM_LIGHT_GRAY, DM_RED, DM_GREEN, DM_YELLOW
```

### Exposing Custom Widgets to Lua

Register in `dm_lua_register()`:

```c
// Constructor
static int l_my_widget(lua_State *L) {
    const char *id = luaL_checkstring(L, 1);
    push_widget(L, my_widget_create(id));
    return 1;
}

// Add to dm_funcs table:
{"my_widget", l_my_widget},

// Add type-specific methods to widget_methods or handle in
// lw_get_value / lw_set_value via strcmp on vt->type_name.
```

## Project Structure

```
demod-ui/
├── include/demod/          # C headers
│   ├── framebuffer.h       # Drawing primitives (triangles, Sierpinski, arrows, bezier)
│   ├── font.h              # Bitmap font
│   ├── widget.h            # Widget system + all widget types
│   ├── app.h               # SDL2 app lifecycle + Lua host
│   └── demod_ui.h          # Umbrella header
├── src/
│   ├── core/framebuffer.c  # Software rasterizer (613 lines)
│   ├── core/font.c         # Embedded 8×16 CP437 bitmap font
│   ├── widgets/widgets.c   # Core widgets (panel, label, button, slider, toggle, text, progress)
│   ├── widgets/dsp_widgets.c # DSP widgets (knob, VU, waveform, dropdown, XY pad, scroll)
│   ├── lua/lua_bindings.c  # dm.* Lua API (806 lines)
│   ├── app/app.c           # SDL2 main loop, event pump, Lua host
│   └── main.c              # Entry point (loads Lua script from argv[1])
├── examples/
│   ├── hello.lua           # Minimal app
│   ├── dsp_panel.lua       # DSP control panel
│   ├── dsp_studio.lua      # Full studio (knobs, VU, waveform, XY pad)
│   └── systems_viz.lua     # systems visualizer example
├── Makefile
└── flake.nix
```

## Common Mistakes

1. **Forgetting `dm.redraw()`** — The framework only redraws when events occur or you explicitly request it. Call `dm.redraw()` at the end of `on_update()` if you have animations.
2. **Setting bounds to 0,0,0,0** — Children with width/height 0 get auto-sized by layout, but only if the parent has a layout set. Without a layout, 0-size widgets are invisible.
3. **Drawing outside `on_draw()`** — The `dm.draw.*` functions write directly to the framebuffer. Call them only from `on_draw()`, which fires after the widget tree renders.
4. **Sierpinski depth > 5** — Depth is clamped to 8 but performance drops fast. Use 2–4 for real-time, 5 for static renders. Adapt depth to zoom level for smooth interaction.
5. **Not setting `on_click` userdata** — The callback receives `(widget, userdata)`. For Lua closures this is handled automatically, but in C you must set `w->userdata` and `w->on_click`.
