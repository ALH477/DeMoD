#!/usr/bin/env bash
# SPDX-License-Identifier: LGPL-3.0-only
# gate.sh — demod-remote-bridge's admission rules, measured end to end.
#
# Builds the bridge (which links Exsecutor's custos gate) and stub_engine, then
# runs gate_probe.py against them: a false frame, a bad CRC, the wrong version
# and an oversized datagram get no answer and never become the telemetry peer;
# a multi-line control op never reaches the control socket. Every one of those
# checks fails on the bridge before the gate.
#
# The source-policy leg needs a non-private address bound on this machine. It
# runs inside an unprivileged user+network namespace when `unshare -rn` and `ip`
# are available, and is otherwise reported as SKIP — never silently omitted.
# Copyright (C) 2026 DeMoD LLC. LGPL-3.0-only; see LICENSE.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
BRIDGE_DIR="$ROOT/audio-stack/bridge"
WORK="$(mktemp -d)"
PORT=$(( 48000 + (RANDOM % 1000) ))
STUB_LOG="$WORK/stub_ops.log"
: > "$STUB_LOG"
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; wait 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

# Build with the host toolchain when it is there, else inside the dev shell.
build() {
    if command -v cc >/dev/null && command -v make >/dev/null; then bash -c "$1"
    else ( cd "$ROOT" && nix develop --command bash -c "$1" ); fi
}

echo "== [1/3] build bridge (+ custos) and stub =="
build "make -C '$BRIDGE_DIR' >/dev/null" || { echo "FAIL: bridge build"; exit 1; }
build "cc -Wall -Wextra -O2 -std=c11 -I'$ROOT/audio-stack/ipc/include' \
       -o '$WORK/stub_engine' '$HERE/stub_engine.c'" || { echo "FAIL: stub build"; exit 1; }

# One stack (stub + bridge) and one probe run, in the current namespace.
run_stack() { # run_stack <bind> <probe args...>
    local bind=$1; shift
    DEMOD_CONTROL_SOCK="$WORK/control.sock" DEMOD_RT_METERS_SHM="$WORK/rt-meters" \
        "$WORK/stub_engine" "$STUB_LOG" 2>/dev/null & PIDS+=($!)
    sleep 0.3
    DEMOD_DCF_PORT="$PORT" DEMOD_DCF_BIND="$bind" DEMOD_CONTROL_SOCK="$WORK/control.sock" \
        DEMOD_RT_METERS_SHM="$WORK/rt-meters" \
        "$BRIDGE_DIR/demod-remote-bridge" 2>"$WORK/bridge.err" & PIDS+=($!)
    sleep 0.3
    python3 "$HERE/gate_probe.py" "$PORT" "$STUB_LOG" "$@"
}

echo "== [2/3] admission checks (loopback) =="
run_stack 127.0.0.1
RC=$?
echo "--- bridge stderr ---"; cat "$WORK/bridge.err"; echo "--- end ---"
[ "$RC" -eq 0 ] || { echo "FAIL: gate_probe"; exit 1; }
for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; wait 2>/dev/null; PIDS=()

echo "== [3/3] source policy (non-private sender, in a network namespace) =="
# 203.0.113.0/24 is TEST-NET-3: documentation space, never routed, not private.
if command -v unshare >/dev/null && command -v ip >/dev/null \
   && unshare -rn true 2>/dev/null; then
    export -f run_stack build
    export WORK PORT STUB_LOG HERE ROOT BRIDGE_DIR
    unshare -rn bash -c '
        set -u; PIDS=()
        # Both addresses on lo: no dummy-interface module needed, and the
        # bridge (bound to 0.0.0.0) sees each as the true source.
        ip link set lo up && ip addr add 203.0.113.7/32 dev lo \
          && ip addr add 10.9.9.9/32 dev lo \
          || { echo "SKIP: could not configure the namespace"; exit 77; }
        GATE_PRIVATE_SRC=10.9.9.9 run_stack 0.0.0.0 --public-src 203.0.113.7
        rc=$?; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; wait 2>/dev/null
        echo "--- bridge stderr ---"; cat "$WORK/bridge.err"; echo "--- end ---"
        exit $rc'
    RC=$?
    if [ "$RC" -eq 77 ]; then echo "SKIP: source-policy leg (namespace setup failed)"
    elif [ "$RC" -ne 0 ]; then echo "FAIL: source policy"; exit 1; fi
else
    echo "SKIP: source-policy leg needs \`unshare -rn\` and \`ip\` (not available here)"
fi

echo "PASS: demod-remote-bridge admits only gated frames from private senders"
