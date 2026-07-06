// SPDX-License-Identifier: MPL-2.0
/*
 * DeMoD UI Framework — Application
 * SDL2 lifecycle, main loop, Lua scripting host.
 * Copyright (c) 2026 DeMoD LLC.
 * Licensed under the Mozilla Public License, v. 2.0; see LICENSE.
 */
#ifndef DEMOD_APP_H
#define DEMOD_APP_H

#include "demod/framebuffer.h"
#include "demod/widget.h"

#include <SDL2/SDL.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DmApp DmApp;
typedef struct DmEncoder DmEncoder;   /* USB serial / Arduino encoder (input.h) */
typedef struct DmGamepad DmGamepad;   /* SDL game controllers (gamepad.h) */
typedef struct DmMidi    DmMidi;      /* MIDI input source (input.h) */
typedef struct DmArContext DmArContext; /* AR passthrough layer (ar.h; DEMOD_AR) */
typedef struct DmPoseSource DmPoseSource; /* 6DOF head-tracking source (ar.h; DEMOD_AR) */

#ifdef DEMOD_XR
/* Present-sink indirection (opt-in, make XR=1): when installed, replaces the
 * default SDL-window present with a custom consumer of the CPU framebuffer —
 * e.g. an OpenXR quad-layer swapchain (src/ar/xr_sink.c). NULL = the SDL path.
 * Kept behind DEMOD_XR so default/ARHUD builds are byte-unchanged. */
typedef struct DmPresentSink {
    void *ctx;
    void (*present)(void *ctx, const DmFramebuffer *fb);
    void (*destroy)(void *ctx);
} DmPresentSink;
#endif

typedef struct {
    const char *title;
    int         width;
    int         height;
    bool        resizable;
    bool        fullscreen;
    int         target_fps;
    int         max_render_height; /* cap the software framebuffer height; the window
                                      stays native and SDL GPU-upscales the texture.
                                      0 = resolve from env DEMOD_MAX_RENDER_HEIGHT or
                                      the built-in default. Keeps high-DPI fill cheap. */
    const char *lua_entry;      /* path to main Lua script (NULL = C-only) */
} DmAppConfig;

struct DmApp {
    SDL_Window     *window;
    SDL_Renderer   *renderer;
    SDL_Texture    *texture;
    DmFramebuffer  *fb;
    DmWidget       *root;
    const DmTheme  *theme;
    lua_State      *L;
    DmEncoder      *encoder;        /* optional hardware encoder (NULL if none) */
    DmGamepad      *gamepad;        /* optional game controllers (NULL if none) */
#define DM_MIDI_MAX_IN 8
    DmMidi         *midi_in[DM_MIDI_MAX_IN]; /* open MIDI input sources (NULL slots) */
    int             midi_out_fd;    /* optional MIDI output fd (-1 if none) */

    DmAppConfig     config;
    bool            running;
    bool            needs_redraw;
    uint64_t        frame_count;
    double          dt;             /* delta time in seconds */
    double          time;           /* total elapsed time */
    int             mouse_x, mouse_y;   /* in framebuffer (logical) space */
    int             window_w, window_h; /* true native window size (>= fb when capped) */
    int             max_render_h;       /* resolved render-height cap (0 = none) */

#ifdef DEMOD_AR
    DmArContext    *ar;             /* AR passthrough layer (NULL unless dm.ar opened) */
    DmPoseSource   *pose;           /* 6DOF head tracking (NULL unless dm.pose opened) */
#endif
#ifdef DEMOD_XR
    DmPresentSink  *present_sink;   /* NULL = default SDL present; else custom sink */
#endif

    /* Main-loop state persisted across dm_app_frame() calls. On native builds
       these are set up once in dm_app_run and consumed by the while-loop's frame
       limiter; on the Emscripten build the loop is driven one frame per
       requestAnimationFrame callback (emscripten_set_main_loop_arg), so this
       per-frame bookkeeping cannot live on dm_app_run's stack. Behaviour is
       byte-identical to the old stack locals on native. */
    Uint64          loop_freq;
    Uint64          loop_last;
    double          loop_target_dt;
    const char     *loop_shot_path;
    long            loop_shot_frame;
    int             loop_shot_quit;
    int             loop_shot_done;
    int             loop_perf_on;
    double          loop_perf_fill, loop_perf_up, loop_perf_pres;
    long            loop_perf_n;
};

/* ── Lifecycle ─────────────────────────────────────────────────────── */

DmApp *dm_app_create(DmAppConfig config);
void   dm_app_destroy(DmApp *app);
int    dm_app_run(DmApp *app);

#ifdef DEMOD_XR
/* Create an OpenXR quad-layer present sink for this app (src/ar/xr_sink.c).
 * Returns NULL if the runtime/headset is unavailable (caller keeps SDL). */
DmPresentSink *dm_xr_sink_create(DmApp *app);
#endif

/* ── Lua Integration ───────────────────────────────────────────────── */

void dm_lua_register(DmApp *app);
int  dm_lua_load_script(DmApp *app, const char *path);

/* ── Input funnel ──────────────────────────────────────────────────────
 * Deliver a semantic nav action ("prev"/"next"/"activate"/"back", or any
 * synonym dm_nav_from_name accepts) to the Lua global on_nav. Any source —
 * keyboard, serial encoder, Lua, MIDI, network — can call this. */
void dm_app_nav(DmApp *app, const char *action);

/* Open/replace the hardware encoder at runtime (baud 0 = 115200).
 * Returns 1 on success, 0 on failure. */
int  dm_app_encoder_open(DmApp *app, const char *path, int baud);
void dm_app_encoder_close(DmApp *app);

/* Add a MIDI input source at runtime (ALSA rawmidi / FIFO / file). Multiple may
 * be open at once (up to DM_MIDI_MAX_IN); re-opening the same path is a no-op.
 * Parsed messages are delivered to the Lua global on_midi(status, data1, data2).
 * Returns 1 on success, 0 on failure/full. */
int  dm_app_midi_open(DmApp *app, const char *path);
/* Close one source by path, or ALL sources when path is NULL/empty. */
void dm_app_midi_close(DmApp *app, const char *path);
/* Open/replace the optional MIDI output (controller feedback). 1 on success. */
int  dm_app_midi_out_open(DmApp *app, const char *path);
/* Send a raw MIDI message on the output (no-op without one). */
void dm_app_midi_send(DmApp *app, unsigned char status,
                      unsigned char d1, unsigned char d2);

/* Remap a game-controller button to a nav action (see demod/gamepad.h). No-op
 * if no controller subsystem. Lets the UI offer a controller-remap settings page. */
void dm_app_gamepad_map(DmApp *app, const char *button, const char *action);

/* ── Utility ───────────────────────────────────────────────────────── */

void dm_app_set_root(DmApp *app, DmWidget *root);
void dm_app_request_redraw(DmApp *app);
DmWidget *dm_app_find_widget(DmApp *app, const char *id);

#ifdef __cplusplus
}
#endif
#endif /* DEMOD_APP_H */
