// SPDX-License-Identifier: MPL-2.0
/*
 * DeMoD UI Framework — Framebuffer Implementation
 * Pure software rasterizer. No GPU. No excuses.
 * Copyright (c) 2026 DeMoD LLC.
 * Licensed under the Mozilla Public License, v. 2.0; see LICENSE.
 */
#include "demod/framebuffer.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>

/* ── Screenshot (binary PPM, no deps) ──────────────────────────────────
 * Dump the ARGB8888 buffer as a P6 PPM (RGB). Used by the DEMOD_SHOT capture
 * path for headless UI review; convert to PNG host-side. No-op on bad args. */
void dm_fb_write_ppm(const DmFramebuffer *fb, const char *path) {
    if (!fb || !fb->pixels || !path) return;
    FILE *f = fopen(path, "wb");
    if (!f) return;
    fprintf(f, "P6\n%d %d\n255\n", fb->width, fb->height);
    uint8_t *row = (uint8_t *)malloc((size_t)fb->width * 3);
    if (!row) { fclose(f); return; }
    for (int y = 0; y < fb->height; y++) {
        const uint32_t *src = fb->pixels + (size_t)y * fb->stride;
        for (int x = 0; x < fb->width; x++) {
            uint32_t p = src[x];
            row[x * 3 + 0] = (uint8_t)((p >> 16) & 0xFF); /* R */
            row[x * 3 + 1] = (uint8_t)((p >> 8) & 0xFF);  /* G */
            row[x * 3 + 2] = (uint8_t)(p & 0xFF);         /* B */
        }
        fwrite(row, 1, (size_t)fb->width * 3, f);
    }
    free(row);
    fclose(f);
}

/* ── Alpha blending (over operator) ───────────────────────────────── */

static inline uint32_t blend_pixel(uint32_t dst, DmColor src) {
    if (src.a == 255) return dm_color_pack(src);
    if (src.a == 0)   return dst;

    DmColor d = dm_color_unpack(dst);
    uint16_t sa = src.a;
    uint16_t da = 255 - sa;

    return dm_color_pack((DmColor){
        .r = (uint8_t)((src.r * sa + d.r * da) / 255),
        .g = (uint8_t)((src.g * sa + d.g * da) / 255),
        .b = (uint8_t)((src.b * sa + d.b * da) / 255),
        .a = (uint8_t)(sa + (d.a * da) / 255),
    });
}

/* ── Lifecycle ─────────────────────────────────────────────────────── */

DmFramebuffer *dm_fb_create(int w, int h) {
    DmFramebuffer *fb = (DmFramebuffer *)calloc(1, sizeof(DmFramebuffer));
    if (!fb) return NULL;
    fb->pixels = (uint32_t *)calloc(w * h, sizeof(uint32_t));
    if (!fb->pixels) { free(fb); return NULL; }
    fb->width  = w;
    fb->height = h;
    fb->stride = w;
    fb->clip   = (DmRect){0, 0, w, h};
    fb->owns_buffer = true;
    return fb;
}

DmFramebuffer *dm_fb_wrap(uint32_t *pixels, int w, int h, int stride) {
    DmFramebuffer *fb = (DmFramebuffer *)calloc(1, sizeof(DmFramebuffer));
    if (!fb) return NULL;
    fb->pixels = pixels;
    fb->width  = w;
    fb->height = h;
    fb->stride = stride;
    fb->clip   = (DmRect){0, 0, w, h};
    fb->owns_buffer = false;
    return fb;
}

void dm_fb_destroy(DmFramebuffer *fb) {
    if (!fb) return;
    if (fb->owns_buffer) free(fb->pixels);
    free(fb);
}

void dm_fb_resize(DmFramebuffer *fb, int w, int h) {
    if (!fb || !fb->owns_buffer) return;
    uint32_t *new_pixels = (uint32_t *)calloc(w * h, sizeof(uint32_t));
    if (!new_pixels) return;
    free(fb->pixels);
    fb->pixels = new_pixels;
    fb->width  = w;
    fb->height = h;
    fb->stride = w;
    fb->clip   = (DmRect){0, 0, w, h};
}

/* ── Clipping ──────────────────────────────────────────────────────── */

