// SPDX-License-Identifier: MPL-2.0
/*
 * DeMoD UI Framework — Bitmap Font
 * Embedded 8x16 bitmap font for pure software text rendering.
 * Copyright (c) 2026 DeMoD LLC.
 * Licensed under the Mozilla Public License, v. 2.0; see LICENSE.
 */
#ifndef DEMOD_FONT_H
#define DEMOD_FONT_H

#include "demod/framebuffer.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    const uint8_t *data;      /* bitmap data, 1bpp, MSB first */
    int            glyph_w;   /* glyph width in pixels */
    int            glyph_h;   /* glyph height in pixels */
    int            first_cp;  /* first codepoint (usually 32) */
    int            num_glyphs;
} DmFont;

/* Built-in fonts */
const DmFont *dm_font_default(void);        /* 8x16 */
const DmFont *dm_font_small(void);          /* 6x10 */

/* UTF-8 + extended glyphs.
 * Text is UTF-8 everywhere. ASCII 32..126 renders from the compiled-in table
 * (allocation-free fast path); all other BMP codepoints come from an optional
 * runtime glyph blob (.dmf, built by tools/genfont.py from GNU Unifont),
 * auto-loaded on first use from $DEMOD_FONT, ~/.local/share/demod/unifont.dmf,
 * or ./unifont.dmf. Glyphs are 8 or 16 px wide (halfwidth/fullwidth); missing
 * glyphs render as a hollow "tofu" box with an 8 px advance. */
int dm_utf8_decode(const char *s, uint32_t *cp); /* bytes consumed (1..4); 0 at NUL;
                                                    invalid input consumes 1 byte and
                                                    yields U+FFFD */
int dm_utf8_len(const char *s);                  /* codepoint count */
int dm_font_cp_advance(const DmFont *f, uint32_t cp); /* px at scale 1 (8 or 16) */
int dm_font_load_ext(const char *path);          /* load a .dmf blob; 0 = ok */

/* Measurement (pixel-correct for UTF-8, incl. fullwidth glyphs) */
int dm_font_text_width(const DmFont *f, const char *text);
int dm_font_text_width_n(const DmFont *f, const char *text, int nbytes); /* prefix */
int dm_font_text_height(const DmFont *f);
int dm_font_text_width_scaled(const DmFont *f, const char *text, int scale);

/* Drawing */
void dm_fb_draw_char(DmFramebuffer *fb, const DmFont *f,
                     int x, int y, char ch, DmColor fg);
void dm_fb_draw_text(DmFramebuffer *fb, const DmFont *f,
                     int x, int y, const char *text, DmColor fg);
void dm_fb_draw_text_centered(DmFramebuffer *fb, const DmFont *f,
                              DmRect bounds, const char *text, DmColor fg);
/* Integer-scaled text (scale >= 1; 1 = native). Each glyph pixel becomes a
   scale x scale block — crisp, on-brand, resolution-independent. */
void dm_fb_draw_text_scaled(DmFramebuffer *fb, const DmFont *f,
                            int x, int y, const char *text, DmColor fg, int scale);

#ifdef __cplusplus
}
#endif
#endif /* DEMOD_FONT_H */
