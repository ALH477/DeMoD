#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-3.0-only
# Copyright (C) 2025-2026 DeMoD LLC.
# control_probe.py <control.sock> — a stdlib AF_UNIX JSON-lines client that asks
# the real orchestrator `get_health` and prints a parseable summary. Used by
# engine_e2e.sh to confirm demod-rt is a live child with advancing callbacks.
import json, socket, sys

SOCK = sys.argv[1] if len(sys.argv) > 1 else "/run/demod/control.sock"

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(2.0)
s.connect(SOCK)
s.sendall(b'{"v":1,"id":"h","op":"get_health"}\n')

buf = b""
while b"\n" not in buf:
    chunk = s.recv(4096)
    if not chunk:
        break
    buf += chunk
s.close()

reply = json.loads(buf.split(b"\n", 1)[0].decode())
ok = reply.get("ok", False)
data = reply.get("data", {}) or {}
callbacks = data.get("callbacks", 0)
alive = data.get("alive", False)
rt_status = "absent"
for c in data.get("children", []):
    if c.get("name") == "demod-rt":
        rt_status = c.get("status", "?")
        break
print(f"ok={ok} alive={alive} rt_status={rt_status} callbacks={callbacks}")
sys.exit(0 if ok else 1)
