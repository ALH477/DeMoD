// SPDX-License-Identifier: MPL-2.0
/*
 * DeMoD UI Framework — DSP Widgets
 * Knob, VU Meter, Waveform, Dropdown, ScrollPanel, XY Pad.
 * Copyright (c) 2026 DeMoD LLC.
 * Licensed under the Mozilla Public License, v. 2.0; see LICENSE.
 */
#include "demod/widget.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <math.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

/* ══════════════════════════════════════════════════════════════════════
 *  KNOB — Rotary Control
 * ══════════════════════════════════════════════════════════════════════ */

static void knob_draw(DmWidget *w, DmFramebuffer *fb, const DmTheme *theme) {
    DmKnobData *d = (DmKnobData *)w->data;
    DmRect r = w->abs_bounds;

    int cx = r.x + r.w / 2;
    int label_h = d->show_label ? 18 : 0;
    int value_h = d->show_value ? 16 : 0;
    int knob_area = r.h - label_h - value_h;
    int radius = (knob_area < r.w ? knob_area : r.w) / 2 - 4;
    if (radius < 8) radius = 8;
    int cy = r.y + label_h + knob_area / 2;

    /* Track arc (background) */
    float norm = (d->value - d->min_val) / (d->max_val - d->min_val);
    int num_segs = 32;
    float arc_range = d->end_angle - d->start_angle;

    /* Draw track dots */
    for (int i = 0; i <= num_segs; i++) {
        float t = (float)i / (float)num_segs;
        float angle = d->start_angle + t * arc_range;
        int px = cx + (int)((radius + 2) * cosf(angle));
        int py = cy + (int)((radius + 2) * sinf(angle));
        DmColor dot_c = (t <= norm) ? d->fill_color : d->track_color;
        dm_fb_fill_circle(fb, px, py, 2, dot_c);
    }

    /* Knob body */
    DmColor body = d->knob_color;
    if (w->flags & DM_WIDGET_PRESSED)
        body = dm_color_lerp(body, theme->accent, 0.3f);
    else if (w->flags & DM_WIDGET_HOVERED)
        body = dm_color_lerp(body, theme->accent, 0.15f);

    dm_fb_fill_circle(fb, cx, cy, radius - 3, body);
    dm_fb_stroke_circle(fb, cx, cy, radius - 3, d->track_color);

    /* Indicator line */
    float ind_angle = d->start_angle + norm * arc_range;
    int inner_r = radius / 3;
    int outer_r = radius - 6;
    int x0 = cx + (int)(inner_r * cosf(ind_angle));
    int y0 = cy + (int)(inner_r * sinf(ind_angle));
    int x1 = cx + (int)(outer_r * cosf(ind_angle));
    int y1 = cy + (int)(outer_r * sinf(ind_angle));
    dm_fb_line(fb, x0, y0, x1, y1, d->indicator_color);
    /* Thicken the indicator */
    dm_fb_line(fb, x0+1, y0, x1+1, y1, d->indicator_color);
    dm_fb_line(fb, x0, y0+1, x1, y1+1, d->indicator_color);

    /* Label text */
    if (d->show_label && d->label[0]) {
        dm_fb_draw_text_centered(fb, theme->font,
            (DmRect){r.x, r.y, r.w, label_h}, d->label, theme->fg_secondary);
    }

    /* Value text */
    if (d->show_value) {
        char buf[64];
        snprintf(buf, sizeof(buf), d->value_fmt, d->value);
        dm_fb_draw_text_centered(fb, theme->font,
            (DmRect){r.x, r.y + r.h - value_h, r.w, value_h}, buf, theme->accent);
    }
}

static bool knob_event(DmWidget *w, DmEvent *e) {
    DmKnobData *d = (DmKnobData *)w->data;

    if (e->type == DM_EVENT_MOUSE_DOWN && e->mouse.button == 1) {
        d->dragging = true;
        d->drag_start_y = e->mouse.y;
        d->drag_start_val = d->value;
        w->flags |= DM_WIDGET_PRESSED;
        return true;
    }

    if (e->type == DM_EVENT_MOUSE_UP) {
        if (d->dragging) {
            d->dragging = false;
            w->flags &= ~DM_WIDGET_PRESSED;
            return true;
        }
    }

    if (e->type == DM_EVENT_MOUSE_MOVE && d->dragging) {
        /* Vertical drag: up increases, down decreases */
        float dy = (float)(d->drag_start_y - e->mouse.y);
        float sensitivity = (d->max_val - d->min_val) / 200.0f;
        d->value = d->drag_start_val + dy * sensitivity;
        if (d->value < d->min_val) d->value = d->min_val;
        if (d->value > d->max_val) d->value = d->max_val;
        if (w->on_change) w->on_change(w, w->userdata);
        return true;
    }

    /* Scroll wheel */
    if (e->type == DM_EVENT_MOUSE_SCROLL) {
        float step = (d->max_val - d->min_val) / 100.0f;
        d->value += e->scroll.dy * step;
        if (d->value < d->min_val) d->value = d->min_val;
        if (d->value > d->max_val) d->value = d->max_val;
        if (w->on_change) w->on_change(w, w->userdata);
        return true;
    }

    return false;
}

