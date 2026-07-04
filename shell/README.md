<!-- SPDX-License-Identifier: MPL-2.0 -->
# DeMoD companion-shell SDK

A small, reusable Lua SDK for building **surface-based companion-computer shells** on the DeMoD UI
framework — head units, ground stations, vehicle consoles, telemetry dashboards. It factors out the
parts every such shell shares (surface/tab manager, input funnel, config, theming, status/tab chrome,
a telemetry provider lifecycle, an optional DCF mesh link, and touch), so an app is just: **surfaces
+ a provider + a palette**. MPL-2.0. Used by [`../auto/`](../auto) (DeMoD Auto).

## An app in one call

```lua
local shell = dofile(os.getenv("DEMOD_SHELL_DIR") .. "shell.lua")
shell.run{
  title    = "My Console",
  palettes = { night = {...}, day = {...} },     -- your own look (see draw.lua colors are {r,g,b})
  config   = { path = "~/.config/demod/x.lua", keys = {"theme",...}, defaults = {...} },
  provider = function(cfg) return MyProvider.new(cfg) end,   -- object or factory(cfg)
  surfaces = { s1, s2, ... },
  status   = function(ctx) return "right-side status text" end,
  on_start = function(ctx) end,   -- e.g. spawn a helper process
}
```

## Contracts

**Surface** — a table `{ name, draw(ctx), nav?(action, ctx), zones?(ctx), update?(dt, ctx) }`:
- `draw(ctx)` renders in the area between the top status bar (40px) and the bottom tab bar (32px).
- `nav(action, ctx)` handles `prev`/`next`/`activate` (and any non-shell action); return true if handled.
- `zones(ctx)` returns touch hit-zones `{{x,y,w,h, on=function() ... end}, ...}` — the shell overlays
  transparent `dm.button`s over them (the tab bar is automatic).

**Provider** — `{ update(dt), status(), read() -> table }`. The common backend pattern is "a helper
process writes a `key=value` state file, the provider tails it with a freshness check, with a pure-Lua
simulator as the always-available fallback" (see `../auto/vehicle/telemetry.lua`).

**ctx** (built each frame) — `{ th (palette), W, H, U (draw helpers), cfg, save(), provider, data
(=provider:read()), dcf {available,status}, events, log(msg), active }`.

## Controls (the on_nav funnel)

`tab`/`tab_prev` switch surface · `back` → surface 1 · `wet` toggles day/night (or your `on_wet`) ·
everything else → the active surface's `nav`. Touch rides the zone overlay. `DEMOD_SURFACE=n`
deep-links a surface (handy for screenshots). Optional mesh: set `DEMOD_DCF_HOST`/`_PORT`.

## Files

`shell.lua` (runtime) · `draw.lua` (rect/panel/text/arc/needle/bar helpers, `ctx.U`) ·
`theme.lua` (day/night/auto resolve) · `touch.lua` (the invisible-`dm.button` overlay — the only
pointer path the framework offers a custom-drawn surface).

## Identity

Ship your **own** neutral palette — never the reserved DeMoD/TERMINUS phosphor trade dress. Apps talk
to the GPL engine only over IPC and use the LGPL `dm.dcf` as a runtime binding, so a shell app stays MPL.
