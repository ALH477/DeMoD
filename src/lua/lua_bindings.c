// SPDX-License-Identifier: MPL-2.0
/*
 * DeMoD UI Framework — Lua Bindings
 * Expose the widget system, drawing primitives, and app state to Lua.
 * Copyright (c) 2026 DeMoD LLC.
 * Licensed under the Mozilla Public License, v. 2.0; see LICENSE.
 *
 * Lua API:
 *   dm.panel(id)                          → widget
 *   dm.label(id, text)                    → widget
 *   dm.button(id, text)                   → widget
 *   dm.slider(id, min, max, val)          → widget
 *   dm.toggle(id, initial)               → widget
 *   dm.text_input(id, placeholder)        → widget
 *   dm.progress(id, value)                → widget
 *
 *   widget:set_bounds(x, y, w, h)
 *   widget:set_layout(type, spacing, padding, cols)
 *   widget:add_child(child)
 *   widget:on_click(callback)
 *   widget:on_change(callback)
 *   widget:set_text(text)
 *   widget:get_value()  / widget:set_value(v)
 *   widget:set_bg(r,g,b[,a])
 *   widget:set_fg(r,g,b[,a])
 *   widget:show() / widget:hide()
 *   widget:enable() / widget:disable()
 *
 *   dm.root()                             → root widget
 *   dm.find(id)                           → widget or nil
 *   dm.redraw()
 *   dm.quit()
 *   dm.time()                             → elapsed seconds
 *   dm.dt()                               → delta time
 *
 *   dm.draw.rect(x,y,w,h, r,g,b[,a])
 *   dm.draw.circle(cx,cy,rad, r,g,b[,a])
 *   dm.draw.line(x0,y0,x1,y1, r,g,b[,a])
 *   dm.draw.text(x,y, text, r,g,b[,a])
 *   dm.draw.gradient_v(x,y,w,h, r1,g1,b1, r2,g2,b2)
 */
#include "demod/app.h"
#include "demod/dsl.h"
#include "demod/input.h"          /* DmMidiInfo, dm_midi_enumerate */
#include "demod/ipc.h"
#include "monocypher-ed25519.h"   /* vendored: RFC-8032 Ed25519 verify + SHA-512 (src/crypto) */
#include "streamdb.h"             /* vendored: embedded reverse-trie KV store (src/db) */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ── Registry key for DmApp pointer ────────────────────────────────── */

#define DM_LUA_APP_KEY "dm_app_ptr"

static DmApp *get_app(lua_State *L) {
    lua_getfield(L, LUA_REGISTRYINDEX, DM_LUA_APP_KEY);
    DmApp *app = (DmApp *)lua_touserdata(L, -1);
    lua_pop(L, 1);
    return app;
}

/* ── Widget Userdata ───────────────────────────────────────────────── */

#define DM_WIDGET_MT "DmWidget"

static DmWidget **push_widget(lua_State *L, DmWidget *w) {
    DmWidget **pw = (DmWidget **)lua_newuserdata(L, sizeof(DmWidget *));
    *pw = w;
    luaL_setmetatable(L, DM_WIDGET_MT);
    return pw;
}

static DmWidget *check_widget(lua_State *L, int idx) {
    DmWidget **pw = (DmWidget **)luaL_checkudata(L, idx, DM_WIDGET_MT);
    return *pw;
}

/* ── Lua Callback Trampoline ───────────────────────────────────────── */

typedef struct {
    lua_State *L;
    int        ref;
} LuaCallback;

static void lua_callback_trampoline(DmWidget *w, void *userdata) {
    LuaCallback *cb = (LuaCallback *)userdata;
    lua_rawgeti(cb->L, LUA_REGISTRYINDEX, cb->ref);
    push_widget(cb->L, w);
    if (lua_pcall(cb->L, 1, 0, 0) != LUA_OK) {
        fprintf(stderr, "[Lua] callback error: %s\n", lua_tostring(cb->L, -1));
        lua_pop(cb->L, 1);
    }
}

/* ── Color helper ──────────────────────────────────────────────────── */

static DmColor read_color(lua_State *L, int start) {
    int r = (int)luaL_checkinteger(L, start);
    int g = (int)luaL_checkinteger(L, start + 1);
    int b = (int)luaL_checkinteger(L, start + 2);
    int a = (int)luaL_optinteger(L, start + 3, 255);
    return dm_rgba((uint8_t)r, (uint8_t)g, (uint8_t)b, (uint8_t)a);
}

/* ══════════════════════════════════════════════════════════════════════
 *  Widget Methods
 * ══════════════════════════════════════════════════════════════════════ */

static int lw_set_bounds(lua_State *L) {
    DmWidget *w = check_widget(L, 1);
    w->bounds.x = (int)luaL_checkinteger(L, 2);
    w->bounds.y = (int)luaL_checkinteger(L, 3);
    w->bounds.w = (int)luaL_checkinteger(L, 4);
    w->bounds.h = (int)luaL_checkinteger(L, 5);
    return 0;
}

static int lw_set_layout(lua_State *L) {
    DmWidget *w = check_widget(L, 1);
    const char *type_str = luaL_checkstring(L, 2);
    if (strcmp(type_str, "vbox") == 0)      w->layout.type = DM_LAYOUT_VBOX;
    else if (strcmp(type_str, "hbox") == 0) w->layout.type = DM_LAYOUT_HBOX;
    else if (strcmp(type_str, "grid") == 0) w->layout.type = DM_LAYOUT_GRID;
    else                                   w->layout.type = DM_LAYOUT_NONE;
    w->layout.spacing = (int)luaL_optinteger(L, 3, 6);
    w->layout.padding = (int)luaL_optinteger(L, 4, 8);
    w->layout.columns = (int)luaL_optinteger(L, 5, 2);
    return 0;
}

static int lw_add_child(lua_State *L) {
    DmWidget *parent = check_widget(L, 1);
    DmWidget *child  = check_widget(L, 2);
    dm_widget_add_child(parent, child);
    return 0;
}

static int lw_on_click(lua_State *L) {
    DmWidget *w = check_widget(L, 1);
    luaL_checktype(L, 2, LUA_TFUNCTION);
    LuaCallback *cb = (LuaCallback *)malloc(sizeof(LuaCallback));
    cb->L   = L;
    lua_pushvalue(L, 2);
    cb->ref = luaL_ref(L, LUA_REGISTRYINDEX);
    w->on_click  = lua_callback_trampoline;
    w->userdata  = cb;
    return 0;
}

static int lw_on_change(lua_State *L) {
    DmWidget *w = check_widget(L, 1);
    luaL_checktype(L, 2, LUA_TFUNCTION);
    LuaCallback *cb = (LuaCallback *)malloc(sizeof(LuaCallback));
    cb->L   = L;
    lua_pushvalue(L, 2);
    cb->ref = luaL_ref(L, LUA_REGISTRYINDEX);
    w->on_change = lua_callback_trampoline;
    w->userdata  = cb;
    return 0;
}

static int lw_set_text(lua_State *L) {
    DmWidget *w = check_widget(L, 1);
    const char *text = luaL_checkstring(L, 2);
    if (strcmp(w->vt->type_name, "label") == 0)
        dm_label_set_text(w, text);
    else if (strcmp(w->vt->type_name, "button") == 0)
        dm_button_set_text(w, text);
    else if (strcmp(w->vt->type_name, "text_input") == 0)
        dm_text_input_set_text(w, text);
    return 0;
}

static int lw_get_value(lua_State *L) {
    DmWidget *w = check_widget(L, 1);
    if (strcmp(w->vt->type_name, "slider") == 0)
        lua_pushnumber(L, dm_slider_get_value(w));
    else if (strcmp(w->vt->type_name, "toggle") == 0)
        lua_pushboolean(L, dm_toggle_get_value(w));
    else if (strcmp(w->vt->type_name, "text_input") == 0)
        lua_pushstring(L, dm_text_input_get_text(w));
    else if (strcmp(w->vt->type_name, "knob") == 0)
        lua_pushnumber(L, dm_knob_get_value(w));
    else if (strcmp(w->vt->type_name, "dropdown") == 0) {
        const char *text = dm_dropdown_get_selected_text(w);
        if (text) lua_pushstring(L, text);
        else lua_pushnil(L);
    }
    else
        lua_pushnil(L);
    return 1;
}

static int lw_set_value(lua_State *L) {
    DmWidget *w = check_widget(L, 1);
    if (strcmp(w->vt->type_name, "slider") == 0)
        dm_slider_set_value(w, (float)luaL_checknumber(L, 2));
    else if (strcmp(w->vt->type_name, "toggle") == 0)
        dm_toggle_set_value(w, lua_toboolean(L, 2));
    else if (strcmp(w->vt->type_name, "progress") == 0)
        dm_progress_set_value(w, (float)luaL_checknumber(L, 2));
    else if (strcmp(w->vt->type_name, "knob") == 0)
        dm_knob_set_value(w, (float)luaL_checknumber(L, 2));
    else if (strcmp(w->vt->type_name, "dropdown") == 0)
        dm_dropdown_set_selected(w, (int)luaL_checkinteger(L, 2));
    return 0;
}