static const DmWidgetVT knob_vt = {
    .type_name = "knob",
    .draw      = knob_draw,
    .event     = knob_event,
};

DmWidget *dm_knob_create(const char *id, const char *label,
                         float min_val, float max_val, float value) {
    DmWidget *w = dm_widget_create(&knob_vt, id);
    DmKnobData *d = (DmKnobData *)calloc(1, sizeof(DmKnobData));
    d->min_val       = min_val;
    d->max_val       = max_val;
    d->value         = value;
    d->default_val   = value;
    d->start_angle   = (float)(M_PI * 0.75);    /* 135° = bottom-left */
    d->end_angle     = (float)(M_PI * 2.25);    /* 405° = bottom-right */
    d->track_color   = (DmColor){0x2A, 0x2A, 0x3E, 0xFF};
    d->fill_color    = (DmColor){0x00, 0xF5, 0xD4, 0xFF};
    d->knob_color    = (DmColor){0x22, 0x22, 0x36, 0xFF};
    d->indicator_color = (DmColor){0x00, 0xF5, 0xD4, 0xFF};
    d->show_label    = true;
    d->show_value    = true;
    snprintf(d->value_fmt, sizeof(d->value_fmt), "%%.1f");
    if (label) snprintf(d->label, sizeof(d->label), "%s", label);
    w->data      = d;
    w->bounds.w  = 80;
    w->bounds.h  = 100;
    w->flags    |= DM_WIDGET_FOCUSABLE;
    return w;
}

float dm_knob_get_value(DmWidget *w)      { return ((DmKnobData *)w->data)->value; }
void  dm_knob_set_value(DmWidget *w, float v) {
    DmKnobData *d = (DmKnobData *)w->data;
    d->value = v < d->min_val ? d->min_val : (v > d->max_val ? d->max_val : v);
}
void dm_knob_set_format(DmWidget *w, const char *fmt) {
    DmKnobData *d = (DmKnobData *)w->data;
    snprintf(d->value_fmt, sizeof(d->value_fmt), "%s", fmt);
}

/* ══════════════════════════════════════════════════════════════════════
 *  VU METER — Level Meter with Peak Hold
 * ══════════════════════════════════════════════════════════════════════ */

static void vu_meter_draw(DmWidget *w, DmFramebuffer *fb, const DmTheme *theme) {
    DmVuMeterData *d = (DmVuMeterData *)w->data;
    DmRect r = w->abs_bounds;
    int nch = d->num_channels;
    if (nch <= 0) nch = 1;
    int nseg = d->num_segments;

    if (d->horizontal) {
        int bar_h = (r.h - (nch - 1) * 2) / nch;
        for (int ch = 0; ch < nch; ch++) {
            int by = r.y + ch * (bar_h + 2);
            float level = d->levels[ch];

            for (int s = 0; s < nseg; s++) {
                float seg_t = (float)s / (float)nseg;
                float seg_end = (float)(s + 1) / (float)nseg;
                int sx = r.x + (int)(seg_t * r.w);
                int sw = (int)(seg_end * r.w) - (int)(seg_t * r.w) - 1;
                if (sw < 1) sw = 1;

                DmColor c;
                if (seg_t >= d->threshold_high)     c = d->color_high;
                else if (seg_t >= d->threshold_mid) c = d->color_mid;
                else                                c = d->color_low;

                if (seg_t >= level) {
                    c = d->color_bg;
                }

                dm_fb_fill_rect(fb, (DmRect){sx, by, sw, bar_h}, c);
            }

            /* Peak indicator */
            float peak = d->peaks[ch];
            if (peak > 0.0f) {
                int peak_x = r.x + (int)(peak * (r.w - 2));
                dm_fb_fill_rect(fb, (DmRect){peak_x, by, 2, bar_h}, d->color_peak);
            }
        }
    } else {
        /* Vertical */
        int bar_w = (r.w - (nch - 1) * 2) / nch;
        for (int ch = 0; ch < nch; ch++) {
            int bx = r.x + ch * (bar_w + 2);
            float level = d->levels[ch];

            for (int s = 0; s < nseg; s++) {
                float seg_t = (float)s / (float)nseg;
                float seg_end = (float)(s + 1) / (float)nseg;
                /* Bottom = 0, top = 1, so invert y */
                int sy = r.y + r.h - (int)(seg_end * r.h);
                int sh = (int)(seg_end * r.h) - (int)(seg_t * r.h) - 1;
                if (sh < 1) sh = 1;

                DmColor c;
                if (seg_t >= d->threshold_high)     c = d->color_high;
                else if (seg_t >= d->threshold_mid) c = d->color_mid;
                else                                c = d->color_low;

                if (seg_t >= level) c = d->color_bg;

                dm_fb_fill_rect(fb, (DmRect){bx, sy, bar_w, sh}, c);
            }

            /* Peak */
            float peak = d->peaks[ch];
            if (peak > 0.0f) {
                int peak_y = r.y + r.h - (int)(peak * r.h);
                dm_fb_fill_rect(fb, (DmRect){bx, peak_y, bar_w, 2}, d->color_peak);
            }
        }
    }
}

