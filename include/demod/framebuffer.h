// SPDX-License-Identifier: MPL-2.0
/*
 * DeMoD UI Framework — Framebuffer
 * Pure software-rendered framebuffer with primitive drawing ops.
 * Copyright (c) 2026 DeMoD LLC.
 * Licensed under the Mozilla Public License, v. 2.0; see LICENSE.
 */
#ifndef DEMOD_FRAMEBUFFER_H
#define DEMOD_FRAMEBUFFER_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ── Color ─────────────────────────────────────────────────────────── */

typedef struct {
    uint8_t r, g, b, a;
} DmColor;

static inline DmColor dm_rgba(uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
    return (DmColor){r, g, b, a};
}
static inline DmColor dm_rgb(uint8_t r, uint8_t g, uint8_t b) {
    return dm_rgba(r, g, b, 255);
}
static inline uint32_t dm_color_pack(DmColor c) {
    return ((uint32_t)c.a << 24) | ((uint32_t)c.r << 16) |
           ((uint32_t)c.g << 8)  |  (uint32_t)c.b;
}
static inline DmColor dm_color_unpack(uint32_t p) {
    return (DmColor){
        .r = (p >> 16) & 0xFF, .g = (p >> 8) & 0xFF,
        .b = p & 0xFF,         .a = (p >> 24) & 0xFF
    };
}
static inline DmColor dm_color_lerp(DmColor a, DmColor b, float t) {
    if (t <= 0.0f) return a;
    if (t >= 1.0f) return b;
    return (DmColor){
        .r = (uint8_t)(a.r + (b.r - a.r) * t),
        .g = (uint8_t)(a.g + (b.g - a.g) * t),
        .b = (uint8_t)(a.b + (b.b - a.b) * t),
        .a = (uint8_t)(a.a + (b.a - a.a) * t),
    };
}

/* ── DeMoD Palette ─────────────────────────────────────────────────── */

#define DM_TURQUOISE    dm_rgb(0x00, 0xF5, 0xD4)
#define DM_VIOLET       dm_rgb(0x8B, 0x5C, 0xF6)
#define DM_BLACK        dm_rgb(0x0A, 0x0A, 0x0F)
#define DM_DARK_GRAY    dm_rgb(0x1A, 0x1A, 0x2E)
#define DM_MID_GRAY     dm_rgb(0x2A, 0x2A, 0x3E)
#define DM_LIGHT_GRAY   dm_rgb(0xC0, 0xC0, 0xD0)
#define DM_WHITE        dm_rgb(0xE8, 0xE8, 0xF0)
#define DM_RED          dm_rgb(0xFF, 0x4C, 0x6A)
#define DM_GREEN        dm_rgb(0x4C, 0xFF, 0x82)
#define DM_YELLOW       dm_rgb(0xFF, 0xD9, 0x4C)

/* ── Rect ──────────────────────────────────────────────────────────── */

typedef struct {
    int x, y, w, h;
} DmRect;

static inline bool dm_rect_contains(DmRect r, int px, int py) {
    return px >= r.x && px < r.x + r.w && py >= r.y && py < r.y + r.h;
}
static inline DmRect dm_rect_intersect(DmRect a, DmRect b) {
    int x1 = a.x > b.x ? a.x : b.x;
    int y1 = a.y > b.y ? a.y : b.y;
    int x2 = (a.x+a.w < b.x+b.w) ? a.x+a.w : b.x+b.w;
    int y2 = (a.y+a.h < b.y+b.h) ? a.y+a.h : b.y+b.h;
    if (x2 <= x1 || y2 <= y1) return (DmRect){0,0,0,0};
    return (DmRect){x1, y1, x2-x1, y2-y1};
}
static inline DmRect dm_rect_inset(DmRect r, int dx, int dy) {
    return (DmRect){r.x+dx, r.y+dy, r.w-2*dx, r.h-2*dy};
}

/* ── Framebuffer ───────────────────────────────────────────────────── */

typedef struct {
    uint32_t *pixels;       /* ARGB8888 */
    int       width;
    int       height;
    int       stride;       /* pixels per row (may differ from width) */
    DmRect    clip;         /* current clipping rectangle */
    bool      owns_buffer;  /* true if we allocated pixels */
} DmFramebuffer;

/* Screenshot: dump the buffer as a binary P6 PPM (RGB). */
void dm_fb_write_ppm(const DmFramebuffer *fb, const char *path);

/* Lifecycle */
DmFramebuffer *dm_fb_create(int w, int h);
DmFramebuffer *dm_fb_wrap(uint32_t *pixels, int w, int h, int stride);
void            dm_fb_destroy(DmFramebuffer *fb);
void            dm_fb_resize(DmFramebuffer *fb, int w, int h);

/* Clipping */
void dm_fb_clip_push(DmFramebuffer *fb, DmRect clip);
void dm_fb_clip_reset(DmFramebuffer *fb);

/* Pixel ops */
void dm_fb_clear(DmFramebuffer *fb, DmColor c);
void dm_fb_put_pixel(DmFramebuffer *fb, int x, int y, DmColor c);

