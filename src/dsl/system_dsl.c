// SPDX-License-Identifier: MPL-2.0
#include "demod/dsl.h"
#include "demod/framebuffer.h"
#include "demod/font.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>

#define MAX_NODES 64
#define MAX_CONNS 128
#define MAX_LAYERS 8
#define MAX_STORY 8
#define NODE_SIZE 60

typedef struct DmVizStory {
    char title[64];
    char *body[32];
    int nlines;
} DmVizStory;

typedef struct DmVizData {
    DmVizItem items[MAX_NODES];
    int item_count;
    DmVizConn conns[MAX_CONNS];
    int conn_count;
    int focus_layer;
    char focused[32];
    float camera_x, camera_y, camera_zoom;
    float anim_phase;
    int pulse_off[MAX_CONNS];
    int w, h;
} DmVizData;

static DmVizData *get_data(DmWidget *w) {
    return (DmVizData *)w->data;
}

static void viz_draw(DmWidget *w, DmFramebuffer *fb, const DmTheme *theme) {
    DmVizData *d = get_data(w);
    if (!d) return;

    int W = w->abs_bounds.w;
    int H = w->abs_bounds.h;
    if (W <= 0 || H <= 0) return;

    d->w = W; d->h = H;

    /* subtle grid */
    int spacing = (int)(100 * d->camera_zoom);
    if (spacing < 8) spacing = 8;
    DmColor gc = {0x14,0x14,0x20,40};
    for (int x = (int)((W/2 - d->camera_x * d->camera_zoom) + spacing) % spacing; x < W; x += spacing)
        dm_fb_line(fb, x, 0, x, H, gc);
    for (int y = (int)((H/2 - d->camera_y * d->camera_zoom) + spacing) % spacing; y < H; y += spacing)
        dm_fb_line(fb, 0, y, W, y, gc);

    /* layer bands */
    struct {int y_top,y_bot,layer;} bands[5] = {
        {180,380,1},{20,180,2},{-130,20,3},{-440,-130,4},{-620,-440,5}
    };
    for (int b=0; b<5; b++) {
        float sy0 = H/2 + (bands[b].y_top - d->camera_y) * d->camera_zoom;
        float sy1 = H/2 + (bands[b].y_bot  - d->camera_y) * d->camera_zoom;
        if (sy1 < 0 || sy0 > H) continue;
        DmColor lc = (DmColor){0x00,0xF5,0xD4,6};
        if (bands[b].layer==2) lc=(DmColor){0x4C,0xD4,0xFF,6};
        if (bands[b].layer==3) lc=(DmColor){0x8B,0x5C,0xF6,6};
        if (bands[b].layer==4) lc=(DmColor){0xFF,0xD9,0x4C,6};
        if (bands[b].layer==5) lc=(DmColor){0xFF,0x6B,0x8A,6};
        dm_fb_fill_rect(fb, (DmRect){0,(int)sy0,W,(int)(sy1-sy0)}, lc);
    }

    /* connections */
    DmColor style_col[5] = {{0,245,212,70},{139,92,246,70},{0x33,0x33,0x44,70},{76,255,130,70},{255,217,76,70}};
    for (int i=0; i<d->conn_count; i++) {
        DmVizConn *c = &d->conns[i];
        DmVizItem *n1=NULL,*n2=NULL;
        for (int j=0;j<d->item_count;j++) {
            if (strcmp(d->items[j].id,c->from)==0) n1=&d->items[j];
            if (strcmp(d->items[j].id,c->to)==0) n2=&d->items[j];
        }
        if (!n1||!n2) continue;
        if (d->focus_layer>0 && n1->layer!=d->focus_layer && n2->layer!=d->focus_layer) continue;

        float sx0 = W/2 + (n1->x - d->camera_x)*d->camera_zoom;
        float sy0 = H/2 + (n1->y - d->camera_y)*d->camera_zoom;
        float sx1 = W/2 + (n2->x - d->camera_x)*d->camera_zoom;
        float sy1 = H/2 + (n2->y - d->camera_y)*d->camera_zoom;

        int style_idx = 2;
        if (strcmp(c->style,"data")==0) style_idx=0;
        if (strcmp(c->style,"control")==0) style_idx=1;
        if (strcmp(c->style,"audio")==0) style_idx=3;
        if (strcmp(c->style,"bidi")==0) style_idx=4;

        DmColor col = style_col[style_idx];
        int thick = 1;
        if (d->focused[0] && (strcmp(c->from,d->focused)==0 || strcmp(c->to,d->focused)==0)) {
            col.a = 220; thick=2;
        }
        dm_fb_arrow_bezier(fb, (int)sx0,(int)sy0, (int)(sx0+(sx1-sx0)*0.3),(int)(sy0+(sy1-sy0)*0.3),
                           (int)(sx0+(sx1-sx0)*0.7),(int)(sy0+(sy1-sy0)*0.7),
                           (int)sx1,(int)sy1, 24, 6, thick, col);

        if (c->label[0] && (d->focused[0] || d->camera_zoom>0.7)) {
            int mx = (int)((sx0+sx1)/2);
            int my = (int)((sy0+sy1)/2 - 8);
            dm_fb_draw_text(fb, dm_font_default(),
                            mx - dm_font_text_width(dm_font_default(), c->label) / 2,
                            my, c->label, col);
        }
    }

    /* nodes */
    for (int i=0; i<d->item_count; i++) {
        DmVizItem *n = &d->items[i];
        float sx = W/2 + (n->x - d->camera_x)*d->camera_zoom;
        float sy = H/2 + (n->y - d->camera_y)*d->camera_zoom;
        float size = NODE_SIZE * d->camera_zoom;
        if (sx < -size*2 || sx>W+size*2 || sy<-size*2 || sy>H+size*2) continue;

        float x0=sx, y0=sy-size*0.8, x1=sx-size*0.7, y1=sy+size*0.46, x2=sx+size*0.7, y2=sy+size*0.46;

        DmColor lc = {0x00,0xF5,0xD4,180};
        if (n->layer==2) lc=(DmColor){0x4C,0xD4,0xFF,180};
        if (n->layer==3) lc=(DmColor){0x8B,0x5C,0xF6,180};
        if (n->layer==4) lc=(DmColor){0xFF,0xD9,0x4C,180};
        if (n->layer==5) lc=(DmColor){0xFF,0x6B,0x8A,180};

        int vis_depth = (n->type == DM_VIZ_NODE) ? n->depth : 3;
        if (d->camera_zoom<0.4) vis_depth=1; else if (d->camera_zoom<0.6) vis_depth=2; else if (d->camera_zoom<0.9) vis_depth=n->depth-1;
        if (vis_depth<1) vis_depth=1;

        DmColor fill = {lc.r,lc.g,lc.b, (unsigned char)(strcmp(d->focused,n->id)==0 ? 240 : 180)};
        DmColor stroke = lc;
        dm_fb_sierpinski(fb, (int)x0,(int)y0,(int)x1,(int)y1,(int)x2,(int)y2, vis_depth, fill, stroke);

        /* status dot */
        DmColor dc = strcmp(n->status,"active")==0 ? (DmColor){76,255,130,255} : (DmColor){255,217,76,255};
        dm_fb_fill_circle(fb, (int)x0, (int)y0-4, 3, dc);

        /* label */
        if (d->camera_zoom > 0.35) {
            int lx = (int)(sx - strlen(n->label)*4);
            dm_fb_draw_text(fb, dm_font_default(), lx, (int)(y2+8), n->label, lc);
        }
    }

    /* detail panel */
    if (d->focused[0]) {
        DmVizItem *n = NULL;
        for (int i=0;i<d->item_count;i++) if (strcmp(d->items[i].id,d->focused)==0) {n=&d->items[i];break;}
        if (n) {
            int px=14, py=H-240, pw=380;
            DmColor lc = {0x00,0xF5,0xD4,220};
            if (n->layer==2) lc=(DmColor){0x4C,0xD4,0xFF,220};
            dm_fb_fill_rect(fb, (DmRect){px,py,pw,220}, (DmColor){0x12,0x12,0x1E,240});
            dm_fb_fill_rect(fb, (DmRect){px,py,pw,3}, lc);
            dm_fb_draw_text(fb, dm_font_default(), px+16, py+14, n->label, lc);
            if (n->type == DM_VIZ_NODE)
                dm_fb_draw_text(fb, dm_font_default(), px+16, py+34, n->headline, (DmColor){0xE8,0xE8,0xF0,200});
        }
    }
}

