# DeMoD UI — Roadmap

A living, non-binding list of directions for the framework. Contributions welcome
(see `CONTRIBUTING.md`); nothing here is a promise or a schedule.

## Shipped

- **Software renderer** — scanline ARGB8888 rasterizer: rects, lines, thick lines,
  circles, triangles, gradients, bezier, arrows, blit, and the Sierpinski primitive.
- **Widget layer** — panel, label, button, slider, toggle, text input, progress,
  knob, VU meter, waveform, dropdown, scroll panel, XY pad.
- **Two declarative DSLs** — `dm.viz` (layered node-graph diagrams with focus ring,
  camera/zoom, typed connections, detail panels) and `dm.control` (encoder-native
  card menus). Shared item model; self-contained focus (`focus_next/prev/activate`).
- **Input funnel** — one focus field fed by keyboard, mouse/touch, serial rotary
  encoder, SDL game controllers, and MIDI; the same script runs on a 320px panel and
  a 1080p desktop.
- **Lua 5.4 scripting** — the full `dm.*` API (see `SKILL.md`).
- **UTF-8 / international text** — codepoint-correct draw + measure, variable advance
  (8px halfwidth / 16px fullwidth CJK), runtime Unifont glyph blob (`tools/genfont.py`,
  `make font`), with a compiled-in ASCII fast path.
- **IPC + audio hooks** — shared-memory param/meter buses and a control-socket client
  for driving an external real-time audio engine (see `audio-stack/`).

## Under consideration

- A real 6×10 small font (`dm_font_small()` currently aliases the 8×16 face).
- Additional widgets (tabs, tables, modal/dialog helpers) driven by real use.
- Bidirectional/RTL text shaping (the cell renderer is LTR-only today).
- Clipping regions / scissor rects as first-class primitives.
- A C-side global focus manager (focus is per-widget by design for now).
- Broader platform coverage beyond Linux + SDL2.

## Non-goals

- GPU acceleration (the point is a pure CPU rasterizer).
- Rounded rectangles / anti-aliased vector fonts.
- A retained web/DOM port.
