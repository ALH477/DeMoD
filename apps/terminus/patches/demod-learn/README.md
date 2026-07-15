<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0 -->
# LEARN — music from zero

A **source-available** TERMINUS app-patch (PolyForm Shield 1.0.0) for people who have never played or read music. It
teaches by doing, not by lecturing — every lesson lets you make a correct sound on
the first try.

Open it from the **patches grid (page 2)** on the home shell, or run it directly:

```bash
~/demod-ui/demod-ui patches/demod-learn/main.lua
```

## Lessons

| Lesson | Teaches | How |
|--------|---------|-----|
| **NOTES & TUNER** | Note names + pitch | An on-screen keyboard names every key you press and plays it. If audio input is wired (orchestrator / desktop rig), a live tuner shows whether you're sharp or flat. |
| **RHYTHM & TIMING** | Steady time | A visual + audible metronome; tap *activate* on the pulse and it tells you if you're on, early, or late. Adjust BPM with left/right. |
| **SCALES & INTERVALS** | Which notes go together | A C-major scale lights up the keyboard; pick an interval and hear the root + that note. |
| **EAR / PLAY-ALONG** | Listening | The app plays a short phrase; you repeat it on the keys and it scores you note-by-note. |

Switch lessons with `[<] / [>]` (Tab / LB-RB / D-pad ◄►). `back` returns to the menu,
or exits to TERMINUS from the menu.

## Sound is optional

LEARN plays notes through the shared `dsp/midi_input` bridge **when a synth voice is
loaded** (device orchestrator, or `nix run .#desktop`). With no synth/engine it runs
**visual-only** — fully usable, just silent — so it loads anywhere, including headless.

## Layout

- `main.lua` — the app (UI only; one focus field, `back = dm.quit`).
- `theory.lua` — pure music theory (note names, frequencies, scales, intervals, phrase
  generation). No `dm.*`, so it unit-tests under plain `lua` (see `selftest.lua`).

Shared draw/sound/save helpers are bundled in the patch directory.

© 2026 DeMoD LLC.
