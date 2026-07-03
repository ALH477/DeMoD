// SPDX-License-Identifier: MPL-2.0
/*
 * DeMoD UI Framework — Widget Implementation
 * All built-in widgets, layout engine, event dispatch.
 * Copyright (c) 2026 DeMoD LLC.
 * Licensed under the Mozilla Public License, v. 2.0; see LICENSE.
 */
#include "demod/widget.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* ── Theme ─────────────────────────────────────────────────────────── */

static DmTheme default_theme = {
    .bg              = {0x0A, 0x0A, 0x0F, 0xFF},
    .bg_secondary    = {0x1A, 0x1A, 0x2E, 0xFF},
    .fg              = {0xE8, 0xE8, 0xF0, 0xFF},
    .fg_secondary    = {0xC0, 0xC0, 0xD0, 0xFF},
    .accent          = {0x00, 0xF5, 0xD4, 0xFF},  /* turquoise */
    .accent_secondary= {0x8B, 0x5C, 0xF6, 0xFF},  /* violet */
    .border          = {0x2A, 0x2A, 0x3E, 0xFF},
    .hover           = {0x1E, 0x1E, 0x38, 0xFF},
    .active          = {0x00, 0xC4, 0xA8, 0xFF},
    .disabled        = {0x55, 0x55, 0x66, 0xFF},
    .error           = {0xFF, 0x4C, 0x6A, 0xFF},
    .success         = {0x4C, 0xFF, 0x82, 0xFF},
    .corner_radius   = 6,
    .border_width    = 1,
    .padding         = 8,
    .spacing         = 6,
    .font            = NULL,  /* set lazily */
    .font_small      = NULL,
};

const DmTheme *dm_theme_default(void) {
    if (!default_theme.font) {
        default_theme.font       = dm_font_default();
        default_theme.font_small = dm_font_small();
    }
    return &default_theme;
}

/* ── Widget Base ───────────────────────────────────────────────────── */

DmWidget *dm_widget_create(const DmWidgetVT *vt, const char *id) {
    DmWidget *w = (DmWidget *)calloc(1, sizeof(DmWidget));
    if (!w) return NULL;
    w->vt    = vt;
    w->flags = DM_WIDGET_VISIBLE | DM_WIDGET_ENABLED;
    w->lua_ref = -1;
    if (id) snprintf(w->id, DM_MAX_ID_LEN, "%s", id);
    return w;
}

void dm_widget_destroy(DmWidget *w) {
    if (!w) return;
    for (int i = 0; i < w->child_count; i++)
        dm_widget_destroy(w->children[i]);
    if (w->vt && w->vt->destroy) w->vt->destroy(w);
    if (w->data) free(w->data);
    free(w);
}

void dm_widget_add_child(DmWidget *parent, DmWidget *child) {
    if (!parent || !child || parent->child_count >= DM_MAX_CHILDREN) return;
    child->parent = parent;
    parent->children[parent->child_count++] = child;
    parent->flags |= DM_WIDGET_DIRTY;
}

void dm_widget_remove_child(DmWidget *parent, DmWidget *child) {
    if (!parent || !child) return;
    for (int i = 0; i < parent->child_count; i++) {
        if (parent->children[i] == child) {
            child->parent = NULL;
            for (int j = i; j < parent->child_count - 1; j++)
                parent->children[j] = parent->children[j + 1];
            parent->child_count--;
            parent->flags |= DM_WIDGET_DIRTY;
            return;
        }
    }
}

DmWidget *dm_widget_find(DmWidget *root, const char *id) {
    if (!root || !id) return NULL;
    if (strcmp(root->id, id) == 0) return root;
    for (int i = 0; i < root->child_count; i++) {
        DmWidget *found = dm_widget_find(root->children[i], id);
        if (found) return found;
    }
    return NULL;
}

/* ── Absolute Bounds ───────────────────────────────────────────────── */