void dm_fb_clip_push(DmFramebuffer *fb, DmRect clip) {
    fb->clip = dm_rect_intersect(fb->clip, clip);
}

void dm_fb_clip_reset(DmFramebuffer *fb) {
    fb->clip = (DmRect){0, 0, fb->width, fb->height};
}

/* ── Pixel ops ─────────────────────────────────────────────────────── */

void dm_fb_clear(DmFramebuffer *fb, DmColor c) {
    uint32_t packed = dm_color_pack(c);
    int total = fb->width * fb->height;
    /* Fast path: use memset for black/white, loop otherwise */
    if (packed == 0) {
        memset(fb->pixels, 0, total * sizeof(uint32_t));
    } else {
        for (int i = 0; i < total; i++)
            fb->pixels[i] = packed;
    }
}

void dm_fb_put_pixel(DmFramebuffer *fb, int x, int y, DmColor c) {
    if (!dm_rect_contains(fb->clip, x, y)) return;
    fb->pixels[y * fb->stride + x] = blend_pixel(fb->pixels[y * fb->stride + x], c);
}

/* ── Lines ─────────────────────────────────────────────────────────── */

void dm_fb_hline(DmFramebuffer *fb, int x1, int x2, int y, DmColor c) {
    if (y < fb->clip.y || y >= fb->clip.y + fb->clip.h) return;
    if (x1 > x2) { int t = x1; x1 = x2; x2 = t; }
    if (x1 < fb->clip.x) x1 = fb->clip.x;
    if (x2 >= fb->clip.x + fb->clip.w) x2 = fb->clip.x + fb->clip.w - 1;
    if (x1 > x2) return;

    uint32_t *row = fb->pixels + y * fb->stride;
    if (c.a == 255) {
        uint32_t packed = dm_color_pack(c);
        for (int x = x1; x <= x2; x++) row[x] = packed;
    } else {
        for (int x = x1; x <= x2; x++)
            row[x] = blend_pixel(row[x], c);
    }
}

void dm_fb_vline(DmFramebuffer *fb, int x, int y1, int y2, DmColor c) {
    if (x < fb->clip.x || x >= fb->clip.x + fb->clip.w) return;
    if (y1 > y2) { int t = y1; y1 = y2; y2 = t; }
    if (y1 < fb->clip.y) y1 = fb->clip.y;
    if (y2 >= fb->clip.y + fb->clip.h) y2 = fb->clip.y + fb->clip.h - 1;
    if (y1 > y2) return;

    if (c.a == 255) {
        uint32_t packed = dm_color_pack(c);
        for (int y = y1; y <= y2; y++) fb->pixels[y * fb->stride + x] = packed;
    } else {
        for (int y = y1; y <= y2; y++)
            fb->pixels[y * fb->stride + x] = blend_pixel(fb->pixels[y * fb->stride + x], c);
    }
}

void dm_fb_line(DmFramebuffer *fb, int x0, int y0, int x1, int y1, DmColor c) {
    /* Bresenham */
    int dx = abs(x1 - x0), sx = x0 < x1 ? 1 : -1;
    int dy = -abs(y1 - y0), sy = y0 < y1 ? 1 : -1;
    int err = dx + dy;

    for (;;) {
        dm_fb_put_pixel(fb, x0, y0, c);
        if (x0 == x1 && y0 == y1) break;
        int e2 = 2 * err;
        if (e2 >= dy) { err += dy; x0 += sx; }
        if (e2 <= dx) { err += dx; y0 += sy; }
    }
}

/* ── Rectangles ────────────────────────────────────────────────────── */

void dm_fb_fill_rect(DmFramebuffer *fb, DmRect r, DmColor c) {
    DmRect clipped = dm_rect_intersect(r, fb->clip);
    if (clipped.w <= 0 || clipped.h <= 0) return;

    for (int y = clipped.y; y < clipped.y + clipped.h; y++)
        dm_fb_hline(fb, clipped.x, clipped.x + clipped.w - 1, y, c);
}

void dm_fb_stroke_rect(DmFramebuffer *fb, DmRect r, DmColor c, int t) {
    for (int i = 0; i < t; i++) {
        dm_fb_hline(fb, r.x, r.x + r.w - 1, r.y + i, c);
        dm_fb_hline(fb, r.x, r.x + r.w - 1, r.y + r.h - 1 - i, c);
        dm_fb_vline(fb, r.x + i, r.y, r.y + r.h - 1, c);
        dm_fb_vline(fb, r.x + r.w - 1 - i, r.y, r.y + r.h - 1, c);
    }
}