static const DmWidgetVT vu_meter_vt = {
    .type_name = "vu_meter",
    .draw      = vu_meter_draw,
};

DmWidget *dm_vu_meter_create(const char *id, int channels) {
    DmWidget *w = dm_widget_create(&vu_meter_vt, id);
    DmVuMeterData *d = (DmVuMeterData *)calloc(1, sizeof(DmVuMeterData));
    d->num_channels   = channels > DM_VU_MAX_CHANNELS ? DM_VU_MAX_CHANNELS : channels;
    d->num_segments   = 24;
    d->horizontal     = false;
    d->peak_decay     = 0.5f;
    d->color_low      = (DmColor){0x4C, 0xFF, 0x82, 0xFF};
    d->color_mid      = (DmColor){0xFF, 0xD9, 0x4C, 0xFF};
    d->color_high     = (DmColor){0xFF, 0x4C, 0x6A, 0xFF};
    d->color_bg       = (DmColor){0x16, 0x16, 0x24, 0xFF};
    d->color_peak     = (DmColor){0xFF, 0xFF, 0xFF, 0xFF};
    d->threshold_mid  = 0.6f;
    d->threshold_high = 0.85f;
    w->data      = d;
    w->bounds.w  = 20 * channels;
    w->bounds.h  = 120;
    return w;
}

void dm_vu_meter_set_level(DmWidget *w, int ch, float level) {
    DmVuMeterData *d = (DmVuMeterData *)w->data;
    if (ch < 0 || ch >= d->num_channels) return;
    if (level < 0.0f) level = 0.0f;
    if (level > 1.0f) level = 1.0f;
    d->levels[ch] = level;
    if (level > d->peaks[ch]) d->peaks[ch] = level;
}

void dm_vu_meter_set_levels(DmWidget *w, const float *levels, int count) {
    DmVuMeterData *d = (DmVuMeterData *)w->data;
    for (int i = 0; i < count && i < d->num_channels; i++)
        dm_vu_meter_set_level(w, i, levels[i]);
}

void dm_vu_meter_update(DmWidget *w, float dt) {
    DmVuMeterData *d = (DmVuMeterData *)w->data;
    for (int i = 0; i < d->num_channels; i++) {
        d->peaks[i] -= d->peak_decay * dt;
        if (d->peaks[i] < d->levels[i]) d->peaks[i] = d->levels[i];
        if (d->peaks[i] < 0.0f) d->peaks[i] = 0.0f;
    }
}

/* ══════════════════════════════════════════════════════════════════════
 *  WAVEFORM — Oscilloscope Display
 * ══════════════════════════════════════════════════════════════════════ */

