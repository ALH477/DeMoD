#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-only
# engine_e2e.sh — TIER 2: the browser path against the REAL engine.
#
# Where loopback.sh / ws_loopback.sh prove the transport with stub_engine (a
# hardware-free fixture), this drives the ACTUAL stack: a browser-style WS client
# through dcf-ws-bridge -> demod-remote-bridge -> the real demod-orchestrator,
# which spawns the real demod-rt on a JACK server. It proves "it works
# completely": a live engine, real meters, and a real control op round-tripping
# to the orchestrator over the browser wire.
#
#   ws_client.py --ws--> dcf-ws-bridge --udp--> demod-remote-bridge --unix-->
#       demod-orchestrator --spawns--> demod-rt --JACK--> (meters shm)
#
# Needs a JACK server + RT priv, so it SELF-SKIPS (exit 0) where those are
# absent — safe to run in CI. On this box JACK comes from the running PipeWire
# via pw-jack; demod-rt uses RUNPATH so pw-jack's LD_LIBRARY_PATH selects it.
# Copyright (C) 2025-2026 DeMoD LLC. LGPL-3.0-only; see LICENSE.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
BRIDGE_DIR="$ROOT/audio-stack/bridge"

# ── Preflight: skip cleanly where the real engine can't run ─────────────
skip() { echo "SKIP: $*"; exit 0; }
RTP="$(ulimit -r 2>/dev/null || echo 0)"
[ "$RTP" = "unlimited" ] || { [ "$RTP" -ge 80 ] 2>/dev/null || skip "real-engine E2E needs rtprio >= 80 (ulimit -r=$RTP)"; }
pgrep -x pipewire >/dev/null 2>&1 || skip "real-engine E2E needs a JACK server (no running PipeWire here)"
PWJACK="$(nix shell nixpkgs#pipewire.jack --command bash -c 'command -v pw-jack' 2>/dev/null)"
[ -n "$PWJACK" ] && [ -x "$PWJACK" ] || skip "pw-jack (nixpkgs#pipewire.jack) unavailable"

WORK="$(mktemp -d)"
PORT=$(( 47000 + (RANDOM % 1000) ))
WSPORT=$(( 7000 + (RANDOM % 500) ))
export DEMOD_DCF_PORT="$PORT"
export DEMOD_CONTROL_SOCK="$WORK/control.sock"
# demod-rt writes the FIXED path /dev/shm/demod-rt-meters; leave DEMOD_RT_METERS_SHM
# unset so the bridge reads that same default.