/* ── Rounded Rectangles ────────────────────────────────────────────── */

static void fill_rounded_scanline(DmFramebuffer *fb, DmRect r, int rad, int y, DmColor c) {
    int rel_y = y - r.y;
    int x_inset = 0;

    if (rel_y < rad) {
        /* Top corners */
        int dy = rad - rel_y - 1;
        x_inset = rad - (int)sqrtf((float)(rad * rad - dy * dy));
    } else if (rel_y >= r.h - rad) {
        /* Bottom corners */
        int dy = rel_y - (r.h - rad);
        x_inset = rad - (int)sqrtf((float)(rad * rad - dy * dy));
    }
    dm_fb_hline(fb, r.x + x_inset, r.x + r.w - 1 - x_inset, y, c);
}

void dm_fb_fill_rounded_rect(DmFramebuffer *fb, DmRect r, int radius, DmColor c) {
    if (radius <= 0) { dm_fb_fill_rect(fb, r, c); return; }
    if (radius > r.w / 2) radius = r.w / 2;
    if (radius > r.h / 2) radius = r.h / 2;

    DmRect clipped = dm_rect_intersect(r, fb->clip);
    for (int y = clipped.y; y < clipped.y + clipped.h; y++)
        fill_rounded_scanline(fb, r, radius, y, c);
}

void dm_fb_stroke_rounded_rect(DmFramebuffer *fb, DmRect r, int radius,
                               DmColor c, int thickness) {
    if (radius <= 0) { dm_fb_stroke_rect(fb, r, c, thickness); return; }
    if (radius > r.w / 2) radius = r.w / 2;
    if (radius > r.h / 2) radius = r.h / 2;

    /* Draw border scanlines only (outer minus inner) */
    int inner_rad = radius - thickness;
    if (inner_rad < 0) inner_rad = 0;
    DmRect inner = dm_rect_inset(r, thickness, thickness);

    DmRect clipped = dm_rect_intersect(r, fb->clip);
    for (int y = clipped.y; y < clipped.y + clipped.h; y++) {
        /* Compute outer x-inset at this scanline */
        int rel_y = y - r.y;
        int outer_inset = 0;
        if (rel_y < radius) {
            int dy = radius - rel_y - 1;
            outer_inset = radius - (int)sqrtf((float)(radius * radius - dy * dy));
        } else if (rel_y >= r.h - radius) {
            int dy = rel_y - (r.h - radius);
            outer_inset = radius - (int)sqrtf((float)(radius * radius - dy * dy));
        }
        int ox1 = r.x + outer_inset;
        int ox2 = r.x + r.w - 1 - outer_inset;

        /* Compute inner x-inset at this scanline */
        int inner_rel_y = y - inner.y;
        bool in_inner = (inner_rel_y >= 0 && inner_rel_y < inner.h && inner.w > 0 && inner.h > 0);
        int ix1 = inner.x, ix2 = inner.x + inner.w - 1;
        if (in_inner && inner_rad > 0) {
            int inner_inset = 0;
            if (inner_rel_y < inner_rad) {
                int dy = inner_rad - inner_rel_y - 1;
                inner_inset = inner_rad - (int)sqrtf((float)(inner_rad * inner_rad - dy * dy));
            } else if (inner_rel_y >= inner.h - inner_rad) {
                int dy = inner_rel_y - (inner.h - inner_rad);
                inner_inset = inner_rad - (int)sqrtf((float)(inner_rad * inner_rad - dy * dy));
            }
            ix1 = inner.x + inner_inset;
            ix2 = inner.x + inner.w - 1 - inner_inset;
        }

        if (!in_inner) {
            /* Entirely in the border */
            dm_fb_hline(fb, ox1, ox2, y, c);
        } else {
            /* Left border span */
            if (ox1 < ix1) dm_fb_hline(fb, ox1, ix1 - 1, y, c);
            /* Right border span */
            if (ox2 > ix2) dm_fb_hline(fb, ix2 + 1, ox2, y, c);
        }
    }
}

