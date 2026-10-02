#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# mixer_e2e.sh — DeMoD Mixer against an engine, end to end, headless.
#
# tests/fake_orchestrator.py stands in for the orchestrator + demod-rt: it
# applies Control.hs's op rules and publishes state through the real meters
# segment. The mixer replays apps/mixer/test/gestures.lua as its pointer, then
# prints what its strips show. Checked:
#   - each gesture became the right op on the wire, and the engine accepted it
#     (a drag sends a stream of gains, not one);
#   - the strips show the ENGINE's state: slot 5 was preset in the engine and
#     never touched by the UI, so its value can only have come from readback;
#   - nothing was refused.
# Not covered: SDL turning a real finger into dm.mouse_down (the replay
# bypasses it), and a real engine (audio-stack/bridge/test/engine_e2e.sh).
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WORK="$(mktemp -d)"
cleanup() { [ -n "${FAKE:-}" ] && kill "$FAKE" 2>/dev/null; wait 2>/dev/null; [ -n "${KEEP:-}" ] && cp "$WORK"/out.txt "$WORK"/ops.log "$KEEP"/ 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
fail=0
pass() { echo "PASS: $*"; }
bad() { echo "FAIL: $*"; fail=1; }

python3 "$ROOT/tests/fake_orchestrator.py" --socket "$WORK/control.sock" --shm "$WORK/meters" \
  --log "$WORK/ops.log" --loaded 10 --preset 5:0.5:-0.25 &
FAKE=$!
for _ in $(seq 150); do [ -S "$WORK/control.sock" ] && break; sleep 0.1; done
[ -S "$WORK/control.sock" ] || { echo "FAIL: fake orchestrator did not start"; exit 1; }

DEMOD_CONTROL_SOCK="$WORK/control.sock" DEMOD_RT_METERS_SHM="$WORK/meters" \
DEMOD_MIXER_GESTURES="$ROOT/apps/mixer/test/gestures.lua" DEMOD_MIXER_CONFIG="$WORK/cfg.lua" \
DEMOD_WIN=1280x800 SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
  timeout 60 "$ROOT/demod-ui" "$ROOT/apps/mixer/main.lua" > "$WORK/out.txt" 2>"$WORK/err.txt"
rc=$?
[ $rc -eq 0 ] || { bad "the mixer exited $rc"; cat "$WORK/err.txt" | tail -5; }

python3 - "$WORK/ops.log" "$WORK/out.txt" <<'PY' || fail=1
import json, sys
ops = []
for line in open(sys.argv[1]):
    raw, verdict = line.rstrip("\n").split("\t", 1)
    ops.append((json.loads(raw), verdict))
rb = {}
backend = None
for line in open(sys.argv[2]):
    if line.startswith("READBACK slot="):
        f = dict(kv.split("=") for kv in line.split()[1:])
        rb[int(f["slot"])] = f
    elif line.startswith("READBACK backend="):
        backend = line.split()[1].split("=")[1]
ok = True
def check(name, cond):
    global ok
    print(("PASS: " if cond else "FAIL: ") + name)
    ok = ok and cond
def last(op, **kw):
    hits = [o for o, v in ops if o.get("op") == op and all(o.get(k) == x for k, x in kw.items())]
    return hits[-1] if hits else None

check("the mixer talked to the engine, not the simulator", backend == "local")
check("every op was accepted by the engine", ops and all(v == "ok" for _, v in ops))
gains0 = [o for o, _ in ops if o.get("op") == "set_slot_gain" and o.get("slot") == 0]
check("dragging channel 1 streams gains (%d ops), not one" % len(gains0), len(gains0) >= 3)
g0 = gains0[-1]["gain"] if gains0 else None
check("channel 1 lands near -40 dB, a quarter of the travel (gain %s)" % g0,
      g0 is not None and 0.0085 <= g0 <= 0.0125)
p1 = last("set_slot_pan", slot=1)
check("channel 2 panned hard right", p1 is not None and p1["pan"] == 1)
check("M on channel 3 mutes slot 2", last("set_slot_mute", slot=2, on=True) is not None)
check("S on channel 4 solos slot 3", last("set_slot_solo", slot=3, on=True) is not None)
m = last("set_gain")
check("master pushed to the top (+3.5 dB, gain 1.5)", m is not None and abs(m["gain"] - 1.5) < 1e-6)
g8 = last("set_slot_gain", slot=8)
check("page 2: its first strip is channel 9", g8 is not None and abs(g8["gain"] - 1.5) < 1e-6)
check("no op carries the old \"cmd\" key", all("cmd" not in o for o, _ in ops))
r = lambda s, k: float(rb[s][k]) if s in rb else float("nan")
check("readback: channel 1 shows the gain the engine applied",
      g0 is not None and abs(r(0, "gain") - g0) < 1e-4)
check("readback: channel 2's pan, channel 3 muted, channel 4 soloed, channel 9 at 1.5",
      r(1, "pan") == 1.0 and rb[2]["mute"] == "1" and rb[3]["solo"] == "1" and abs(r(8, "gain") - 1.5) < 1e-4)
check("readback: channel 6 shows the engine's preset (gain 0.5, pan -0.25), which the UI never sent",
      abs(r(5, "gain") - 0.5) < 1e-4 and abs(r(5, "pan") + 0.25) < 1e-4)
sys.exit(0 if ok else 1)
PY
[ $fail -eq 0 ] && echo "mixer e2e: gestures became accepted ops, and the strips read the engine back"
exit $fail
