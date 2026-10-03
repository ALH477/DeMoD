#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-PolyForm-Shield-1.0.0
# Copyright (c) 2026 DeMoD LLC
"""gen-duck-anim.py -- draws the TERMINUS duck and writes its dance.

The duck is DeMoD's own: a yellow pixel-art duck in turquoise-and-violet
headphones, drawn here from shapes; nothing is traced or sampled. The melody
is Asher LeRoy's, read from duck-dance-melody.tsv and copied into the index
unchanged. Run it from anywhere; it writes, next to itself:

  duck-anim-frames.bin                   raw RGBA frames, 96x96, 4 bytes a pixel
  duck-anim-frames.lua                   the index the players read
  demod-duck-dance/duck-anim-frames.*    the same two files, for the app patch

The loop is 6 bars of 4/4 at 160 BPM: 24 beats, exactly 9.0 s. At 16 fps a
beat is 6 frames, so the dance is frame-exact on every beat. Only the 48
distinct frames (two bars, A and B) are stored; frame_offsets maps all 144
frame slots onto them in the bar order A A B A A B.

Optional outputs, for demod-ad renders of duck-dance.lua:

  --png DIR     every frame slot as DIR/f_0001.png ... (scaled, see --scale)
  --midi FILE   the melody as a standard MIDI file

Python 3 standard library only. Deterministic: the same script writes the
same bytes.
"""

import argparse
import math
import os
import struct
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))

W = H = 96  # sprite size in screen pixels
G = 32  # drawing grid; each grid cell is a 3x3 block of screen pixels
CELL = W // G
BPM = 160.0
FPS = 16
BEATS = 24  # 6 bars of 4/4
FRAMES_PER_BEAT = 6  # 16 fps * 60 / 160
SLOTS = BEATS * FRAMES_PER_BEAT  # 144 frame slots = 9.0 s
BAR_ORDER = "AABAAB"

# DeMoD palette (CLAUDE.md "Visual identity") plus duck colours.
CLEAR = (0, 0, 0, 0)
OUTLINE = (26, 26, 46, 255)  # DeMoD dark gray: reads on the black background
YELLOW = (255, 217, 76, 255)  # DeMoD warning yellow
YELLOW_SHADE = (224, 178, 48, 255)
YELLOW_LIGHT = (255, 242, 168, 255)
WING = (236, 182, 44, 255)
ORANGE = (255, 138, 61, 255)
ORANGE_SHADE = (214, 98, 30, 255)
EYE = (10, 10, 15, 255)
GLINT = (232, 232, 240, 255)
TURQ = (0, 245, 212, 255)
VIOLET = (139, 92, 246, 255)