static void waveform_draw(DmWidget *w, DmFramebuffer *fb, const DmTheme *theme) {
    DmWaveformData *d = (DmWaveformData *)w->data;
    DmRect r = w->abs_bounds;

    /* Background */
    dm_fb_fill_rect(fb, r, d->bg_color);

    int mid_y = r.y + r.h / 2;

    /* Grid */
    if (d->show_grid) {
        /* Horizontal grid lines at ±0.25, ±0.5, ±0.75 */
        for (int g = 1; g <= 3; g++) {
            float frac = g * 0.25f;
            int gy_pos = mid_y - (int)(frac * d->zoom_y * r.h / 2);
            int gy_neg = mid_y + (int)(frac * d->zoom_y * r.h / 2);
            dm_fb_hline(fb, r.x, r.x + r.w - 1, gy_pos, d->grid_color);
            dm_fb_hline(fb, r.x, r.x + r.w - 1, gy_neg, d->grid_color);
        }
        /* Vertical grid (8 divisions) */
        for (int g = 1; g < 8; g++) {
            int gx = r.x + g * r.w / 8;
            dm_fb_vline(fb, gx, r.y, r.y + r.h - 1, d->grid_color);
        }
    }

    /* Zero line */
    dm_fb_hline(fb, r.x, r.x + r.w - 1, mid_y, d->zero_line_color);

    /* Waveform */
    if (d->num_samples <= 0) return;

    int visible = (int)(d->num_samples / d->zoom_x);
    int start = (int)(d->offset_x * (d->num_samples - visible));
    if (start < 0) start = 0;

    int prev_x = -1, prev_y = -1;
    for (int px = 0; px < r.w; px++) {
        /* Map pixel to sample index */
        int si = start + (int)((float)px / (float)r.w * visible);
        if (si < 0) si = 0;

        int actual_idx;
        if (d->ring_buffer) {
            actual_idx = (d->write_pos - d->num_samples + si) % DM_WAVEFORM_MAX_SAMPLES;
            if (actual_idx < 0) actual_idx += DM_WAVEFORM_MAX_SAMPLES;
        } else {
            actual_idx = si;
        }
        if (actual_idx >= DM_WAVEFORM_MAX_SAMPLES) continue;

        float sample = d->samples[actual_idx];
        int sy = mid_y - (int)(sample * d->zoom_y * r.h / 2);
        if (sy < r.y) sy = r.y;
        if (sy >= r.y + r.h) sy = r.y + r.h - 1;

        /* Fill below waveform */
        if (d->fill) {
            if (sy < mid_y)
                dm_fb_vline(fb, r.x + px, sy, mid_y, d->fill_color);
            else
                dm_fb_vline(fb, r.x + px, mid_y, sy, d->fill_color);
        }

        /* Line to previous point */
        if (prev_x >= 0)
            dm_fb_line(fb, prev_x, prev_y, r.x + px, sy, d->wave_color);

        prev_x = r.x + px;
        prev_y = sy;
    }

    /* Border */
    dm_fb_stroke_rect(fb, r, theme->border, 1);
}

static bool waveform_event(DmWidget *w, DmEvent *e) {
    DmWaveformData *d = (DmWaveformData *)w->data;

    if (e->type == DM_EVENT_MOUSE_SCROLL) {
        /* Scroll to zoom */
        d->zoom_x += e->scroll.dy * 0.1f;
        if (d->zoom_x < 0.1f) d->zoom_x = 0.1f;
        if (d->zoom_x > 10.0f) d->zoom_x = 10.0f;
        return true;
    }
    return false;
}

static const DmWidgetVT waveform_vt = {
    .type_name = "waveform",
    .draw      = waveform_draw,
    .event     = waveform_event,
};

DmWidget *dm_waveform_create(const char *id, int num_samples) {
    DmWidget *w = dm_widget_create(&waveform_vt, id);
    DmWaveformData *d = (DmWaveformData *)calloc(1, sizeof(DmWaveformData));
    d->num_samples     = num_samples > DM_WAVEFORM_MAX_SAMPLES ? DM_WAVEFORM_MAX_SAMPLES : num_samples;
    d->zoom_x          = 1.0f;
    d->zoom_y          = 0.9f;
    d->wave_color      = (DmColor){0x00, 0xF5, 0xD4, 0xFF};
    d->grid_color      = (DmColor){0x1A, 0x1A, 0x2E, 0x80};
    d->zero_line_color = (DmColor){0x2A, 0x2A, 0x3E, 0xFF};
    d->bg_color        = (DmColor){0x0C, 0x0C, 0x14, 0xFF};
    d->fill_color      = (DmColor){0x00, 0xF5, 0xD4, 0x30};
    d->show_grid       = true;
    d->fill            = false;
    d->line_width      = 1;
    w->data       = d;
    w->bounds.w   = 400;
    w->bounds.h   = 128;
    return w;
}