/* ── Circles ───────────────────────────────────────────────────────── */

void dm_fb_fill_circle(DmFramebuffer *fb, int cx, int cy, int radius, DmColor c) {
    for (int y = -radius; y <= radius; y++) {
        int half_w = (int)sqrtf((float)(radius * radius - y * y));
        dm_fb_hline(fb, cx - half_w, cx + half_w, cy + y, c);
    }
}

void dm_fb_stroke_circle(DmFramebuffer *fb, int cx, int cy, int radius, DmColor c) {
    /* Midpoint circle algorithm */
    int x = radius, y = 0, err = 1 - radius;
    while (x >= y) {
        dm_fb_put_pixel(fb, cx + x, cy + y, c);
        dm_fb_put_pixel(fb, cx - x, cy + y, c);
        dm_fb_put_pixel(fb, cx + x, cy - y, c);
        dm_fb_put_pixel(fb, cx - x, cy - y, c);
        dm_fb_put_pixel(fb, cx + y, cy + x, c);
        dm_fb_put_pixel(fb, cx - y, cy + x, c);
        dm_fb_put_pixel(fb, cx + y, cy - x, c);
        dm_fb_put_pixel(fb, cx - y, cy - x, c);
        y++;
        if (err < 0) {
            err += 2 * y + 1;
        } else {
            x--;
            err += 2 * (y - x) + 1;
        }
    }
}

/* ── Gradients ─────────────────────────────────────────────────────── */

void dm_fb_fill_rect_gradient_v(DmFramebuffer *fb, DmRect r, DmColor top, DmColor bottom) {
    DmRect clipped = dm_rect_intersect(r, fb->clip);
    for (int y = clipped.y; y < clipped.y + clipped.h; y++) {
        float t = (float)(y - r.y) / (float)(r.h > 1 ? r.h - 1 : 1);
        DmColor c = dm_color_lerp(top, bottom, t);
        dm_fb_hline(fb, clipped.x, clipped.x + clipped.w - 1, y, c);
    }
}

void dm_fb_fill_rect_gradient_h(DmFramebuffer *fb, DmRect r, DmColor left, DmColor right) {
    DmRect clipped = dm_rect_intersect(r, fb->clip);
    for (int x = clipped.x; x < clipped.x + clipped.w; x++) {
        float t = (float)(x - r.x) / (float)(r.w > 1 ? r.w - 1 : 1);
        DmColor c = dm_color_lerp(left, right, t);
        dm_fb_vline(fb, x, clipped.y, clipped.y + clipped.h - 1, c);
    }
}

/* ── Blitting ──────────────────────────────────────────────────────── */

void dm_fb_blit(DmFramebuffer *dst, const DmFramebuffer *src, int dx, int dy) {
    dm_fb_blit_rect(dst, src, (DmRect){0, 0, src->width, src->height}, dx, dy);
}

void dm_fb_blit_rect(DmFramebuffer *dst, const DmFramebuffer *src,
                     DmRect sr, int dx, int dy) {
    /* Clip source rect to source bounds */
    DmRect src_bounds = {0, 0, src->width, src->height};
    sr = dm_rect_intersect(sr, src_bounds);

    for (int y = 0; y < sr.h; y++) {
        int dst_y = dy + y;
        if (dst_y < dst->clip.y || dst_y >= dst->clip.y + dst->clip.h) continue;
        for (int x = 0; x < sr.w; x++) {
            int dst_x = dx + x;
            if (dst_x < dst->clip.x || dst_x >= dst->clip.x + dst->clip.w) continue;
            uint32_t sp = src->pixels[(sr.y + y) * src->stride + (sr.x + x)];
            DmColor sc = dm_color_unpack(sp);
            dst->pixels[dst_y * dst->stride + dst_x] =
                blend_pixel(dst->pixels[dst_y * dst->stride + dst_x], sc);
        }
    }
}

