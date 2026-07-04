<!-- SPDX-License-Identifier: LGPL-3.0-only -->
# Remote-transport tests — two tiers

These prove the remote/browser path that lets a UI drive the engine over DCF
(`dm.dcf` ↔ `demod-remote-bridge`, and the browser's `dcf-ws-bridge` in front).
There are **two tiers**, and both are worth keeping — they test different things.

## Tier 1 — transport, against `stub_engine` (fast, portable, CI)

`loopback.sh` (UDP) and `ws_loopback.sh` (WebSocket) run the bridge chain against
**`stub_engine`** — a fixture that fakes the engine's two touch-points: it creates
the meters shm and listens on the control socket, replying `{"ok":true}` per op like
the real orchestrator. **Why a stub?** So the *transport* (frame codec, reassembly,
WS↔UDP relay, PING/PONG, telemetry) can be tested on any machine with **no JACK, no
RT-audio, no privileges** — ideal for CI and quick iteration. It deliberately does
*not* run real audio.

```bash
bash audio-stack/bridge/test/loopback.sh      # dm.dcf (UDP)  -> bridge -> stub
bash audio-stack/bridge/test/ws_loopback.sh   # browser (WS)  -> bridge -> stub
```

## Tier 2 — the whole stack, against the REAL engine (`engine_e2e.sh`)

`engine_e2e.sh` proves the browser path drives the **actual** engine end-to-end:

```
ws_client.py --ws--> dcf-ws-bridge --udp--> demod-remote-bridge --unix-->
    demod-orchestrator --spawns--> demod-rt --JACK--> (meters shm)
```

It starts the real `demod-orchestrator` (which spawns the real `demod-rt` on a JACK
server), fronts it with `demod-remote-bridge` + `dcf-ws-bridge`, and drives it with the
browser-style `ws_client.py`. It asserts, against the live engine:

1. **PONG** round-trips over the WebSocket relay.
2. **Real meter telemetry** flows from the live `demod-rt` meters shm.
3. `demod-rt` is a **live JACK client** — `get_health` (via `control_probe.py`) shows it
   `running` with **callbacks advancing** between two probes.
4. A **control op round-trips to the real orchestrator** — a deliberately invalid op
   makes the orchestrator reply `{"ok":false}`, which the bridge reads and logs. (This
   is also the regression test for the bridge's reply-read: it now reads the
   orchestrator's per-op reply before closing, so back-to-back ops are serialized and
   the reply can't land on a half-closed socket — see `demod-remote-bridge.c`
   `control_send_line`, mirroring `src/ipc/demod_control.c`.)

```bash
bash audio-stack/bridge/test/engine_e2e.sh    # browser (WS) -> REAL orchestrator + demod-rt
```

**Requirements / self-skip.** It needs a JACK server and RT privileges (`ulimit -r` ≥ 80).
On a dev box JACK comes from a running **PipeWire** via `pw-jack` (`demod-rt` uses RUNPATH,
so `pw-jack`'s `LD_LIBRARY_PATH` selects PipeWire's libjack). Where those are absent (most
CI), `engine_e2e.sh` prints `SKIP: …` and **exits 0**, so it's safe to wire into CI as a
best-effort gate. The fixed shm names (`/demod-*`, `/dev/shm/demod-rt-meters`) mean one
engine instance at a time.

## Files
- `loopback.sh` / `ws_loopback.sh` — Tier-1 transport proofs (UDP / WebSocket).
- `engine_e2e.sh` — Tier-2 real-engine proof.
- `stub_engine.c` — the Tier-1 fixture (fake control socket + meters shm).
- `ws_client.py` — stdlib browser-style WS client (RFC6455 by hand; encodes real
  DeModFrames + DCF-Text control ops).
- `control_probe.py` — stdlib AF_UNIX JSON-lines `get_health` probe for the orchestrator.
