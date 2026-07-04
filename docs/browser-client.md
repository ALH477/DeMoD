<!-- SPDX-License-Identifier: MPL-2.0 -->
# Browser client: run the DeMoD UI in a tab, drive a Linux engine over WebSocket

The DeMoD UI is portable C + SDL2 + Lua, so it compiles to **WebAssembly** and runs
**in a browser tab** — the software rasterizer draws its ARGB framebuffer to a canvas,
pixel-identical to the native window. Two ways to use it:

1. **Standalone demo** — the real phosphor UI (an example app) running against the
   in-memory stub backend. Open a URL, the UI runs. No engine, no install.
2. **Remote client** — the same tab drives a **Linux** audio engine (VM or server) over
   a **WebSocket**, because browsers can't open raw UDP. This is the [native remote
   client](remote-client.md) taken all the way into the browser.

```
  browser tab (WASM)                              Linux VM or server
  ┌───────────────────────────┐   binary WS   ┌───────────────────────────────┐
  │  demod-ui.wasm             │◄─────────────►│  dcf-ws-bridge  (WS <-> UDP)   │
  │   dm.dcf.open(host, port)  │  (DeModFrames)│         ↕ UDP (verbatim)       │
  │   SDL2 canvas              │               │  demod-remote-bridge           │
  └───────────────────────────┘               │   ↕ control.sock / meters shm  │
                                               │  demod-orchestrator + demod-rt │
                                               └───────────────────────────────┘
```

The wire is the unchanged **17-byte DeModFrame** — the browser just carries it over a
binary WebSocket instead of a UDP datagram. `dcf-ws-bridge` is a stateless relay that
never parses a frame; the DCF codec runs in the wasm exactly as it does natively.

## Build the wasm (Emscripten)

```bash
nix shell nixpkgs#emscripten nixpkgs#cmake --command bash -c '
  emcmake cmake -S . -B build-wasm -DCMAKE_BUILD_TYPE=Release
  cmake --build build-wasm -j'
# -> build-wasm/demod-ui.{js,wasm,data}
```

Emscripten specifics (all in the `if(EMSCRIPTEN)` block of `CMakeLists.txt`): SDL2 via
`-sUSE_SDL=2`, Lua 5.4 compiled from source into the wasm, `STREAMDB_NO_THREADS` (no
pthreads → streamdb's inline-flush path), local IPC/MIDI/serial stubbed out (`__linux__`
undefined), `-lwebsocket.js` for the transport, and the chosen example preloaded into
MEMFS as `main.lua`. The main loop is `emscripten_set_main_loop` (see `dm_app_run`).

## Serve it

```bash
cp build-wasm/demod-ui.{js,wasm,data} web/     # or serve build-wasm/ directly
python3 -m http.server -d web 8080             # any static server; wasm needs no COOP/COEP
# open http://localhost:8080/
```

`web/index.html` is a minimal canvas host. This alone is the **standalone demo** — the
example UI runs against the stub backend, no engine required.

## Drive a real engine

On the Linux box/VM run the engine + the two bridges (all build from this flake):

```bash
nix build .#demod-orchestrator .#demod-rt .#demod-remote-bridge .#dcf-ws-bridge
# start the engine + orchestrator (see audio-stack/README.md), then:
DEMOD_DCF_PORT=47000 ./result/bin/demod-remote-bridge          # UDP endpoint
./result/bin/dcf-ws-bridge --listen 0.0.0.0:7000               # WS <-> UDP relay
```

Point the tab at the bridge — the client reads `window.DEMOD_WS_BRIDGE`, defaulting to
`ws(s)://<page-host>/dcf`, or pass `?bridge=`:

```
http://localhost:8080/?bridge=ws://192.168.1.50:7000
```

Then from the UI's Lua (or the DSP Studio's remote backend):

```lua
dm.dcf.open("192.168.1.50", 47000)  -- the *engine's* UDP endpoint (sent to the bridge
                                     --   as an {"op":"addpeer",...} control frame on connect)
assert(dm.dcf.ping())               -- non-blocking in the browser: sends PING now, the
                                     --   RTT is filled in on the pong (0 until the first)
dm.dcf.poll()                        -- drains meter/telemetry frames each frame
```

`dm.dcf.open(host, port)` names the **engine**, not the bridge — the bridge URL comes
from the page (above). The transport is otherwise API-identical to the native path; only
`open`/`ping` differ (async, since a browser socket can't block). See
`src/ipc/dm_dcf.c`'s `__EMSCRIPTEN__` branch.

## Security

The DCF wire is **unauthenticated and plaintext by design**. Serve the page over **https**
(so the socket is `wss://`) and run `dcf-ws-bridge` behind **WireGuard** or an
operator-supplied tunnel. Never expose the bridge on an untrusted network.

## Verify

```bash
# WASM build + headless render (Playwright chromium) — the standalone-UI proof.
# WS transport end-to-end (browser-style client -> dcf-ws-bridge -> demod-remote-bridge):
bash audio-stack/bridge/test/ws_loopback.sh    # PASS = PING/PONG + telemetry over the WS relay
# The pure-UDP (native-client) path is the sibling audio-stack/bridge/test/loopback.sh.
```

## Latency & scope

Control is one WS round-trip (sub-millisecond on a LAN / local VM). Telemetry
(meters/scope) is a lossy latest-wins stream at frame rate. **Audio itself does not cross
this link** — it stays on the Linux engine (monitor it there, or via the DCF-Audio path,
a later phase). Full-CJK fonts are a lazy `emscripten_fetch` follow-up; ASCII needs no
blob. The private DSP Studio's `backend/remote.lua` (the consumer that makes the *real*
DSP Studio, not just the example UIs, drive an engine in-browser) is a separate app task.
