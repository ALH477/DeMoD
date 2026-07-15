<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0 -->
# SNAKE

A **source-available** TERMINUS arcade app-patch (PolyForm Shield 1.0.0) — the classic, on the demod-ui engine. Eat food to
grow; hit a wall or yourself and the run ends.

```bash
~/demod-ui/demod-ui patches/demod-snake/main.lua
```

## Controls (relative steering)

| Action | Effect |
|--------|--------|
| `prev` | turn **left** |
| `next` | turn **right** |
| `activate` | start (title) · retry (game over) |
| `back` | exit to TERMINUS (title) · abort to title (playing) |

Relative steering means two buttons are enough — it plays perfectly on the encoder. The
snake speeds up as it grows. Best score persists at `~/.config/demod/games/demod-snake.lua`.

## Why the fixed timestep

Movement runs on an accumulator (`acc += dt; while acc >= STEP do step() end`) so the snake
advances at a constant rate regardless of frame-rate or vsync jitter — deterministic
stepping decoupled from rendering. No audio dependency; runs headless.

Shared draw/save helpers are bundled in the patch directory.

© 2026 DeMoD LLC.
