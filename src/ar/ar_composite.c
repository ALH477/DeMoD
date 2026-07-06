// SPDX-License-Identifier: MPL-2.0
/*
 * DeMoD UI Framework — AR passthrough compositor + dm.ar Lua bindings
 * Owns a DmArContext (frame source + composite config), paints the latest frame
 * as the framebuffer's base layer, and exposes the dm.ar.* Lua module. Compiled
 * only under -DDEMOD_AR (make ARHUD=1); registered like dm.dcf.
 *
 * Copyright (c) 2026 DeMoD LLC.
 * Licensed under the Mozilla Public License, v. 2.0; see LICENSE.
 */
#include "demod/ar.h"
#include "demod/app.h"

#include <lua.h>
#include <lauxlib.h>
#include <stdlib.h>
#include <string.h>

/* Same registry key lua_bindings.c stashes the DmApp* under. */
#define DM_LUA_APP_KEY "dm_app_ptr"

struct DmArContext {
    DmArSource    *src;
    DmArConfig     cfg;
    int            width, height;
    DmArPixFmt     format;
    char           uri[256];
    uint64_t       frames;
    DmFramebuffer *eye;   /* per-eye scratch for the lens-warp pass (lazy) */
};

/* ── Context ───────────────────────────────────────────────────────────── */

DmArContext *dm_ar_open(const char *uri, int w, int h, DmArPixFmt fmt, DmArConfig cfg) {
    if (!uri) return NULL;
    DmArSource *src = dm_ar_source_open(uri, w, h, fmt);
    if (!src) return NULL;
    DmArContext *c = (DmArContext *)calloc(1, sizeof(*c));
    if (!c) { dm_ar_source_close(src); return NULL; }
    c->src = src;
    c->cfg = cfg;
    c->width = w; c->height = h; c->format = fmt;
    snprintf(c->uri, sizeof(c->uri), "%s", uri);
    return c;
}

bool dm_ar_active(DmArContext *c) { return c && c->src; }

bool dm_ar_poll(DmArContext *c) {
    if (!c || !c->src) return false;
    if (dm_ar_source_poll(c->src)) { c->frames++; return true; }
    return false;
}

/* Paint one eye's viewport `dst` from the wrapped source frame. Flat (no lens
   coeffs) is a direct scale; otherwise scale into a per-eye scratch and warp. */
static void render_eye(DmArContext *c, DmFramebuffer *fb, DmFramebuffer *src, DmRect dst) {
    if (c->cfg.k1 == 0.0f && c->cfg.k2 == 0.0f) {
        dm_fb_blit_scaled(fb, src, dst, c->cfg.fit, c->cfg.alpha);
        return;
    }
    if (!c->eye || c->eye->width != dst.w || c->eye->height != dst.h) {
        if (c->eye) dm_fb_destroy(c->eye);
        c->eye = dm_fb_create(dst.w, dst.h);
        if (!c->eye) { dm_fb_blit_scaled(fb, src, dst, c->cfg.fit, c->cfg.alpha); return; }
    }
    dm_fb_blit_scaled(c->eye, src, (DmRect){0, 0, dst.w, dst.h}, c->cfg.fit, 255);
    dm_fb_fill_rect(fb, dst, dm_rgb(0, 0, 0));  /* vignette outside the warp */
    dm_fb_warp_barrel(fb, c->eye, dst, c->cfg.k1, c->cfg.k2, c->cfg.alpha);
}

void dm_ar_composite_background(DmArContext *c, DmFramebuffer *fb) {
    if (!c || !fb) return;
    int w = 0, h = 0;
    const uint32_t *px = c->src ? dm_ar_source_latest(c->src, &w, &h) : NULL;
    if (!px || w <= 0 || h <= 0) { dm_fb_clear(fb, dm_rgb(0, 0, 0)); return; }

    DmFramebuffer *src = dm_fb_wrap((uint32_t *)px, w, h, w);
    if (!src) { dm_fb_clear(fb, dm_rgb(0, 0, 0)); return; }

    if (c->cfg.eyes > 1) {
        int half = fb->width / 2;   /* equal-width eyes keep the scratch stable */
        render_eye(c, fb, src, (DmRect){0, 0, half, fb->height});
        render_eye(c, fb, src, (DmRect){fb->width - half, 0, half, fb->height});
    } else {
        render_eye(c, fb, src, (DmRect){0, 0, fb->width, fb->height});
    }
    dm_fb_destroy(src);
}