void dm_waveform_set_samples(DmWidget *w, const float *samples, int count) {
    DmWaveformData *d = (DmWaveformData *)w->data;
    if (count > DM_WAVEFORM_MAX_SAMPLES) count = DM_WAVEFORM_MAX_SAMPLES;
    memcpy(d->samples, samples, count * sizeof(float));
    d->num_samples = count;
    d->ring_buffer = false;
}

void dm_waveform_push_sample(DmWidget *w, float sample) {
    DmWaveformData *d = (DmWaveformData *)w->data;
    d->samples[d->write_pos] = sample;
    d->write_pos = (d->write_pos + 1) % DM_WAVEFORM_MAX_SAMPLES;
    if (d->num_samples < DM_WAVEFORM_MAX_SAMPLES) d->num_samples++;
    d->ring_buffer = true;
}

void dm_waveform_clear(DmWidget *w) {
    DmWaveformData *d = (DmWaveformData *)w->data;
    memset(d->samples, 0, sizeof(d->samples));
    d->num_samples = 0;
    d->write_pos = 0;
}

/* ══════════════════════════════════════════════════════════════════════
 *  DROPDOWN — Select from Options
 * ══════════════════════════════════════════════════════════════════════ */

static void dropdown_draw(DmWidget *w, DmFramebuffer *fb, const DmTheme *theme) {
    DmDropdownData *d = (DmDropdownData *)w->data;
    DmRect r = w->abs_bounds;
    int item_h = theme->font->glyph_h + 8;

    /* Main box */
    dm_fb_fill_rounded_rect(fb, (DmRect){r.x, r.y, r.w, item_h}, 4, d->bg_color);
    dm_fb_stroke_rounded_rect(fb, (DmRect){r.x, r.y, r.w, item_h}, 4,
        d->open ? theme->accent : d->border_color, 1);

    /* Selected text or placeholder */
    const char *display = d->placeholder;
    DmColor text_c = theme->fg_secondary;
    if (d->selected >= 0 && d->selected < d->num_items) {
        display = d->items[d->selected];
        text_c = d->fg_color;
    }
    dm_fb_draw_text(fb, theme->font, r.x + 8,
        r.y + (item_h - theme->font->glyph_h) / 2, display, text_c);

    /* Arrow indicator */
    int ax = r.x + r.w - 16;
    int ay = r.y + item_h / 2;
    if (d->open) {
        dm_fb_line(fb, ax - 4, ay + 2, ax, ay - 2, theme->accent);
        dm_fb_line(fb, ax, ay - 2, ax + 4, ay + 2, theme->accent);
    } else {
        dm_fb_line(fb, ax - 4, ay - 2, ax, ay + 2, theme->fg_secondary);
        dm_fb_line(fb, ax, ay + 2, ax + 4, ay - 2, theme->fg_secondary);
    }

    /* Dropdown list */
    if (d->open && d->num_items > 0) {
        int visible = d->max_visible;
        if (visible > d->num_items) visible = d->num_items;
        int list_h = visible * item_h;
        int list_y = r.y + item_h + 2;

        /* Drop shadow */
        dm_fb_fill_rect(fb, (DmRect){r.x + 2, list_y + 2, r.w, list_h},
            (DmColor){0, 0, 0, 80});

        /* Background */
        dm_fb_fill_rounded_rect(fb,
            (DmRect){r.x, list_y, r.w, list_h}, 4, d->bg_color);
        dm_fb_stroke_rounded_rect(fb,
            (DmRect){r.x, list_y, r.w, list_h}, 4, d->border_color, 1);

        for (int i = 0; i < visible; i++) {
            int idx = d->scroll_offset + i;
            if (idx >= d->num_items) break;
            int iy = list_y + i * item_h;
            DmRect item_r = {r.x + 1, iy, r.w - 2, item_h};

            /* Hover highlight (check mouse position via the hovered flag) */
            if (idx == d->selected) {
                dm_fb_fill_rect(fb, item_r,
                    (DmColor){0x00, 0xF5, 0xD4, 0x30});
            }

            dm_fb_draw_text(fb, theme->font, r.x + 8,
                iy + (item_h - theme->font->glyph_h) / 2,
                d->items[idx], d->fg_color);
        }
    }
}