ORCH_PID=""; BRIDGE_PID=""; WSB_PID=""
cleanup() {
    for p in "$WSB_PID" "$BRIDGE_PID" "$ORCH_PID"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done
    pkill -f "demod-rt --core" 2>/dev/null
    wait 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "== [1/6] build the real engine + bridges =="
( cd "$ROOT" \
  && nix build .#demod-orchestrator -o "$WORK/orch" \
  && nix build .#demod-rt           -o "$WORK/rt"   \
  && nix build .#dcf-ws-bridge      -o "$WORK/wsb" ) \
    || { echo "FAIL: nix build engine"; exit 1; }
ORCH="$WORK/orch/bin/demod-orchestrator"
RT="$WORK/rt/bin/demod-rt"
WSB="$WORK/wsb/bin/dcf-ws-bridge"
# demod-remote-bridge from source (carries the reply-read fix under test).
( cd "$ROOT" && nix develop --command make -C audio-stack/bridge >/dev/null ) \
    || { echo "FAIL: demod-remote-bridge build"; exit 1; }

echo "== [2/6] start real orchestrator under pw-jack (spawns demod-rt on JACK) =="
"$PWJACK" "$ORCH" --control-socket "$WORK/control.sock" --rt-binary "$RT" >"$WORK/orch.log" 2>&1 &
ORCH_PID=$!
# Wait for demod-rt to come up (get_health reports the child running).
rt_up=0
for _ in $(seq 1 40); do
    sleep 0.25
    if python3 "$HERE/control_probe.py" "$WORK/control.sock" 2>/dev/null | grep -q "rt_status=running"; then
        rt_up=1; break
    fi
done
[ "$rt_up" = 1 ] || { echo "FAIL: demod-rt did not reach 'running'"; echo "--- orch.log ---"; tail -15 "$WORK/orch.log"; exit 1; }
H1="$(python3 "$HERE/control_probe.py" "$WORK/control.sock")"
CB1="$(echo "$H1" | sed -n 's/.*callbacks=\([0-9]*\).*/\1/p')"
echo "  engine health: $H1"

echo "== [3/6] start demod-remote-bridge (udp :$PORT) + dcf-ws-bridge (ws :$WSPORT) =="
DEMOD_DCF_PORT="$PORT" DEMOD_CONTROL_SOCK="$WORK/control.sock" \
    "$BRIDGE_DIR/demod-remote-bridge" >"$WORK/bridge.log" 2>&1 & BRIDGE_PID=$!
sleep 0.3
"$WSB" --listen 127.0.0.1:$WSPORT & WSB_PID=$!
sleep 0.4
for n in "orchestrator:$ORCH_PID" "demod-remote-bridge:$BRIDGE_PID" "dcf-ws-bridge:$WSB_PID"; do
    kill -0 "${n#*:}" 2>/dev/null || { echo "FAIL: ${n%%:*} died"; exit 1; }
done

echo "== [4/6] browser-style WS client: PING + a valid op + a deliberately invalid op =="
# The invalid op makes the REAL orchestrator reply {"ok":false}; the fixed bridge
# reads that reply and logs 'control op rejected' — a positive proof the control
# op traversed the whole browser path to the real engine and back.
WSOUT="$(python3 "$HERE/ws_client.py" "ws://127.0.0.1:$WSPORT" "127.0.0.1" "$PORT" \
            --op '{"v":1,"id":"ok","op":"set_bpm","bpm":128}' \
            --op '{"v":1,"id":"bad","op":"__e2e_probe_invalid__"}' 2>&1)"
echo "$WSOUT" | grep -E "pong=|PASS|FAIL"
echo "$WSOUT" | grep -q "pong=True" || { echo "FAIL: no PONG over the WS relay"; exit 1; }
echo "$WSOUT" | grep -q "telemetry_frames=[1-9]" || { echo "FAIL: no real meter telemetry over the WS relay"; exit 1; }

echo "== [5/6] confirm the engine is a live demod-rt (callbacks advanced) =="
sleep 0.5
H2="$(python3 "$HERE/control_probe.py" "$WORK/control.sock")"
CB2="$(echo "$H2" | sed -n 's/.*callbacks=\([0-9]*\).*/\1/p')"
echo "  engine health: $H2"
echo "$H2" | grep -q "rt_status=running" || { echo "FAIL: demod-rt not running"; exit 1; }
[ "${CB2:-0}" -gt "${CB1:-0}" ] 2>/dev/null || { echo "FAIL: JACK callbacks did not advance ($CB1 -> $CB2)"; exit 1; }

echo "== [6/7] confirm the control op reached the REAL orchestrator (reply round-trip) =="
if grep -q "control op rejected" "$WORK/bridge.log"; then
    echo "  orchestrator rejected the invalid op and the bridge read the reply:"
    grep "control op rejected" "$WORK/bridge.log" | tail -1 | sed 's/^/    /'
else
    echo "FAIL: expected the real orchestrator to reject the invalid op (control round-trip)"
    echo "--- bridge.log ---"; tail -8 "$WORK/bridge.log"
    exit 1
fi

echo "== [7/7] the UI's loud fail: dm.dcf surfaces the rejection as an op-reply event =="
# remote_client (native dm.dcf) connects to the real engine, sends an invalid op,
# and must raise a 'connected' notification + an op_reply(ok=false) — the loud fail.
# clean first: toggling -DDEMOD_DCF doesn't invalidate .o files, so a prior
# plain `make` would leave dm.dcf unregistered (same gotcha as loopback.sh).
( cd "$ROOT" && nix develop --command bash -c "make clean >/dev/null 2>&1; make DCF=1 >/dev/null 2>&1" ) \
    || { echo "FAIL: demod-ui DCF=1 build"; exit 1; }
DEMOD_DCF_HOST=127.0.0.1 DEMOD_DCF_PORT="$PORT" DEMOD_RC_TEST=1 \
    DEMOD_RC_OP='{"v":1,"op":"__loud_fail_probe__"}' DEMOD_RC_EXPECT=fail \
    SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
    timeout 20 "$ROOT/demod-ui" examples/remote_client.lua 2>&1 | grep -E "\[toast\]|PASS|FAIL"
rc=${PIPESTATUS[0]}
[ "$rc" -eq 0 ] || { echo "FAIL: remote_client did not surface the loud fail (rc=$rc)"; exit 1; }

echo
echo "PASS: browser path drives the REAL engine"
echo "  - PONG + real meter telemetry over the WebSocket relay"
echo "  - live demod-rt on JACK (callbacks $CB1 -> $CB2)"
echo "  - a control op round-tripped to the real orchestrator (reply read by the bridge)"
echo "  - the UI raised a 'connected' notification + a loud op_reply(ok=false) rejection"
exit 0