/* Primitives */
void dm_fb_fill_rect(DmFramebuffer *fb, DmRect r, DmColor c);
void dm_fb_stroke_rect(DmFramebuffer *fb, DmRect r, DmColor c, int thickness);
void dm_fb_fill_rounded_rect(DmFramebuffer *fb, DmRect r, int radius, DmColor c);
void dm_fb_stroke_rounded_rect(DmFramebuffer *fb, DmRect r, int radius, DmColor c, int thickness);
void dm_fb_hline(DmFramebuffer *fb, int x1, int x2, int y, DmColor c);
void dm_fb_vline(DmFramebuffer *fb, int x, int y1, int y2, DmColor c);
void dm_fb_line(DmFramebuffer *fb, int x0, int y0, int x1, int y1, DmColor c);
void dm_fb_fill_circle(DmFramebuffer *fb, int cx, int cy, int radius, DmColor c);
void dm_fb_stroke_circle(DmFramebuffer *fb, int cx, int cy, int radius, DmColor c);

/* Gradient */
void dm_fb_fill_rect_gradient_v(DmFramebuffer *fb, DmRect r, DmColor top, DmColor bottom);
void dm_fb_fill_rect_gradient_h(DmFramebuffer *fb, DmRect r, DmColor left, DmColor right);

/* Triangles */
void dm_fb_fill_triangle(DmFramebuffer *fb,
                         int x0, int y0, int x1, int y1, int x2, int y2,
                         DmColor c);
void dm_fb_stroke_triangle(DmFramebuffer *fb,
                           int x0, int y0, int x1, int y1, int x2, int y2,
                           DmColor c);
void dm_fb_fill_triangle_gradient(DmFramebuffer *fb,
                                  int x0, int y0, int x1, int y1, int x2, int y2,
                                  DmColor c0, DmColor c1, DmColor c2);

/* Sierpinski */
void dm_fb_sierpinski(DmFramebuffer *fb,
                      int x0, int y0, int x1, int y1, int x2, int y2,
                      int depth, DmColor fill, DmColor stroke);
void dm_fb_sierpinski_glow(DmFramebuffer *fb,
                           int x0, int y0, int x1, int y1, int x2, int y2,
                           int depth, DmColor fill, DmColor stroke, DmColor glow,
                           int glow_radius);

/* Arrows & Connectors */
void dm_fb_thick_line(DmFramebuffer *fb, int x0, int y0, int x1, int y1,
                      int thickness, DmColor c);
void dm_fb_arrow(DmFramebuffer *fb, int x0, int y0, int x1, int y1,
                 int head_size, int thickness, DmColor c);
void dm_fb_bezier(DmFramebuffer *fb,
                  int x0, int y0, int cx0, int cy0,
                  int cx1, int cy1, int x1, int y1,
                  int segments, DmColor c);
void dm_fb_arrow_bezier(DmFramebuffer *fb,
                        int x0, int y0, int cx0, int cy0,
                        int cx1, int cy1, int x1, int y1,
                        int segments, int head_size, int thickness, DmColor c);

/* Blitting */
void dm_fb_blit(DmFramebuffer *dst, const DmFramebuffer *src, int dx, int dy);
void dm_fb_blit_rect(DmFramebuffer *dst, const DmFramebuffer *src,
                     DmRect src_rect, int dx, int dy);
void dm_fb_blit_alpha(DmFramebuffer *dst, const DmFramebuffer *src,
                      int dx, int dy, uint8_t alpha);

/* Scale-to-fit blit (nearest-neighbor, 16.16 fixed-point).
 *   STRETCH  — map src onto the whole dst_rect, ignoring aspect.
 *   CONTAIN  — fit src inside dst_rect preserving aspect (letterbox; the
 *              uncovered margin of dst_rect is left untouched).
 *   COVER    — fill dst_rect preserving aspect, cropping src (centered).
 * alpha==255 is an opaque direct write (also the framework's only opaque-copy
 * blit — replaces dst, per-pixel src alpha ignored); alpha<255 alpha-blends the
 * whole source by that factor. Respects dst->clip and dst->stride. */
typedef enum { DM_FIT_STRETCH, DM_FIT_CONTAIN, DM_FIT_COVER } DmFitMode;
void dm_fb_blit_scaled(DmFramebuffer *dst, const DmFramebuffer *src,
                       DmRect dst_rect, DmFitMode fit, uint8_t alpha);

/* Radial (barrel/pincushion) lens-distortion warp — the CPU stand-in for a VR
 * headset's lens correction. Inverse-maps each dst pixel through
 *   f = 1 + k1*r^2 + k2*r^4      (r normalized to the shorter half-axis)
 * and nearest-neighbor samples src. `src` is expected to be the SAME size as
 * dst_rect (a per-eye buffer); samples that fall outside src are left untouched
 * (clear dst_rect to black first for a proper vignette). k1==k2==0 is identity.
 * Respects dst->clip / dst->stride; alpha<255 alpha-blends the whole warp. */
void dm_fb_warp_barrel(DmFramebuffer *dst, const DmFramebuffer *src,
                       DmRect dst_rect, float k1, float k2, uint8_t alpha);

#ifdef __cplusplus
}
#endif
#endif /* DEMOD_FRAMEBUFFER_H */
