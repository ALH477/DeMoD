<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0 -->
# PITCH RUNNER

A **free** TERMINUS app-patch: a Beat-Saber × Guitar-Hero note highway built to **teach a
real instrument**. Notes fly down toward a hit-line and a bottom **target view** (keyboard
or fretboard) shows exactly where to play the next one. Pick any instrument — hits are
graded on **pitch**, so it's instrument-agnostic.

```bash
~/demod-ui/demod-ui patches/demod-pitch-runner/main.lua
```

## Two ways to play (auto-selected)

| Mode | Where | How you hit |
|------|-------|-------------|
| **PERFORM** | demod5 device (pitch detector) | **Play the note on your instrument.** Graded on timing AND in-tune accuracy (cents). Monophonic, single-note lines. |
| **PRACTICE** | desktop / headless / no input | Move the cursor to the lit target and press `activate`. Graded on timing. Works everywhere. |

The game watches the pitch detector; if it sees your instrument it offers PERFORM, otherwise
it stays in PRACTICE. `tab` toggles between them during play.

## Controls

| Action | Menu | Playing |
|--------|------|---------|
| `tab` / `tab_prev` | move between rows | toggle PERFORM/PRACTICE |
| `prev` / `next` | change the selected row | move the note cursor (PRACTICE) |
| `activate` | start | strike the cursor's note (PRACTICE) |
| `wet` (X) | — | cycle notation |
| `back` | exit to TERMINUS | back to menu |

## Notation

Notes are labelled in your chosen notation everywhere they appear (the NEXT readout, each
falling note, the target view). Pick it on the menu's **NOTATION** row, or cycle it live in
play with `wet`. The choice persists.

| Mode | Looks like | Notes |
|------|-----------|-------|
| **Tab** | `E:3` | open-string letter + fret (string instruments). Falls back to note names on piano/voice/wind. |
| **Notes** | `C4` | letter + octave (scientific pitch; middle C = C4). |
| **Staff** | ♪ on a treble staff | a mini 5-line staff with the note drawn on it (ledger lines + sharps). |

Pick an **instrument** (guitar, bass, ukulele, violin, piano, voice, flute), a **drill**
(scale lines, generated and instrument-aware) or a **riff** (a real melody like Ode to Joy,
transposed into the instrument's range), and a **difficulty** (tempo + density). On drills,
each note is previewed audibly as it appears so you learn it by ear too.

Best score persists per instrument + content at `~/.config/demod/games/`.

## Files

- `main.lua` — UI + game state (highway, dual-mode input, grading, count-in, menu).
- `instruments.lua` — **pure** instrument profiles (tunings/ranges) + fret math.
- `track.lua` — **pure** chart generation (scale- and range-constrained) + timing/cents judge.
- `view.lua` — the keyboard + fretboard target widget.
- `songs.lua` — drill catalogue + authored riffs.
- Music theory (`cents_off`, scales, note names) is reused from `../demod-learn/theory.lua`;
  shared draw/sound/save helpers from `../games/gamekit.lua`.

Run the logic tests: `~/demod-ui/demod-ui patches/demod-pitch-runner/selftest.lua`

> PERFORM (real-pitch grading) requires the on-device orchestrator's pitch detector and is
> monophonic; chords aren't graded. Everywhere else the game runs fully in PRACTICE.

© 2026 DeMoD LLC.
