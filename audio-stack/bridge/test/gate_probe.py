#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-3.0-only
# Copyright (C) 2026 DeMoD LLC.
"""gate_probe.py -- what demod-remote-bridge refuses, measured from outside.

Drives a running bridge (fronting stub_engine) over UDP and checks behaviour,
not structure: a refused datagram must produce no reply, must not reach the
control socket, and must not become the telemetry peer. Every check below
fails against the bridge before the gate (it learned the peer from any 17
bytes, cut oversized datagrams down to 17, and wrote multi-line ops verbatim).

Usage: gate_probe.py <bridge_port> <stub_log> [--public-src ADDR]
  --public-src: also send a valid PING from ADDR (a non-private address that
  must be bound locally, e.g. inside a network namespace) and require it to be
  ignored. gate.sh sets that up when it can and reports SKIP when it cannot.
Exit 0 = every check passed. Prints one PASS/FAIL line per check.
"""
import os
import socket
import struct
import sys
import time

SYNC, VER, DATA, CTRL, UI_SRC, CTRL_CHAN = 0xD3, 1, 0, 3, 2, 1

# A real false HydraModem output: 17 bytes that passed HydraModem's own CRC-16
# on random data (Punctim hydramodem/docs/RECEIVER.md, "False frames"). It is
# not a DeModFrame, and before Punctim gated dcf.bridge it was relayed anyway.
FALSE_FRAME = bytes.fromhex("41ee14814dfec5e9d589fcfe339e08af79")


def crc16(data):
    c = 0xFFFF
    for b in data:
        c ^= b << 8
        for _ in range(8):
            c = ((c << 1) ^ 0x1021) & 0xFFFF if c & 0x8000 else (c << 1) & 0xFFFF
    return c


def frame(ftype, seq, payload4, version=VER, src=UI_SRC, dst=CTRL_CHAN):
    b = bytearray(17)
    b[0] = SYNC
    b[1] = ((version & 0x0F) << 4) | (ftype & 0x0F)
    struct.pack_into(">HHH", b, 2, seq & 0xFFFF, src, dst)
    b[8:12] = payload4[:4].ljust(4, b"\0")
    struct.pack_into(">H", b, 15, crc16(b[:15]))
    return bytes(b)