static int lw_set_bg(lua_State *L) {
    DmWidget *w = check_widget(L, 1);
    DmColor c = read_color(L, 2);
    if (strcmp(w->vt->type_name, "panel") == 0)
        dm_panel_set_bg(w, c);
    else if (strcmp(w->vt->type_name, "button") == 0) {
        DmButtonData *d = (DmButtonData *)w->data;
        d->bg = c;
    }
    return 0;
}

static int lw_set_fg(lua_State *L) {
    DmWidget *w = check_widget(L, 1);
    DmColor c = read_color(L, 2);
    if (strcmp(w->vt->type_name, "label") == 0)
        dm_label_set_color(w, c);
    else if (strcmp(w->vt->type_name, "button") == 0) {
        DmButtonData *d = (DmButtonData *)w->data;
        d->fg = c;
    }
    return 0;
}

static int lw_show(lua_State *L)    { dm_widget_show(check_widget(L, 1)); return 0; }
static int lw_hide(lua_State *L)    { dm_widget_hide(check_widget(L, 1)); return 0; }
static int lw_enable(lua_State *L)  { dm_widget_enable(check_widget(L, 1)); return 0; }
static int lw_disable(lua_State *L) { dm_widget_disable(check_widget(L, 1)); return 0; }

static int lw_id(lua_State *L) {
    DmWidget *w = check_widget(L, 1);
    lua_pushstring(L, w->id);
    return 1;
}

/* DSP widget methods */
static int lw_add_item(lua_State *L) {
    DmWidget *w = check_widget(L, 1);
    const char *item = luaL_checkstring(L, 2);
    if (strcmp(w->vt->type_name, "dropdown") == 0)
        dm_dropdown_add_item(w, item);
    return 0;
}

static int lw_set_level(lua_State *L) {
    DmWidget *w = check_widget(L, 1);
    if (strcmp(w->vt->type_name, "vu_meter") == 0) {
        int ch = (int)luaL_checkinteger(L, 2);
        float level = (float)luaL_checknumber(L, 3);
        dm_vu_meter_set_level(w, ch, level);
    }
    return 0;
}

static int lw_push_sample(lua_State *L) {
    DmWidget *w = check_widget(L, 1);
    if (strcmp(w->vt->type_name, "waveform") == 0) {
        float sample = (float)luaL_checknumber(L, 2);
        dm_waveform_push_sample(w, sample);
    }
    return 0;
}

static int lw_set_format(lua_State *L) {
    DmWidget *w = check_widget(L, 1);
    const char *fmt = luaL_checkstring(L, 2);
    if (strcmp(w->vt->type_name, "knob") == 0)
        dm_knob_set_format(w, fmt);
    return 0;
}

static int lw_get_xy(lua_State *L) {
    DmWidget *w = check_widget(L, 1);
    if (strcmp(w->vt->type_name, "xy_pad") == 0) {
        float x, y;
        dm_xy_pad_get_value(w, &x, &y);
        lua_pushnumber(L, x);
        lua_pushnumber(L, y);
        return 2;
    }
    return 0;
}

static int lw_set_xy(lua_State *L) {
    DmWidget *w = check_widget(L, 1);
    if (strcmp(w->vt->type_name, "xy_pad") == 0) {
        float x = (float)luaL_checknumber(L, 2);
        float y = (float)luaL_checknumber(L, 3);
        dm_xy_pad_set_value(w, x, y);
    }
    return 0;
}

static int lw_vu_update(lua_State *L) {
    DmWidget *w = check_widget(L, 1);
    if (strcmp(w->vt->type_name, "vu_meter") == 0) {
        float dt = (float)luaL_checknumber(L, 2);
        dm_vu_meter_update(w, dt);
    }
    return 0;
}

static int lw_clear(lua_State *L) {
    DmWidget *w = check_widget(L, 1);
    if (strcmp(w->vt->type_name, "waveform") == 0)
        dm_waveform_clear(w);
    else if (strcmp(w->vt->type_name, "dropdown") == 0)
        dm_dropdown_clear_items(w);
    return 0;
}

static const luaL_Reg widget_methods[] = {
    {"set_bounds",  lw_set_bounds},
    {"set_layout",  lw_set_layout},
    {"add_child",   lw_add_child},
    {"on_click",    lw_on_click},
    {"on_change",   lw_on_change},
    {"set_text",    lw_set_text},
    {"get_value",   lw_get_value},
    {"set_value",   lw_set_value},
    {"set_bg",      lw_set_bg},
    {"set_fg",      lw_set_fg},
    {"show",        lw_show},
    {"hide",        lw_hide},
    {"enable",      lw_enable},
    {"disable",     lw_disable},
    {"id",          lw_id},
    /* DSP widget methods */
    {"add_item",    lw_add_item},
    {"set_level",   lw_set_level},
    {"push_sample", lw_push_sample},
    {"set_format",  lw_set_format},
    {"get_xy",      lw_get_xy},
    {"set_xy",      lw_set_xy},
    {"vu_update",   lw_vu_update},
    {"clear",       lw_clear},
    {NULL, NULL}
};

/* ══════════════════════════════════════════════════════════════════════
 *  dm.* Module Functions (Widget Constructors)
 * ══════════════════════════════════════════════════════════════════════ */

static int l_panel(lua_State *L) {
    const char *id = luaL_checkstring(L, 1);
    push_widget(L, dm_panel_create(id));
    return 1;
}

static int l_label(lua_State *L) {
    const char *id   = luaL_checkstring(L, 1);
    const char *text = luaL_optstring(L, 2, "");
    push_widget(L, dm_label_create(id, text));
    return 1;
}

static int l_button(lua_State *L) {
    const char *id   = luaL_checkstring(L, 1);
    const char *text = luaL_optstring(L, 2, "");
    push_widget(L, dm_button_create(id, text));
    return 1;
}

static int l_slider(lua_State *L) {
    const char *id = luaL_checkstring(L, 1);
    float min_v = (float)luaL_optnumber(L, 2, 0.0);
    float max_v = (float)luaL_optnumber(L, 3, 1.0);
    float val   = (float)luaL_optnumber(L, 4, 0.5);
    push_widget(L, dm_slider_create(id, min_v, max_v, val));
    return 1;
}

static int l_toggle(lua_State *L) {
    const char *id = luaL_checkstring(L, 1);
    bool init = lua_toboolean(L, 2);
    push_widget(L, dm_toggle_create(id, init));
    return 1;
}

static int l_text_input(lua_State *L) {
    const char *id = luaL_checkstring(L, 1);
    const char *ph = luaL_optstring(L, 2, "");
    push_widget(L, dm_text_input_create(id, ph));
    return 1;
}

static int l_progress(lua_State *L) {
    const char *id = luaL_checkstring(L, 1);
    float val = (float)luaL_optnumber(L, 2, 0.0);
    push_widget(L, dm_progress_create(id, val));
    return 1;
}

static int l_knob(lua_State *L) {
    const char *id    = luaL_checkstring(L, 1);
    const char *label = luaL_optstring(L, 2, "");
    float min_v = (float)luaL_optnumber(L, 3, 0.0);
    float max_v = (float)luaL_optnumber(L, 4, 1.0);
    float val   = (float)luaL_optnumber(L, 5, 0.5);
    push_widget(L, dm_knob_create(id, label, min_v, max_v, val));
    return 1;
}

static int l_vu_meter(lua_State *L) {
    const char *id = luaL_checkstring(L, 1);
    int channels   = (int)luaL_optinteger(L, 2, 2);
    push_widget(L, dm_vu_meter_create(id, channels));
    return 1;
}

static int l_waveform(lua_State *L) {
    const char *id = luaL_checkstring(L, 1);
    int samples    = (int)luaL_optinteger(L, 2, 512);
    push_widget(L, dm_waveform_create(id, samples));
    return 1;
}

static int l_dropdown(lua_State *L) {
    const char *id = luaL_checkstring(L, 1);
    const char *ph = luaL_optstring(L, 2, "Select...");
    push_widget(L, dm_dropdown_create(id, ph));
    return 1;
}

static int l_scroll_panel(lua_State *L) {
    const char *id = luaL_checkstring(L, 1);
    int cw = (int)luaL_optinteger(L, 2, 800);
    int ch = (int)luaL_optinteger(L, 3, 1200);
    push_widget(L, dm_scroll_panel_create(id, cw, ch));
    return 1;
}