void dm_widget_compute_abs_bounds(DmWidget *w, int px, int py) {
    w->abs_bounds.x = px + w->bounds.x;
    w->abs_bounds.y = py + w->bounds.y;
    w->abs_bounds.w = w->bounds.w;
    w->abs_bounds.h = w->bounds.h;

    for (int i = 0; i < w->child_count; i++)
        dm_widget_compute_abs_bounds(w->children[i],
                                    w->abs_bounds.x, w->abs_bounds.y);
}

/* ── Layout ────────────────────────────────────────────────────────── */

void dm_widget_layout(DmWidget *w) {
    if (!w) return;

    /* Apply auto-layout to children if set */
    if (w->layout.type != DM_LAYOUT_NONE && w->child_count > 0) {
        int pad  = w->layout.padding;
        int spc  = w->layout.spacing;
        int cx   = pad;
        int cy   = pad;
        int avail_w = w->bounds.w - 2 * pad;
        int avail_h = w->bounds.h - 2 * pad;

        switch (w->layout.type) {
        case DM_LAYOUT_VBOX: {
            /* Stack children vertically, full width */
            int per_child = (avail_h - spc * (w->child_count - 1)) / w->child_count;
            for (int i = 0; i < w->child_count; i++) {
                DmWidget *c = w->children[i];
                c->bounds.x = cx;
                c->bounds.y = cy;
                c->bounds.w = avail_w;
                if (c->bounds.h <= 0) c->bounds.h = per_child;
                cy += c->bounds.h + spc;
            }
            break;
        }
        case DM_LAYOUT_HBOX: {
            int per_child = (avail_w - spc * (w->child_count - 1)) / w->child_count;
            for (int i = 0; i < w->child_count; i++) {
                DmWidget *c = w->children[i];
                c->bounds.x = cx;
                c->bounds.y = cy;
                if (c->bounds.w <= 0) c->bounds.w = per_child;
                c->bounds.h = avail_h;
                cx += c->bounds.w + spc;
            }
            break;
        }
        case DM_LAYOUT_GRID: {
            int cols = w->layout.columns > 0 ? w->layout.columns : 2;
            int rows = (w->child_count + cols - 1) / cols;
            int cell_w = (avail_w - spc * (cols - 1)) / cols;
            int cell_h = (avail_h - spc * (rows - 1)) / rows;
            for (int i = 0; i < w->child_count; i++) {
                int col = i % cols;
                int row = i / cols;
                DmWidget *c = w->children[i];
                c->bounds.x = pad + col * (cell_w + spc);
                c->bounds.y = pad + row * (cell_h + spc);
                c->bounds.w = cell_w;
                c->bounds.h = cell_h;
            }
            break;
        }
        default: break;
        }
    }

    /* Recursively layout children */
    for (int i = 0; i < w->child_count; i++)
        dm_widget_layout(w->children[i]);

    /* Call custom layout if defined */
    if (w->vt && w->vt->layout) w->vt->layout(w);
}

/* ── Drawing ───────────────────────────────────────────────────────── */

void dm_widget_draw(DmWidget *w, DmFramebuffer *fb, const DmTheme *theme) {
    if (!w || !(w->flags & DM_WIDGET_VISIBLE)) return;

    DmRect saved_clip = fb->clip;
    if (w->flags & DM_WIDGET_CLIP_CHILDREN)
        dm_fb_clip_push(fb, w->abs_bounds);

    /* Draw self */
    if (w->vt && w->vt->draw) w->vt->draw(w, fb, theme);

    /* Draw children (back to front) */
    for (int i = 0; i < w->child_count; i++)
        dm_widget_draw(w->children[i], fb, theme);

    fb->clip = saved_clip;
}

/* ── Event Dispatch ────────────────────────────────────────────────── */

