<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0 -->
# RHYTHM RUNNER

A **free** TERMINUS arcade app-patch — the first game on the demod-ui engine. Notes
scroll down three lanes toward a hit-line; move the lane cursor and **strike on the
beat**. Clean hits play that lane's note through the synth, so good play *is* music.

Open it from the **patches grid (page 2)** on the home shell, or run it directly:

```bash
~/demod-ui/demod-ui patches/demod-rhythm/main.lua
```

## Controls (the standard focus-field vocabulary — encoder / gamepad / keyboard)

| Action | Title | Playing |
|--------|-------|---------|
| `prev` / `next` | change difficulty | move lane cursor (wraps) |
| `activate` | start | **strike** the cursor's lane |
| `tab` | cycle difficulty | — |
| `back` | exit to TERMINUS | abort to title |

Three difficulties (EASY 90 / NORMAL 120 / HARD 150 BPM) change tempo and density.
Hits score **PERFECT** (≤45 ms) or **GOOD** (≤110 ms); consecutive hits build a combo
multiplier; a missed note breaks the combo. Your best score persists at
`~/.config/demod/games/demod-rhythm.lua`.

## Sound is optional

Strikes play through the shared `dsp/midi_input` bridge **when a synth voice is loaded**
(device orchestrator, or `nix run .#desktop`). With no voice it runs **visual-only** —
fully playable, just silent — so it loads anywhere, including headless.

## Layout

- `main.lua` — the game (UI + state; one cursor, `back` returns/quits).
- `chart.lua` — pure beat-map generation + hit judging. No `dm.*`, so it unit-tests under
  the embedded interpreter (`selftest.lua`).
- Shared draw/sound/save helpers come from `../games/gamekit.lua`.

Run the logic tests: `~/demod-ui/demod-ui patches/demod-rhythm/selftest.lua`

© 2026 DeMoD LLC.
