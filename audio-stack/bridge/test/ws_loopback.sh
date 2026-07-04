#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-only
# ws_loopback.sh — end-to-end proof of the *browser* DCF transport path.
#
# The browser (WASM) client can't open raw UDP, so it speaks binary WebSocket to
# HydraMesh's stateless dcf-ws-bridge, which relays each frame verbatim to the
# UDP demod-remote-bridge. This wires that whole chain on localhost and drives it
# with a browser-style WS client (Python stdlib — the same 17-byte DeModFrames
# src/ipc/dm_dcf.c's __EMSCRIPTEN__ branch emits):
#
#   ws_client.py --ws--> dcf-ws-bridge --udp--> demod-remote-bridge
#                                                  |  control.sock / meters shm
#                                                 stub_engine
#
# Prints PASS and exits 0 only if a real DeModFrame PING round-trips to a PONG
# and live meter telemetry flows back — all over the WebSocket relay.
# The pure-UDP path is audio-stack/bridge/test/loopback.sh.
# Copyright (C) 2025-2026 DeMoD LLC. LGPL-3.0-only; see LICENSE.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
BRIDGE_DIR="$ROOT/audio-stack/bridge"

WORK="$(mktemp -d)"
PORT=$(( 47000 + (RANDOM % 1000) ))
WSPORT=$(( 7000 + (RANDOM % 500) ))
export DEMOD_DCF_PORT="$PORT"
export DEMOD_CONTROL_SOCK="$WORK/control.sock"
export DEMOD_RT_METERS_SHM="$WORK/rt-meters"
STUB_LOG="$WORK/stub_ops.log"; : > "$STUB_LOG"

STUB_PID=""; BRIDGE_PID=""; WSB_PID=""
cleanup() {
    for p in "$WSB_PID" "$BRIDGE_PID" "$STUB_PID"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
    wait 2>/dev/null; rm -rf "$WORK"
}
trap cleanup EXIT
run() { ( cd "$ROOT" && nix develop --command bash -c "$1" ); }

echo "== [1/4] build dcf-ws-bridge (vendored) + demod-remote-bridge + stub =="
( cd "$ROOT" && nix build .#dcf-ws-bridge -o "$WORK/wsb" ) || { echo "FAIL: dcf-ws-bridge build"; exit 1; }
WSB="$WORK/wsb/bin/dcf-ws-bridge"
run "make -C '$BRIDGE_DIR' >/dev/null" || { echo "FAIL: demod-remote-bridge build"; exit 1; }
run "cc -Wall -Wextra -O2 -std=c11 -I'$ROOT/audio-stack/ipc/include' \
        -o '$WORK/stub_engine' '$HERE/stub_engine.c'" \
    || { echo "FAIL: stub_engine build"; exit 1; }

echo "== [2/4] start stub + demod-remote-bridge (udp :$PORT) + dcf-ws-bridge (ws :$WSPORT) =="
"$WORK/stub_engine" "$STUB_LOG" & STUB_PID=$!
sleep 0.4
"$BRIDGE_DIR/demod-remote-bridge" & BRIDGE_PID=$!
sleep 0.3
"$WSB" --listen 127.0.0.1:$WSPORT & WSB_PID=$!
sleep 0.4
for n in "stub:$STUB_PID" "demod-remote-bridge:$BRIDGE_PID" "dcf-ws-bridge:$WSB_PID"; do
    kill -0 "${n#*:}" 2>/dev/null || { echo "FAIL: ${n%%:*} died"; exit 1; }
done

echo "== [3/4] run browser-style WS client (real DeModFrame PING) =="
run "python3 '$HERE/ws_client.py' 'ws://127.0.0.1:$WSPORT' '127.0.0.1' '$PORT'"
RC=$?
[ "$RC" -eq 0 ] || { echo "FAIL: ws client rc=$RC"; exit 1; }

echo "== [4/4] wire summary =="
echo "  WS client -> dcf-ws-bridge -> UDP -> demod-remote-bridge -> stub_engine (and back)"
echo
echo "PASS: DCF remote transport over the WebSocket bridge (browser path)"
exit 0
