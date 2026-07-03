// SPDX-License-Identifier: MPL-2.0
/*
 * test_font_utf8.c — UTF-8 decode + width vectors for the font pipeline.
 * Build/run: make test  (no SDL/display needed — pure measurement paths).
 * Run with DEMOD_FONT pointing at a full .dmf blob to exercise fullwidth
 * advances; without one, the fullwidth assertions are skipped.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "demod/font.h"

static int failures = 0;
#define CHECK(cond, msg)                                                     \
    do {                                                                     \
        if (!(cond)) {                                                       \
            printf("FAIL: %s (%s:%d)\n", msg, __FILE__, __LINE__);           \
            failures++;                                                      \
        }                                                                    \
    } while (0)

static void test_decode(void) {
    uint32_t cp;

    CHECK(dm_utf8_decode("A", &cp) == 1 && cp == 'A', "ASCII decodes as 1 byte");
    CHECK(dm_utf8_decode("", &cp) == 0, "NUL terminates");
    CHECK(dm_utf8_decode("\xC3\xA9", &cp) == 2 && cp == 0xE9, "2-byte e-acute");
    CHECK(dm_utf8_decode("\xE4\xB8\xAD", &cp) == 3 && cp == 0x4E2D, "3-byte CJK");
    CHECK(dm_utf8_decode("\xF0\x9F\x8E\xB8", &cp) == 4 && cp == 0x1F3B8,
          "4-byte astral cp");

    /* invalid input: consume exactly one byte, yield U+FFFD, never 0 */
    CHECK(dm_utf8_decode("\x80x", &cp) == 1 && cp == 0xFFFD, "stray continuation");
    CHECK(dm_utf8_decode("\xC3x", &cp) == 1 && cp == 0xFFFD, "truncated 2-byte");
    CHECK(dm_utf8_decode("\xC0\xAF", &cp) == 1 && cp == 0xFFFD, "overlong form");
    CHECK(dm_utf8_decode("\xED\xA0\x80", &cp) == 1 && cp == 0xFFFD, "surrogate");
    CHECK(dm_utf8_decode("\xFF", &cp) == 1 && cp == 0xFFFD, "0xFF byte");

    CHECK(dm_utf8_len("abc") == 3, "utf8_len ascii");
    CHECK(dm_utf8_len("caf\xC3\xA9") == 4, "utf8_len accent");
    CHECK(dm_utf8_len("\xE4\xB8\xAD\xE6\x96\x87") == 2, "utf8_len cjk");
    CHECK(dm_utf8_len("a\x80z") == 3, "utf8_len forgiving on invalid");
}

static void test_width(void) {
    const DmFont *f = dm_font_default();

    CHECK(dm_font_text_width(f, "") == 0, "empty width 0");
    CHECK(dm_font_text_width(f, "DSP") == 3 * 8, "ascii width");
    CHECK(dm_font_text_width_scaled(f, "DSP", 2) == 3 * 16, "scaled ascii width");
    CHECK(dm_font_text_width_n(f, "DSPXX", 3) == 3 * 8, "prefix width");

    /* unknown/missing glyphs always advance 8px (tofu), never 0 */
    CHECK(dm_font_text_width(f, "\xEF\xBF\xBF") == 8, "unassigned cp advances 8");

    if (getenv("DEMOD_FONT")) {
        /* fullwidth CJK = 16px, halfwidth stays 8px */
        CHECK(dm_font_cp_advance(f, 0x4E2D) == 16, "CJK fullwidth advance");
        CHECK(dm_font_cp_advance(f, 0xE9) == 8, "e-acute halfwidth advance");
        /* "DSP 中文" = 4*8 + 2*16 */
        CHECK(dm_font_text_width(f, "DSP \xE4\xB8\xAD\xE6\x96\x87") == 64,
              "mixed-width string");
        /* prefix cut measures only whole leading sequences */
        CHECK(dm_font_text_width_n(f, "\xE4\xB8\xAD_", 3) == 16, "cjk prefix");
    } else {
        printf("note: DEMOD_FONT unset — fullwidth advance checks skipped\n");
    }
}

int main(void) {
    test_decode();
    test_width();
    if (failures) {
        printf("%d failure(s)\n", failures);
        return 1;
    }
    printf("test_font_utf8: all checks passed\n");
    return 0;
}
