// SPDX-License-Identifier: MPL-2.0
/*
 * DeMoD UI Framework — Widget System
 * Retained-mode widget tree with event dispatch and layout.
 * Copyright (c) 2026 DeMoD LLC.
 * Licensed under the Mozilla Public License, v. 2.0; see LICENSE.
 */
#ifndef DEMOD_WIDGET_H
#define DEMOD_WIDGET_H

#include "demod/framebuffer.h"
#include "demod/font.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ── Forward Declarations ──────────────────────────────────────────── */

typedef struct DmWidget     DmWidget;
typedef struct DmWidgetVT   DmWidgetVT;
typedef struct DmEvent      DmEvent;
typedef struct DmTheme      DmTheme;

/* ── Events ────────────────────────────────────────────────────────── */

typedef enum {
    DM_EVENT_NONE = 0,
    DM_EVENT_MOUSE_MOVE,
    DM_EVENT_MOUSE_DOWN,
    DM_EVENT_MOUSE_UP,
    DM_EVENT_MOUSE_SCROLL,
    DM_EVENT_KEY_DOWN,
    DM_EVENT_KEY_UP,
    DM_EVENT_TEXT_INPUT,
    DM_EVENT_FOCUS_IN,
    DM_EVENT_FOCUS_OUT,
    DM_EVENT_RESIZE,
} DmEventType;

typedef enum {
    DM_MOUSE_LEFT   = 1,
    DM_MOUSE_MIDDLE = 2,
    DM_MOUSE_RIGHT  = 3,
} DmMouseButton;

struct DmEvent {
    DmEventType type;
    union {
        struct { int x, y; int button; }        mouse;
        struct { int x, y; float dx, dy; }      scroll;
        struct { int scancode; int keycode;
                 int mod; bool repeat; }         key;
        struct { char text[32]; }                text;
        struct { int w, h; }                     resize;
    };
    bool consumed;
};

/* ── Theme ─────────────────────────────────────────────────────────── */

struct DmTheme {
    DmColor bg;
    DmColor bg_secondary;
    DmColor fg;
    DmColor fg_secondary;
    DmColor accent;
    DmColor accent_secondary;
    DmColor border;
    DmColor hover;
    DmColor active;
    DmColor disabled;
    DmColor error;
    DmColor success;

    int     corner_radius;
    int     border_width;
    int     padding;
    int     spacing;

    const DmFont *font;
    const DmFont *font_small;
};

/* Default DeMoD theme (turquoise/violet on black) */
const DmTheme *dm_theme_default(void);

/* ── Widget Flags ──────────────────────────────────────────────────── */

typedef enum {
    DM_WIDGET_VISIBLE     = (1 << 0),
    DM_WIDGET_ENABLED     = (1 << 1),
    DM_WIDGET_FOCUSABLE   = (1 << 2),
    DM_WIDGET_HOVERED     = (1 << 3),
    DM_WIDGET_PRESSED     = (1 << 4),
    DM_WIDGET_FOCUSED     = (1 << 5),
    DM_WIDGET_DIRTY       = (1 << 6),
    DM_WIDGET_CLIP_CHILDREN = (1 << 7),
} DmWidgetFlags;

/* ── Layout ────────────────────────────────────────────────────────── */

typedef enum {
    DM_LAYOUT_NONE = 0,     /* manual positioning */
    DM_LAYOUT_VBOX,         /* vertical stack */
    DM_LAYOUT_HBOX,         /* horizontal stack */
    DM_LAYOUT_GRID,         /* grid layout */
} DmLayoutType;

typedef struct {
    DmLayoutType type;
    int          spacing;
    int          padding;
    int          columns;   /* for grid layout */
} DmLayout;

/* ── Widget VTable ─────────────────────────────────────────────────── */

struct DmWidgetVT {
    const char *type_name;
    void (*draw)(DmWidget *w, DmFramebuffer *fb, const DmTheme *theme);
    bool (*event)(DmWidget *w, DmEvent *e);
    void (*layout)(DmWidget *w);
    void (*destroy)(DmWidget *w);
};

/* ── Widget Base ───────────────────────────────────────────────────── */

#define DM_MAX_CHILDREN 64
#define DM_MAX_ID_LEN   64

typedef void (*DmWidgetCallback)(DmWidget *widget, void *userdata);

struct DmWidget {
    const DmWidgetVT *vt;
    char              id[DM_MAX_ID_LEN];
    uint32_t          flags;
    DmRect            bounds;       /* position relative to parent */
    DmRect            abs_bounds;   /* computed absolute position */
    DmLayout          layout;

    DmWidget         *parent;
    DmWidget         *children[DM_MAX_CHILDREN];
    int               child_count;

    /* Callbacks */
    DmWidgetCallback  on_click;
    DmWidgetCallback  on_change;
    void             *userdata;

    /* Lua reference (if created from Lua) */
    int               lua_ref;

    /* Per-type data (allocated by derived types) */
    void             *data;
};