void dm_fb_blit_alpha(DmFramebuffer *dst, const DmFramebuffer *src,
                      int dx, int dy, uint8_t alpha) {
    for (int y = 0; y < src->height; y++) {
        int dst_y = dy + y;
        if (dst_y < dst->clip.y || dst_y >= dst->clip.y + dst->clip.h) continue;
        for (int x = 0; x < src->width; x++) {
            int dst_x = dx + x;
            if (dst_x < dst->clip.x || dst_x >= dst->clip.x + dst->clip.w) continue;
            DmColor sc = dm_color_unpack(src->pixels[y * src->stride + x]);
            sc.a = (uint8_t)((sc.a * alpha) / 255);
            dst->pixels[dst_y * dst->stride + dst_x] =
                blend_pixel(dst->pixels[dst_y * dst->stride + dst_x], sc);
        }
    }
}

/* ── Triangles ─────────────────────────────────────────────────────── */

/*
 * Scanline triangle fill using edge walking.
 * Sorts vertices by Y, interpolates edges per scanline.
 */
void dm_fb_fill_triangle(DmFramebuffer *fb,
                         int x0, int y0, int x1, int y1, int x2, int y2,
                         DmColor c) {
    /* Sort vertices by Y (v0.y <= v1.y <= v2.y) */
    int vx[3] = {x0, x1, x2}, vy[3] = {y0, y1, y2};
    for (int i = 0; i < 2; i++) {
        for (int j = i + 1; j < 3; j++) {
            if (vy[j] < vy[i]) {
                int t;
                t = vx[i]; vx[i] = vx[j]; vx[j] = t;
                t = vy[i]; vy[i] = vy[j]; vy[j] = t;
            }
        }
    }

    if (vy[0] == vy[2]) return; /* degenerate */

    for (int y = vy[0]; y <= vy[2]; y++) {
        /* Interpolate x along the long edge (v0→v2) */
        float t_long = (float)(y - vy[0]) / (float)(vy[2] - vy[0]);
        int xa = vx[0] + (int)(t_long * (vx[2] - vx[0]));

        /* Interpolate x along the short edges */
        int xb;
        if (y < vy[1]) {
            if (vy[1] == vy[0]) { xb = vx[0]; }
            else {
                float t = (float)(y - vy[0]) / (float)(vy[1] - vy[0]);
                xb = vx[0] + (int)(t * (vx[1] - vx[0]));
            }
        } else {
            if (vy[2] == vy[1]) { xb = vx[1]; }
            else {
                float t = (float)(y - vy[1]) / (float)(vy[2] - vy[1]);
                xb = vx[1] + (int)(t * (vx[2] - vx[1]));
            }
        }

        if (xa > xb) { int t = xa; xa = xb; xb = t; }
        dm_fb_hline(fb, xa, xb, y, c);
    }
}

void dm_fb_stroke_triangle(DmFramebuffer *fb,
                           int x0, int y0, int x1, int y1, int x2, int y2,
                           DmColor c) {
    dm_fb_line(fb, x0, y0, x1, y1, c);
    dm_fb_line(fb, x1, y1, x2, y2, c);
    dm_fb_line(fb, x2, y2, x0, y0, c);
}

void dm_fb_fill_triangle_gradient(DmFramebuffer *fb,
                                  int x0, int y0, int x1, int y1, int x2, int y2,
                                  DmColor c0, DmColor c1, DmColor c2) {
    /* Bounding box */
    int min_y = y0 < y1 ? (y0 < y2 ? y0 : y2) : (y1 < y2 ? y1 : y2);
    int max_y = y0 > y1 ? (y0 > y2 ? y0 : y2) : (y1 > y2 ? y1 : y2);
    int min_x = x0 < x1 ? (x0 < x2 ? x0 : x2) : (x1 < x2 ? x1 : x2);
    int max_x = x0 > x1 ? (x0 > x2 ? x0 : x2) : (x1 > x2 ? x1 : x2);

    /* Barycentric fill */
    float denom = (float)((y1 - y2) * (x0 - x2) + (x2 - x1) * (y0 - y2));
    if (fabsf(denom) < 0.001f) return;

    for (int y = min_y; y <= max_y; y++) {
        if (y < fb->clip.y || y >= fb->clip.y + fb->clip.h) continue;
        for (int x = min_x; x <= max_x; x++) {
            if (x < fb->clip.x || x >= fb->clip.x + fb->clip.w) continue;
            float w0 = ((y1 - y2) * (x - x2) + (x2 - x1) * (y - y2)) / denom;
            float w1 = ((y2 - y0) * (x - x2) + (x0 - x2) * (y - y2)) / denom;
            float w2 = 1.0f - w0 - w1;

            if (w0 >= -0.01f && w1 >= -0.01f && w2 >= -0.01f) {
                if (w0 < 0) w0 = 0; if (w1 < 0) w1 = 0; if (w2 < 0) w2 = 0;
                DmColor c = {
                    (uint8_t)(c0.r * w0 + c1.r * w1 + c2.r * w2),
                    (uint8_t)(c0.g * w0 + c1.g * w1 + c2.g * w2),
                    (uint8_t)(c0.b * w0 + c1.b * w1 + c2.b * w2),
                    (uint8_t)(c0.a * w0 + c1.a * w1 + c2.a * w2),
                };
                dm_fb_put_pixel(fb, x, y, c);
            }
        }
    }
}