static int l_xy_pad(lua_State *L) {
    const char *id = luaL_checkstring(L, 1);
    push_widget(L, dm_xy_pad_create(id));
    return 1;
}

static int l_root(lua_State *L) {
    DmApp *app = get_app(L);
    push_widget(L, app->root);
    return 1;
}

static int l_find(lua_State *L) {
    DmApp *app = get_app(L);
    const char *id = luaL_checkstring(L, 1);
    DmWidget *w = dm_widget_find(app->root, id);
    if (w) push_widget(L, w);
    else   lua_pushnil(L);
    return 1;
}

static int l_redraw(lua_State *L) {
    dm_app_request_redraw(get_app(L));
    return 0;
}

static int l_quit(lua_State *L) {
    get_app(L)->running = false;
    return 0;
}

/* dm.exec(cmd) — launch a command in the background (fire-and-forget).
 * Used by the launcher shell to open a channel's app. Returns bool. */
static int l_exec(lua_State *L) {
    const char *cmd = luaL_checkstring(L, 1);
    char buf[1024];
    int n = snprintf(buf, sizeof(buf), "%s &", cmd);
    int ok = (n > 0 && (size_t)n < sizeof(buf) && system(buf) != -1);
    lua_pushboolean(L, ok);
    return 1;
}

/* dm.nav(action) — inject a semantic nav action from Lua (or any source
 * routed through Lua: touch, MIDI, network). Accepts the lenient synonym
 * vocabulary ("next","cw","push","back","+", ...). */
static int l_nav(lua_State *L) {
    dm_app_nav(get_app(L), luaL_checkstring(L, 1));
    return 0;
}

/* dm.encoder_open(path[, baud]) — open/replace the hardware encoder. → bool */
static int l_encoder_open(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    int baud = (int)luaL_optinteger(L, 2, 0);
    lua_pushboolean(L, dm_app_encoder_open(get_app(L), path, baud));
    return 1;
}

static int l_encoder_close(lua_State *L) {
    dm_app_encoder_close(get_app(L));
    return 0;
}

/* dm.midi_open(path) — add a MIDI input source (ALSA rawmidi / FIFO / file).
 * Multiple may be open; re-opening the same path is idempotent. Parsed messages
 * arrive as on_midi(status, d1, d2). → bool */
static int l_midi_open(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    lua_pushboolean(L, dm_app_midi_open(get_app(L), path));
    return 1;
}

/* dm.midi_close([path]) — close one source by path, or ALL when omitted. */
static int l_midi_close(lua_State *L) {
    const char *path = luaL_optstring(L, 1, NULL);
    dm_app_midi_close(get_app(L), path);
    return 0;
}

/* dm.midi_list() — enumerate ALSA rawmidi inputs as { {id=,name=}, ... }. */
static int l_midi_list(lua_State *L) {
    DmMidiInfo info[DM_MIDI_MAX_IN * 2];
    int n = dm_midi_enumerate(info, (int)(sizeof(info) / sizeof(info[0])));
    lua_createtable(L, n, 0);
    for (int i = 0; i < n; i++) {
        lua_createtable(L, 0, 2);
        lua_pushstring(L, info[i].id);   lua_setfield(L, -2, "id");
        lua_pushstring(L, info[i].name); lua_setfield(L, -2, "name");
        lua_rawseti(L, -2, i + 1);
    }
    return 1;
}

/* dm.midi_out_open(path) — open the optional MIDI output (controller feedback). */
static int l_midi_out_open(lua_State *L) {
    const char *path = luaL_checkstring(L, 1);
    lua_pushboolean(L, dm_app_midi_out_open(get_app(L), path));
    return 1;
}

/* dm.midi_send(status, d1, d2) — send a raw MIDI message on the output. */
static int l_midi_send(lua_State *L) {
    unsigned char st = (unsigned char)(luaL_checkinteger(L, 1) & 0xFF);
    unsigned char d1 = (unsigned char)(luaL_optinteger(L, 2, 0) & 0xFF);
    unsigned char d2 = (unsigned char)(luaL_optinteger(L, 3, 0) & 0xFF);
    dm_app_midi_send(get_app(L), st, d1, d2);
    return 0;
}

/* dm.gamepad_map(button, action) — remap a controller button (see demod/gamepad.h).
 * e.g. dm.gamepad_map("a", "activate"); "none"/"" unbinds. No-op without a pad. */
static int l_gamepad_map(lua_State *L) {
    dm_app_gamepad_map(get_app(L), luaL_checkstring(L, 1), luaL_checkstring(L, 2));
    return 0;
}

/* ── Orchestrator IPC (demod5): param bus read + control socket write ──── */

/* dm.params_read() -> table | nil  (nil when no orchestrator is present) */
static int l_params_read(lua_State *L) {
    DemodParamSnapshot s;
    if (!demod_params_read(&s)) { lua_pushnil(L); return 1; }

    lua_newtable(L);
    lua_pushnumber(L, s.detected_pitch_hz); lua_setfield(L, -2, "pitch_hz");
    lua_pushnumber(L, s.pitch_confidence);  lua_setfield(L, -2, "pitch_conf");
    lua_pushinteger(L, s.midi_note);        lua_setfield(L, -2, "midi_note");
    lua_pushnumber(L, s.bpm);               lua_setfield(L, -2, "bpm");
    lua_pushinteger(L, s.beat_count);       lua_setfield(L, -2, "beat_count");
    lua_pushinteger(L, s.fx_bypass_mask);   lua_setfield(L, -2, "bypass_mask");
    lua_pushnumber(L, s.synth_gain);        lua_setfield(L, -2, "synth_gain");

    lua_newtable(L);                        /* fx_params = {16 floats} */
    for (int i = 0; i < 16; i++) {
        lua_pushnumber(L, s.fx_params[i]);
        lua_rawseti(L, -2, i + 1);
    }
    lua_setfield(L, -2, "fx_params");

    /* Live readback straight from demod-rt (per-slot RMS + post-chain scope), if it
     * is publishing. Folded into the same table so dsp.meters().levels and
     * dsp.scope() light up with no extra plumbing: levels = {16},
     * scope = { L = {N}, R = {N}, n = N }. */
    DemodRtMeters meters;
    if (demod_rt_meters_read(&meters)) {
        lua_newtable(L);                    /* levels = {16 floats} */
        for (int i = 0; i < DEMOD_RT_METERS_SLOTS; i++) {
            lua_pushnumber(L, meters.fx_levels[i]);
            lua_rawseti(L, -2, i + 1);
        }
        lua_setfield(L, -2, "levels");

        /* per-slot mixer readback for the MIXER screen: stereo levels + authoritative
         * gain/pan + mute/solo masks (keys mirror dsp/backend/orchestrator.lua poll). */
        lua_newtable(L);                    /* levels_l = {16 floats} */
        for (int i = 0; i < DEMOD_RT_METERS_SLOTS; i++) {
            lua_pushnumber(L, meters.fx_levels_l[i]);
            lua_rawseti(L, -2, i + 1);
        }
        lua_setfield(L, -2, "levels_l");
        lua_newtable(L);                    /* levels_r = {16 floats} */
        for (int i = 0; i < DEMOD_RT_METERS_SLOTS; i++) {
            lua_pushnumber(L, meters.fx_levels_r[i]);
            lua_rawseti(L, -2, i + 1);
        }
        lua_setfield(L, -2, "levels_r");
        lua_newtable(L);                    /* gain = {16 floats} (authoritative) */
        for (int i = 0; i < DEMOD_RT_METERS_SLOTS; i++) {
            lua_pushnumber(L, meters.slot_gain[i]);
            lua_rawseti(L, -2, i + 1);
        }
        lua_setfield(L, -2, "gain");
        lua_newtable(L);                    /* pan = {16 floats} */
        for (int i = 0; i < DEMOD_RT_METERS_SLOTS; i++) {
            lua_pushnumber(L, meters.slot_pan[i]);
            lua_rawseti(L, -2, i + 1);
        }
        lua_setfield(L, -2, "pan");
        lua_pushinteger(L, (lua_Integer)meters.slot_mute_mask);
        lua_setfield(L, -2, "mute_mask");
        lua_pushinteger(L, (lua_Integer)meters.slot_solo_mask);
        lua_setfield(L, -2, "solo_mask");

        if (meters.scope_n >= 2) {
            uint32_t n = meters.scope_n;
            if (n > DEMOD_RT_METERS_SCOPE_N) n = DEMOD_RT_METERS_SCOPE_N;
            lua_newtable(L);                /* scope */
            lua_newtable(L);                /* scope.L */
            for (uint32_t i = 0; i < n; i++) {
                lua_pushnumber(L, meters.scope_l[i]);
                lua_rawseti(L, -2, (int)i + 1);
            }
            lua_setfield(L, -2, "L");
            lua_newtable(L);                /* scope.R */
            for (uint32_t i = 0; i < n; i++) {
                lua_pushnumber(L, meters.scope_r[i]);
                lua_rawseti(L, -2, (int)i + 1);
            }
            lua_setfield(L, -2, "R");
            lua_pushinteger(L, (lua_Integer)n);
            lua_setfield(L, -2, "n");
            lua_setfield(L, -2, "scope");
        }
    }
    return 1;
}

