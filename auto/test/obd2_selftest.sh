#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# obd2_selftest.sh — verify the ELM327 reader with no hardware: a mock ELM327 on
# a pty answers obd2-reader.py's PID requests; we assert the parsed state file.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTO="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"
STATE="$WORK/veh.kv"
trap 'kill $MOCK 2>/dev/null; rm -rf "$WORK"' EXIT

python3 "$HERE/mock_elm327.py" >"$WORK/pty.txt" 2>/dev/null &
MOCK=$!
sleep 0.5
PTY="$(head -1 "$WORK/pty.txt")"
[ -n "$PTY" ] || { echo "FAIL: mock ELM327 did not start"; exit 1; }
echo "mock ELM327 on $PTY"

DEMOD_OBD_DEV="$PTY" DEMOD_VEHICLE_STATE="$STATE" timeout 2 python3 "$AUTO/vehicle/obd2-reader.py" 2>/dev/null
[ -f "$STATE" ] || { echo "FAIL: no state file written"; exit 1; }
echo "state: $(cat "$STATE")"

python3 - "$STATE" <<'PY'
import sys
kv = dict(x.split("=") for x in open(sys.argv[1]).read().split())
want = {"rpm": "1724", "speed": "60", "coolant": "50", "fuel": "50", "volts": "12.5"}
bad = {k: (kv.get(k), v) for k, v in want.items() if kv.get(k) != v}
if bad:
    print("FAIL:", bad); sys.exit(1)
print("PASS: ELM327 reader parsed rpm/speed/coolant/fuel/volts correctly")
PY