bool dm_widget_dispatch(DmWidget *w, DmEvent *e) {
    if (!w || !(w->flags & DM_WIDGET_VISIBLE) || !(w->flags & DM_WIDGET_ENABLED))
        return false;

    /* Dispatch to children first (front to back = reverse order) */
    for (int i = w->child_count - 1; i >= 0; i--) {
        if (dm_widget_dispatch(w->children[i], e)) return true;
    }

    /* Handle mouse events: check bounds */
    if (e->type == DM_EVENT_MOUSE_MOVE || e->type == DM_EVENT_MOUSE_DOWN ||
        e->type == DM_EVENT_MOUSE_UP) {
        bool inside = dm_rect_contains(w->abs_bounds, e->mouse.x, e->mouse.y);

        if (e->type == DM_EVENT_MOUSE_MOVE) {
            if (inside && !(w->flags & DM_WIDGET_HOVERED)) {
                w->flags |= DM_WIDGET_HOVERED;
                w->flags |= DM_WIDGET_DIRTY;
            } else if (!inside && (w->flags & DM_WIDGET_HOVERED)) {
                w->flags &= ~DM_WIDGET_HOVERED;
                w->flags |= DM_WIDGET_DIRTY;
            }
        }

        if (!inside && e->type != DM_EVENT_MOUSE_UP) return false;
    }

    /* Let widget handle the event */
    if (w->vt && w->vt->event) return w->vt->event(w, e);
    return false;
}

/* ══════════════════════════════════════════════════════════════════════
 *  BUILT-IN WIDGETS
 * ══════════════════════════════════════════════════════════════════════ */

/* ── Panel ─────────────────────────────────────────────────────────── */

static void panel_draw(DmWidget *w, DmFramebuffer *fb, const DmTheme *theme) {
    DmPanelData *d = (DmPanelData *)w->data;
    DmRect r = w->abs_bounds;
    if (d->draw_bg)
        dm_fb_fill_rounded_rect(fb, r, d->radius, d->bg);
    if (d->draw_border)
        dm_fb_stroke_rounded_rect(fb, r, d->radius, d->border, 1);
}

static const DmWidgetVT panel_vt = {
    .type_name = "panel",
    .draw      = panel_draw,
};

DmWidget *dm_panel_create(const char *id) {
    DmWidget *w = dm_widget_create(&panel_vt, id);
    DmPanelData *d = (DmPanelData *)calloc(1, sizeof(DmPanelData));
    d->bg     = DM_DARK_GRAY;
    d->border = DM_MID_GRAY;
    d->radius = 6;
    d->draw_bg     = true;
    d->draw_border = true;
    w->data = d;
    w->flags |= DM_WIDGET_CLIP_CHILDREN;
    return w;
}

void dm_panel_set_bg(DmWidget *w, DmColor bg) {
    DmPanelData *d = (DmPanelData *)w->data;
    d->bg = bg;
    d->draw_bg = true;
}

void dm_panel_set_border(DmWidget *w, DmColor border) {
    DmPanelData *d = (DmPanelData *)w->data;
    d->border = border;
    d->draw_border = true;
}

/* ── Label ─────────────────────────────────────────────────────────── */

static void label_draw(DmWidget *w, DmFramebuffer *fb, const DmTheme *theme) {
    DmLabelData *d = (DmLabelData *)w->data;
    DmRect r = w->abs_bounds;
    const DmFont *f = theme->font;

    if (d->align == 1) { /* center */
        dm_fb_draw_text_centered(fb, f, r, d->text, d->color);
    } else if (d->align == 2) { /* right */
        int tw = dm_font_text_width(f, d->text);
        dm_fb_draw_text(fb, f, r.x + r.w - tw,
                        r.y + (r.h - dm_font_text_height(f)) / 2,
                        d->text, d->color);
    } else { /* left */
        dm_fb_draw_text(fb, f, r.x,
                        r.y + (r.h - dm_font_text_height(f)) / 2,
                        d->text, d->color);
    }
}

static const DmWidgetVT label_vt = {
    .type_name = "label",
    .draw      = label_draw,
};

