# SAMPLER

A 16-pad sample player backed by a **StreamDB sample library**, built on the demod-ui
framebuffer + the shared `patches/sampler/` kit. Samples are stored as blobs in a single
portable StreamDB file (`~/.config/demod/samples.db`, or `$DEMOD_SAMPLES_DB`) that rides
the marketplace USB-C sync exactly like patches.

## Two screens

- **PADS** — a 4×4 grid. Each pad binds to a library sample (name + gain). The focus field
  walks every pad then the soft-button row, so a bare encoder reaches everything.
  - `[*]` (activate) plays the focused pad.
  - `[X]` (secondary / "wet") opens the LIBRARY to **assign** a sample to that pad.
  - Soft buttons: `LIBRARY · IMPORT · GAIN- · GAIN+ · CLEAR`.
- **LIBRARY** — browse the sample library (name, duration, channels).
  - `[*]` auditions a sample (or, in assign mode, binds it to the pad and returns).
  - Top row `IMPORT FILE` imports `$DEMOD_SAMPLER_IMPORT` or the latest take recorder take.
  - `[X]` deletes a sample (pads referencing it are pruned).

## Inputs

- **Focus field** — encoder / keyboard / gamepad / touch.
- **Live MIDI** — `on_midi` maps notes 36‥51 to pads 1‥16; set `DEMOD_SAMPLER_MIDI=<dev>`
  (or rely on the framework's `DEMOD_MIDI`).

## How it works

- **Library** — `patches/sampler/sampledb.lua` wraps the framework's `dm.streamdb_*`
  binding. `import` normalizes any input through **ffmpeg** to 48 kHz/16-bit WAV and stores
  the blob + metadata (`name, sr, ch, bits, dur_ms, bytes, tags`). `list` enumerates via a
  reverse-trie suffix search on the metadata keys.
- **Playback** — `patches/sampler/player.lua` fires one-shots through **pw-play** (else
  ffplay/aplay); overlapping hits are naturally polyphonic. Latency is the process-spawn +
  buffer cost — great for auditioning and fine for moderate-tempo pads. A persistent JACK
  client (preloaded buffers + a trigger FIFO) is the documented low-latency upgrade.

## Files

- `main.lua` — UI, focus field, two screens, MIDI, persistence.
- `pads.lua` — the 16-pad model (assign/gain/serialize/prune), pure + unit-tested.
- `../sampler/sampledb.lua` — the StreamDB sample library (shared).
- `../sampler/player.lua` — the one-shot player (shared).
- `selftest.lua` — pad-model asserts; `../sampler/selftest.lua` covers the library + player.

## Test

```bash
~/demod-ui/demod-ui patches/demod-sampler/selftest.lua          # pad model
~/demod-ui/demod-ui patches/sampler/selftest.lua                # library + player (needs ffmpeg)
SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy timeout 3 \
  ~/demod-ui/demod-ui patches/demod-sampler/main.lua            # headless smoke
DEMOD_SAMPLER_IMPORT=hit.wav ~/demod-ui/demod-ui patches/demod-sampler/main.lua
```
