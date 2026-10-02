<!-- SPDX-License-Identifier: MPL-2.0 -->
# DeMoD Mixer

A touch-first channel-strip surface for the DeMoD audio engine, on the
companion-shell SDK. MPL-2.0. The same script runs as the front panel of a
rack unit (kiosk), on an embedded touchscreen, or in a window on a laptop.

```sh
./dev run mixer                                  # from a checkout
nix run .#mixer                                  # store-built (demod-ui-dcf)
DEMOD_KIOSK=1 demod-mixer                        # fullscreen, no cursor: a panel
DEMOD_MIXER_ENGINE=remote:10.78.0.2 demod-mixer  # an engine elsewhere, over DCF
```

| page | what it does |
|---|---|
| MIXER | channels 1-8 / 9-16 and the master: fader (unity at 3/4, +3.5 dB top, silence at the bottom), pan with detents at centre and both ends, mute, solo, stereo meters |
| ENGINE | what it is connected to, health (alive, CPU, xruns), the 16 slots with bypass, tempo |

Touch: drag faders and pan bars; tap M, S, the page arrows, a slot (bypass),
or −/+ (tempo). Encoder / keys: `prev`/`next` walk the controls; `activate`
grabs a fader or pan (then `prev`/`next` move it 1 dB or 0.05) or toggles
M/S; `tab` switches page.

## Where the engine is

| `DEMOD_MIXER_ENGINE` | engine | ops | readback |
|---|---|---|---|
| `local` (default, if it answers) | orchestrator on this machine, `$DEMOD_CONTROL_SOCK` | replies, refusals named | `dm.meters_read()` (demod-rt's segment) |
| `remote:HOST[:PORT]` | `demod-remote-bridge` on HOST (port 47000) | accepted / refused only | the bridge's meter stream |
| `sim` (or nothing reachable) | none | kept locally | the UI's own shadow, labelled SIMULATOR |

A mixer that starts before its engine shows **SIMULATOR** and keeps retrying
the local socket every 3 s, so a kiosk that boots first attaches when the
engine comes up. A remote engine is plaintext DCF (export posture): reach it
through WireGuard, which is how ArchibaldOS wires a rack unit to the Oligarchy
DSP VM. The bridge admits private senders only.

While a finger is on a control, its strip shows that value, and for 0.6 s
afterwards. Otherwise every strip shows what the engine reports, so a change
made elsewhere (another panel, `dsp-ctl`, TERMINUS) appears here.

## Tests

`./dev test mixer`:
- `test/taper_test.lua` checks the fader law: fixed points, round trip, detents.
- `test/mixer_e2e.sh` replays `test/gestures.lua` as the pointer against
  `tests/fake_orchestrator.py`, which applies Control.hs's op rules and
  publishes through the real meters segment. It checks:
  - every gesture became the right accepted op, and a drag streams gains;
  - the strips show the engine's state, including a value preset in the engine
    that the UI never sent.

Not measured here:
- SDL turning a real finger into `dm.mouse_down()` (the replay bypasses it);
- two faders moved at once. Touch arrives through SDL's touch-to-mouse
  emulation, which follows the first finger only;
- a real engine (`audio-stack/bridge/test/engine_e2e.sh`, which needs JACK).

## Identity

Its own graphite/amber palette (`theme.lua`), not the reserved DeMoD/TERMINUS
phosphor trade dress. It talks to the GPL engine only over IPC, so it stays
MPL. TERMINUS (PolyForm Shield) has its own MIXER screen; this is not a copy
of it and shares no code with it.
