# TERMINUS

A unified shell and DSP studio for the DeMoD audio platform.

## Overview

TERMINUS is the flagship application layer of DeMoD: a home shell that launches DSP Studio and other subsystems, plus a full-featured DSP effects rack with a grouped navbar, control surface, modulation matrix, and DAW-style mixer/sequencer.

## Features

### Home Shell
- **Unified launcher** — surfaces every DeMoD subsystem (DSP Studio, Lyrics, Ferrofluid, Systems) as a launchable "channel"
- **Display-adaptive layout** — reflows from 320px panels to 1080p desktops
- **Focus field model** — one integer index, every input source funnels into it (encoder, keyboard, mouse, MIDI, network)

### DSP Studio
- **15 screens** grouped into RACK / MOD / DAW / SYS
- **Grouped navbar** — expands the active group, collapses others (scales 320px..desktop)
- **Full control surface** — CC/footswitch bindings with shaping, soft-takeover, MIDI-out
- **Modulation matrix** — tempo-synced LFOs, envelope follower, step sequencer
- **Macros + scenes** — one control → many params, snapshot + crossfade
- **DAW surfaces** — mixer (channel strips), take recorder, piano-roll sequencer, arrangement view

### Backend Agnostic
- **Stub** — in-memory fake, runs anywhere with no backend
- **Local** — embeds the C++ `demodoom_core` via `dm.local_*` (framework built with `LOCAL_DSP=1`)
- **Orchestrator** — connects to the real `demod-rt` engine over control socket + shared memory

## Quickstart

```bash
# Build the framework (if not already built)
cd /path/to/DeMoD
make

# Run TERMINUS Home
./demod-ui apps/terminus/home.lua

# Run DSP Studio directly
./demod-ui apps/terminus/dsp/dsp_studio.lua

# Headless smoke test
SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy timeout 3 ./demod-ui apps/terminus/home.lua
```

## Example Patches

The `patches/` directory includes 46 source-available example Faust effects (boost, delay, reverb, distortion, etc.) under PolyForm Shield 1.0.0. These are included as examples to demonstrate the patch system.

## Licensing

**TERMINUS is source-available under PolyForm Shield 1.0.0.** You can read the code, run it, and learn from it for personal and non-commercial use.

### Commercial Use

**Commercial use requires a paid license.** If you want to use TERMINUS in a commercial product, you need:

1. **Commercial license** — paid license to use TERMINUS in a commercial product
2. **3% hardware fee** — additional 3% fee on the hardware selling price (on top of the commercial license)

Contact **alh477@proton.me** for commercial licensing information and pricing.

### What Counts as Commercial Use?

- Selling a product that includes TERMINUS
- Using TERMINUS in a product you sell (hardware or software)
- Using TERMINUS in a service you charge for
- Integrating TERMINUS into a commercial product

### What Doesn't Require a Commercial License?

- Personal projects
- Educational use
- Open-source projects (non-commercial)
- Reading the code to learn from it

## Navigation

Every input source (encoder, keyboard, mouse, MIDI, gamepad) funnels into one **focus field** — a single integer index. The same code drives a 320px guitar panel (encoder-only) and a 1080p desktop (mouse+keyboard).

### Universal Controls
- **Turn / arrows** — move the cursor
- **Press / select** — open or adjust
- **Back / esc** — go back or exit
- **Tab / shift-tab** — switch screens (walks grouped order: RACK → MOD → DAW → SYS → RACK...)

### DSP Studio Screens
- **RACK** — FX CHAIN / MIXER / PARAMS
- **MOD** — BINDINGS / MACROS / MOD MATRIX / SCENES / SCRIPTS
- **DAW** — SEQUENCER / ARRANGE / RECORD
- **SYS** — VIZ / ROUTING / PATCHES / SETTINGS

## Architecture

### The Focus Field
Both apps (Home + DSP Studio) share one navigation model. There is always exactly **one focused item**, identified by a single integer index. Every input source funnels into it, so the same code drives a rotary encoder, keyboard, mouse/touch, MIDI, or a network script.

### Display-Adaptive Layout (Home)
The same channel set reflows by physical size, computed from `dm.width()`/`dm.height()` each frame and **lerped** between arrangements for smooth reflow on resize:
- **Compact** (`W<540 || H<380`): carousel, one big card, neighbours peeking
- **Standard** (`W<960`): coverflow row, focused card enlarged, neighbours scaled/faded
- **Wide** (else): 3×2 channel grid, focused card lifted

### Grouped Navbar (DSP Studio)
The 15 screens are grouped into RACK/MOD/DAW/SYS. The navbar shows the **active group expanded** to its screens + the other groups collapsed to a single label, so at most ~8 cells show instead of 15. This solves the cramming issue on wide screens and the lack of context on compact screens.

### Framebuffer Constraints
The framework is a scanline-by-scanline software renderer with **no GPU**. Therefore:
- No rounded-rect, no clip region, no GPU blur, no font scaling
- Cards are sharp scope-style rects with corner trace-accents
- Text is the fixed 8×16 font — **ASCII 32–126 only**
- "Frosted glass" / bloom / halos are **faked with stacked low-alpha primitives**

## License

**PolyForm Shield 1.0.0** — source-available, non-commercial. Commercial use requires a paid license + 3% hardware fee.

See `LICENSE` for the full text.

## Contact

For commercial licensing: **alh477@proton.me**

## Copyright

(c) 2026 DeMoD LLC. All rights reserved.
