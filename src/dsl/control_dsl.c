// SPDX-License-Identifier: MPL-2.0
#include "demod/dsl.h"
#include "demod/framebuffer.h"
#include "demod/font.h"
#include <stdlib.h>
#include <string.h>

#define MAX_ITEMS 64
#define CARD_W 220
#define CARD_H 64

typedef struct DmControlData {
    DmVizItem items[MAX_ITEMS];
    int item_count;
    char focused[32];
    int w, h;
} DmControlData;

static DmControlData *get_data(DmWidget *w) {
    return (DmControlData *)w->data;
}

static void control_draw(DmWidget *w, DmFramebuffer *fb, const DmTheme *theme) {
    DmControlData *d = get_data(w);
    if (!d || d->item_count == 0 || !w->abs_bounds.w) return;

    int W = w->abs_bounds.w;
    int H = w->abs_bounds.h;
    d->w = W; d->h = H;

    int x = 20, y = 20;
    for (int i = 0; i < d->item_count; i++) {
        DmVizItem *it = &d->items[i];
        DmColor border = strcmp(d->focused, it->id) == 0 ? (DmColor){0x00,0xF5,0xD4,255} : (DmColor){0x2A,0x2A,0x3E,200};

        dm_fb_fill_rect(fb, (DmRect){x, y, CARD_W, CARD_H}, (DmColor){0x12,0x12,0x1E,240});
        dm_fb_fill_rect(fb, (DmRect){x, y, CARD_W, 3}, border);

        dm_fb_draw_text(fb, dm_font_default(), x + 12, y + 10, it->label, (DmColor){0xE8,0xE8,0xF0,255});
        if (it->subtitle[0])
            dm_fb_draw_text(fb, dm_font_default(), x + 12, y + 28, it->subtitle, (DmColor){0x88,0x88,0x99,200});

        /* status dot */
        DmColor dot = strcmp(it->status,"active")==0 ? (DmColor){76,255,130,255} : (DmColor){255,217,76,255};
        dm_fb_fill_circle(fb, x + CARD_W - 16, y + 16, 4, dot);

        x += CARD_W + 12;
        if (x + CARD_W > W) { x = 20; y += CARD_H + 12; }
    }
}

static bool control_event(DmWidget *w, DmEvent *e) {
    DmControlData *d = get_data(w);
    if (!d) return false;
    if (e->type == DM_EVENT_MOUSE_DOWN) {
        int mx = e->mouse.x, my = e->mouse.y;
        for (int i=0; i<d->item_count; i++) {
            /* simple hit test on card grid */
            int cx = 20 + (i % 5) * (CARD_W + 12);
            int cy = 20 + (i / 5) * (CARD_H + 12);
            if (mx >= cx && mx < cx+CARD_W && my >= cy && my < cy+CARD_H) {
                strcpy(d->focused, d->items[i].id);
                return true;
            }
        }
    }
    return false;
}

static void control_layout(DmWidget *w) { (void)w; }
static void control_destroy(DmWidget *w) { free(w->data); }

static const DmWidgetVT control_vt = {
    .type_name = "control",
    .draw = control_draw,
    .event = control_event,
    .layout = control_layout,
    .destroy = control_destroy,
};

DmWidget *dm_control_create(const char *id) {
    DmWidget *w = dm_widget_create(&control_vt, id);
    w->data = calloc(1, sizeof(DmControlData));
    w->bounds.w = 1280;
    w->bounds.h = 200;
    return w;
}

void dm_control_add_item(DmWidget *w, const DmVizItem *item) {
    DmControlData *d = get_data(w);
    if (d && d->item_count < MAX_ITEMS) {
        d->items[d->item_count++] = *item;
    }
}

void dm_control_focus_next(DmWidget *w) {
    DmControlData *d = get_data(w);
    if (d->item_count == 0) return;
    int idx = 0;
    for (int i=0;i<d->item_count;i++) if (strcmp(d->items[i].id,d->focused)==0){idx=i;break;}
    idx = (idx+1)%d->item_count;
    strcpy(d->focused, d->items[idx].id);
}

void dm_control_focus_prev(DmWidget *w) {
    DmControlData *d = get_data(w);
    if (d->item_count == 0) return;
    int idx = 0;
    for (int i=0;i<d->item_count;i++) if (strcmp(d->items[i].id,d->focused)==0){idx=i;break;}
    idx = (idx-1+d->item_count)%d->item_count;
    strcpy(d->focused, d->items[idx].id);
}

void dm_control_focus_activate(DmWidget *w) { (void)w; }

const char *dm_control_get_focused(DmWidget *w) {
    return get_data(w)->focused;
}

void dm_control_set_focused(DmWidget *w, const char *id) {
    DmControlData *d = get_data(w);
    strncpy(d->focused, id?id:"",sizeof(d->focused)-1);
}