DmArConfig dm_ar_get_config(DmArContext *c) {
    if (c) return c->cfg;
    return (DmArConfig){ DM_FIT_COVER, 1, 255, 0.0f, 0.0f };
}
void dm_ar_set_config(DmArContext *c, DmArConfig cfg) { if (c) c->cfg = cfg; }

void dm_ar_status(DmArContext *c, int *w, int *h, uint64_t *seq, uint64_t *frames) {
    if (w) *w = c ? c->width : 0;
    if (h) *h = c ? c->height : 0;
    if (seq)    *seq = 0;
    if (frames) *frames = c ? c->frames : 0;
    if (c && c->src) {
        int sw = 0, sh = 0;
        if (dm_ar_source_latest(c->src, &sw, &sh)) {
            if (w) *w = sw;
            if (h) *h = sh;
        }
    }
}

void dm_ar_close(DmArContext *c) {
    if (!c) return;
    if (c->src) dm_ar_source_close(c->src);
    if (c->eye) dm_fb_destroy(c->eye);
    free(c);
}

/* ── Lua bindings (dm.ar.*) ────────────────────────────────────────────── */

static DmApp *ar_get_app(lua_State *L) {
    lua_getfield(L, LUA_REGISTRYINDEX, DM_LUA_APP_KEY);
    DmApp *app = (DmApp *)lua_touserdata(L, -1);
    lua_pop(L, 1);
    return app;
}

static DmFitMode fit_from_string(const char *s) {
    if (!s) return DM_FIT_COVER;
    if (!strcmp(s, "contain")) return DM_FIT_CONTAIN;
    if (!strcmp(s, "stretch")) return DM_FIT_STRETCH;
    return DM_FIT_COVER;
}
static const char *fit_to_string(DmFitMode f) {
    switch (f) {
        case DM_FIT_CONTAIN: return "contain";
        case DM_FIT_STRETCH: return "stretch";
        default:             return "cover";
    }
}

/* Read an optional string field from the table at index 1; returns default. */
static const char *opt_field_str(lua_State *L, const char *k, const char *dflt) {
    lua_getfield(L, 1, k);
    const char *v = lua_isstring(L, -1) ? lua_tostring(L, -1) : dflt;
    /* keep the value alive on the stack until the caller is done reading it;
       callers copy immediately, so pop here is fine for our short-lived reads. */
    lua_pop(L, 1);
    return v;
}
static int opt_field_int(lua_State *L, const char *k, int dflt) {
    lua_getfield(L, 1, k);
    int v = lua_isnumber(L, -1) ? (int)lua_tointeger(L, -1) : dflt;
    lua_pop(L, 1);
    return v;
}
static float opt_field_num(lua_State *L, const char *k, float dflt) {
    lua_getfield(L, 1, k);
    float v = lua_isnumber(L, -1) ? (float)lua_tonumber(L, -1) : dflt;
    lua_pop(L, 1);
    return v;
}

/* dm.ar.open{ source=, w=, h=, fit="cover"|"contain"|"stretch",
 *             eyes=1, alpha=255, format="rgba"|"bgra" } -> true | nil,err */
static int lar_open(lua_State *L) {
    DmApp *app = ar_get_app(L);
    if (!app) return luaL_error(L, "ar.open: no app");
    luaL_checktype(L, 1, LUA_TTABLE);

    lua_getfield(L, 1, "source");
    const char *source = luaL_checkstring(L, -1);
    char src_copy[256];
    snprintf(src_copy, sizeof(src_copy), "%s", source);
    lua_pop(L, 1);

    int w = opt_field_int(L, "w", 0);
    int h = opt_field_int(L, "h", 0);

    char fit_buf[16];  snprintf(fit_buf, sizeof(fit_buf), "%s", opt_field_str(L, "fit", "cover"));
    char fmt_buf[16];  snprintf(fmt_buf, sizeof(fmt_buf), "%s", opt_field_str(L, "format", "rgba"));

    DmArConfig cfg;
    cfg.fit   = fit_from_string(fit_buf);
    cfg.eyes  = opt_field_int(L, "eyes", 1);
    cfg.alpha = (uint8_t)opt_field_int(L, "alpha", 255);
    cfg.k1    = opt_field_num(L, "k1", 0.0f);
    cfg.k2    = opt_field_num(L, "k2", 0.0f);
    DmArPixFmt fmt = (!strcmp(fmt_buf, "bgra")) ? DM_AR_FMT_BGRA8888 : DM_AR_FMT_RGBA8888;

    if (app->ar) { dm_ar_close(app->ar); app->ar = NULL; }

    DmArContext *c = dm_ar_open(src_copy, w, h, fmt, cfg);
    if (!c) {
        lua_pushnil(L);
        lua_pushfstring(L, "ar.open: could not open source '%s'", src_copy);
        return 2;
    }
    app->ar = c;
    lua_pushboolean(L, 1);
    return 1;
}

