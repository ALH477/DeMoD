#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-only
# loopback.sh — end-to-end proof of the DCF (HydraMesh/UDP) remote transport.
#
# Builds demod-ui (DCF=1) + the bridge + the stub engine, wires them over
# localhost UDP, and runs examples/dcf_loopback.lua against them. Prints PASS
# and exits 0 only if ping + control-op delivery + telemetry decode all succeed.
# Copyright (C) 2025-2026 DeMoD LLC. LGPL-3.0-only; see LICENSE.
set -u

# Repo root = two levels above this script's dir (audio-stack/bridge/test).
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
BRIDGE_DIR="$ROOT/audio-stack/bridge"

WORK="$(mktemp -d)"
PORT=$(( 47000 + (RANDOM % 1000) ))
export DEMOD_DCF_PORT="$PORT"
export DEMOD_CONTROL_SOCK="$WORK/control.sock"
export DEMOD_RT_METERS_SHM="$WORK/rt-meters"
STUB_LOG="$WORK/stub_ops.log"
: > "$STUB_LOG"

STUB_PID=""
BRIDGE_PID=""
cleanup() {
    [ -n "$BRIDGE_PID" ] && kill "$BRIDGE_PID" 2>/dev/null
    [ -n "$STUB_PID" ]   && kill "$STUB_PID"   2>/dev/null
    wait 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

run() { # run a command inside the nix dev shell (toolchain lives there)
    ( cd "$ROOT" && nix develop --command bash -c "$1" )
}

echo "== [1/5] build demod-ui (DCF=1) =="
# clean first: toggling -DDEMOD_DCF does not invalidate existing .o files, so a
# prior default `make` would leave lua_bindings.o without the dm.dcf registration.
run "make clean >/dev/null 2>&1; make DCF=1 >/dev/null" || { echo "FAIL: demod-ui build (DCF=1)"; exit 1; }
[ -x "$ROOT/demod-ui" ] || { echo "FAIL: ./demod-ui not produced"; exit 1; }

echo "== [2/5] build bridge + stub =="
run "make -C '$BRIDGE_DIR' >/dev/null" || { echo "FAIL: bridge build"; exit 1; }
run "cc -Wall -Wextra -O2 -std=c11 -I'$ROOT/audio-stack/ipc/include' \
        -o '$WORK/stub_engine' '$HERE/stub_engine.c'" \
    || { echo "FAIL: stub_engine build"; exit 1; }

echo "== [3/5] start stub_engine + bridge (udp 127.0.0.1:$PORT) =="
"$WORK/stub_engine" "$STUB_LOG" &
STUB_PID=$!
sleep 0.4
"$BRIDGE_DIR/demod-remote-bridge" &
BRIDGE_PID=$!
sleep 0.4

if ! kill -0 "$STUB_PID" 2>/dev/null;   then echo "FAIL: stub_engine died"; exit 1; fi
if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then echo "FAIL: bridge died"; exit 1; fi

echo "== [4/5] run dcf_loopback.lua (headless) =="
run "SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
     DEMOD_DCF_PORT='$PORT' DEMOD_CONTROL_SOCK='$DEMOD_CONTROL_SOCK' \
     timeout 20 ./demod-ui examples/dcf_loopback.lua"
LUA_RC=$?
if [ "$LUA_RC" -ne 0 ]; then echo "FAIL: dcf_loopback.lua exited $LUA_RC"; exit 1; fi

echo "== [5/5] assert control op reached the stub control socket =="
# Bridge writes JSON ops from dm.dcf.send() into the stub's control-socket log.
if grep -q '"op":"ping"' "$STUB_LOG"; then
    echo "control op present in stub log: $(tr -d '\n' < "$STUB_LOG")"
else
    echo "FAIL: control op not found in stub log"
    echo "--- stub log ---"; cat "$STUB_LOG"; echo "--- end ---"
    exit 1
fi

echo "== [6/6] connection notification + op-reply event (dm.dcf.status/poll_event) =="
# remote_client asserts it saw a 'connected' event and an accepted op-reply
# (the stub replies {"ok":true}); the loud-fail path is engine_e2e.sh's job.
run "SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
     DEMOD_DCF_PORT='$PORT' DEMOD_RC_TEST=1 \
     DEMOD_RC_OP='{\"v\":1,\"op\":\"ping\"}' DEMOD_RC_EXPECT=ok \
     timeout 20 ./demod-ui examples/remote_client.lua"
[ $? -eq 0 ] || { echo "FAIL: remote_client selftest (connected + op_reply)"; exit 1; }

echo
echo "PASS: DCF remote transport loopback (ping + control op + telemetry + events)"
exit 0