static bool viz_event(DmWidget *w, DmEvent *e) {
    DmVizData *d = get_data(w);
    if (!d) return false;
    if (e->type == DM_EVENT_MOUSE_DOWN) {
        float mx = e->mouse.x, my = e->mouse.y;
        for (int i=0;i<d->item_count;i++) {
            DmVizItem *n=&d->items[i];
            float sx = d->w/2 + (n->x-d->camera_x)*d->camera_zoom;
            float sy = d->h/2 + (n->y-d->camera_y)*d->camera_zoom;
            float dx=mx-sx, dy=my-sy;
            if (dx*dx+dy*dy < (NODE_SIZE*d->camera_zoom)*(NODE_SIZE*d->camera_zoom)*0.6f) {
                strcpy(d->focused, n->id);
                return true;
            }
        }
    }
    return false;
}

static void viz_layout(DmWidget *w) { (void)w; }
static void viz_destroy(DmWidget *w) { free(w->data); }

static const DmWidgetVT viz_vt = {
    .type_name = "viz",
    .draw = viz_draw,
    .event = viz_event,
    .layout = viz_layout,
    .destroy = viz_destroy,
};

DmWidget *dm_viz_create(const char *id) {
    DmWidget *w = dm_widget_create(&viz_vt, id);
    w->data = calloc(1, sizeof(DmVizData));
    DmVizData *d = get_data(w);
    d->camera_zoom = 0.78f;
    for (int i=0;i<MAX_CONNS;i++) d->pulse_off[i] = rand() % 628;
    w->bounds.w = 1280;
    w->bounds.h = 720;
    return w;
}

