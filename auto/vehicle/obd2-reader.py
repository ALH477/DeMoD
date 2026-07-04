#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 DeMoD LLC.
"""
obd2-reader.py — a dependency-free ELM327 OBD-II reader for DeMoD Auto.

Opens a serial ELM327 adapter (USB `/dev/ttyUSB*` or Bluetooth `/dev/rfcomm*`),
initialises it, polls a handful of standard mode-01 PIDs, and writes the latest
values as a `key=value` line to $DEMOD_VEHICLE_STATE (~5 Hz). The Lua telemetry
provider (vehicle/telemetry.lua, `obd2` backend) reads that file; if it's stale
or absent, the app falls back to the simulator.

Pure Python standard library only (termios + os + select) — no pyserial.

Env: DEMOD_OBD_DEV (device, default /dev/ttyUSB0), DEMOD_OBD_BAUD (default 38400),
     DEMOD_VEHICLE_STATE (state file, default /tmp/demod-vehicle.kv).
Read-only telemetry — this never writes to the vehicle bus.
"""
import os
import re
import select
import sys
import termios
import time

DEV = os.environ.get("DEMOD_OBD_DEV") or (sys.argv[1] if len(sys.argv) > 1 else "/dev/ttyUSB0")
BAUD = int(os.environ.get("DEMOD_OBD_BAUD") or "38400")
STATE = os.environ.get("DEMOD_VEHICLE_STATE") or "/tmp/demod-vehicle.kv"

# Standard mode-01 PIDs we poll (hex pid, name, decoder).
PIDS = [
    ("0C", "rpm",      lambda a, b: round(((a * 256) + b) / 4.0)),       # RPM
    ("0D", "speed",    lambda a, b: a),                                   # km/h
    ("05", "coolant",  lambda a, b: a - 40),                              # deg C
    ("2F", "fuel",     lambda a, b: round(a * 100.0 / 255.0)),            # %
    ("11", "throttle", lambda a, b: round(a * 100.0 / 255.0)),            # %
]


def open_serial(path, baud):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY)
    a = termios.tcgetattr(fd)
    iflag, oflag, cflag, lflag, ispeed, ospeed, cc = a
    speed = getattr(termios, "B%d" % baud, termios.B38400)
    iflag = 0
    oflag = 0
    cflag = (cflag | termios.CLOCAL | termios.CREAD) & ~termios.PARENB & ~termios.CSTOPB
    cflag = (cflag & ~termios.CSIZE) | termios.CS8
    lflag = 0
    cc = list(cc)
    cc[termios.VMIN] = 0
    cc[termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, [iflag, oflag, cflag, lflag, speed, speed, cc])
    return fd


def read_until_prompt(fd, timeout=1.5):
    buf = b""
    end = time.time() + timeout
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], max(0.0, end - time.time()))
        if fd in r:
            try:
                c = os.read(fd, 256)
            except OSError:
                break
            if not c:
                break
            buf += c
            if b">" in buf:
                break
    return buf.decode("ascii", "ignore")


def cmd(fd, s, timeout=1.5):
    os.write(fd, (s + "\r").encode())
    return read_until_prompt(fd, timeout)


def parse_01(resp, pid):
    hexs = "".join(ch for ch in resp.upper() if ch in "0123456789ABCDEF")
    i = hexs.find("41" + pid)          # "41" = positive response to mode 01
    if i < 0:
        return None
    return hexs[i + 4:]


def decode(pid, dec, data):
    if not data or len(data) < 2:
        return None
    a = int(data[0:2], 16)
    b = int(data[2:4], 16) if len(data) >= 4 else 0
    try:
        return dec(a, b)
    except Exception:  # noqa: BLE001
        return None


def write_state(d):
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        f.write(" ".join("%s=%s" % (k, v) for k, v in d.items()))
    os.replace(tmp, STATE)   # atomic: the reader never yields a partial line


def main():
    try:
        fd = open_serial(DEV, BAUD)
    except OSError as e:
        sys.stderr.write("obd2: cannot open %s: %s\n" % (DEV, e))
        return 2
    for c in ("ATZ", "ATE0", "ATL0", "ATS0", "ATSP0"):
        cmd(fd, c, timeout=2.0)
        time.sleep(0.05)
    sys.stderr.write("obd2: %s initialised, polling %d PIDs -> %s\n" % (DEV, len(PIDS), STATE))

    while True:
        d = {}
        for pid, name, dec in PIDS:
            v = decode(pid, dec, parse_01(cmd(fd, "01" + pid), pid))
            if v is not None:
                d[name] = v
        m = re.search(r"(\d+\.\d+)", cmd(fd, "ATRV"))   # battery/module voltage
        if m:
            d["volts"] = m.group(1)
        d["ts"] = int(time.time())
        try:
            write_state(d)
        except OSError as e:
            sys.stderr.write("obd2: state write failed: %s\n" % e)
        time.sleep(0.2)


if __name__ == "__main__":
    sys.exit(main())