/* dm.ar.config{ fit=, alpha=, eyes= } — mutate the live config. */
static int lar_config(lua_State *L) {
    DmApp *app = ar_get_app(L);
    if (!app || !app->ar) return 0;
    luaL_checktype(L, 1, LUA_TTABLE);
    DmArConfig cfg = dm_ar_get_config(app->ar);

    lua_getfield(L, 1, "fit");
    if (lua_isstring(L, -1)) cfg.fit = fit_from_string(lua_tostring(L, -1));
    lua_pop(L, 1);
    cfg.eyes  = opt_field_int(L, "eyes",  cfg.eyes);
    cfg.alpha = (uint8_t)opt_field_int(L, "alpha", cfg.alpha);
    cfg.k1    = opt_field_num(L, "k1", cfg.k1);
    cfg.k2    = opt_field_num(L, "k2", cfg.k2);

    dm_ar_set_config(app->ar, cfg);
    return 0;
}

/* dm.ar.status() -> { active=, w=, h=, frames=, fit=, source= } | { active=false } */
static int lar_status(lua_State *L) {
    DmApp *app = ar_get_app(L);
    lua_newtable(L);
    if (!app || !app->ar) {
        lua_pushboolean(L, 0); lua_setfield(L, -2, "active");
        return 1;
    }
    int w = 0, h = 0; uint64_t seq = 0, frames = 0;
    dm_ar_status(app->ar, &w, &h, &seq, &frames);
    DmArConfig cfg = dm_ar_get_config(app->ar);

    lua_pushboolean(L, 1);              lua_setfield(L, -2, "active");
    lua_pushinteger(L, w);             lua_setfield(L, -2, "w");
    lua_pushinteger(L, h);             lua_setfield(L, -2, "h");
    lua_pushinteger(L, (lua_Integer)frames); lua_setfield(L, -2, "frames");
    lua_pushstring(L, fit_to_string(cfg.fit)); lua_setfield(L, -2, "fit");
    lua_pushinteger(L, cfg.eyes);      lua_setfield(L, -2, "eyes");
    return 1;
}

static int lar_close(lua_State *L) {
    DmApp *app = ar_get_app(L);
    if (app && app->ar) { dm_ar_close(app->ar); app->ar = NULL; }
    return 0;
}

static const luaL_Reg ar_funcs[] = {
    { "open",   lar_open   },
    { "config", lar_config },
    { "status", lar_status },
    { "close",  lar_close  },
    { NULL, NULL }
};

/* dm.pose.open{ source= } -> true | nil,err — head-tracking (6DOF) source. */
static int lpose_open(lua_State *L) {
    DmApp *app = ar_get_app(L);
    if (!app) return luaL_error(L, "pose.open: no app");
    luaL_checktype(L, 1, LUA_TTABLE);
    lua_getfield(L, 1, "source");
    const char *source = luaL_checkstring(L, -1);
    char src_copy[256];
    snprintf(src_copy, sizeof(src_copy), "%s", source);
    lua_pop(L, 1);

    if (app->pose) { dm_pose_close(app->pose); app->pose = NULL; }
    DmPoseSource *p = dm_pose_open(src_copy);
    if (!p) {
        lua_pushnil(L);
        lua_pushfstring(L, "pose.open: could not open source '%s'", src_copy);
        return 2;
    }
    app->pose = p;
    lua_pushboolean(L, 1);
    return 1;
}

static int lpose_close(lua_State *L) {
    DmApp *app = ar_get_app(L);
    if (app && app->pose) { dm_pose_close(app->pose); app->pose = NULL; }
    return 0;
}

static const luaL_Reg pose_funcs[] = {
    { "open",  lpose_open  },
    { "close", lpose_close },
    { NULL, NULL }
};

void dm_ar_register(lua_State *L) {
    luaL_newlib(L, ar_funcs);
    lua_setfield(L, -2, "ar");     /* dm.ar (dm table is on top at the call site) */
    luaL_newlib(L, pose_funcs);
    lua_setfield(L, -2, "pose");   /* dm.pose — 6DOF head tracking → on_pose(...) */
}