def text_message(op, packet_id):
    """dcf_text_packetize: a descriptor DATA frame, then ceil(len/4) chunks."""
    n = len(op)
    base = (packet_id & 0x3F) << 10
    out = [frame(DATA, base, bytes([n >> 8, n & 0xFF, 0x04, 0]))]
    for k in range(1, (n + 3) // 4 + 1):
        out.append(frame(DATA, base | k, op[(k - 1) * 4:k * 4]))
    return out


def sock(bind="127.0.0.1"):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind((bind, 0))
    s.settimeout(0.05)
    return s


def drain(s, seconds):
    """Every datagram s receives within `seconds`."""
    got, end = [], time.time() + seconds
    while time.time() < end:
        try:
            got.append(s.recv(2048))
        except (socket.timeout, BlockingIOError):
            pass
    return got


def is_ctrl(d, tag):
    return len(d) == 17 and d[0] == SYNC and (d[1] & 0x0F) == CTRL and d[8:8 + len(tag)] == tag


RESULTS = []


def check(name, ok, detail=""):
    RESULTS.append(ok)
    print(("PASS: " if ok else "FAIL: ") + name + (f"  [{detail}]" if detail else ""))


def main():
    args = sys.argv[1:]
    public = None
    if "--public-src" in args:
        i = args.index("--public-src")
        public = args[i + 1]
        del args[i:i + 2]
    port, stub_log = int(args[0]), args[1]
    bridge = ("127.0.0.1", port)

    def log():
        try:
            with open(stub_log, "rb") as f:
                return f.read()
        except FileNotFoundError:
            return b""

    # 1. Baseline: a valid PING is answered. Without this, every refusal below
    #    could be a dead bridge and would prove nothing.
    good = sock()
    good.sendto(frame(CTRL, 1, b"PING"), bridge)
    replies = drain(good, 0.6)
    check("a valid PING is answered with PONG (baseline)",
          any(is_ctrl(d, b"PONG") for d in replies), f"{len(replies)} datagram(s)")

    # 2. Refused datagrams get no answer, from a fresh socket each time.
    def unanswered(name, payload):
        s = sock()
        s.sendto(payload, bridge)
        got = drain(s, 0.4)
        check(name, got == [], f"{len(got)} datagram(s) came back")
        s.close()

    unanswered("a false HydraModem frame is not answered", FALSE_FRAME)
    bad = bytearray(frame(CTRL, 2, b"PING"))
    bad[16] ^= 1
    unanswered("a PING with a bad CRC is not answered", bytes(bad))
    unanswered("a PING at version 2 (valid CRC) is not answered",
               frame(CTRL, 3, b"PING", version=2))
    # A valid PING followed by trailing bytes: the old bridge read 17 of them
    # and answered. The gate judges the datagram at its real length.
    unanswered("a valid PING padded to 64 bytes is not answered",
               frame(CTRL, 4, b"PING") + bytes(47))

    # 3. Refused senders do not become the telemetry peer. The stub's meters
    #    shm is live, so the peer receives meters frames every ~33 ms.
    good.sendto(frame(CTRL, 5, b"PING"), bridge)
    drain(good, 0.2)
    attacker = sock()
    for p in (FALSE_FRAME, bytes(bad), frame(CTRL, 6, b"PING", version=2)):
        attacker.sendto(p, bridge)
    stolen = drain(attacker, 0.5)
    still = drain(good, 0.3)
    check("refused datagrams do not redirect telemetry to their sender",
          stolen == [], f"{len(stolen)} datagram(s) reached the sender")
    check("telemetry keeps flowing to the admitted peer",
          len(still) > 0, f"{len(still)} datagram(s)")

    # 4. One message is one op. A newline inside a DCF-Text message would make
    #    one message two control-socket lines behind one reply.
    before = log()
    smuggled = b'{"op":"ping"}\n{"op":"load_fx","slot":0,"path":"/tmp/x.so"}'
    for f in text_message(smuggled, packet_id=7):
        good.sendto(f, bridge)
    replies = drain(good, 0.6)
    after = log()
    check("a multi-line op never reaches the control socket",
          b"load_fx" not in after[len(before):], repr(after[len(before):][:80]))
    check("the multi-line op is answered with CTL_REFUSED (status 3)",
          any(is_ctrl(d, b"R") and d[9] == 3 for d in replies))

    # 5. And a well-formed op still goes through, so the refusal above is the
    #    newline's doing and not a broken text path.
    before = log()
    for f in text_message(b'{"op":"gate_probe"}', packet_id=8):
        good.sendto(f, bridge)
    replies = drain(good, 0.6)
    check("a one-line op reaches the control socket",
          b'{"op":"gate_probe"}\n' in log()[len(before):])
    check("and is answered with CTL_OK (status 0)",
          any(is_ctrl(d, b"R") and d[9] == 0 for d in replies))

    # 6. Source policy, when the caller could give us a non-private address.
    if public:
        s = sock(public)
        s.sendto(frame(CTRL, 9, b"PING"), (public, port))
        got = drain(s, 0.5)
        check(f"a valid PING from non-private {public} is ignored", got == [],
              f"{len(got)} datagram(s) came back")
        priv = sock(os.environ.get("GATE_PRIVATE_SRC", "127.0.0.1"))
        priv.sendto(frame(CTRL, 10, b"PING"), (public, port))
        got = drain(priv, 0.5)
        check("the same PING from a private source is answered (control)",
              any(is_ctrl(d, b"PONG") for d in got))

    n_ok = sum(RESULTS)
    print(f"{n_ok}/{len(RESULTS)} checks passed")
    return 0 if all(RESULTS) else 1


sys.exit(main())
