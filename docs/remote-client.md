<!-- SPDX-License-Identifier: MPL-2.0 -->
# Remote client: run the UI on macOS / Windows, the engine on Linux

The DeMoD UI is portable C + SDL2 + Lua; the real-time audio engine is Linux-only
(JACK, PREEMPT_RT, `SCHED_FIFO`/`mlock`, `/dev/shm`). So you can run the **UI natively on
your macOS or Windows workstation** and offload the audio to a **Linux box or VM**, with the
two talking over **DCF/UDP** (`dm.dcf` ↔ `demod-remote-bridge`). No X-forwarding, no VM
display — a native window on your desktop, real-time audio on the Linux side.

```
  macOS / Windows workstation                 Linux VM or server
  ┌───────────────────────────┐   DCF/UDP   ┌──────────────────────────────┐
  │  demod-ui  (native client) │◄──────────►│  demod-remote-bridge          │
  │   dm.dcf.open(host, port)  │            │   ↕ control.sock / meters shm │
  └───────────────────────────┘            │  demod-orchestrator + demod-rt│
                                            └──────────────────────────────┘
```

## Build the client (macOS / Windows / Linux) — CMake

The client is built with CMake (the Unix `Makefile` remains the Linux/Nix default). Off Linux,
CMake defaults to `DEMOD_CLIENT=ON` — a remote-only build: the core renderer + `dm.dcf`, with the
Linux-only local IPC/MIDI/serial modules stubbed out.

### macOS
```bash
brew install sdl2 lua cmake pkg-config
cmake -S . -B build -DDEMOD_DCF=ON
cmake --build build -j
./build/demod-ui examples/hello.lua
```

### Windows (MSVC + vcpkg)
```powershell
vcpkg install sdl2 lua
cmake -S . -B build -DDEMOD_DCF=ON -DCMAKE_TOOLCHAIN_FILE=<vcpkg>/scripts/buildsystems/vcpkg.cmake
cmake --build build --config Release
```
Ship `demod-ui.exe` next to `SDL2.dll` + `lua54.dll`. (MinGW works too.)

### Fonts
For non-ASCII / CJK, put a Unifont `.dmf` blob (see `make font`) at `%LOCALAPPDATA%\demod\unifont.dmf`
(Windows) / `~/.local/share/demod/unifont.dmf` (macOS), or point `DEMOD_FONT` at it. ASCII needs nothing.

## Run the engine (the Linux "server")

On the Linux box/VM (built from this repo's flake — nothing new to write):

```bash
nix build .#demod-orchestrator .#demod-rt .#demod-remote-bridge
# start the engine + orchestrator (see audio-stack/README.md), then the bridge:
DEMOD_DCF_PORT=47000 ./result/bin/demod-remote-bridge   # exposes the UDP endpoint
```

Open UDP `47000` on the VM/host firewall. On an untrusted network, tunnel it (WireGuard/SSH) —
the DCF wire is unauthenticated by design.

## Point the client at it

From the UI's Lua (or the DSP Studio's remote backend), open the connection:

```lua
dm.dcf.open("192.168.1.50", 47000)   -- the Linux engine's address
assert(dm.dcf.ping())                -- round-trip check
```

`dm.dcf.send(op)` relays control ops to the engine; `dm.dcf.poll()` drains the meter/telemetry
stream. A headless end-to-end proof (bridge + a stub engine ↔ `dm.dcf`, all over localhost UDP)
is `audio-stack/bridge/test/loopback.sh`.

## Latency

Control is one UDP round-trip (sub-millisecond on a LAN or a local VM's virtual NIC). Telemetry
(meters/scope) is a lossy latest-wins stream at UI frame rate. Audio itself does **not** cross
this link — it stays on the Linux engine (monitor it there, or via the DCF-Audio path, a later
phase). A wired LAN or a local VM (vsock/virtio-NIC) keeps the UI feeling live.
