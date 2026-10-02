#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# ctl_wire.sh — the dm.ctl_* helpers against the orchestrator's real op rules.
#
# Starts tests/fake_orchestrator.py (Control.hs's dispatch: no "op" -> "missing
# op") and runs tests/ctl_wire.lua in a headless demod-ui. Passes only if the
# engine accepted every helper's line, ctl_request handed back the reply, and
# the wire carried "op" — the helpers sent "cmd" until 2026-10, which the real
# orchestrator refused, so every one of them failed against it.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
cleanup() { [ -n "${FAKE:-}" ] && kill "$FAKE" 2>/dev/null; wait 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

python3 "$ROOT/tests/fake_orchestrator.py" --socket "$WORK/control.sock" \
  --shm "$WORK/meters" --log "$WORK/ops.log" &
FAKE=$!
for _ in $(seq 150); do [ -S "$WORK/control.sock" ] && break; sleep 0.1; done
[ -S "$WORK/control.sock" ] || { echo "FAIL: fake orchestrator did not start"; exit 1; }

DEMOD_CONTROL_SOCK="$WORK/control.sock" SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
  timeout 20 "$ROOT/demod-ui" "$ROOT/tests/ctl_wire.lua"
rc=$?

if grep -q '"cmd"' <(cut -f1 "$WORK/ops.log" | grep -v '"id":"' ); then
  echo 'FAIL: a helper sent "cmd"'; rc=1
fi
for op in set_param bypass_fx set_bpm set_gain; do
  grep -q "\"op\":\"$op\".*	ok$" "$WORK/ops.log" || { echo "FAIL: no accepted $op on the wire"; rc=1; }
done
[ $rc -eq 0 ] && echo "ctl wire: all helpers speak the orchestrator's protocol"
exit $rc