/* ── Sierpinski Fractal ────────────────────────────────────────────── */

static void sierpinski_recurse(DmFramebuffer *fb,
                               int x0, int y0, int x1, int y1, int x2, int y2,
                               int depth, DmColor fill, DmColor stroke) {
    if (depth <= 0) {
        dm_fb_fill_triangle(fb, x0, y0, x1, y1, x2, y2, fill);
        dm_fb_stroke_triangle(fb, x0, y0, x1, y1, x2, y2, stroke);
        return;
    }

    /* Midpoints */
    int mx01 = (x0 + x1) / 2, my01 = (y0 + y1) / 2;
    int mx12 = (x1 + x2) / 2, my12 = (y1 + y2) / 2;
    int mx20 = (x2 + x0) / 2, my20 = (y2 + y0) / 2;

    /* Three sub-triangles (skip the center one = the Sierpinski hole) */
    sierpinski_recurse(fb, x0, y0,   mx01, my01, mx20, my20, depth - 1, fill, stroke);
    sierpinski_recurse(fb, mx01, my01, x1, y1,   mx12, my12, depth - 1, fill, stroke);
    sierpinski_recurse(fb, mx20, my20, mx12, my12, x2, y2,   depth - 1, fill, stroke);
}

void dm_fb_sierpinski(DmFramebuffer *fb,
                      int x0, int y0, int x1, int y1, int x2, int y2,
                      int depth, DmColor fill, DmColor stroke) {
    if (depth > 8) depth = 8;
    sierpinski_recurse(fb, x0, y0, x1, y1, x2, y2, depth, fill, stroke);
}

void dm_fb_sierpinski_glow(DmFramebuffer *fb,
                           int x0, int y0, int x1, int y1, int x2, int y2,
                           int depth, DmColor fill, DmColor stroke, DmColor glow,
                           int glow_radius) {
    /* Draw glow passes (concentric outlines with fading alpha) */
    for (int g = glow_radius; g >= 1; g--) {
        float alpha_t = 1.0f - (float)g / (float)(glow_radius + 1);
        DmColor gc = glow;
        gc.a = (uint8_t)(gc.a * alpha_t * 0.3f);

        /* Offset each vertex outward from centroid */
        int cx = (x0 + x1 + x2) / 3;
        int cy = (y0 + y1 + y2) / 3;
        float scale = 1.0f + (float)g * 0.008f;
        int gx0 = cx + (int)((x0 - cx) * scale);
        int gy0 = cy + (int)((y0 - cy) * scale);
        int gx1 = cx + (int)((x1 - cx) * scale);
        int gy1 = cy + (int)((y1 - cy) * scale);
        int gx2 = cx + (int)((x2 - cx) * scale);
        int gy2 = cy + (int)((y2 - cy) * scale);

        dm_fb_stroke_triangle(fb, gx0, gy0, gx1, gy1, gx2, gy2, gc);
    }

    /* Draw the actual Sierpinski */
    dm_fb_sierpinski(fb, x0, y0, x1, y1, x2, y2, depth, fill, stroke);
}

/* ── Thick Line ────────────────────────────────────────────────────── */