DmWidget *dm_label_create(const char *id, const char *text) {
    DmWidget *w = dm_widget_create(&label_vt, id);
    DmLabelData *d = (DmLabelData *)calloc(1, sizeof(DmLabelData));
    snprintf(d->text, sizeof(d->text), "%s", text ? text : "");
    d->color = DM_WHITE;
    d->align = 0;
    w->data = d;
    w->bounds.h = 20;
    return w;
}

void dm_label_set_text(DmWidget *w, const char *text) {
    DmLabelData *d = (DmLabelData *)w->data;
    snprintf(d->text, sizeof(d->text), "%s", text ? text : "");
}

void dm_label_set_color(DmWidget *w, DmColor c) {
    DmLabelData *d = (DmLabelData *)w->data;
    d->color = c;
}

/* ── Button ────────────────────────────────────────────────────────── */

static void button_draw(DmWidget *w, DmFramebuffer *fb, const DmTheme *theme) {
    DmButtonData *d = (DmButtonData *)w->data;
    DmRect r = w->abs_bounds;

    DmColor bg = d->bg;
    if (!(w->flags & DM_WIDGET_ENABLED)) bg = theme->disabled;
    else if (w->flags & DM_WIDGET_PRESSED)  bg = d->bg_active;
    else if (w->flags & DM_WIDGET_HOVERED)  bg = d->bg_hover;

    dm_fb_fill_rounded_rect(fb, r, d->radius, bg);
    dm_fb_draw_text_centered(fb, theme->font, r, d->text, d->fg);
}

static bool button_event(DmWidget *w, DmEvent *e) {
    if (!(w->flags & DM_WIDGET_ENABLED)) return false;

    if (e->type == DM_EVENT_MOUSE_DOWN && e->mouse.button == DM_MOUSE_LEFT) {
        w->flags |= DM_WIDGET_PRESSED;
        return true;
    }
    if (e->type == DM_EVENT_MOUSE_UP && e->mouse.button == DM_MOUSE_LEFT) {
        if (w->flags & DM_WIDGET_PRESSED) {
            w->flags &= ~DM_WIDGET_PRESSED;
            if (dm_rect_contains(w->abs_bounds, e->mouse.x, e->mouse.y)) {
                if (w->on_click) w->on_click(w, w->userdata);
            }
            return true;
        }
    }
    return false;
}

static const DmWidgetVT button_vt = {
    .type_name = "button",
    .draw      = button_draw,
    .event     = button_event,
};

DmWidget *dm_button_create(const char *id, const char *text) {
    DmWidget *w = dm_widget_create(&button_vt, id);
    DmButtonData *d = (DmButtonData *)calloc(1, sizeof(DmButtonData));
    snprintf(d->text, sizeof(d->text), "%s", text ? text : "");
    d->bg        = DM_TURQUOISE;
    d->fg        = DM_BLACK;
    d->bg_hover  = (DmColor){0x33, 0xFF, 0xE0, 0xFF};
    d->bg_active = (DmColor){0x00, 0xC4, 0xA8, 0xFF};
    d->radius    = 6;
    w->data      = d;
    w->bounds.h  = 36;
    w->flags    |= DM_WIDGET_FOCUSABLE;
    return w;
}

void dm_button_set_text(DmWidget *w, const char *text) {
    DmButtonData *d = (DmButtonData *)w->data;
    snprintf(d->text, sizeof(d->text), "%s", text ? text : "");
}

void dm_button_set_colors(DmWidget *w, DmColor bg, DmColor fg) {
    DmButtonData *d = (DmButtonData *)w->data;
    d->bg = bg;
    d->fg = fg;
}

/* ── Slider ────────────────────────────────────────────────────────── */

