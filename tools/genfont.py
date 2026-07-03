# SPDX-License-Identifier: MPL-2.0
"""
genfont.py — build a .dmf glyph blob for demod-ui from GNU Unifont .hex source.

Unifont's .hex format is exactly demod-ui's cell model: each line is
"CODEPOINT:HEXDATA" where HEXDATA is 32 hex chars (16 bytes = 8x16 halfwidth,
one byte per row, MSB = leftmost pixel) or 64 hex chars (32 bytes = 16x16
fullwidth, two bytes per row). The framework's builtin table keeps ASCII 32..126
compiled in; this blob supplies everything else at runtime.

.dmf v1 layout (little-endian, BMP only):
  0   magic   "DMF1"
  4   u8      version (1)
  5   u8      glyph_h (16)
  6   u16     flags (0)
  8   u32     glyph count (informational)
  12  u32     heap size in bytes
  16  u32[256]  top table: file offset of each page table (cp >> 8), 0 = absent
  ... page tables: u32[256] each (indexed by cp & 0xFF):
        0xFFFFFFFF          = glyph absent
        else bit0           = fullwidth (32-byte glyph, 16 px advance)
             bits 31..1     = byte offset into the heap
  ... heap: raw glyph bitmaps (16 or 32 bytes each)

Usage:
  python3 tools/genfont.py unifont_all.hex out.dmf [--subset eu] [--subset cjk]
  (no --subset = full BMP; presets combine; --ranges FILE adds "0xA0-0x17F" lines)

Unifont is (c) its contributors, dual-licensed OFL-1.1 / GPL-2.0-or-later with
font-embedding exception; demod-ui uses it under OFL-1.1 (THIRD_PARTY_LICENSES.md).
"""

import argparse
import struct
import sys

PRESETS = {
    # Latin-1 .. Latin Extended-B, IPA-ish, Greek, Cyrillic, general punctuation,
    # currency, letterlike, arrows/box-drawing commonly used in UIs.
    "eu": [
        (0x00A0, 0x024F),
        (0x0370, 0x03FF),
        (0x0400, 0x04FF),
        (0x1E00, 0x1EFF),
        (0x2000, 0x206F),
        (0x20A0, 0x20CF),
        (0x2100, 0x214F),
        (0x2190, 0x21FF),
        (0x2500, 0x257F),
    ],
    # CJK: punctuation, kana, Hangul jamo + syllables, CJK Unified + compat,
    # half/fullwidth forms.
    "cjk": [
        (0x1100, 0x11FF),
        (0x3000, 0x30FF),
        (0x3130, 0x318F),
        (0x31F0, 0x31FF),
        (0x4E00, 0x9FFF),
        (0xAC00, 0xD7AF),
        (0xF900, 0xFAFF),
        (0xFF00, 0xFFEF),
    ],
}


def parse_ranges_file(path):
    out = []
    with open(path) as f:
        for line in f:
            line = line.split("#")[0].strip()
            if not line:
                continue
            a, _, b = line.partition("-")
            lo = int(a, 16)
            hi = int(b, 16) if b else lo
            out.append((lo, hi))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("hex_in")
    ap.add_argument("dmf_out")
    ap.add_argument("--subset", action="append", choices=sorted(PRESETS), default=[])
    ap.add_argument("--ranges", help="file of extra codepoint ranges (hex, one per line)")
    args = ap.parse_args()

    ranges = []
    for p in args.subset:
        ranges += PRESETS[p]
    if args.ranges:
        ranges += parse_ranges_file(args.ranges)

    def wanted(cp):
        if cp > 0xFFFF:
            return False  # v1 is BMP-only
        if not ranges:
            return True  # full BMP
        return any(lo <= cp <= hi for lo, hi in ranges)

    glyphs = {}  # cp -> bytes
    with open(args.hex_in) as f:
        for line in f:
            line = line.strip()
            if not line or ":" not in line:
                continue
            cps, data = line.split(":", 1)
            cp = int(cps, 16)
            if not wanted(cp):
                continue
            raw = bytes.fromhex(data)
            if len(raw) not in (16, 32):
                print(f"skip U+{cp:04X}: odd glyph size {len(raw)}", file=sys.stderr)
                continue
            glyphs[cp] = raw

    # heap + page tables
    heap = bytearray()
    pages = {}  # page index -> list of 256 entry u32s
    for cp in sorted(glyphs):
        raw = glyphs[cp]
        off = len(heap)
        if off >= (1 << 31):
            sys.exit("heap too large for v1 offsets")
        entry = (off << 1) | (1 if len(raw) == 32 else 0)
        pages.setdefault(cp >> 8, [0xFFFFFFFF] * 256)[cp & 0xFF] = entry
        heap += raw

    top = [0] * 256
    page_base = 16 + 256 * 4
    for i, pi in enumerate(sorted(pages)):
        top[pi] = page_base + i * 256 * 4
    heap_base = page_base + len(pages) * 256 * 4

    with open(args.dmf_out, "wb") as f:
        f.write(b"DMF1")
        f.write(struct.pack("<BBH", 1, 16, 0))
        f.write(struct.pack("<II", len(glyphs), len(heap)))
        f.write(struct.pack("<256I", *top))
        for pi in sorted(pages):
            f.write(struct.pack("<256I", *pages[pi]))
        f.write(heap)

    total = heap_base + len(heap)
    full = sum(1 for g in glyphs.values() if len(g) == 32)
    print(
        f"{args.dmf_out}: {len(glyphs)} glyphs ({full} fullwidth), "
        f"{len(pages)} pages, {total / 1024:.0f} KiB"
    )


if __name__ == "__main__":
    main()