/* dm.ctl_set_param(slot, idx, value) -> bool */
static int l_ctl_set_param(lua_State *L) {
    int slot = (int)luaL_checkinteger(L, 1);
    int idx  = (int)luaL_checkinteger(L, 2);
    float v  = (float)luaL_checknumber(L, 3);
    lua_pushboolean(L, demod_control_set_param(slot, idx, v) == 0);
    return 1;
}
/* dm.ctl_bypass(slot, on) -> bool */
static int l_ctl_bypass(lua_State *L) {
    int slot = (int)luaL_checkinteger(L, 1);
    int on   = lua_toboolean(L, 2);
    lua_pushboolean(L, demod_control_bypass(slot, on) == 0);
    return 1;
}
/* dm.ctl_bpm(bpm) -> bool */
static int l_ctl_bpm(lua_State *L) {
    lua_pushboolean(L, demod_control_set_bpm((float)luaL_checknumber(L, 1)) == 0);
    return 1;
}
/* dm.ctl_gain(gain) -> bool */
static int l_ctl_gain(lua_State *L) {
    lua_pushboolean(L, demod_control_set_gain((float)luaL_checknumber(L, 1)) == 0);
    return 1;
}
/* dm.ctl(jsonline) -> bool  (raw escape hatch) */
static int l_ctl_raw(lua_State *L) {
    lua_pushboolean(L, demod_control_send_raw(luaL_checkstring(L, 1)) == 0);
    return 1;
}

/* dm.local_available() -> bool  (true only when built with LOCAL_DSP=1, i.e. the
 * demodoom_core C++ engine is linked in; otherwise backend/select falls through). */
static int l_local_available(lua_State *L) {
#ifdef DEMOD_LOCAL_DSP
    lua_pushboolean(L, 1);
#else
    lua_pushboolean(L, 0);
#endif
    return 1;
}

#ifdef DEMOD_LOCAL_DSP
/* ── Local demodoom_core backend bindings (desktop, real audio) ───────── */
#include "demod/local_dsp.h"

static int l_local_init(lua_State *L) {
    int sr = (int)luaL_optinteger(L, 1, 48000);
    int bs = (int)luaL_optinteger(L, 2, 256);
    lua_pushboolean(L, demod_local_init(sr, bs));
    return 1;
}
static int l_local_shutdown(lua_State *L) { (void)L; demod_local_shutdown(); return 0; }
static int l_local_slot_count(lua_State *L) { lua_pushinteger(L, demod_local_slot_count()); return 1; }

/* dm.local_slot(slot0) -> loaded, name, bypassed, wet, nparams */
static int l_local_slot(lua_State *L) {
    int s = (int)luaL_checkinteger(L, 1);
    lua_pushboolean(L, demod_local_slot_loaded(s));
    lua_pushstring(L, demod_local_slot_name(s));
    lua_pushboolean(L, demod_local_slot_bypassed(s));
    lua_pushnumber(L, demod_local_slot_wet(s));
    lua_pushinteger(L, demod_local_num_params(s));
    return 5;
}
/* dm.local_param(slot0, idx0) -> label, min, max, init, step, value */
static int l_local_param(lua_State *L) {
    int s = (int)luaL_checkinteger(L, 1);
    int i = (int)luaL_checkinteger(L, 2);
    lua_pushstring(L, demod_local_param_label(s, i));
    lua_pushnumber(L, demod_local_param_min(s, i));
    lua_pushnumber(L, demod_local_param_max(s, i));
    lua_pushnumber(L, demod_local_param_init(s, i));
    lua_pushnumber(L, demod_local_param_step(s, i));
    lua_pushnumber(L, demod_local_get_param(s, i));
    return 6;
}
static int l_local_set_param(lua_State *L) {
    demod_local_set_param((int)luaL_checkinteger(L,1),(int)luaL_checkinteger(L,2),(float)luaL_checknumber(L,3));
    return 0;
}
static int l_local_set_bypass(lua_State *L) {
    demod_local_set_bypass((int)luaL_checkinteger(L,1), lua_toboolean(L,2)); return 0;
}
static int l_local_set_wet(lua_State *L) {
    demod_local_set_wet((int)luaL_checkinteger(L,1),(float)luaL_checknumber(L,2)); return 0;
}
static int l_local_load_slot(lua_State *L) {
    lua_pushboolean(L, demod_local_load_slot((int)luaL_checkinteger(L,1), luaL_checkstring(L,2))); return 1;
}
static int l_local_unload_slot(lua_State *L) { demod_local_unload_slot((int)luaL_checkinteger(L,1)); return 0; }
static int l_local_swap(lua_State *L) { demod_local_swap((int)luaL_checkinteger(L,1),(int)luaL_checkinteger(L,2)); return 0; }

/* dm.local_scope(max) -> {L=..}, {R=..}, n */
static int l_local_scope(lua_State *L) {
    int max = (int)luaL_optinteger(L, 1, 256);
    if (max > 2048) max = 2048;
    static float Lb[2048], Rb[2048];
    int n = demod_local_scope(Lb, Rb, max);
    lua_newtable(L);
    for (int i = 0; i < n; i++) { lua_pushnumber(L, Lb[i]); lua_rawseti(L, -2, i+1); }
    lua_newtable(L);
    for (int i = 0; i < n; i++) { lua_pushnumber(L, Rb[i]); lua_rawseti(L, -2, i+1); }
    lua_pushinteger(L, n);
    return 3;
}
static int l_local_meters(lua_State *L) {
    lua_pushnumber(L, demod_local_cpu());
    lua_pushinteger(L, demod_local_xruns());
    return 2;
}
#endif /* DEMOD_LOCAL_DSP */

#ifdef DEMOD_STEAM
/* ── dm.steam.* — Steamworks runtime (Steam edition; STEAM=1) ──────────────
 * Wraps the C-ABI shim (src/steam/steam_shim.cpp → libsteam_api.so). DLC
 * ownership is the entitlement authority and Workshop is the free patch channel.
 * Registered only in Steam builds; steam.lua no-ops when dm.steam is absent. */
#include "demod/steam_api_shim.h"

static int l_steam_init(lua_State *L)          { lua_pushboolean(L, demod_steam_init()); return 1; }
static int l_steam_available(lua_State *L)     { lua_pushboolean(L, demod_steam_available()); return 1; }
static int l_steam_run_callbacks(lua_State *L) { (void)L; demod_steam_run_callbacks(); return 0; }

/* dm.steam.app_id() -> integer|nil (nil when unknown so steam.lua can degrade) */
static int l_steam_app_id(lua_State *L) {
    uint32_t id = demod_steam_app_id();
    if (id == 0) { lua_pushnil(L); } else { lua_pushinteger(L, (lua_Integer)id); }
    return 1;
}
static int l_steam_dlc_owned(lua_State *L) {
    /* accept the appid as string (home.lua passes manifest strings) or number;
     * luaL_checkstring coerces a numeric arg, strtoul handles both. */
    uint32_t appid = (uint32_t)strtoul(luaL_checkstring(L, 1), NULL, 10);
    lua_pushboolean(L, demod_steam_dlc_owned(appid));
    return 1;
}
static int l_steam_overlay_url(lua_State *L) {
    lua_pushboolean(L, demod_steam_overlay_url(luaL_checkstring(L, 1)));
    return 1;
}

/* Push a Lua array of {id,title,installed,install_path,state} tables from a
 * (count, get) shim pair. id is pushed as a STRING (PublishedFileId_t is 64-bit;
 * a Lua number can't hold it losslessly and steam.lua passes it straight back). */
static void push_ws_list(lua_State *L,
                         int (*count)(void),
                         int (*get)(int, demod_steam_ws_item *)) {
    int n = count();
    lua_newtable(L);
    int row = 0;
    for (int i = 0; i < n; i++) {
        demod_steam_ws_item it;
        if (!get(i, &it)) continue;
        lua_newtable(L);
        char idbuf[24];
        snprintf(idbuf, sizeof(idbuf), "%llu", (unsigned long long)it.id);
        lua_pushstring(L, idbuf);                       lua_setfield(L, -2, "id");
        lua_pushstring(L, it.title ? it.title : "");     lua_setfield(L, -2, "title");
        lua_pushboolean(L, it.installed);                lua_setfield(L, -2, "installed");
        lua_pushstring(L, it.install_path ? it.install_path : ""); lua_setfield(L, -2, "install_path");
        lua_pushinteger(L, (lua_Integer)it.state);       lua_setfield(L, -2, "state");
        lua_rawseti(L, -2, ++row);
    }
}