/* ── Widget API ────────────────────────────────────────────────────── */

/* Lifecycle */
DmWidget *dm_widget_create(const DmWidgetVT *vt, const char *id);
void      dm_widget_destroy(DmWidget *w);

/* Tree */
void      dm_widget_add_child(DmWidget *parent, DmWidget *child);
void      dm_widget_remove_child(DmWidget *parent, DmWidget *child);
DmWidget *dm_widget_find(DmWidget *root, const char *id);

/* Drawing */
void dm_widget_draw(DmWidget *w, DmFramebuffer *fb, const DmTheme *theme);

/* Events */
bool dm_widget_dispatch(DmWidget *w, DmEvent *e);

/* Layout */
void dm_widget_layout(DmWidget *w);
void dm_widget_compute_abs_bounds(DmWidget *w, int parent_x, int parent_y);

/* Flags */
static inline void dm_widget_show(DmWidget *w)    { w->flags |= DM_WIDGET_VISIBLE; }
static inline void dm_widget_hide(DmWidget *w)    { w->flags &= ~DM_WIDGET_VISIBLE; }
static inline void dm_widget_enable(DmWidget *w)  { w->flags |= DM_WIDGET_ENABLED; }
static inline void dm_widget_disable(DmWidget *w) { w->flags &= ~DM_WIDGET_ENABLED; }
static inline bool dm_widget_is_visible(DmWidget *w) { return w->flags & DM_WIDGET_VISIBLE; }
static inline bool dm_widget_is_enabled(DmWidget *w) { return w->flags & DM_WIDGET_ENABLED; }

/* ── Built-in Widgets ──────────────────────────────────────────────── */

/* Panel — container with optional background/border */
typedef struct {
    DmColor bg;
    DmColor border;
    int     radius;
    bool    draw_bg;
    bool    draw_border;
} DmPanelData;

DmWidget *dm_panel_create(const char *id);
void      dm_panel_set_bg(DmWidget *w, DmColor bg);
void      dm_panel_set_border(DmWidget *w, DmColor border);

/* Label — text display */
typedef struct {
    char    text[256];
    DmColor color;
    int     align; /* 0=left, 1=center, 2=right */
} DmLabelData;

DmWidget *dm_label_create(const char *id, const char *text);
void      dm_label_set_text(DmWidget *w, const char *text);
void      dm_label_set_color(DmWidget *w, DmColor c);

/* Button — clickable with text */
typedef struct {
    char    text[128];
    DmColor bg;
    DmColor fg;
    DmColor bg_hover;
    DmColor bg_active;
    int     radius;
} DmButtonData;

DmWidget *dm_button_create(const char *id, const char *text);
void      dm_button_set_text(DmWidget *w, const char *text);
void      dm_button_set_colors(DmWidget *w, DmColor bg, DmColor fg);

/* Slider — horizontal value slider */
typedef struct {
    float   value;      /* 0.0 .. 1.0 */
    float   min_val;
    float   max_val;
    DmColor track_color;
    DmColor knob_color;
    bool    dragging;
} DmSliderData;

DmWidget *dm_slider_create(const char *id, float min_val, float max_val, float value);
float     dm_slider_get_value(DmWidget *w);
void      dm_slider_set_value(DmWidget *w, float value);

/* Toggle — on/off switch */
typedef struct {
    bool    value;
    DmColor on_color;
    DmColor off_color;
} DmToggleData;

DmWidget *dm_toggle_create(const char *id, bool initial);
bool      dm_toggle_get_value(DmWidget *w);
void      dm_toggle_set_value(DmWidget *w, bool value);

/* TextInput — single-line text field */
typedef struct {
    char    text[512];
    int     cursor;
    int     max_len;
    char    placeholder[128];
    DmColor text_color;
    DmColor bg_color;
    DmColor cursor_color;
    DmColor placeholder_color;
} DmTextInputData;

DmWidget *dm_text_input_create(const char *id, const char *placeholder);
const char *dm_text_input_get_text(DmWidget *w);
void dm_text_input_set_text(DmWidget *w, const char *text);

/* ProgressBar */
typedef struct {
    float   value;   /* 0.0 .. 1.0 */
    DmColor fill_color;
    DmColor track_color;
} DmProgressData;

DmWidget *dm_progress_create(const char *id, float value);
void      dm_progress_set_value(DmWidget *w, float value);

/* Knob — rotary control (essential for DSP) */
typedef struct {
    float   value;          /* 0.0 .. 1.0 normalized */
    float   min_val;
    float   max_val;
    float   default_val;
    float   start_angle;    /* radians, default -2.35 (~225°) */
    float   end_angle;      /* radians, default  2.35 (~315°) */
    DmColor track_color;
    DmColor fill_color;
    DmColor knob_color;
    DmColor indicator_color;
    char    label[64];
    char    value_fmt[32];  /* printf format for value display */
    bool    dragging;
    int     drag_start_y;
    float   drag_start_val;
    bool    show_label;
    bool    show_value;
} DmKnobData;

