#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""fake_orchestrator.py — the orchestrator's control socket and demod-rt's
meters segment, for tests that must not need JACK, GHC or a sound card.

Unlike audio-stack/bridge/test/stub_engine.c (which answers {"ok":true} to any
line), this applies the rules of audio-stack/orchestrator/src/DeMoD/Control.hs
to the ops a UI sends:

  - the op is named by "op" (or "verb"); without one the reply is
    {"ok":false,"err":"missing op"}, exactly as Control.hs answers;
  - slot must be an integer in 0..15, gain/pan numbers, on a boolean, with
    Control.hs's error strings;
  - replies are {"v":1,"id":<id>,"ok":true,"data":{...}} on one line.

Then it plays demod-rt: an accepted set_slot_* is applied to the per-slot
mixer state and published through the real DemodRtMeters layout (seqlock,
include/demod/demod_rt_meters.h), with levels that follow gain and mute, so
a UI's readback closes the loop.

  fake_orchestrator.py --socket PATH --shm PATH --log PATH [--loaded N] [--preset S:G:P]

Every received line is appended to --log as received, followed by a tab and
the reply's ok flag, so a test can assert both the bytes on the wire and the
engine's verdict.
"""
import argparse
import json
import mmap
import os
import signal
import socket
import struct
import sys
import threading
import time

SLOTS = 16
SCOPE_N = 256
# seq, scope_n, fx_levels[16], scope_l[256], scope_r[256], fx_levels_l[16],
# fx_levels_r[16], slot_gain[16], slot_pan[16], slot_mute_mask, slot_solo_mask
LAYOUT = "<II16f256f256f16f16f16f16fII"
SIZE = struct.calcsize(LAYOUT)
assert SIZE == 2384, SIZE


class Engine:
    def __init__(self, shm_path, loaded):
        self.lock = threading.Lock()
        self.gain = [1.0] * SLOTS
        self.pan = [0.0] * SLOTS
        self.mute = 0
        self.solo = 0
        self.master = 1.0
        self.bpm = 120.0
        self.bypass = 0
        self.loaded = loaded
        self.t0 = time.monotonic()
        fd = os.open(shm_path, os.O_RDWR | os.O_CREAT, 0o600)
        os.ftruncate(fd, SIZE)
        self.mm = mmap.mmap(fd, SIZE)
        os.close(fd)
        self.seq = 0
        self.publish()

    def levels(self):
        t = time.monotonic() - self.t0
        audible = []
        any_solo = self.solo != 0
        for i in range(SLOTS):
            on = i < self.loaded and not (self.mute >> i) & 1
            if any_solo:
                on = on and (self.solo >> i) & 1
            sig = 0.55 + 0.15 * ((i * 7 + int(t * 10)) % 5) / 4.0
            audible.append(min(1.0, sig * self.gain[i] * self.master) if on else 0.0)
        return audible

    def publish(self):
        lv = self.levels()
        left = [v * (1.0 - max(0.0, self.pan[i])) for i, v in enumerate(lv)]
        right = [v * (1.0 + min(0.0, self.pan[i])) for i, v in enumerate(lv)]
        self.seq += 1  # odd: writing
        struct.pack_into("<I", self.mm, 0, self.seq)
        body = struct.pack(LAYOUT, self.seq, SCOPE_N, *lv, *([0.0] * SCOPE_N), *([0.0] * SCOPE_N),
                           *left, *right, *self.gain, *self.pan, self.mute, self.solo)
        self.mm[4:SIZE] = body[4:]
        self.seq += 1  # even: stable
        struct.pack_into("<I", self.mm, 0, self.seq)

    # ── Control.hs dispatch, for the ops a mixer sends ────────────────────
    def dispatch(self, req):
        rid = req.get("id", "") if isinstance(req, dict) else ""

        def ok(data):
            return {"v": 1, "id": rid, "ok": True, "data": data}

        def err(msg):
            return {"v": 1, "id": rid, "ok": False, "err": msg}

        if not isinstance(req, dict):
            return err("request must be a JSON object")
        op = req.get("op", req.get("verb"))
        if not isinstance(op, str):
            return err("missing op")

        def as_int(k):
            v = req.get(k)
            return v if isinstance(v, int) and not isinstance(v, bool) else None

        def as_num(k):
            v = req.get(k)
            return float(v) if isinstance(v, (int, float)) and not isinstance(v, bool) else None

        def as_bool(k):
            v = req.get(k)
            return v if isinstance(v, bool) else None

        def slot_op(name, field, getter, apply):
            s, v = as_int("slot"), getter(field)
            if s is None or v is None:
                kind = "bool" if getter is as_bool else "number"
                return err("%s requires slot(int) and %s(%s)" % (name, field, kind))
            if not 0 <= s < SLOTS:
                return err("slot out of range (0-15)")
            with self.lock:
                apply(s, v)
                self.publish()
            return ok({"slot": s, field: v})

        def set_bit(mask_name):
            def apply(s, on):
                m = getattr(self, mask_name)
                setattr(self, mask_name, (m | (1 << s)) if on else (m & ~(1 << s)))
            return apply

        if op == "ping":
            return ok({"pong": True, "queued": True})
        if op == "get_health":
            return ok({"alive": True, "callbacks": int((time.monotonic() - self.t0) * 375),
                       "xruns": 0, "cpu_load": 0.12, "children": []})
        if op == "list_slots":
            slots = [{"slot": i, "loaded": i < self.loaded,
                      "path": ("/fx/slot%d.so" % i) if i < self.loaded else None,
                      "bypassed": bool((self.bypass >> i) & 1), "value": 0.0} for i in range(SLOTS)]
            return ok({"count": SLOTS, "bypass_mask": self.bypass, "slots": slots})
        if op == "set_slot_gain":
            return slot_op(op, "gain", as_num, lambda s, v: self.gain.__setitem__(s, v))
        if op == "set_slot_pan":
            return slot_op(op, "pan", as_num, lambda s, v: self.pan.__setitem__(s, v))
        if op == "set_slot_mute":
            return slot_op(op, "on", as_bool, set_bit("mute"))
        if op == "set_slot_solo":
            return slot_op(op, "on", as_bool, set_bit("solo"))
        if op == "bypass_fx":
            return slot_op(op, "on", as_bool, set_bit("bypass"))
        if op == "set_gain":
            g = as_num("gain")
            if g is None:
                return err("set_gain requires gain(number)")
            if g < 0:
                return err("set_gain requires gain(number >= 0)")
            self.master = g
            return ok({"gain": g})
        if op == "set_bpm":
            b = as_num("bpm")
            if b is None:
                return err("set_bpm requires bpm(number)")
            if b <= 0:
                return err("set_bpm requires bpm(number > 0)")
            self.bpm = b
            return ok({"bpm": b})
        if op == "set_param":
            s, i, v = as_int("slot"), as_int("idx"), as_num("value")
            if s is None or i is None or v is None:
                return err("set_param requires slot(int), idx(int), value(number)")
            return ok({"slot": s, "idx": i, "value": v})
        return err("unknown op: " + op)


def serve(engine, sock_path, log_path):
    try:
        os.unlink(sock_path)
    except FileNotFoundError:
        pass
    ls = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    ls.bind(sock_path)
    ls.listen(16)
    log = open(log_path, "a", buffering=1)
    while True:
        cs, _ = ls.accept()
        with cs:
            buf = b""
            while b"\n" not in buf:
                chunk = cs.recv(4096)
                if not chunk:
                    break
                buf += chunk
            line = buf.split(b"\n", 1)[0].decode("utf-8", "replace")
            if not line:
                continue
            try:
                reply = engine.dispatch(json.loads(line))
            except ValueError:
                reply = {"v": 1, "id": "", "ok": False, "err": "invalid JSON"}
            log.write("%s\t%s\n" % (line, "ok" if reply["ok"] else "refused:" + reply["err"]))
            cs.sendall((json.dumps(reply, separators=(",", ":")) + "\n").encode())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--socket", required=True)
    ap.add_argument("--shm", required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--loaded", type=int, default=4, help="slots reported as loaded")
    ap.add_argument("--preset", action="append", default=[], metavar="SLOT:GAIN:PAN",
                    help="engine state the UI did not set (proves its readback comes from here)")
    a = ap.parse_args()
    engine = Engine(a.shm, a.loaded)
    for p in a.preset:
        slot, gain, pan = p.split(":")
        engine.gain[int(slot)] = float(gain)
        engine.pan[int(slot)] = float(pan)
    engine.publish()

    def tick():
        while True:
            time.sleep(0.03)
            with engine.lock:
                engine.publish()
    threading.Thread(target=tick, daemon=True).start()
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    print("[fake-orchestrator] ready", file=sys.stderr, flush=True)
    serve(engine, a.socket, a.log)


if __name__ == "__main__":
    main()