static int l_steam_workshop_subscribed(lua_State *L) {
    push_ws_list(L, demod_steam_ws_subscribed_count, demod_steam_ws_subscribed_get);
    return 1;
}
static int l_steam_workshop_featured(lua_State *L) {
    push_ws_list(L, demod_steam_ws_featured_count, demod_steam_ws_featured_get);
    return 1;
}

/* accept the id as string (preferred) or number; strtoull handles both. */
static uint64_t steam_check_id(lua_State *L, int idx) {
    return (uint64_t)strtoull(luaL_checkstring(L, idx), NULL, 10);
}
static int l_steam_workshop_subscribe(lua_State *L) {
    lua_pushboolean(L, demod_steam_ws_subscribe(steam_check_id(L, 1)));
    return 1;
}
static int l_steam_workshop_unsubscribe(lua_State *L) {
    lua_pushboolean(L, demod_steam_ws_unsubscribe(steam_check_id(L, 1)));
    return 1;
}

static const luaL_Reg steam_funcs[] = {
    {"init",                l_steam_init},
    {"available",           l_steam_available},
    {"run_callbacks",       l_steam_run_callbacks},
    {"app_id",              l_steam_app_id},
    {"dlc_owned",           l_steam_dlc_owned},
    {"overlay_url",         l_steam_overlay_url},
    {"workshop_subscribed", l_steam_workshop_subscribed},
    {"workshop_featured",   l_steam_workshop_featured},
    {"workshop_subscribe",  l_steam_workshop_subscribe},
    {"workshop_unsubscribe",l_steam_workshop_unsubscribe},
    {NULL, NULL}
};
#endif /* DEMOD_STEAM */

static int l_time(lua_State *L) {
    lua_pushnumber(L, get_app(L)->time);
    return 1;
}

static int l_dt(lua_State *L) {
    lua_pushnumber(L, get_app(L)->dt);
    return 1;
}

static int l_mouse_x(lua_State *L) {
    lua_pushinteger(L, get_app(L)->mouse_x);
    return 1;
}

static int l_mouse_y(lua_State *L) {
    lua_pushinteger(L, get_app(L)->mouse_y);
    return 1;
}

static int l_width(lua_State *L) {
    lua_pushinteger(L, get_app(L)->fb->width);
    return 1;
}

static int l_height(lua_State *L) {
    lua_pushinteger(L, get_app(L)->fb->height);
    return 1;
}

/* ══════════════════════════════════════════════════════════════════════
 *  dm.draw.* — Direct framebuffer drawing from Lua
 * ══════════════════════════════════════════════════════════════════════ */

static int ld_rect(lua_State *L) {
    DmApp *app = get_app(L);
    DmRect r = {(int)luaL_checkinteger(L,1), (int)luaL_checkinteger(L,2),
                (int)luaL_checkinteger(L,3), (int)luaL_checkinteger(L,4)};
    DmColor c = read_color(L, 5);
    dm_fb_fill_rect(app->fb, r, c);
    return 0;
}

static int ld_circle(lua_State *L) {
    DmApp *app = get_app(L);
    int cx = (int)luaL_checkinteger(L,1);
    int cy = (int)luaL_checkinteger(L,2);
    int rad = (int)luaL_checkinteger(L,3);
    DmColor c = read_color(L, 4);
    dm_fb_fill_circle(app->fb, cx, cy, rad, c);
    return 0;
}

static int ld_line(lua_State *L) {
    DmApp *app = get_app(L);
    int x0 = (int)luaL_checkinteger(L,1), y0 = (int)luaL_checkinteger(L,2);
    int x1 = (int)luaL_checkinteger(L,3), y1 = (int)luaL_checkinteger(L,4);
    DmColor c = read_color(L, 5);
    dm_fb_line(app->fb, x0, y0, x1, y1, c);
    return 0;
}

/* dm.draw.text(x, y, str, r, g, b [, a [, scale]]) — scale is an integer
   font multiplier (1 = native 8x16); crisp resolution-independent text. */
static int ld_text(lua_State *L) {
    DmApp *app = get_app(L);
    int x = (int)luaL_checkinteger(L,1), y = (int)luaL_checkinteger(L,2);
    const char *text = luaL_checkstring(L, 3);
    DmColor c = read_color(L, 4);
    int scale = (int)luaL_optinteger(L, 8, 1);
    if (scale < 1) scale = 1;
    dm_fb_draw_text_scaled(app->fb, dm_font_default(), x, y, text, c, scale);
    return 0;
}

/* dm.draw.text_width(str [, scale]) -> pixel width of the string.
   UTF-8-correct: fullwidth (CJK) glyphs count 16 px, halfwidth 8 px. This is
   the single source of truth for text measurement — never use #str * 8. */
static int ld_text_width(lua_State *L) {
    const char *text = luaL_checkstring(L, 1);
    int scale = (int)luaL_optinteger(L, 2, 1);
    if (scale < 1) scale = 1;
    lua_pushinteger(L, dm_font_text_width_scaled(dm_font_default(), text, scale));
    return 1;
}

/* dm.utf8_len(str) -> codepoint count. Forgiving (an invalid byte counts as one
   replacement char), matching exactly what the renderer draws — unlike Lua
   5.4's utf8.len, which returns nil on invalid input. */
static int l_utf8_len(lua_State *L) {
    lua_pushinteger(L, dm_utf8_len(luaL_checkstring(L, 1)));
    return 1;
}

static int ld_gradient_v(lua_State *L) {
    DmApp *app = get_app(L);
    DmRect r = {(int)luaL_checkinteger(L,1), (int)luaL_checkinteger(L,2),
                (int)luaL_checkinteger(L,3), (int)luaL_checkinteger(L,4)};
    DmColor top = read_color(L, 5);
    DmColor bot = {(uint8_t)luaL_checkinteger(L,8),
                   (uint8_t)luaL_checkinteger(L,9),
                   (uint8_t)luaL_checkinteger(L,10), 255};
    dm_fb_fill_rect_gradient_v(app->fb, r, top, bot);
    return 0;
}

/* dm.draw.triangle(x0,y0, x1,y1, x2,y2, r,g,b[,a]) */
static int ld_triangle(lua_State *L) {
    DmApp *app = get_app(L);
    int x0=(int)luaL_checkinteger(L,1), y0=(int)luaL_checkinteger(L,2);
    int x1=(int)luaL_checkinteger(L,3), y1=(int)luaL_checkinteger(L,4);
    int x2=(int)luaL_checkinteger(L,5), y2=(int)luaL_checkinteger(L,6);
    DmColor c = read_color(L, 7);
    dm_fb_fill_triangle(app->fb, x0,y0, x1,y1, x2,y2, c);
    return 0;
}

/* dm.draw.stroke_triangle(x0,y0, x1,y1, x2,y2, r,g,b[,a]) */
static int ld_stroke_triangle(lua_State *L) {
    DmApp *app = get_app(L);
    int x0=(int)luaL_checkinteger(L,1), y0=(int)luaL_checkinteger(L,2);
    int x1=(int)luaL_checkinteger(L,3), y1=(int)luaL_checkinteger(L,4);
    int x2=(int)luaL_checkinteger(L,5), y2=(int)luaL_checkinteger(L,6);
    DmColor c = read_color(L, 7);
    dm_fb_stroke_triangle(app->fb, x0,y0, x1,y1, x2,y2, c);
    return 0;
}

/* dm.draw.sierpinski(x0,y0, x1,y1, x2,y2, depth, fr,fg,fb[,fa], sr,sg,sb[,sa]) */
static int ld_sierpinski(lua_State *L) {
    DmApp *app = get_app(L);
    int x0=(int)luaL_checkinteger(L,1), y0=(int)luaL_checkinteger(L,2);
    int x1=(int)luaL_checkinteger(L,3), y1=(int)luaL_checkinteger(L,4);
    int x2=(int)luaL_checkinteger(L,5), y2=(int)luaL_checkinteger(L,6);
    int depth=(int)luaL_checkinteger(L,7);
    DmColor fill   = read_color(L, 8);
    /* stroke color starts at arg 11 or 12 depending on fill alpha */
    int si = lua_isnoneornil(L, 11) ? 11 : (lua_isnumber(L, 11) ? 11 : 11);
    /* Determine stroke color argument position */
    int has_fill_alpha = lua_isnumber(L, 11) && lua_isnumber(L, 12);
    DmColor stroke;
    if (has_fill_alpha) {
        fill.a = (uint8_t)luaL_checkinteger(L, 11);
        stroke = read_color(L, 12);
    } else {
        stroke = read_color(L, 11);
    }
    dm_fb_sierpinski(app->fb, x0,y0, x1,y1, x2,y2, depth, fill, stroke);
    return 0;
}