DmWidget *dm_knob_create(const char *id, const char *label,
                         float min_val, float max_val, float value);
float     dm_knob_get_value(DmWidget *w);
void      dm_knob_set_value(DmWidget *w, float value);
void      dm_knob_set_format(DmWidget *w, const char *fmt);

/* VU Meter — level meter with peak hold */
#define DM_VU_MAX_CHANNELS 8

typedef struct {
    float   levels[DM_VU_MAX_CHANNELS];     /* current levels 0..1 */
    float   peaks[DM_VU_MAX_CHANNELS];      /* peak hold levels */
    float   peak_decay;                      /* decay rate per second */
    int     num_channels;
    int     num_segments;
    bool    horizontal;
    DmColor color_low;      /* green zone */
    DmColor color_mid;      /* yellow zone */
    DmColor color_high;     /* red zone */
    DmColor color_bg;
    DmColor color_peak;
    float   threshold_mid;  /* 0..1, default 0.6 */
    float   threshold_high; /* 0..1, default 0.85 */
} DmVuMeterData;

DmWidget *dm_vu_meter_create(const char *id, int channels);
void      dm_vu_meter_set_level(DmWidget *w, int channel, float level);
void      dm_vu_meter_set_levels(DmWidget *w, const float *levels, int count);
void      dm_vu_meter_update(DmWidget *w, float dt);

/* Waveform — oscilloscope / waveform display */
#define DM_WAVEFORM_MAX_SAMPLES 4096

typedef struct {
    float   samples[DM_WAVEFORM_MAX_SAMPLES];
    int     num_samples;
    int     write_pos;          /* ring buffer write position */
    bool    ring_buffer;        /* true = circular, false = static */
    float   zoom_x;             /* horizontal zoom, 1.0 = full */
    float   zoom_y;             /* vertical zoom / amplitude scale */
    float   offset_x;           /* horizontal scroll offset */
    DmColor wave_color;
    DmColor grid_color;
    DmColor zero_line_color;
    DmColor bg_color;
    bool    show_grid;
    bool    fill;               /* fill below waveform */
    DmColor fill_color;
    int     line_width;
} DmWaveformData;

DmWidget *dm_waveform_create(const char *id, int num_samples);
void      dm_waveform_set_samples(DmWidget *w, const float *samples, int count);
void      dm_waveform_push_sample(DmWidget *w, float sample);
void      dm_waveform_clear(DmWidget *w);

/* Dropdown — select from options list */
#define DM_DROPDOWN_MAX_ITEMS 32
#define DM_DROPDOWN_ITEM_LEN  64

typedef struct {
    char    items[DM_DROPDOWN_MAX_ITEMS][DM_DROPDOWN_ITEM_LEN];
    int     num_items;
    int     selected;           /* -1 = none */
    bool    open;
    DmColor bg_color;
    DmColor fg_color;
    DmColor hover_color;
    DmColor border_color;
    int     max_visible;        /* max items shown when open */
    int     scroll_offset;
    char    placeholder[64];
} DmDropdownData;

DmWidget *dm_dropdown_create(const char *id, const char *placeholder);
void      dm_dropdown_add_item(DmWidget *w, const char *item);
void      dm_dropdown_clear_items(DmWidget *w);
int       dm_dropdown_get_selected(DmWidget *w);
const char *dm_dropdown_get_selected_text(DmWidget *w);
void      dm_dropdown_set_selected(DmWidget *w, int index);

/* ScrollPanel — scrollable container */
typedef struct {
    int     scroll_x;
    int     scroll_y;
    int     content_w;
    int     content_h;
    bool    show_scrollbar_v;
    bool    show_scrollbar_h;
    DmColor scrollbar_color;
    DmColor scrollbar_bg;
    int     scrollbar_width;
    bool    dragging_scrollbar;
    int     drag_start;
    int     drag_start_scroll;
} DmScrollPanelData;

DmWidget *dm_scroll_panel_create(const char *id, int content_w, int content_h);
void      dm_scroll_panel_set_content_size(DmWidget *w, int cw, int ch);
void      dm_scroll_panel_scroll_to(DmWidget *w, int x, int y);

/* XY Pad — 2D control surface */
typedef struct {
    float   value_x;        /* 0.0 .. 1.0 */
    float   value_y;        /* 0.0 .. 1.0 */
    DmColor bg_color;
    DmColor grid_color;
    DmColor cursor_color;
    DmColor trail_color;
    bool    dragging;
    bool    show_grid;
    bool    show_crosshair;
    /* Trail history */
    float   trail_x[128];
    float   trail_y[128];
    int     trail_len;
    int     trail_pos;
    bool    show_trail;
} DmXYPadData;

DmWidget *dm_xy_pad_create(const char *id);
void      dm_xy_pad_get_value(DmWidget *w, float *x, float *y);
void      dm_xy_pad_set_value(DmWidget *w, float x, float y);

#ifdef __cplusplus
}
#endif
#endif /* DEMOD_WIDGET_H */