void dm_fb_thick_line(DmFramebuffer *fb, int x0, int y0, int x1, int y1,
                      int thickness, DmColor c) {
    if (thickness <= 1) {
        dm_fb_line(fb, x0, y0, x1, y1, c);
        return;
    }

    /* Perpendicular offset */
    float dx = (float)(x1 - x0);
    float dy = (float)(y1 - y0);
    float len = sqrtf(dx * dx + dy * dy);
    if (len < 0.001f) return;

    float nx = -dy / len;
    float ny =  dx / len;

    int half = thickness / 2;
    for (int i = -half; i <= half; i++) {
        int ox = (int)(nx * i);
        int oy = (int)(ny * i);
        dm_fb_line(fb, x0 + ox, y0 + oy, x1 + ox, y1 + oy, c);
    }
}

/* ── Arrow ─────────────────────────────────────────────────────────── */

void dm_fb_arrow(DmFramebuffer *fb, int x0, int y0, int x1, int y1,
                 int head_size, int thickness, DmColor c) {
    /* Shaft */
    dm_fb_thick_line(fb, x0, y0, x1, y1, thickness, c);

    /* Arrowhead */
    float dx = (float)(x1 - x0);
    float dy = (float)(y1 - y0);
    float len = sqrtf(dx * dx + dy * dy);
    if (len < 0.001f) return;

    dx /= len;
    dy /= len;

    /* Two points forming the arrowhead base */
    float hx = x1 - dx * head_size;
    float hy = y1 - dy * head_size;
    float nx = -dy, ny = dx;

    int ax = (int)(hx + nx * head_size * 0.5f);
    int ay = (int)(hy + ny * head_size * 0.5f);
    int bx = (int)(hx - nx * head_size * 0.5f);
    int by = (int)(hy - ny * head_size * 0.5f);

    dm_fb_fill_triangle(fb, x1, y1, ax, ay, bx, by, c);
}

/* ── Bezier Curve ──────────────────────────────────────────────────── */

void dm_fb_bezier(DmFramebuffer *fb,
                  int x0, int y0, int cx0, int cy0,
                  int cx1, int cy1, int x1, int y1,
                  int segments, DmColor c) {
    float px = (float)x0, py = (float)y0;

    for (int i = 1; i <= segments; i++) {
        float t = (float)i / (float)segments;
        float it = 1.0f - t;
        float it2 = it * it, it3 = it2 * it;
        float t2 = t * t, t3 = t2 * t;

        float nx = it3 * x0 + 3 * it2 * t * cx0 + 3 * it * t2 * cx1 + t3 * x1;
        float ny = it3 * y0 + 3 * it2 * t * cy0 + 3 * it * t2 * cy1 + t3 * y1;

        dm_fb_line(fb, (int)px, (int)py, (int)nx, (int)ny, c);
        px = nx;
        py = ny;
    }
}

void dm_fb_arrow_bezier(DmFramebuffer *fb,
                        int x0, int y0, int cx0, int cy0,
                        int cx1, int cy1, int x1, int y1,
                        int segments, int head_size, int thickness, DmColor c) {
    /* Draw thick bezier */
    float px = (float)x0, py = (float)y0;
    float last_dx = 0, last_dy = 0;

    for (int i = 1; i <= segments; i++) {
        float t = (float)i / (float)segments;
        float it = 1.0f - t;
        float it2 = it * it, it3 = it2 * it;
        float t2 = t * t, t3 = t2 * t;

        float nx = it3 * x0 + 3 * it2 * t * cx0 + 3 * it * t2 * cx1 + t3 * x1;
        float ny = it3 * y0 + 3 * it2 * t * cy0 + 3 * it * t2 * cy1 + t3 * y1;

        dm_fb_thick_line(fb, (int)px, (int)py, (int)nx, (int)ny, thickness, c);
        last_dx = nx - px;
        last_dy = ny - py;
        px = nx;
        py = ny;
    }

    /* Arrowhead at endpoint */
    float len = sqrtf(last_dx * last_dx + last_dy * last_dy);
    if (len > 0.001f) {
        float dx = last_dx / len;
        float dy = last_dy / len;
        float hx = x1 - dx * head_size;
        float hy = y1 - dy * head_size;
        float nnx = -dy, nny = dx;
        int ax = (int)(hx + nnx * head_size * 0.5f);
        int ay = (int)(hy + nny * head_size * 0.5f);
        int bx = (int)(hx - nnx * head_size * 0.5f);
        int by = (int)(hy - nny * head_size * 0.5f);
        dm_fb_fill_triangle(fb, x1, y1, ax, ay, bx, by, c);
    }
}