static void slider_draw(DmWidget *w, DmFramebuffer *fb, const DmTheme *theme) {
    DmSliderData *d = (DmSliderData *)w->data;
    DmRect r = w->abs_bounds;

    int track_h = 4;
    int track_y = r.y + r.h / 2 - track_h / 2;
    dm_fb_fill_rounded_rect(fb, (DmRect){r.x, track_y, r.w, track_h}, 2, d->track_color);

    /* Filled portion */
    float norm = (d->value - d->min_val) / (d->max_val - d->min_val);
    int fill_w = (int)(norm * r.w);
    dm_fb_fill_rounded_rect(fb, (DmRect){r.x, track_y, fill_w, track_h}, 2, theme->accent);

    /* Knob */
    int knob_x = r.x + fill_w;
    int knob_r = 8;
    DmColor knob_c = d->knob_color;
    if (w->flags & DM_WIDGET_PRESSED) knob_c = theme->active;
    else if (w->flags & DM_WIDGET_HOVERED) knob_c = theme->accent;
    dm_fb_fill_circle(fb, knob_x, r.y + r.h / 2, knob_r, knob_c);
}

static bool slider_event(DmWidget *w, DmEvent *e) {
    DmSliderData *d = (DmSliderData *)w->data;

    if (e->type == DM_EVENT_MOUSE_DOWN && e->mouse.button == DM_MOUSE_LEFT) {
        d->dragging = true;
        w->flags |= DM_WIDGET_PRESSED;
    }
    if (e->type == DM_EVENT_MOUSE_UP) {
        d->dragging = false;
        w->flags &= ~DM_WIDGET_PRESSED;
    }
    if ((e->type == DM_EVENT_MOUSE_MOVE || e->type == DM_EVENT_MOUSE_DOWN) && d->dragging) {
        float norm = (float)(e->mouse.x - w->abs_bounds.x) / (float)w->abs_bounds.w;
        if (norm < 0.0f) norm = 0.0f;
        if (norm > 1.0f) norm = 1.0f;
        d->value = d->min_val + norm * (d->max_val - d->min_val);
        if (w->on_change) w->on_change(w, w->userdata);
        return true;
    }
    return false;
}

static const DmWidgetVT slider_vt = {
    .type_name = "slider",
    .draw      = slider_draw,
    .event     = slider_event,
};

DmWidget *dm_slider_create(const char *id, float min_val, float max_val, float value) {
    DmWidget *w = dm_widget_create(&slider_vt, id);
    DmSliderData *d = (DmSliderData *)calloc(1, sizeof(DmSliderData));
    d->min_val     = min_val;
    d->max_val     = max_val;
    d->value       = value;
    d->track_color = DM_MID_GRAY;
    d->knob_color  = DM_WHITE;
    d->dragging    = false;
    w->data        = d;
    w->bounds.h    = 24;
    w->flags      |= DM_WIDGET_FOCUSABLE;
    return w;
}

float dm_slider_get_value(DmWidget *w)  { return ((DmSliderData *)w->data)->value; }
void dm_slider_set_value(DmWidget *w, float v) { ((DmSliderData *)w->data)->value = v; }

/* ── Toggle ────────────────────────────────────────────────────────── */

static void toggle_draw(DmWidget *w, DmFramebuffer *fb, const DmTheme *theme) {
    DmToggleData *d = (DmToggleData *)w->data;
    DmRect r = w->abs_bounds;

    int track_w = 40, track_h = 20;
    int tx = r.x, ty = r.y + (r.h - track_h) / 2;
    DmColor bg = d->value ? d->on_color : d->off_color;
    dm_fb_fill_rounded_rect(fb, (DmRect){tx, ty, track_w, track_h}, track_h / 2, bg);

    /* Knob */
    int knob_r = track_h / 2 - 2;
    int knob_x = d->value ? tx + track_w - knob_r - 3 : tx + knob_r + 3;
    int knob_y = ty + track_h / 2;
    dm_fb_fill_circle(fb, knob_x, knob_y, knob_r, DM_WHITE);
}

static bool toggle_event(DmWidget *w, DmEvent *e) {
    if (e->type == DM_EVENT_MOUSE_DOWN && e->mouse.button == DM_MOUSE_LEFT) {
        DmToggleData *d = (DmToggleData *)w->data;
        d->value = !d->value;
        if (w->on_change) w->on_change(w, w->userdata);
        return true;
    }
    return false;
}

