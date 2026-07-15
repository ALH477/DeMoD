# DRUM MACHINE

A per-voice **step sequencer** app-patch for the TERMINUS shell, built on the demod-ui
framebuffer. It's the classic TR-style grid
(rows = drum voices, columns = time) distilled to its proven core and adapted to a
320–1280px software-rendered display driven by an encoder, buttons, gamepad or keyboard.

## The grid

- **8 voices × 16 steps**: KICK, SNARE, CLAP, CLOSED HAT, OPEN HAT, TOM, COWBELL, CRASH.
- **4-step group shading** + a brighter **downbeat marker** on beat 1 for orientation.
- **Velocity** is drawn redundantly as **brightness + a height bar** (survives a CRT).
- An **animated playhead column** is the "is it alive" affordance during playback.
- **A–D pattern banks**, each independent; everything persists to
  `~/.config/demod/games/demod-drum-machine.lua`.

## Controls (one focus field)

A single linear focus walks **every cell, then the transport buttons**, so a bare rotary
encoder reaches everything:

| Input | Action |
|-------|--------|
| prev / next (encoder, ◄ ►) | move focus one step along the ring |
| up / down · tab / tab_prev | jump by **voice row** / transport button (accelerator) |
| activate (push, A, Enter) | toggle the focused step / fire the focused button |
| secondary (X / "wet") | cycle the focused step's **velocity** (lo → med → hi) |
| back (B, Esc) | exit to TERMINUS |

**Transport buttons:** `PLAY/STOP · BPM- · BPM+ · MODE · BANK · CLEAR`.

**STEP vs LIVE:** STEP edits the grid directly. In **LIVE**, while playing, `activate`
quantizes a tap of the focused voice onto the step nearest the playhead.

## Audio

The sequencer resolves the best output once and shows it in the top-right of the chrome:

- **KIT** — a real `demod-drums` slot is loaded on the DSP backend; each voice fires its
  one-shot `*Gate` param (the genuine 808/909 kit). *(demod-drums is a paid patch.)*
- **NOTE** — no kit, but the gamekit synth bridge is live; voices play their General-MIDI
  drum notes through whatever synth is loaded.
- **VISUAL** — no audio path (e.g. headless); the sequencer still runs and animates.

Velocity is audible on the NOTE path; on the KIT path the gate trigger is binary, so
velocity there is visual (a per-hit level is a future enhancement).

## Three ways to drive it

1. **The focus field** — encoder / keyboard / gamepad / touch, as above.
2. **A live MIDI controller** — set `DEMOD_DM_MIDI=<rawmidi|fifo>` (or rely on the
   framework's `DEMOD_MIDI`). The framework's MIDI reader delivers messages to the patch's
   `on_midi`; General-MIDI drum notes map to the 8 voices and play instantly. In **LIVE**
   mode while playing, each pad hit is **recorded** onto the step nearest the playhead.
3. **MIDI files + the BEATS menu** — the **BEATS** transport button opens a library of
   saved beats, which **are `.mid` files** in a beats directory (`$DEMOD_BEATS_DIR`, else
   `~/.config/demod/beats`). `[*]` on a beat loads it; `[*]` on the top row saves the
   current bank as a new `.mid` (usable in any DAW); `[X]` deletes. Drop a `.mid` into the
   directory and it appears in the list. `DEMOD_DM_IMPORT=<file.mid>` loads one on boot.

The live-MIDI input is a small **framework** binding (`dm.midi_open` + `on_midi`, an ALSA
rawmidi / FIFO reader modeled on the serial encoder) — first-class and reusable by any patch.

## Files

- `main.lua` — UI, responsive layout, focus field, transport clock, persistence, BEATS menu.
- `pattern.lua` — pure model + transport (grid, banks, `step_dur`/`advance`, serialize).
- `voices.lua` — the 8-voice table (gate index, GM note, accent) + the GM→voice map.
- `audio.lua` — the KIT/NOTE/VISUAL trigger bridge.
- `midi.lua` — live MIDI message → drum action (note → voice/velocity), pure.
- `smf.lua` — Standard MIDI File import/export (pure Lua reader + writer).
- `beats.lua` — the saved-beats (`.mid`) library.
- `selftest.lua` — headless asserts for the pure cores (`demod-ui selftest.lua`).

## Test

```bash
# pure-core asserts: pattern + GM map + MIDI parse + SMF round-trip (no display)
~/demod-ui/demod-ui patches/demod-drum-machine/selftest.lua

# headless smoke
SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy timeout 3 \
  ~/demod-ui/demod-ui patches/demod-drum-machine/main.lua

# drive it from a MIDI controller (or a FIFO you feed raw MIDI bytes into)
DEMOD_DM_MIDI=/dev/snd/midiC1D0 DEMOD_DM_MODE=LIVE \
  ~/demod-ui/demod-ui patches/demod-drum-machine/main.lua

# load a .mid on boot; browse the saved-beats library
DEMOD_DM_IMPORT=groove.mid ~/demod-ui/demod-ui patches/demod-drum-machine/main.lua
DEMOD_DM_SCREEN=beats       ~/demod-ui/demod-ui patches/demod-drum-machine/main.lua
```