# --------------------------------------------------------------------------
# Drawing on the 32x32 grid
# --------------------------------------------------------------------------
class Grid:
    def __init__(self):
        self.px = [[CLEAR] * G for _ in range(G)]

    def put(self, x, y, c):
        if 0 <= x < G and 0 <= y < G:
            self.px[y][x] = c

    def ellipse(self, cx, cy, rx, ry, c, angle=0.0):
        ca, sa = math.cos(angle), math.sin(angle)
        for y in range(G):
            for x in range(G):
                dx, dy = x + 0.5 - cx, y + 0.5 - cy
                u = dx * ca + dy * sa
                v = -dx * sa + dy * ca
                if (u / rx) ** 2 + (v / ry) ** 2 <= 1.0:
                    self.px[y][x] = c

    def rect(self, x0, y0, x1, y1, c):
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                self.put(x, y, c)

    def outline(self, c):
        filled = [[p[3] > 0 for p in row] for row in self.px]
        for y in range(G):
            for x in range(G):
                if filled[y][x]:
                    continue
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < G and 0 <= ny < G and filled[ny][nx]:
                        self.px[y][x] = c
                        break

    def rgba(self):
        out = bytearray()
        for y in range(H):
            row = self.px[y // CELL]
            for x in range(W):
                out += bytes(row[x // CELL])
        return bytes(out)


def draw_duck(beat, phase, variant):
    """One frame. beat: 0-3 within the bar; phase: 0..1 within the beat."""
    g = Grid()
    hop = math.sin(math.pi * phase)  # 0 on the beat, 1 mid-beat
    land = phase < 1.0 / FRAMES_PER_BEAT  # the frame that lands on the beat
    side = 1 if beat % 2 == 0 else -1  # sway right on even beats, left on odd

    lift = round(2 * hop)
    sx, sy = (1.12, 0.86) if land else (1.0, 1.0)  # squash on landing
    sway = side * round(hop)
    by = 21.0 - lift + (1 if land else 0)  # body centre y

    quack = variant == "B" and beat == 3 and 0.15 < phase < 0.7
    wave = variant == "B" and beat in (1, 2)
    flap = 0.25 + 0.55 * hop if wave else 0.15 * hop

    # feet: one steps forward per beat, alternating
    step = 1 if side > 0 else -1
    foot_l = (12 - step * round(hop), 29 - (1 if side > 0 and hop > 0.5 else 0))
    foot_r = (18 + step * round(hop), 29 - (1 if side < 0 and hop > 0.5 else 0))
    for fx, fy in (foot_l, foot_r):
        g.rect(fx, int(by) + 4, fx, fy - 1, ORANGE_SHADE)  # leg
        g.ellipse(fx + 1.0, fy + 0.5, 1.9, 0.9, ORANGE)  # foot

    # tail
    g.ellipse(7.0 + sway * 0.5, by - 2.5, 2.2, 1.6, YELLOW_SHADE, angle=-0.6)
    # body, with a darker belly underside and a highlight on the back
    g.ellipse(15.0 + sway * 0.5, by, 8.2 * sx, 5.8 * sy, YELLOW)
    g.ellipse(15.5 + sway * 0.5, by + 3.0 * sy, 6.5 * sx, 2.2 * sy, YELLOW_SHADE)
    g.ellipse(12.5 + sway * 0.5, by - 3.4 * sy, 3.2, 1.0, YELLOW_LIGHT)
    # wing: rests on the body, lifts and swings out when waving
    wx, wy, wa = 12.5 + sway * 0.5, by - 0.5 - 3.0 * flap, -0.3 - 1.1 * flap
    g.ellipse(wx, wy, 5.0, 3.1, YELLOW_SHADE, angle=wa)  # rim
    g.ellipse(wx, wy, 4.0, 2.2, WING, angle=wa)

    # head, tilting toward the sway
    hx = 20.0 + sway
    hy = by - 8.0 - (1 if land else 0)
    g.ellipse(hx, hy, 5.2, 5.0, YELLOW)
    g.ellipse(hx - 1.5, hy - 2.6, 1.8, 0.8, YELLOW_LIGHT)

    # beak: open on the quack
    if quack:
        g.ellipse(hx + 5.0, hy + 0.2, 2.8, 1.1, ORANGE)
        g.ellipse(hx + 4.6, hy + 2.3, 2.4, 0.9, ORANGE_SHADE)
    else:
        g.ellipse(hx + 5.0, hy + 1.0, 3.0, 1.4, ORANGE)
        g.rect(int(hx + 3), int(hy + 1.5), int(hx + 7), int(hy + 1.5), ORANGE_SHADE)

    # eye with a glint; it blinks on beat 2 of bar A
    ex, ey = int(hx + 1.5), int(hy - 1)
    if variant == "A" and beat == 2 and land:
        g.rect(ex - 1, ey, ex, ey, EYE)
    else:
        g.rect(ex, ey - 1, ex, ey, EYE)
        g.put(ex, ey - 1, GLINT)

    # headphones: a turquoise band over the crown, a violet cup on the ear
    for a in range(-165, -14, 5):
        r = math.radians(a)
        g.put(int(round(hx - 0.5 + 5.7 * math.cos(r))), int(round(hy + 0.5 + 5.7 * math.sin(r))), TURQ)
    cx, cy = int(round(hx - 4.5)), int(round(hy + 0.5))
    g.rect(cx - 1, cy - 1, cx + 1, cy + 2, VIOLET)
    g.rect(cx - 1, cy - 1, cx + 1, cy - 1, TURQ)

    g.outline(OUTLINE)
    return g


def unique_frames():
    """The two stored bars, A then B: 2 x 4 beats x 6 frames = 48 frames."""
    frames = []
    for variant in "AB":
        for beat in range(4):
            for k in range(FRAMES_PER_BEAT):
                frames.append(draw_duck(beat, k / FRAMES_PER_BEAT, variant).rgba())
    return frames


def slot_to_frame(slot):
    bar = slot // (4 * FRAMES_PER_BEAT)
    within = slot % (4 * FRAMES_PER_BEAT)
    variant = BAR_ORDER[bar]
    return (0 if variant == "A" else 4 * FRAMES_PER_BEAT) + within


# --------------------------------------------------------------------------
# The melody: Asher LeRoy's, kept as written in duck-dance-melody.tsv
# --------------------------------------------------------------------------
def melody():
    """The note events as their original text tokens (t, k, n, v), in order."""
    rows = []
    with open(os.path.join(HERE, "duck-dance-melody.tsv"), encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#"):
                rows.append(tuple(line.split("\t")))
    return rows


# --------------------------------------------------------------------------
# Writers
# --------------------------------------------------------------------------
def write_lua(path, frames_stored):
    sz = W * H * 4
    lines = [
        "-- SPDX-" "License-Identifier: LicenseRef-PolyForm-Shield-1.0.0",  # split for reuse lint
        "-- Copyright (c) 2026 DeMoD LLC",
        "-- Generated by gen-duck-anim.py: DeMoD's own duck; melody by Asher LeRoy.",
        "-- %d frame slots map onto %d stored frames (bars %s)." % (SLOTS, frames_stored, BAR_ORDER),
        "return {",
        "\tw = %d," % W,
        "\th = %d," % H,
        "\ttotal = %d," % SLOTS,
        "\tfps = %d," % FPS,
        "\tduration = %.1f," % (SLOTS / FPS),
        "\tbpm = %.1f," % BPM,
        "\tframe_offsets = {",
    ]
    lines += ["\t\t%d," % (slot_to_frame(s) * sz) for s in range(SLOTS)]
    lines += ["\t},", "\tframe_map = {"]
    lines += ["\t\t%s," % fmt_num(s / FPS) for s in range(SLOTS)]
    lines += ["\t},", "\tmidi_notes = {"]
    for t, k, n, v in melody():
        lines.append("\t\t{ t = %s, k = %s, n = %s, v = %s }," % (t, k, n, v))
    lines += ["\t},", "}", ""]
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines))


def fmt_num(x):
    s = "%.4f" % x
    s = s.rstrip("0")
    return s + "0" if s.endswith(".") else s


def write_png(path, rgba, scale):
    w, h = W * scale, H * scale
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        row = rgba[(y // scale) * W * 4:(y // scale + 1) * W * 4]
        for x in range(w):
            i = (x // scale) * 4
            raw += row[i:i + 4]

    def chunk(kind, data):
        c = kind + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


def write_midi(path):
    tpq = 480
    sec_per_tick = 60.0 / BPM / tpq
    track = bytearray()

    def vlq(n):
        out = [n & 0x7F]
        n >>= 7
        while n:
            out.append(0x80 | (n & 0x7F))
            n >>= 7
        return bytes(reversed(out))

    track += vlq(0) + b"\xff\x51\x03" + int(60e6 / BPM).to_bytes(3, "big")
    last = 0
    for t, k, n, v in melody():
        tick = round(float(t) / sec_per_tick)
        on = k == "1"
        track += vlq(tick - last)
        track += bytes([0x90 if on else 0x80, int(n), round(float(v) * 127) if on else 0])
        last = tick
    track += vlq(0) + b"\xff\x2f\x00"
    data = b"MThd" + struct.pack(">IHHH", 6, 0, 1, tpq)
    data += b"MTrk" + struct.pack(">I", len(track)) + bytes(track)
    with open(path, "wb") as f:
        f.write(data)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--png", metavar="DIR", help="also write every frame slot as PNG")
    ap.add_argument("--scale", type=int, default=8, help="PNG scale factor (default 8)")
    ap.add_argument("--midi", metavar="FILE", help="also write the melody as a MIDI file")
    a = ap.parse_args()

    frames = unique_frames()
    blob = b"".join(frames)
    for d in (HERE, os.path.join(HERE, "demod-duck-dance")):
        with open(os.path.join(d, "duck-anim-frames.bin"), "wb") as f:
            f.write(blob)
        write_lua(os.path.join(d, "duck-anim-frames.lua"), len(frames))
    print("wrote %d frames (%d bytes) and the index, twice" % (len(frames), len(blob)))

    if a.png:
        os.makedirs(a.png, exist_ok=True)
        for s in range(SLOTS):
            write_png(os.path.join(a.png, "f_%04d.png" % (s + 1)), frames[slot_to_frame(s)], a.scale)
        print("wrote %d PNGs to %s" % (SLOTS, a.png))
    if a.midi:
        write_midi(a.midi)
        print("wrote %s" % a.midi)


if __name__ == "__main__":
    main()
