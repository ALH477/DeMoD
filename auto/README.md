<!-- SPDX-License-Identifier: MPL-2.0 -->
# DeMoD Auto — a FOSS car head unit + vehicle-companion shell

A car infotainment / dashboard **and** a vehicle-companion computer, built on the DeMoD UI
framework. No GPU (runs on cheap ARM/RISC-V), drivable entirely from a rotary controller /
steering-wheel buttons / keyboard / gamepad (touch optional), and — with Nix/ArchibaldOS — shippable
as a reproducible immutable car image. Pure Lua on the framework; **MPL-2.0**.

```bash
nix run .#auto            # DCF-enabled UI + the OBD-II reader on PATH
# or, from a working tree:
DEMOD_AUTO_DIR=$PWD/auto/ ./demod-ui auto/main.lua
```

## Surfaces

- **DRIVE** — the cluster: speedo + tach + coolant / fuel / battery / throttle, gear, warnings.
- **COMPANION** — the *computation mode*: live telemetry aggregation, the DCF mesh link, and an
  event log — the head unit acting as the vehicle's companion computer.
- **SETTINGS** — theme (night / day / auto), units (km/h·mph, C·F), and the data source.

Controls: `tab`/`tab_prev` switch surface, `prev`/`next` move focus, `activate` change/select,
`back` → DRIVE, `wet` (X) toggle day/night. Config persists to `$DEMOD_AUTO_CONFIG`
(default `~/.config/demod/auto.lua`).

## Vehicle data — a pluggable provider

`vehicle/telemetry.lua` reads `{speed, rpm, coolant, fuel, volts, throttle, gear}` from one of:

- **`obd2`** — a real ELM327 adapter via `vehicle/obd2-reader.py` (pure stdlib: termios, no pyserial).
  Point it at your adapter and it polls standard mode-01 PIDs (rpm/speed/coolant/fuel/throttle + `ATRV`
  voltage) into a state file the UI reads:
  ```bash
  DEMOD_OBD_DEV=/dev/ttyUSB0 python3 auto/vehicle/obd2-reader.py   # or /dev/rfcomm0 for Bluetooth
  ```
  The app spawns this itself when the data source is `obd2`/`auto` and an OBD device is set.
- **`simulator`** — a synthetic drive cycle; the always-available fallback (used when no adapter is
  reachable), so DeMoD Auto runs and demos with no car.
- **`dcf`** — telemetry over `dm.dcf` (seam; wired in a later phase alongside a companion node).

Env: `DEMOD_OBD_DEV`, `DEMOD_OBD_BAUD` (default 38400), `DEMOD_VEHICLE_STATE` (default
`/tmp/demod-vehicle.kv`), `DEMOD_DCF_HOST`/`_PORT` (optional mesh link for COMPANION).

## Verify (no hardware)

```bash
bash auto/test/obd2_selftest.sh   # a mock ELM327 on a pty -> obd2-reader.py -> asserts parsed state
```
Headless render: `SDL_VIDEODRIVER=dummy DEMOD_SHOT=/tmp/a.ppm ./demod-ui auto/main.lua`
(`DEMOD_AUTO_SURFACE=1|2|3` deep-links a surface for screenshots).

## Safety & compliance (defaults on)

DeMoD Auto ships the safety/privacy defaults a FOSS infotainment framework should — see the
integrator guide **[`../docs/automotive-compliance.md`](../docs/automotive-compliance.md)**:

- **Non-preemptible rear camera** (`surfaces/camera.lua` + `camera.sh`): reverse forces the rear view
  and blocks navigating away from it — the FMVSS 111 function can't be preempted by entertainment.
- **Motion lockout** (on by default): entertainment surfaces (MEDIA) are disabled above ~8 km/h with a
  "PULL OVER" screen; the cluster, camera, and config stay available.
- **Data-minimization**: no telematics collected/sent by default; the mesh is opt-in; the camera is
  captured only when explicitly configured (`$DEMOD_CAMERA_DEV`), never an arbitrary webcam.
- **Read-only OBD** (no CAN writes) and **no end-user RF controls**.

## Scope

**AS IS, no warranty (MPL-2.0).** A framework for research and integration — **not** a finished
aftermarket product, and **not** a driving-critical controller ([`../docs/vehicle-feasibility.md`](../docs/vehicle-feasibility.md)):
DeMoD is the infotainment / companion / HMI layer, never the safety-critical loop. No throttle/brake/
steering actuation; OBD is read-only. Certification (FCC, FMVSS 111 validation, ISO 26262/21434) is the
integrator's responsibility — see the compliance guide.

Roadmap (seams in place): an **Audio/media** surface (car EQ/DSP over the engine control socket + an
out-of-engine music player), nav/maps, a backup camera (V4L2 → `dm.draw.blit`), climate/CAN, BT phone,
and a soft-RT companion telemetry node.

## Identity

DeMoD Auto uses its **own** neutral automotive look (`theme.lua`, day/night), deliberately distinct
from the reserved DeMoD/TERMINUS phosphor trade dress — so it stays clean, reusable MPL.