static const DmWidgetVT toggle_vt = {
    .type_name = "toggle",
    .draw      = toggle_draw,
    .event     = toggle_event,
};

DmWidget *dm_toggle_create(const char *id, bool initial) {
    DmWidget *w = dm_widget_create(&toggle_vt, id);
    DmToggleData *d = (DmToggleData *)calloc(1, sizeof(DmToggleData));
    d->value     = initial;
    d->on_color  = DM_TURQUOISE;
    d->off_color = DM_MID_GRAY;
    w->data      = d;
    w->bounds.h  = 24;
    w->flags    |= DM_WIDGET_FOCUSABLE;
    return w;
}

bool dm_toggle_get_value(DmWidget *w)      { return ((DmToggleData *)w->data)->value; }
void dm_toggle_set_value(DmWidget *w, bool v) { ((DmToggleData *)w->data)->value = v; }

/* ── TextInput ─────────────────────────────────────────────────────── */

static void text_input_draw(DmWidget *w, DmFramebuffer *fb, const DmTheme *theme) {
    DmTextInputData *d = (DmTextInputData *)w->data;
    DmRect r = w->abs_bounds;

    /* Background */
    DmColor bg = d->bg_color;
    if (w->flags & DM_WIDGET_FOCUSED) {
        dm_fb_fill_rounded_rect(fb, r, 4, bg);
        dm_fb_stroke_rounded_rect(fb, r, 4, theme->accent, 1);
    } else {
        dm_fb_fill_rounded_rect(fb, r, 4, bg);
        dm_fb_stroke_rounded_rect(fb, r, 4, theme->border, 1);
    }

    /* Text or placeholder */
    int tx = r.x + 6;
    int ty = r.y + (r.h - dm_font_text_height(theme->font)) / 2;
    if (d->text[0] == '\0' && d->placeholder[0] != '\0') {
        dm_fb_draw_text(fb, theme->font, tx, ty, d->placeholder, d->placeholder_color);
    } else {
        dm_fb_draw_text(fb, theme->font, tx, ty, d->text, d->text_color);
    }

    /* Cursor — pixel position of the UTF-8 byte-prefix before it (glyphs can be
       8 or 16 px wide, so byte-index * glyph_w would drift on non-ASCII text) */
    if (w->flags & DM_WIDGET_FOCUSED) {
        int cursor_x = tx + dm_font_text_width_n(theme->font, d->text, d->cursor);
        dm_fb_vline(fb, cursor_x, ty, ty + theme->font->glyph_h, d->cursor_color);
    }
}

/* Step a byte index to the previous/next UTF-8 sequence boundary. */
static int utf8_prev_boundary(const char *s, int i) {
    if (i > 0) i--;
    while (i > 0 && ((unsigned char)s[i] & 0xC0) == 0x80) i--;
    return i;
}
static int utf8_next_boundary(const char *s, int i, int len) {
    if (i < len) i++;
    while (i < len && ((unsigned char)s[i] & 0xC0) == 0x80) i++;
    return i;
}