static bool dropdown_event(DmWidget *w, DmEvent *e) {
    DmDropdownData *d = (DmDropdownData *)w->data;
    DmRect r = w->abs_bounds;
    int item_h = 24; /* approximate */

    if (e->type == DM_EVENT_MOUSE_DOWN && e->mouse.button == 1) {
        if (!d->open) {
            /* Click on closed dropdown — open it */
            if (dm_rect_contains((DmRect){r.x, r.y, r.w, item_h},
                                 e->mouse.x, e->mouse.y)) {
                d->open = true;
                return true;
            }
        } else {
            /* Click on item in open list */
            int list_y = r.y + item_h + 2;
            int visible = d->max_visible < d->num_items ? d->max_visible : d->num_items;
            DmRect list_r = {r.x, list_y, r.w, visible * item_h};

            if (dm_rect_contains(list_r, e->mouse.x, e->mouse.y)) {
                int idx = d->scroll_offset + (e->mouse.y - list_y) / item_h;
                if (idx >= 0 && idx < d->num_items) {
                    d->selected = idx;
                    d->open = false;
                    if (w->on_change) w->on_change(w, w->userdata);
                }
                return true;
            }

            /* Click outside — close */
            d->open = false;
            return true;
        }
    }

    if (d->open && e->type == DM_EVENT_MOUSE_SCROLL) {
        d->scroll_offset -= (int)e->scroll.dy;
        if (d->scroll_offset < 0) d->scroll_offset = 0;
        int max_off = d->num_items - d->max_visible;
        if (max_off < 0) max_off = 0;
        if (d->scroll_offset > max_off) d->scroll_offset = max_off;
        return true;
    }

    return false;
}

static const DmWidgetVT dropdown_vt = {
    .type_name = "dropdown",
    .draw      = dropdown_draw,
    .event     = dropdown_event,
};

DmWidget *dm_dropdown_create(const char *id, const char *placeholder) {
    DmWidget *w = dm_widget_create(&dropdown_vt, id);
    DmDropdownData *d = (DmDropdownData *)calloc(1, sizeof(DmDropdownData));
    d->selected      = -1;
    d->max_visible   = 6;
    d->bg_color      = (DmColor){0x14, 0x14, 0x24, 0xFF};
    d->fg_color      = (DmColor){0xE8, 0xE8, 0xF0, 0xFF};
    d->hover_color   = (DmColor){0x1E, 0x1E, 0x38, 0xFF};
    d->border_color  = (DmColor){0x2A, 0x2A, 0x3E, 0xFF};
    if (placeholder) snprintf(d->placeholder, sizeof(d->placeholder), "%s", placeholder);
    w->data      = d;
    w->bounds.h  = 32;
    w->flags    |= DM_WIDGET_FOCUSABLE;
    return w;
}

void dm_dropdown_add_item(DmWidget *w, const char *item) {
    DmDropdownData *d = (DmDropdownData *)w->data;
    if (d->num_items >= DM_DROPDOWN_MAX_ITEMS) return;
    snprintf(d->items[d->num_items], DM_DROPDOWN_ITEM_LEN, "%s", item);
    d->num_items++;
}

void dm_dropdown_clear_items(DmWidget *w) {
    DmDropdownData *d = (DmDropdownData *)w->data;
    d->num_items = 0;
    d->selected  = -1;
}

int dm_dropdown_get_selected(DmWidget *w) {
    return ((DmDropdownData *)w->data)->selected;
}

const char *dm_dropdown_get_selected_text(DmWidget *w) {
    DmDropdownData *d = (DmDropdownData *)w->data;
    if (d->selected < 0 || d->selected >= d->num_items) return NULL;
    return d->items[d->selected];
}

void dm_dropdown_set_selected(DmWidget *w, int index) {
    DmDropdownData *d = (DmDropdownData *)w->data;
    d->selected = (index >= 0 && index < d->num_items) ? index : -1;
}

/* ══════════════════════════════════════════════════════════════════════
 *  SCROLL PANEL — Scrollable Container
 * ══════════════════════════════════════════════════════════════════════ */

static void scroll_panel_draw(DmWidget *w, DmFramebuffer *fb, const DmTheme *theme) {
    DmScrollPanelData *d = (DmScrollPanelData *)w->data;
    DmRect r = w->abs_bounds;

    /* Background */
    dm_fb_fill_rect(fb, r, theme->bg_secondary);

    /* The children are drawn by the parent draw system with clipping.
       We just draw the scrollbar overlay. */
    int sb_w = d->scrollbar_width;

    if (d->show_scrollbar_v && d->content_h > r.h) {
        int track_x = r.x + r.w - sb_w;
        dm_fb_fill_rect(fb, (DmRect){track_x, r.y, sb_w, r.h}, d->scrollbar_bg);

        float visible_frac = (float)r.h / (float)d->content_h;
        int thumb_h = (int)(visible_frac * r.h);
        if (thumb_h < 20) thumb_h = 20;
        float scroll_frac = (float)d->scroll_y / (float)(d->content_h - r.h);
        int thumb_y = r.y + (int)(scroll_frac * (r.h - thumb_h));

        DmColor tc = d->scrollbar_color;
        if (d->dragging_scrollbar) tc = theme->accent;
        dm_fb_fill_rounded_rect(fb, (DmRect){track_x + 1, thumb_y, sb_w - 2, thumb_h},
            (sb_w - 2) / 2, tc);
    }
}