/* Simplified: dm.draw.sierpinski2(x0,y0,x1,y1,x2,y2,depth, {fill}, {stroke}) */
/* Uses tables for colors for cleaner Lua API */
static int ld_sierpinski2(lua_State *L) {
    DmApp *app = get_app(L);
    int x0=(int)luaL_checkinteger(L,1), y0=(int)luaL_checkinteger(L,2);
    int x1=(int)luaL_checkinteger(L,3), y1=(int)luaL_checkinteger(L,4);
    int x2=(int)luaL_checkinteger(L,5), y2=(int)luaL_checkinteger(L,6);
    int depth=(int)luaL_checkinteger(L,7);

    /* Read fill color from table at arg 8 */
    DmColor fill = {0,0,0,255}, stroke = {255,255,255,255};
    if (lua_istable(L, 8)) {
        lua_rawgeti(L,8,1); fill.r=(uint8_t)lua_tointeger(L,-1); lua_pop(L,1);
        lua_rawgeti(L,8,2); fill.g=(uint8_t)lua_tointeger(L,-1); lua_pop(L,1);
        lua_rawgeti(L,8,3); fill.b=(uint8_t)lua_tointeger(L,-1); lua_pop(L,1);
        lua_rawgeti(L,8,4);
        if (!lua_isnil(L,-1)) fill.a=(uint8_t)lua_tointeger(L,-1);
        lua_pop(L,1);
    }
    if (lua_istable(L, 9)) {
        lua_rawgeti(L,9,1); stroke.r=(uint8_t)lua_tointeger(L,-1); lua_pop(L,1);
        lua_rawgeti(L,9,2); stroke.g=(uint8_t)lua_tointeger(L,-1); lua_pop(L,1);
        lua_rawgeti(L,9,3); stroke.b=(uint8_t)lua_tointeger(L,-1); lua_pop(L,1);
        lua_rawgeti(L,9,4);
        if (!lua_isnil(L,-1)) stroke.a=(uint8_t)lua_tointeger(L,-1);
        lua_pop(L,1);
    }
    dm_fb_sierpinski(app->fb, x0,y0, x1,y1, x2,y2, depth, fill, stroke);
    return 0;
}

/* dm.draw.sierpinski_glow(x0,y0,x1,y1,x2,y2,depth,{fill},{stroke},{glow},glow_rad) */
static int ld_sierpinski_glow(lua_State *L) {
    DmApp *app = get_app(L);
    int x0=(int)luaL_checkinteger(L,1), y0=(int)luaL_checkinteger(L,2);
    int x1=(int)luaL_checkinteger(L,3), y1=(int)luaL_checkinteger(L,4);
    int x2=(int)luaL_checkinteger(L,5), y2=(int)luaL_checkinteger(L,6);
    int depth=(int)luaL_checkinteger(L,7);

    DmColor fill={0,0,0,255}, stroke={255,255,255,255}, glow={0,245,212,255};
    int glow_rad = 6;

    /* Helper macro to read color table */
    #define READ_CT(idx, col) if(lua_istable(L,idx)){         \
        lua_rawgeti(L,idx,1);col.r=(uint8_t)lua_tointeger(L,-1);lua_pop(L,1); \
        lua_rawgeti(L,idx,2);col.g=(uint8_t)lua_tointeger(L,-1);lua_pop(L,1); \
        lua_rawgeti(L,idx,3);col.b=(uint8_t)lua_tointeger(L,-1);lua_pop(L,1); \
        lua_rawgeti(L,idx,4);if(!lua_isnil(L,-1))col.a=(uint8_t)lua_tointeger(L,-1);lua_pop(L,1);}

    READ_CT(8, fill);
    READ_CT(9, stroke);
    READ_CT(10, glow);
    #undef READ_CT
    if (lua_isnumber(L, 11)) glow_rad = (int)lua_tointeger(L, 11);

    dm_fb_sierpinski_glow(app->fb, x0,y0,x1,y1,x2,y2, depth, fill, stroke, glow, glow_rad);
    return 0;
}

/* dm.draw.thick_line(x0,y0,x1,y1,thickness, r,g,b[,a]) */
static int ld_thick_line(lua_State *L) {
    DmApp *app = get_app(L);
    int x0=(int)luaL_checkinteger(L,1), y0=(int)luaL_checkinteger(L,2);
    int x1=(int)luaL_checkinteger(L,3), y1=(int)luaL_checkinteger(L,4);
    int th=(int)luaL_checkinteger(L,5);
    DmColor c = read_color(L, 6);
    dm_fb_thick_line(app->fb, x0,y0, x1,y1, th, c);
    return 0;
}

/* dm.draw.arrow(x0,y0,x1,y1,head_size,thickness, r,g,b[,a]) */
static int ld_arrow(lua_State *L) {
    DmApp *app = get_app(L);
    int x0=(int)luaL_checkinteger(L,1), y0=(int)luaL_checkinteger(L,2);
    int x1=(int)luaL_checkinteger(L,3), y1=(int)luaL_checkinteger(L,4);
    int hs=(int)luaL_checkinteger(L,5);
    int th=(int)luaL_checkinteger(L,6);
    DmColor c = read_color(L, 7);
    dm_fb_arrow(app->fb, x0,y0, x1,y1, hs, th, c);
    return 0;
}

/* dm.draw.bezier(x0,y0, cx0,cy0, cx1,cy1, x1,y1, segs, r,g,b[,a]) */
static int ld_bezier(lua_State *L) {
    DmApp *app = get_app(L);
    int x0=(int)luaL_checkinteger(L,1),  y0=(int)luaL_checkinteger(L,2);
    int cx0=(int)luaL_checkinteger(L,3), cy0=(int)luaL_checkinteger(L,4);
    int cx1=(int)luaL_checkinteger(L,5), cy1=(int)luaL_checkinteger(L,6);
    int x1=(int)luaL_checkinteger(L,7),  y1=(int)luaL_checkinteger(L,8);
    int segs=(int)luaL_checkinteger(L,9);
    DmColor c = read_color(L, 10);
    dm_fb_bezier(app->fb, x0,y0, cx0,cy0, cx1,cy1, x1,y1, segs, c);
    return 0;
}

/* dm.draw.arrow_bezier(x0,y0,cx0,cy0,cx1,cy1,x1,y1,segs,head,thick, r,g,b[,a]) */
static int ld_arrow_bezier(lua_State *L) {
    DmApp *app = get_app(L);
    int x0=(int)luaL_checkinteger(L,1),  y0=(int)luaL_checkinteger(L,2);
    int cx0=(int)luaL_checkinteger(L,3), cy0=(int)luaL_checkinteger(L,4);
    int cx1=(int)luaL_checkinteger(L,5), cy1=(int)luaL_checkinteger(L,6);
    int x1=(int)luaL_checkinteger(L,7),  y1=(int)luaL_checkinteger(L,8);
    int segs=(int)luaL_checkinteger(L,9);
    int hs=(int)luaL_checkinteger(L,10);
    int th=(int)luaL_checkinteger(L,11);
    DmColor c = read_color(L, 12);
    dm_fb_arrow_bezier(app->fb, x0,y0, cx0,cy0, cx1,cy1, x1,y1, segs, hs, th, c);
    return 0;
}

/* dm.draw.blit(x, y, w, h, rgba_string[, alpha]) — Blit raw RGBA pixel data.
   rgba_string must be w*h*4 bytes long (R,G,B,A per pixel).
   Converts to ARGB8888 native framebuffer format and blends onto screen. */
static int ld_blit(lua_State *L) {
    DmApp *app = get_app(L);
    int x = (int)luaL_checkinteger(L, 1);
    int y = (int)luaL_checkinteger(L, 2);
    int w = (int)luaL_checkinteger(L, 3);
    int h = (int)luaL_checkinteger(L, 4);
    size_t len;
    const char *data = luaL_checklstring(L, 5, &len);
    uint8_t alpha = (uint8_t)luaL_optinteger(L, 6, 255);
    size_t needed = (size_t)(w * h * 4);
    if (len < needed)
        return luaL_error(L, "blit: data too short (need %zu, got %zu)", needed, len);

    uint32_t *pixels = (uint32_t *)malloc(w * h * sizeof(uint32_t));
    if (!pixels) return luaL_error(L, "blit: out of memory");

    /* Convert RGBA string bytes → ARGB8888 uint32_t */
    for (int i = 0; i < w * h; i++) {
        uint8_t r = data[i * 4];
        uint8_t g = data[i * 4 + 1];
        uint8_t b = data[i * 4 + 2];
        uint8_t a = data[i * 4 + 3];
        pixels[i] = ((uint32_t)a << 24) | ((uint32_t)r << 16) | ((uint32_t)g << 8) | (uint32_t)b;
    }

    DmFramebuffer *src = dm_fb_wrap(pixels, w, h, w);
    dm_fb_blit_alpha(app->fb, src, x, y, alpha);
    dm_fb_destroy(src);  /* frees DmFramebuffer struct, not pixels (owns_buffer=false) */
    free(pixels);
    return 0;
}