static bool text_input_event(DmWidget *w, DmEvent *e) {
    DmTextInputData *d = (DmTextInputData *)w->data;

    if (e->type == DM_EVENT_MOUSE_DOWN) {
        w->flags |= DM_WIDGET_FOCUSED;
        return true;
    }
    if (!(w->flags & DM_WIDGET_FOCUSED)) return false;

    if (e->type == DM_EVENT_TEXT_INPUT) {
        int len = (int)strlen(d->text);
        int input_len = (int)strlen(e->text.text);
        if (len + input_len < d->max_len) {
            /* Insert at cursor */
            memmove(d->text + d->cursor + input_len,
                    d->text + d->cursor,
                    len - d->cursor + 1);
            memcpy(d->text + d->cursor, e->text.text, input_len);
            d->cursor += input_len;
            if (w->on_change) w->on_change(w, w->userdata);
        }
        return true;
    }

    if (e->type == DM_EVENT_KEY_DOWN) {
        int len = (int)strlen(d->text);
        if (e->key.keycode == 8) { /* backspace: remove the whole UTF-8 sequence */
            if (d->cursor > 0) {
                int prev = utf8_prev_boundary(d->text, d->cursor);
                memmove(d->text + prev,
                        d->text + d->cursor,
                        len - d->cursor + 1);
                d->cursor = prev;
                if (w->on_change) w->on_change(w, w->userdata);
            }
            return true;
        }
        if (e->key.keycode == 127) { /* delete: remove the whole UTF-8 sequence */
            if (d->cursor < len) {
                int next = utf8_next_boundary(d->text, d->cursor, len);
                memmove(d->text + d->cursor,
                        d->text + next,
                        len - next + 1);
                if (w->on_change) w->on_change(w, w->userdata);
            }
            return true;
        }
        if (e->key.keycode == 1073741904) { /* left arrow (SDL) */
            d->cursor = utf8_prev_boundary(d->text, d->cursor);
            return true;
        }
        if (e->key.keycode == 1073741903) { /* right arrow */
            d->cursor = utf8_next_boundary(d->text, d->cursor, len);
            return true;
        }
    }
    return false;
}

static const DmWidgetVT text_input_vt = {
    .type_name = "text_input",
    .draw      = text_input_draw,
    .event     = text_input_event,
};

DmWidget *dm_text_input_create(const char *id, const char *placeholder) {
    DmWidget *w = dm_widget_create(&text_input_vt, id);
    DmTextInputData *d = (DmTextInputData *)calloc(1, sizeof(DmTextInputData));
    d->text[0]  = '\0';
    d->cursor   = 0;
    d->max_len  = 511;
    d->text_color       = DM_WHITE;
    d->bg_color         = (DmColor){0x12, 0x12, 0x20, 0xFF};
    d->cursor_color     = DM_TURQUOISE;
    d->placeholder_color= (DmColor){0x66, 0x66, 0x77, 0xFF};
    if (placeholder) snprintf(d->placeholder, sizeof(d->placeholder), "%s", placeholder);
    w->data     = d;
    w->bounds.h = 32;
    w->flags   |= DM_WIDGET_FOCUSABLE;
    return w;
}

const char *dm_text_input_get_text(DmWidget *w) { return ((DmTextInputData *)w->data)->text; }
void dm_text_input_set_text(DmWidget *w, const char *t) {
    DmTextInputData *d = (DmTextInputData *)w->data;
    snprintf(d->text, sizeof(d->text), "%s", t ? t : "");
    d->cursor = (int)strlen(d->text);
}

/* ── ProgressBar ───────────────────────────────────────────────────── */

static void progress_draw(DmWidget *w, DmFramebuffer *fb, const DmTheme *theme) {
    DmProgressData *d = (DmProgressData *)w->data;
    DmRect r = w->abs_bounds;

    dm_fb_fill_rounded_rect(fb, r, 3, d->track_color);
    int fill_w = (int)(d->value * r.w);
    if (fill_w > 0)
        dm_fb_fill_rounded_rect(fb, (DmRect){r.x, r.y, fill_w, r.h}, 3, d->fill_color);
}

static const DmWidgetVT progress_vt = {
    .type_name = "progress",
    .draw      = progress_draw,
};

DmWidget *dm_progress_create(const char *id, float value) {
    DmWidget *w = dm_widget_create(&progress_vt, id);
    DmProgressData *d = (DmProgressData *)calloc(1, sizeof(DmProgressData));
    d->value       = value;
    d->fill_color  = DM_TURQUOISE;
    d->track_color = DM_MID_GRAY;
    w->data        = d;
    w->bounds.h    = 12;
    return w;
}

void dm_progress_set_value(DmWidget *w, float v) {
    DmProgressData *d = (DmProgressData *)w->data;
    d->value = v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v);
}