static void scroll_panel_layout(DmWidget *w) {
    DmScrollPanelData *d = (DmScrollPanelData *)w->data;
    /* Offset children by scroll position */
    for (int i = 0; i < w->child_count; i++) {
        w->children[i]->bounds.y -= d->scroll_y;
        w->children[i]->bounds.x -= d->scroll_x;
    }
}

static bool scroll_panel_event(DmWidget *w, DmEvent *e) {
    DmScrollPanelData *d = (DmScrollPanelData *)w->data;

    if (e->type == DM_EVENT_MOUSE_SCROLL) {
        d->scroll_y -= (int)(e->scroll.dy * 30);
        if (d->scroll_y < 0) d->scroll_y = 0;
        int max_scroll = d->content_h - w->bounds.h;
        if (max_scroll < 0) max_scroll = 0;
        if (d->scroll_y > max_scroll) d->scroll_y = max_scroll;
        return true;
    }
    return false;
}

static const DmWidgetVT scroll_panel_vt = {
    .type_name = "scroll_panel",
    .draw      = scroll_panel_draw,
    .layout    = scroll_panel_layout,
    .event     = scroll_panel_event,
};

DmWidget *dm_scroll_panel_create(const char *id, int content_w, int content_h) {
    DmWidget *w = dm_widget_create(&scroll_panel_vt, id);
    DmScrollPanelData *d = (DmScrollPanelData *)calloc(1, sizeof(DmScrollPanelData));
    d->content_w        = content_w;
    d->content_h        = content_h;
    d->show_scrollbar_v = true;
    d->scrollbar_width  = 8;
    d->scrollbar_color  = (DmColor){0x55, 0x55, 0x66, 0xCC};
    d->scrollbar_bg     = (DmColor){0x12, 0x12, 0x20, 0x80};
    w->data  = d;
    w->flags |= DM_WIDGET_CLIP_CHILDREN;
    return w;
}

void dm_scroll_panel_set_content_size(DmWidget *w, int cw, int ch) {
    DmScrollPanelData *d = (DmScrollPanelData *)w->data;
    d->content_w = cw;
    d->content_h = ch;
}

void dm_scroll_panel_scroll_to(DmWidget *w, int x, int y) {
    DmScrollPanelData *d = (DmScrollPanelData *)w->data;
    d->scroll_x = x;
    d->scroll_y = y;
}

/* ══════════════════════════════════════════════════════════════════════
 *  XY PAD — 2D Control Surface
 * ══════════════════════════════════════════════════════════════════════ */

static void xy_pad_draw(DmWidget *w, DmFramebuffer *fb, const DmTheme *theme) {
    DmXYPadData *d = (DmXYPadData *)w->data;
    DmRect r = w->abs_bounds;

    /* Background */
    dm_fb_fill_rect(fb, r, d->bg_color);

    /* Grid */
    if (d->show_grid) {
        for (int g = 1; g < 4; g++) {
            int gx = r.x + g * r.w / 4;
            int gy = r.y + g * r.h / 4;
            dm_fb_vline(fb, gx, r.y, r.y + r.h - 1, d->grid_color);
            dm_fb_hline(fb, r.x, r.x + r.w - 1, gy, d->grid_color);
        }
    }

    int cursor_x = r.x + (int)(d->value_x * r.w);
    int cursor_y = r.y + (int)((1.0f - d->value_y) * r.h);

    /* Trail */
    if (d->show_trail && d->trail_len > 1) {
        for (int i = 1; i < d->trail_len; i++) {
            int idx0 = (d->trail_pos - d->trail_len + i - 1 + 128) % 128;
            int idx1 = (d->trail_pos - d->trail_len + i + 128) % 128;
            int x0 = r.x + (int)(d->trail_x[idx0] * r.w);
            int y0 = r.y + (int)((1.0f - d->trail_y[idx0]) * r.h);
            int x1 = r.x + (int)(d->trail_x[idx1] * r.w);
            int y1 = r.y + (int)((1.0f - d->trail_y[idx1]) * r.h);
            float alpha_t = (float)i / (float)d->trail_len;
            DmColor tc = d->trail_color;
            tc.a = (uint8_t)(alpha_t * tc.a);
            dm_fb_line(fb, x0, y0, x1, y1, tc);
        }
    }

    /* Crosshair */
    if (d->show_crosshair) {
        DmColor ch_c = d->cursor_color;
        ch_c.a = 80;
        dm_fb_hline(fb, r.x, r.x + r.w - 1, cursor_y, ch_c);
        dm_fb_vline(fb, cursor_x, r.y, r.y + r.h - 1, ch_c);
    }

    /* Cursor dot */
    DmColor cc = d->cursor_color;
    if (w->flags & DM_WIDGET_PRESSED)
        cc = theme->active;
    dm_fb_fill_circle(fb, cursor_x, cursor_y, 6, cc);
    dm_fb_stroke_circle(fb, cursor_x, cursor_y, 6,
        (DmColor){0xFF, 0xFF, 0xFF, 0x80});

    /* Border */
    dm_fb_stroke_rect(fb, r, theme->border, 1);
}