void dm_viz_add_item(DmWidget *w, const DmVizItem *item) {
    DmVizData *d = get_data(w);
    if (d->item_count >= MAX_NODES) return;
    d->items[d->item_count++] = *item;
}

void dm_viz_add_connection(DmWidget *w, const DmVizConn *c) {
    DmVizData *d = get_data(w);
    if (d->conn_count >= MAX_CONNS) return;
    d->conns[d->conn_count++] = *c;
}

void dm_viz_focus_next(DmWidget *w) {
    DmVizData *d = get_data(w);
    if (d->item_count == 0) return;
    int idx = 0;
    for (int i=0; i<d->item_count; i++) if (strcmp(d->items[i].id, d->focused)==0) { idx=i; break; }
    idx = (idx + 1) % d->item_count;
    strcpy(d->focused, d->items[idx].id);
}

void dm_viz_focus_prev(DmWidget *w) {
    DmVizData *d = get_data(w);
    if (d->item_count == 0) return;
    int idx = 0;
    for (int i=0; i<d->item_count; i++) if (strcmp(d->items[i].id, d->focused)==0) { idx=i; break; }
    idx = (idx - 1 + d->item_count) % d->item_count;
    strcpy(d->focused, d->items[idx].id);
}

void dm_viz_focus_activate(DmWidget *w) {
    /* placeholder – real implementation will trigger on_activate callback */
}

const char *dm_viz_get_focused(DmWidget *w) {
    return get_data(w)->focused;
}

void dm_viz_set_focused(DmWidget *w, const char *id) {
    DmVizData *d = get_data(w);
    strncpy(d->focused, id ? id : "", sizeof(d->focused)-1);
}