/* dm.viz(id) - system visualization widget */
static int l_viz(lua_State *L) {
    const char *id = luaL_checkstring(L, 1);
    push_widget(L, dm_viz_create(id));
    return 1;
}

/* dm.control(id) - encoder-native control panel */
static int l_control(lua_State *L) {
    const char *id = luaL_checkstring(L, 1);
    push_widget(L, dm_control_create(id));
    return 1;
}

/* dm.viz_add_item(viz_widget, {type=..., ...}) */
static int l_viz_add_item(lua_State *L) {
    DmWidget *w = lua_touserdata(L, 1);
    if (!w) return 0;

    DmVizItem it = {0};
    if (lua_istable(L, 2)) {
        lua_getfield(L,2,"type"); const char *t = lua_tostring(L,-1); lua_pop(L,1);
        it.type = (t && strcmp(t,"card")==0) ? DM_VIZ_CARD : DM_VIZ_NODE;

        lua_getfield(L,2,"id");     strncpy(it.id, lua_tostring(L,-1) ? : "", 31); lua_pop(L,1);
        lua_getfield(L,2,"label");  strncpy(it.label, lua_tostring(L,-1) ? : "", 63); lua_pop(L,1);
        lua_getfield(L,2,"layer");  it.layer = lua_tointeger(L,-1); lua_pop(L,1);
        lua_getfield(L,2,"status"); strncpy(it.status, lua_tostring(L,-1) ? : "", 15); lua_pop(L,1);

        if (it.type == DM_VIZ_NODE) {
            lua_getfield(L,2,"x"); it.x = lua_tointeger(L,-1); lua_pop(L,1);
            lua_getfield(L,2,"y"); it.y = lua_tointeger(L,-1); lua_pop(L,1);
            lua_getfield(L,2,"depth"); it.depth = lua_tointeger(L,-1); lua_pop(L,1);
        } else {
            lua_getfield(L,2,"subtitle"); strncpy(it.subtitle, lua_tostring(L,-1) ? : "", 63); lua_pop(L,1);
        }
    }
    dm_viz_add_item(w, &it);
    return 0;
}

/* dm.control_add_item(control_widget, {type=..., ...}) */
static int l_control_add_item(lua_State *L) {
    DmWidget *w = lua_touserdata(L, 1);
    if (!w) return 0;

    DmVizItem it = {0};
    if (lua_istable(L, 2)) {
        lua_getfield(L,2,"id");     strncpy(it.id, lua_tostring(L,-1) ? : "", 31); lua_pop(L,1);
        lua_getfield(L,2,"label");  strncpy(it.label, lua_tostring(L,-1) ? : "", 63); lua_pop(L,1);
        lua_getfield(L,2,"subtitle"); strncpy(it.subtitle, lua_tostring(L,-1) ? : "", 63); lua_pop(L,1);
        lua_getfield(L,2,"status"); strncpy(it.status, lua_tostring(L,-1) ? : "", 15); lua_pop(L,1);
        lua_getfield(L,2,"layer");  it.layer = lua_tointeger(L,-1); lua_pop(L,1);
        it.type = DM_VIZ_CARD;
    }
    /* Note: dm_control_add_item not yet implemented in control_dsl.c - using generic for now */
    dm_control_add_item(w, &it);
    return 0;
}

/* ══════════════════════════════════════════════════════════════════════
 *  dm.crypto.* — Ed25519 verification + SHA-512 (vendored monocypher).
 *  Used by the client for signed-build self-checks and signed entitlement /
 *  install-link verification. Verify-only: there is no signing API on the
 *  client (private keys never ship). RFC-8032 (SHA-512) compatible with the
 *  marketplace backend's standard Ed25519.
 * ══════════════════════════════════════════════════════════════════════ */

/* dm.crypto.ed25519_verify(public_key, message, signature) -> bool
 *   public_key: 32-byte string, signature: 64-byte string, message: any string. */
static int l_crypto_ed25519_verify(lua_State *L) {
    size_t pklen, msglen, siglen;
    const char *pk  = luaL_checklstring(L, 1, &pklen);
    const char *msg = luaL_checklstring(L, 2, &msglen);
    const char *sig = luaL_checklstring(L, 3, &siglen);
    if (pklen != 32 || siglen != 64) {       /* wrong-sized key/sig is never valid */
        lua_pushboolean(L, 0);
        return 1;
    }
    int ok = crypto_ed25519_check((const uint8_t *)sig, (const uint8_t *)pk,
                                  (const uint8_t *)msg, msglen) == 0;
    lua_pushboolean(L, ok);
    return 1;
}

/* dm.crypto.sha512(data) -> lowercase hex string (128 chars) */
static int l_crypto_sha512(lua_State *L) {
    size_t len;
    const char *data = luaL_checklstring(L, 1, &len);
    uint8_t h[64];
    crypto_sha512(h, (const uint8_t *)data, len);
    char hex[129];
    static const char *digits = "0123456789abcdef";
    for (int i = 0; i < 64; i++) {
        hex[i * 2]     = digits[h[i] >> 4];
        hex[i * 2 + 1] = digits[h[i] & 0x0f];
    }
    hex[128] = '\0';
    lua_pushlstring(L, hex, 128);
    return 1;
}

static const luaL_Reg crypto_funcs[] = {
    {"ed25519_verify", l_crypto_ed25519_verify},
    {"sha512",         l_crypto_sha512},
    {NULL, NULL}
};

static const luaL_Reg draw_funcs[] = {
    {"rect",             ld_rect},
    {"circle",           ld_circle},
    {"line",             ld_line},
    {"text",             ld_text},
    {"text_width",       ld_text_width},
    {"gradient_v",       ld_gradient_v},
    {"triangle",         ld_triangle},
    {"stroke_triangle",  ld_stroke_triangle},
    {"sierpinski",       ld_sierpinski2},
    {"sierpinski_raw",   ld_sierpinski},
    {"sierpinski_glow",  ld_sierpinski_glow},
    {"thick_line",       ld_thick_line},
    {"arrow",            ld_arrow},
    {"bezier",           ld_bezier},
    {"arrow_bezier",     ld_arrow_bezier},
    /* dm.draw.blit(x, y, w, h, rgba_string[, alpha]) — blit RGBA pixel data from a Lua string */
    {"blit",             ld_blit},
    {NULL, NULL}
};

/* ══════════════════════════════════════════════════════════════════════
 *  Registration
 * ══════════════════════════════════════════════════════════════════════ */

/* ── StreamDB binding (embedded reverse-trie KV store; src/db/streamdb.c) ────
 * Keys and values are Lua strings (binary-safe via explicit lengths). A handle
 * is a full userdata whose __gc flushes + frees the db, so an app that forgets
 * to close still cleans up at lua_close. Reverse-trie ⇒ search matches SUFFIX. */
#define DM_STREAMDB_MT "demod.streamdb"

typedef struct { StreamDB *db; } DmSdbBox;

static StreamDB *sdb_db(lua_State *L, int idx) {
    DmSdbBox *b = (DmSdbBox *)luaL_checkudata(L, idx, DM_STREAMDB_MT);
    if (!b->db) luaL_error(L, "streamdb: handle is closed");
    return b->db;
}

/* dm.streamdb_open(path|nil[, flush_ms]) -> handle | nil,err
 * nil path = in-memory; a path = single-file persistence (flush_ms default 2000). */
static int l_sdb_open(lua_State *L) {
    const char *path = luaL_optstring(L, 1, NULL);
    int flush_ms = (int)luaL_optinteger(L, 2, 2000);
    StreamDB *db = streamdb_init(path, flush_ms);
    if (!db) { lua_pushnil(L); lua_pushstring(L, "streamdb_init failed"); return 2; }
    DmSdbBox *b = (DmSdbBox *)lua_newuserdatauv(L, sizeof(DmSdbBox), 0);
    b->db = db;
    luaL_setmetatable(L, DM_STREAMDB_MT);
    return 1;
}

/* dm.streamdb_insert(h, key, value) -> bool */
static int l_sdb_insert(lua_State *L) {
    StreamDB *db = sdb_db(L, 1);
    size_t klen, vlen;
    const char *key = luaL_checklstring(L, 2, &klen);
    const char *val = luaL_checklstring(L, 3, &vlen);
    lua_pushboolean(L, streamdb_insert(db, (const unsigned char *)key, klen, val, vlen) == STREAMDB_OK);
    return 1;
}

