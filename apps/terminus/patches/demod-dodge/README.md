<!-- SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0 -->
# DODGE

A **source-available** TERMINUS arcade app-patch (PolyForm Shield 1.0.0). Your ship sits at the bottom across five lanes;
blocks fall from the top and the pace ramps up. Slide between lanes and survive — one
hit ends the run.

```bash
~/demod-ui/demod-ui patches/demod-dodge/main.lua
```

## Controls

| Action | Effect |
|--------|--------|
| `prev` / `next` | move the ship one lane left / right |
| `activate` | start (title) · retry (game over) |
| `back` | exit to TERMINUS (title) · abort to title (playing) |

Score is survival time plus blocks dodged; falling speed and spawn rate climb the longer
you last. Best score persists at `~/.config/demod/games/demod-dodge.lua`. Visual-only —
no synth voice required (runs headless).

Shared draw/save helpers are bundled in the patch directory.

© 2026 DeMoD LLC.
