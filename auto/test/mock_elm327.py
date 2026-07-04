#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
# Copyright (c) 2026 DeMoD LLC.
# mock_elm327.py — a fake ELM327 on a pty, so obd2-reader.py can be tested with
# no hardware. Prints the slave device path on line 1, then answers AT + mode-01
# PID requests with canned frames until killed.
import os
import pty
import select
import sys

# Canned mode-01 responses (spaces stripped by the reader anyway):
#   010C 41 0C 1A F0 -> rpm = 0x1AF0/4 = 1724
#   010D 41 0D 3C    -> speed = 60 km/h
#   0105 41 05 5A    -> coolant = 0x5A-40 = 50 C
#   012F 41 2F 80    -> fuel = 128*100/255 = 50%
#   0111 41 11 20    -> throttle = 32*100/255 = 13%
RESP = {
    "010C": "410C1AF0", "010D": "410D3C", "0105": "41055A",
    "012F": "412F80", "0111": "411120",
}


def answer(cmd):
    if cmd == "ATRV":
        return "12.5V"
    if cmd.startswith("AT"):
        return "ELM327 v1.5" if cmd == "ATZ" else "OK"
    return RESP.get(cmd, "NO DATA")


def main():
    master, slave = os.openpty()
    sys.stdout.write(os.ttyname(slave) + "\n")
    sys.stdout.flush()
    buf = b""
    while True:
        r, _, _ = select.select([master], [], [], 30)
        if master not in r:
            return 0
        try:
            data = os.read(master, 256)
        except OSError:
            return 0
        if not data:
            return 0
        buf += data
        while b"\r" in buf:
            line, _, buf = buf.partition(b"\r")
            cmd = line.decode("ascii", "ignore").strip().upper()
            if cmd:
                os.write(master, (answer(cmd) + "\r>").encode())


if __name__ == "__main__":
    sys.exit(main())
