<!-- SPDX-License-Identifier: MPL-2.0 -->
# Could DeMoD control a vehicle? (drone / AUV feasibility)

A recurring question: could the DeMoD stack become a **flight controller for a drone**, or a
controller for a **JANUS submersible**? This is the honest, code-grounded answer, written as a
decision document — no vehicle code exists yet; this is the reference to choose a direction from.

## TL;DR

There are two very different questions hiding in "make it a flight controller," and they have
opposite answers:

- **The safety-critical inner loop** (a drone's 1–8 kHz attitude/rate control): DeMoD is a **poor
  and — for an agile aircraft — unsafe** fit. The real-time engine here is a *JACK audio callback*;
  its failure mode is a recoverable glitch (an xrun is a pop), not the hard-deadline world where a
  missed tick drops the vehicle. And it has **none** of the substance of a flight controller.
- **The autonomy / telemetry / HMI layer around that loop** (companion computer, ground station,
  mesh comms, HUD): DeMoD is a **genuinely good** fit, because that skeleton already exists here.

**So: DeMoD is the skeleton around a vehicle, not the flight-critical controller.** Keep the
critical loop on a proven autopilot (PX4/ArduPilot/ArduSub on a dedicated MCU); use DeMoD as the
companion computer, telemetry mesh, and cockpit/console.

## What transfers as-is (the reusable skeleton)

| Piece | Where | Why it's reusable |
|-------|-------|-------------------|
| **Process supervisor** | `audio-stack/orchestrator/src/DeMoD/Supervisor.hs` (`ChildSpec`: `csCpuCore`/`csSchedFifo`/`csMlockAll`/heartbeat/restart-backoff) | Generic pinned-real-time process manager. Nothing audio is baked in — it already runs four heterogeneous children (`mkRtAudioSpec`, `mkUiSpec`, `mkLyricsSpec`, `mkHydraMeshSpec` in `ProcessTree.hs`). A vehicle control process is just a new `ChildSpec` builder. |
| **Lock-free IPC bus** | `audio-stack/ipc/include/` (`demod_spsc.h`, `demod_triple_buf.h`, `demod_shm.h`, `demod_rt_meters.h`) | The command ring is a generic *opcode + float-args* bus; the 256-byte param snapshot's `fx_params[16]` is already an untyped 16-float **setpoint array** (+ 136 reserved bytes); telemetry is a single-writer **seqlock**. The "read setpoints → compute → publish telemetry" shape is not audio-specific *in form*. |
| **DCF / HydraMesh transport** | `third_party/hydramesh/demod_frame.h`, `src/ipc/dm_dcf.c`, `audio-stack/bridge/demod-remote-bridge.c` | Payload-agnostic 17-byte datagram. The vendored code **already** carries non-audio telemetry (`DCF_METERS_CODEC` = `codec_id 16`) and JSON commands with **no wire change** — sensor/setpoint payloads map the same way. |
| **Framebuffer UI + focus-field input** | `src/` (renderer), the `on_nav`/`on_input` funnel | A no-GPU HUD / ground-control station that runs on microcontroller-class hardware and drives from an encoder, stick, keyboard, or network — a ready cockpit. |
| **ArchibaldOS** | `github.com/ALH477/ArchibaldOS` | A PREEMPT_RT NixOS (x86 / aarch64 / RISC-V) — a solid *companion computer* OS. |

## What must be built new (nothing here does this)

- **A control-loop clock.** `demod-rt` has *no timer loop* — its `main()` just sleeps for signal
  handling (`audio-stack/rt-audio/src/main.c:653-656`, "the callback does all the work") and all work
  runs in the JACK process callback (`jack_set_process_callback`, `demod_rt_audio.h:834`). A vehicle
  node needs a new fixed-rate loop (`clock_nanosleep`/`timerfd`, `CLOCK_MONOTONIC`, `TIMER_ABSTIME`).
  The IPC read/compute/telemetry *skeleton* transfers; the clock and the compute stage are new.
- **All sensor/actuator I/O.** IMU / baro / mag / GPS in; PWM / DShot / CAN / ESC / servo out. A repo
  grep finds **none** of it — the only serial path is a UI-navigation rotary-encoder reader
  (`src/input/serial_encoder.c`), not a vehicle bus.
- **State estimation** (EKF / complementary filter), the **control law** (PID / cascade / LQR),
  **actuator mixing**, and **failsafes / arming / kill logic**. None exist.

In short: the **orchestration + IPC + transport + UI** are reusable; the **engine** (control loop,
drivers, estimator, controller) is entirely new work.

## The safety fault line

- **Agile aircraft (drone) inner loop.** Do **not** put a 1–8 kHz attitude/rate loop on DeMoD or on
  Linux — even PREEMPT_RT. Scheduling jitter, non-certifiability, and audio-style "recoverable glitch"
  failure semantics are all wrong for it. Real systems run that loop bare-metal on an MCU/RTOS
  (PX4/ArduPilot on STM32) and use Linux only for the *companion computer*. DeMoD ↔ FC over **MAVLink**.
- **Slow marine vehicle (AUV / ROV / glider).** Control is slow-loop (depth / heading / ballast /
  thrusters, ~10–50 Hz), which a soft-real-time Linux loop can **defensibly host for research/bench**
  work (BlueROV / ArduSub class). Even so, keep a proven autopilot in the loop for any real dive and
  treat DeMoD as the mission / comms / HMI layer first.

## The JANUS / underwater angle (the submersible instinct is well-founded)

The *upstream* HydraMesh repo (not the UDP-only subset vendored here) already contemplates exactly
this. It ships `Documentation/DCF_JANUS_SPEC.md` — carrying the 17-byte DCF frame as **JANUS cargo
over a NATO STANAG-4748** underwater acoustic link, stated verbatim for *"AUVs, naval/sensor nodes"* —
plus an acoustic M-FSK modem (`hydramodem/`), an SDR radio path (HackRF / PlutoSDR), a self-healing
RTT-weighted-Dijkstra mesh, a `BEACON` clock-sync frame type, and an application `POSITION` message.
Acoustic bandwidth is tiny (~37 B/s) and latency is seconds — which is precisely where DCF's 17-byte
frames and **latest-wins, lossy telemetry** model fit *better* than a chatty protocol would. So the
sub case isn't a stretch; it's a niche the transport was partly designed for.

## Roadmaps (each starts hardware-free)

**Milestone 0 — vehicle-node PoC (either track, zero hardware, zero risk).**
A new timer-driven soft-real-time process, supervised by the existing orchestrator, that reads
setpoints from the param bus, runs a toy control law against a **simulated plant**, and publishes
telemetry over DCF to a new framebuffer HUD. Proves *supervise → loop → mesh → HUD* end to end — a
direct analog of how the audio engine node + `demod_stack_up` already work.

**Track A — drone companion computer + ground station.**
A link node talks **MAVLink** to a real PX4/ArduPilot FC over UART and mirrors telemetry into the shm
bus; a **DCF↔MAVLink bridge** (mirroring `demod-remote-bridge`) carries it over the mesh / a DCF-SDR
telemetry radio; a framebuffer HUD shows horizon / battery / GPS / link / arm state. The FC flies the
aircraft; DeMoD never does.

**Track B — AUV / submersible + JANUS.**
A soft-real-time depth/heading/thruster loop (reusing the supervisor + IPC skeleton); new IMU / depth /
compass input + thruster/ESC output drivers; a **DCF-over-JANUS** surface↔sub acoustic link (from
upstream HydraMesh); a topside framebuffer console. Bench / tank / simulation first; ArduSub in the
loop for any real dive.

## What DeMoD must **not** be

The flight-critical control loop for anything crewed, valuable, or that can hurt someone; a substitute
for a certified autopilot. The intended scope is **civil / research** — companion computing, telemetry,
HMI, and slow-AUV experimentation — the same open territory as ArduPilot, ArduSub, and BlueROV.
