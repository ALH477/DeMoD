#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-3.0-only
# Copyright (C) 2025-2026 DeMoD LLC.
# WS test client (Python stdlib only — no websockets package). Does the RFC6455
# handshake + masked framing by hand, encodes real 17-byte DeModFrames, sends
# them through dcf-ws-bridge (WS->UDP), and validates the PONG that comes back
# (UDP->WS). Exercises the exact wire the browser WASM dm_dcf.c emits.
#
# Usage: ws_client.py <ws_url> <engine_host> <engine_port> [--op '<json>' ...]
#   Each --op is a control op sent as a DCF-Text message (like dm.dcf.send), so
#   the engine_e2e harness can drive a REAL orchestrator over the browser path.
import base64, hashlib, os, socket, struct, sys, time
from urllib.parse import urlparse

_pos, OPS = [], []
_it = iter(sys.argv[1:])
for a in _it:
    if a == "--op":
        OPS.append(next(_it))
    else:
        _pos.append(a)
WS_URL   = _pos[0] if len(_pos) > 0 else "ws://127.0.0.1:7000"
ENG_HOST = _pos[1] if len(_pos) > 1 else "127.0.0.1"
ENG_PORT = int(_pos[2]) if len(_pos) > 2 else 47000

SYNC, VER, DATA, CTRL, UI_SRC, CTRL_CHAN = 0xD3, 1, 0, 3, 2, 1
TEXT_RELIABLE = 0x04


def crc16_ccitt(data):
    crc = 0xFFFF
    for b in data:
        crc ^= (b << 8) & 0xFFFF
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if (crc & 0x8000) else (crc << 1) & 0xFFFF
    return crc


def encode_frame(ftype, seq, src, dst, payload4, ts_us=0):
    buf = bytearray(17)
    buf[0] = SYNC
    buf[1] = ((VER & 0x0F) << 4) | (ftype & 0x0F)
    struct.pack_into(">H", buf, 2, seq & 0xFFFF)
    struct.pack_into(">H", buf, 4, src & 0xFFFF)
    struct.pack_into(">H", buf, 6, dst & 0xFFFF)
    buf[8:12] = payload4[:4].ljust(4, b"\0")
    buf[12], buf[13], buf[14] = (ts_us >> 16) & 0xFF, (ts_us >> 8) & 0xFF, ts_us & 0xFF
    struct.pack_into(">H", buf, 15, crc16_ccitt(buf[0:15]))
    return bytes(buf)


def encode_text_message(op_bytes, packet_id=0, flags=TEXT_RELIABLE):
    # Mirror dcf_text_packetize (third_party/hydramesh/demod_text.h): one message
    # -> 1 descriptor DATA frame + ceil(len/4) data DATA frames. seq packs the
    # 6-bit packet_id in the high bits and the 10-bit fragment index in the low.
    L = len(op_bytes)
    frags = (L + 3) // 4
    base = (packet_id & 0x3F) << 10
    frames = [encode_frame(DATA, base, UI_SRC, CTRL_CHAN,
                           bytes([(L >> 8) & 0xFF, L & 0xFF, flags, 0]))]
    for k in range(1, frags + 1):
        chunk = op_bytes[(k - 1) * 4:(k - 1) * 4 + 4].ljust(4, b"\0")
        frames.append(encode_frame(DATA, base | k, UI_SRC, CTRL_CHAN, chunk))
    return frames


def is_pong(fr):
    return (len(fr) == 17 and fr[0] == SYNC and (fr[1] & 0x0F) == CTRL
            and fr[8:12] == b"PONG"
            and crc16_ccitt(fr[0:15]) == struct.unpack(">H", fr[15:17])[0])


# ── minimal RFC6455 client ──────────────────────────────────────────────
def ws_connect(url):
    u = urlparse(url)
    sock = socket.create_connection((u.hostname, u.port or 80), timeout=5)
    key = base64.b64encode(os.urandom(16)).decode()
    path = u.path or "/"
    req = (f"GET {path} HTTP/1.1\r\nHost: {u.hostname}:{u.port}\r\n"
           "Upgrade: websocket\r\nConnection: Upgrade\r\n"
           f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n")
    sock.sendall(req.encode())
    resp = b""
    while b"\r\n\r\n" not in resp:
        resp += sock.recv(4096)
    if b"101" not in resp.split(b"\r\n", 1)[0]:
        raise RuntimeError("ws handshake failed: " + resp[:80].decode(errors="replace"))
    return sock


def ws_send(sock, data, opcode):
    hdr = bytearray([0x80 | opcode])  # FIN + opcode
    n = len(data)
    mask = os.urandom(4)
    if n < 126:
        hdr.append(0x80 | n)
    elif n < 65536:
        hdr.append(0x80 | 126); hdr += struct.pack(">H", n)
    else:
        hdr.append(0x80 | 127); hdr += struct.pack(">Q", n)
    hdr += mask
    masked = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
    sock.sendall(bytes(hdr) + masked)


def ws_recv(sock):
    def rd(n):
        b = b""
        while len(b) < n:
            c = sock.recv(n - len(b))
            if not c:
                raise ConnectionError("closed")
            b += c
        return b
    b0, b1 = rd(2)
    opcode = b0 & 0x0F
    ln = b1 & 0x7F
    if ln == 126:
        ln = struct.unpack(">H", rd(2))[0]
    elif ln == 127:
        ln = struct.unpack(">Q", rd(8))[0]
    payload = rd(ln) if ln else b""
    if b1 & 0x80:  # server->client is never masked, but be safe
        m = payload[:4]; payload = bytes(x ^ m[i % 4] for i, x in enumerate(payload[4:]))
    return opcode, payload


def main():
    sock = ws_connect(WS_URL)
    ws_send(sock, ('{"op":"addpeer","host":"%s","port":%d}' % (ENG_HOST, ENG_PORT)).encode(), 0x1)
    time.sleep(0.2)
    ws_send(sock, encode_frame(CTRL, 0, UI_SRC, CTRL_CHAN, b"PING"), 0x2)

    # Send any control ops (DCF-Text) over the same WS wire — one frame per WS
    # binary message, exactly as dm.dcf.send does. The bridge reassembles them
    # and writes the JSON op to the engine's control socket.
    for pid, op in enumerate(OPS):
        for fr in encode_text_message(op.encode(), packet_id=pid % 64):
            ws_send(sock, fr, 0x2)
        time.sleep(0.15)  # let the orchestrator apply + reply (bridge serializes)

    got_pong = False
    telemetry = 0
    sock.settimeout(4.0)
    deadline = time.time() + 4.0
    try:
        while (not got_pong or telemetry < 1) and time.time() < deadline:
            opcode, payload = ws_recv(sock)
            if opcode == 0x2:  # binary
                for off in range(0, len(payload) - 16, 17):
                    fr = payload[off:off + 17]
                    if is_pong(fr):
                        got_pong = True
                    elif len(fr) == 17 and fr[0] == SYNC:
                        telemetry += 1
            elif opcode == 0x8:
                break
    except (socket.timeout, TimeoutError, ConnectionError):
        pass

    print(f"pong={got_pong} telemetry_frames={telemetry}")
    if got_pong and telemetry >= 1:
        print("PASS: WS<->UDP relay carried PING/PONG + telemetry verbatim")
        return 0
    print("FAIL: did not observe both a PONG and telemetry over the WS relay")
    return 1


sys.exit(main())
