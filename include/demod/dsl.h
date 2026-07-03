// SPDX-License-Identifier: MPL-2.0
/* DeMoD UI — Declarative Visualization & Control DSL
 * C-first data model for system diagrams (Sierpinski) and encoder-native control panels (rectangular cards).
 * Licensed under the Mozilla Public License, v. 2.0; see LICENSE.
 */
#ifndef DEMOD_DSL_H
#define DEMOD_DSL_H

#include "demod/widget.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    DM_VIZ_NODE = 0,
    DM_VIZ_CARD = 1
} DmVizItemType;

typedef struct DmVizItem {
    DmVizItemType type;
    char          id[32];
    char          label[64];
    int           layer;
    char          status[16];     /* active, dev, ... */
    /* Node-specific (Sierpinski) */
    int           x, y;
    int           depth;
    char          headline[128];
    char          desc[512];
    char          tech[64];
    char          loc[16];
    char          license[32];
    /* Card-specific (rectangular control) */
    char          subtitle[64];
    bool          desktop;        /* show small Sierpinski icon inside card */
} DmVizItem;

typedef struct DmVizConn {
    char from[32];
    char to[32];
    char label[32];
    char style[16]; /* data, control, depends, audio, bidi */
} DmVizConn;

/* Widget creation */
DmWidget *dm_viz_create(const char *id);      /* rich Sierpinski visualizer */
DmWidget *dm_control_create(const char *id);  /* compact rectangular control surface */

/* Population (C or Lua) */
void dm_viz_add_item(DmWidget *w, const DmVizItem *item);
void dm_viz_add_connection(DmWidget *w, const DmVizConn *c);
void dm_control_add_item(DmWidget *w, const DmVizItem *item);

/* Focus / Encoder API (self-contained) */
void dm_viz_focus_next(DmWidget *w);
void dm_viz_focus_prev(DmWidget *w);
void dm_viz_focus_activate(DmWidget *w);
const char *dm_viz_get_focused(DmWidget *w);
void dm_viz_set_focused(DmWidget *w, const char *id);

void dm_control_focus_next(DmWidget *w);
void dm_control_focus_prev(DmWidget *w);
void dm_control_focus_activate(DmWidget *w);
const char *dm_control_get_focused(DmWidget *w);
void dm_control_set_focused(DmWidget *w, const char *id);

#ifdef __cplusplus
}
#endif
#endif /* DEMOD_DSL_H */