/* dm.streamdb_get(h, key) -> value | nil */
static int l_sdb_get(lua_State *L) {
    StreamDB *db = sdb_db(L, 1);
    size_t klen, vsize = 0;
    const char *key = luaL_checklstring(L, 2, &klen);
    void *val = streamdb_get(db, (const unsigned char *)key, klen, &vsize);
    if (!val) { lua_pushnil(L); return 1; }
    lua_pushlstring(L, (const char *)val, vsize);
    free(val);
    return 1;
}

/* dm.streamdb_delete(h, key) -> bool */
static int l_sdb_delete(lua_State *L) {
    StreamDB *db = sdb_db(L, 1);
    size_t klen;
    const char *key = luaL_checklstring(L, 2, &klen);
    lua_pushboolean(L, streamdb_delete(db, (const unsigned char *)key, klen) == STREAMDB_OK);
    return 1;
}

/* dm.streamdb_search(h, suffix) -> { {key=,value=}, ... }  (reverse-trie suffix match) */
static int l_sdb_search(lua_State *L) {
    StreamDB *db = sdb_db(L, 1);
    size_t slen;
    const char *suffix = luaL_checklstring(L, 2, &slen);
    StreamDBResult *res = streamdb_suffix_search(db, (const unsigned char *)suffix, slen);
    lua_newtable(L);
    int n = 0;
    for (StreamDBResult *r = res; r; r = r->next) {
        lua_newtable(L);
        lua_pushlstring(L, (const char *)r->key, r->key_len);
        lua_setfield(L, -2, "key");
        lua_pushlstring(L, r->value ? (const char *)r->value : "", r->value ? r->value_size : 0);
        lua_setfield(L, -2, "value");
        lua_rawseti(L, -2, ++n);
    }
    streamdb_free_results(res);
    return 1;
}

/* dm.streamdb_flush(h) -> bool (false for in-memory DBs) */
static int l_sdb_flush(lua_State *L) {
    lua_pushboolean(L, streamdb_flush(sdb_db(L, 1)) == STREAMDB_OK);
    return 1;
}

/* dm.streamdb_close(h) — flush + free now (idempotent; also runs on GC).
 * streamdb_shutdown() stops the auto-flush thread promptly so free() doesn't
 * block up to a flush interval joining it. */
static int l_sdb_close(lua_State *L) {
    DmSdbBox *b = (DmSdbBox *)luaL_checkudata(L, 1, DM_STREAMDB_MT);
    if (b->db) { streamdb_shutdown(b->db); streamdb_free(b->db); b->db = NULL; }
    return 0;
}

static int sdb_gc(lua_State *L) {
    DmSdbBox *b = (DmSdbBox *)luaL_checkudata(L, 1, DM_STREAMDB_MT);
    if (b->db) { streamdb_shutdown(b->db); streamdb_free(b->db); b->db = NULL; }
    return 0;
}

static const luaL_Reg dm_funcs[] = {
    {"panel",        l_panel},
    {"label",        l_label},
    {"button",       l_button},
    {"slider",       l_slider},
    {"toggle",       l_toggle},
    {"text_input",   l_text_input},
    {"progress",     l_progress},
    /* DSP widgets */
    {"knob",         l_knob},
    {"vu_meter",     l_vu_meter},
    {"waveform",     l_waveform},
    {"dropdown",     l_dropdown},
    {"scroll_panel", l_scroll_panel},
    {"xy_pad",       l_xy_pad},
    {"viz",          l_viz},
    {"control",      l_control},
    {"viz_add_item", l_viz_add_item},
    {"control_add_item", l_control_add_item},
    /* App */
    {"root",         l_root},
    {"find",         l_find},
    {"redraw",       l_redraw},
    {"quit",         l_quit},
    {"exec",         l_exec},
    {"nav",          l_nav},
    {"encoder_open", l_encoder_open},
    {"encoder_close",l_encoder_close},
    {"midi_open",     l_midi_open},
    {"midi_close",    l_midi_close},
    {"midi_list",     l_midi_list},
    {"midi_out_open", l_midi_out_open},
    {"midi_send",     l_midi_send},
    {"gamepad_map",  l_gamepad_map},
    {"utf8_len",     l_utf8_len},
    /* StreamDB embedded KV store (src/db) */
    {"streamdb_open",   l_sdb_open},
    {"streamdb_insert", l_sdb_insert},
    {"streamdb_get",    l_sdb_get},
    {"streamdb_delete", l_sdb_delete},
    {"streamdb_search", l_sdb_search},
    {"streamdb_flush",  l_sdb_flush},
    {"streamdb_close",  l_sdb_close},
    /* orchestrator IPC (demod5) */
    {"params_read",   l_params_read},
    {"ctl_set_param", l_ctl_set_param},
    {"ctl_bypass",    l_ctl_bypass},
    {"ctl_bpm",       l_ctl_bpm},
    {"ctl_gain",      l_ctl_gain},
    {"ctl",           l_ctl_raw},
    {"local_available", l_local_available},
#ifdef DEMOD_LOCAL_DSP
    {"local_init",        l_local_init},
    {"local_shutdown",    l_local_shutdown},
    {"local_slot_count",  l_local_slot_count},
    {"local_slot",        l_local_slot},
    {"local_param",       l_local_param},
    {"local_set_param",   l_local_set_param},
    {"local_set_bypass",  l_local_set_bypass},
    {"local_set_wet",     l_local_set_wet},
    {"local_load_slot",   l_local_load_slot},
    {"local_unload_slot", l_local_unload_slot},
    {"local_swap",        l_local_swap},
    {"local_scope",       l_local_scope},
    {"local_meters",      l_local_meters},
#endif
    {"time",         l_time},
    {"dt",           l_dt},
    {"mouse_x",      l_mouse_x},
    {"mouse_y",      l_mouse_y},
    {"width",        l_width},
    {"height",       l_height},
    {NULL, NULL}
};

void dm_lua_register(DmApp *app) {
    lua_State *L = app->L;

    /* Store app pointer in registry */
    lua_pushlightuserdata(L, app);
    lua_setfield(L, LUA_REGISTRYINDEX, DM_LUA_APP_KEY);

    /* Create DmWidget metatable */
    luaL_newmetatable(L, DM_WIDGET_MT);
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");
    luaL_setfuncs(L, widget_methods, 0);
    lua_pop(L, 1);

    /* StreamDB handle metatable (__gc flushes + frees the db) */
    luaL_newmetatable(L, DM_STREAMDB_MT);
    lua_pushcfunction(L, sdb_gc);
    lua_setfield(L, -2, "__gc");
    lua_pop(L, 1);

    /* Register dm module */
    luaL_newlib(L, dm_funcs);

    /* dm.draw sub-table */
    luaL_newlib(L, draw_funcs);
    lua_setfield(L, -2, "draw");

    /* dm.crypto sub-table (Ed25519 verify + SHA-512; verify-only) */
    luaL_newlib(L, crypto_funcs);
    lua_setfield(L, -2, "crypto");

#ifdef DEMOD_STEAM
    /* dm.steam sub-table (Steam edition only; STEAM=1). Absent otherwise so
     * steam.lua no-ops on every non-Steam build / the device. */
    luaL_newlib(L, steam_funcs);
    lua_setfield(L, -2, "steam");
#endif

    /* dm.color constants */
    lua_newtable(L);
    #define SET_COLOR(name, r, g, b) \
        lua_newtable(L); \
        lua_pushinteger(L, r); lua_rawseti(L, -2, 1); \
        lua_pushinteger(L, g); lua_rawseti(L, -2, 2); \
        lua_pushinteger(L, b); lua_rawseti(L, -2, 3); \
        lua_setfield(L, -2, name);

    SET_COLOR("turquoise",   0x00, 0xF5, 0xD4)
    SET_COLOR("violet",      0x8B, 0x5C, 0xF6)
    SET_COLOR("black",       0x0A, 0x0A, 0x0F)
    SET_COLOR("dark_gray",   0x1A, 0x1A, 0x2E)
    SET_COLOR("white",       0xE8, 0xE8, 0xF0)
    SET_COLOR("red",         0xFF, 0x4C, 0x6A)
    SET_COLOR("green",       0x4C, 0xFF, 0x82)
    SET_COLOR("yellow",      0xFF, 0xD9, 0x4C)
    #undef SET_COLOR
    lua_setfield(L, -2, "color");

    lua_setglobal(L, "dm");
}

int dm_lua_load_script(DmApp *app, const char *path) {
    if (luaL_dofile(app->L, path) != LUA_OK) {
        fprintf(stderr, "[Lua] Error loading '%s': %s\n",
                path, lua_tostring(app->L, -1));
        lua_pop(app->L, 1);
        return -1;
    }
    return 0;
}