static bool xy_pad_event(DmWidget *w, DmEvent *e) {
    DmXYPadData *d = (DmXYPadData *)w->data;
    DmRect r = w->abs_bounds;

    if (e->type == DM_EVENT_MOUSE_DOWN && e->mouse.button == 1) {
        d->dragging = true;
        w->flags |= DM_WIDGET_PRESSED;
    }
    if (e->type == DM_EVENT_MOUSE_UP) {
        d->dragging = false;
        w->flags &= ~DM_WIDGET_PRESSED;
    }

    if ((e->type == DM_EVENT_MOUSE_DOWN || e->type == DM_EVENT_MOUSE_MOVE) && d->dragging) {
        float nx = (float)(e->mouse.x - r.x) / (float)r.w;
        float ny = 1.0f - (float)(e->mouse.y - r.y) / (float)r.h;
        if (nx < 0.0f) nx = 0.0f; if (nx > 1.0f) nx = 1.0f;
        if (ny < 0.0f) ny = 0.0f; if (ny > 1.0f) ny = 1.0f;
        d->value_x = nx;
        d->value_y = ny;

        /* Record trail */
        if (d->show_trail) {
            d->trail_x[d->trail_pos] = nx;
            d->trail_y[d->trail_pos] = ny;
            d->trail_pos = (d->trail_pos + 1) % 128;
            if (d->trail_len < 128) d->trail_len++;
        }

        if (w->on_change) w->on_change(w, w->userdata);
        return true;
    }
    return false;
}

static const DmWidgetVT xy_pad_vt = {
    .type_name = "xy_pad",
    .draw      = xy_pad_draw,
    .event     = xy_pad_event,
};

DmWidget *dm_xy_pad_create(const char *id) {
    DmWidget *w = dm_widget_create(&xy_pad_vt, id);
    DmXYPadData *d = (DmXYPadData *)calloc(1, sizeof(DmXYPadData));
    d->value_x       = 0.5f;
    d->value_y       = 0.5f;
    d->bg_color      = (DmColor){0x0C, 0x0C, 0x14, 0xFF};
    d->grid_color    = (DmColor){0x1A, 0x1A, 0x2E, 0x80};
    d->cursor_color  = (DmColor){0x00, 0xF5, 0xD4, 0xFF};
    d->trail_color   = (DmColor){0x8B, 0x5C, 0xF6, 0xAA};
    d->show_grid     = true;
    d->show_crosshair = true;
    d->show_trail    = true;
    w->data      = d;
    w->bounds.w  = 200;
    w->bounds.h  = 200;
    w->flags    |= DM_WIDGET_FOCUSABLE;
    return w;
}

void dm_xy_pad_get_value(DmWidget *w, float *x, float *y) {
    DmXYPadData *d = (DmXYPadData *)w->data;
    if (x) *x = d->value_x;
    if (y) *y = d->value_y;
}

void dm_xy_pad_set_value(DmWidget *w, float x, float y) {
    DmXYPadData *d = (DmXYPadData *)w->data;
    d->value_x = x < 0.0f ? 0.0f : (x > 1.0f ? 1.0f : x);
    d->value_y = y < 0.0f ? 0.0f : (y > 1.0f ? 1.0f : y);
}
