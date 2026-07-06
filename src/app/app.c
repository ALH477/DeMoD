// SPDX-License-Identifier: MPL-2.0
/*
 * DeMoD UI Framework — Application Implementation
 * SDL2 main loop, event pump, frame present.
 * Copyright (c) 2026 DeMoD LLC.
 * Licensed under the Mozilla Public License, v. 2.0; see LICENSE.
 */
#include "demod/app.h"
#include "demod/input.h"
#include "demod/gamepad.h"
#include "demod/ipc.h"
#ifdef DEMOD_AR
#include "demod/ar.h"            /* AR passthrough layer (make ARHUD=1) */
#endif
#include "../platform/compat.h" /* dm_now_ms — portable monotonic clock */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#ifdef __EMSCRIPTEN__
#include <emscripten.h>  /* emscripten_set_main_loop_arg — browser rAF driver */
#endif

/* Monotonic milliseconds (for the DEMOD_PERF frame-time probe) now comes from
 * platform/compat.h so the same code builds on Linux/macOS/Windows. */

/* ── Logical render resolution ─────────────────────────────────────────
 * Above the cap the software framebuffer renders at a reduced (aspect-
 * preserved) size and SDL upscales the texture to the native window on
 * present (RenderCopy stretches NULL->NULL). This keeps per-frame fill
 * cost bounded on 4K+ displays. At or below the cap it is 1:1. */
static void dm_logical_dims(int win_w, int win_h, int max_h, int *fb_w, int *fb_h) {
    if (max_h > 0 && win_h > max_h) {
        *fb_h = max_h;
        *fb_w = (int)((long)win_w * max_h / win_h);
        if (*fb_w < 1) *fb_w = 1;
    } else {
        *fb_w = win_w;
        *fb_h = win_h;
    }
}

/* ── Semantic nav dispatch ─────────────────────────────────────────────
 * Every input source (keyboard, USB serial encoder, Arduino) funnels into the
 * same four actions and is delivered to the Lua global on_nav(action). One
 * focus field, every input. */
/* Deliver a raw action string to on_nav. Used by enum actions (via dm_nav_name)
 * and by sources that emit extended actions like "wet" (gamepad X, i2c long-press). */
static void dispatch_nav_str(DmApp *app, const char *action) {
    if (!action || !*action) return;
    lua_getglobal(app->L, "on_nav");
    if (lua_isfunction(app->L, -1)) {
        lua_pushstring(app->L, action);
        if (lua_pcall(app->L, 1, 0, 0) != LUA_OK) {
            fprintf(stderr, "[Lua] on_nav error: %s\n", lua_tostring(app->L, -1));
            lua_pop(app->L, 1);
        }
    } else {
        lua_pop(app->L, 1);
    }
    app->needs_redraw = true;
}

static void dispatch_nav(DmApp *app, DmNavAction a) {
    if (a == DM_NAV_NONE) return;
    dispatch_nav_str(app, dm_nav_name(a));
}

/* DmGamepadEmit callback: the gamepad layer hands us action strings. */
static void gamepad_emit(void *ud, const char *action) {
    dispatch_nav_str((DmApp *)ud, action);
}

/* Public funnel: any source can deliver an action by name/synonym. */
void dm_app_nav(DmApp *app, const char *action) {
    if (!app || !action) return;
    dispatch_nav(app, dm_nav_from_name(action));
}

int dm_app_encoder_open(DmApp *app, const char *path, int baud) {
    if (!app) return 0;
    if (app->encoder) { dm_encoder_close(app->encoder); app->encoder = NULL; }
    app->encoder = dm_encoder_open(path, baud);
    return app->encoder != NULL;
}

void dm_app_encoder_close(DmApp *app) {
    if (app && app->encoder) {
        dm_encoder_close(app->encoder);
        app->encoder = NULL;
    }
}

/* Deliver one parsed MIDI message to the Lua global on_midi(status, d1, d2). */
static void dispatch_midi(DmApp *app, unsigned char status,
                          unsigned char d1, unsigned char d2) {
    lua_getglobal(app->L, "on_midi");
    if (lua_isfunction(app->L, -1)) {
        lua_pushinteger(app->L, status);
        lua_pushinteger(app->L, d1);
        lua_pushinteger(app->L, d2);
        if (lua_pcall(app->L, 3, 0, 0) != LUA_OK) {
            fprintf(stderr, "[Lua] on_midi error: %s\n", lua_tostring(app->L, -1));
            lua_pop(app->L, 1);
        }
    } else {
        lua_pop(app->L, 1);
    }
    app->needs_redraw = true;
}

#ifdef DEMOD_AR
/* Deliver a 6DOF pose to the Lua global on_pose(x,y,z, qx,qy,qz,qw). */
static void dispatch_pose(DmApp *app, const float p[DM_POSE_FLOATS]) {
    lua_getglobal(app->L, "on_pose");
    if (lua_isfunction(app->L, -1)) {
        for (int i = 0; i < DM_POSE_FLOATS; i++)
            lua_pushnumber(app->L, p[i]);
        if (lua_pcall(app->L, DM_POSE_FLOATS, 0, 0) != LUA_OK) {
            fprintf(stderr, "[Lua] on_pose error: %s\n", lua_tostring(app->L, -1));
            lua_pop(app->L, 1);
        }
    } else {
        lua_pop(app->L, 1);
    }
    app->needs_redraw = true;
}
#endif

int dm_app_midi_open(DmApp *app, const char *path) {
    if (!app || !path || !*path) return 0;
    int free_slot = -1;
    for (int i = 0; i < DM_MIDI_MAX_IN; i++) {
        if (!app->midi_in[i]) {
            if (free_slot < 0) free_slot = i;
        } else if (strcmp(dm_midi_path(app->midi_in[i]), path) == 0) {
            return 1; /* already open — idempotent */
        }
    }
    if (free_slot < 0) return 0; /* full */
    app->midi_in[free_slot] = dm_midi_open(path);
    return app->midi_in[free_slot] != NULL;
}

void dm_app_midi_close(DmApp *app, const char *path) {
    if (!app) return;
    for (int i = 0; i < DM_MIDI_MAX_IN; i++) {
        if (!app->midi_in[i]) continue;
        if (!path || !*path || strcmp(dm_midi_path(app->midi_in[i]), path) == 0) {
            dm_midi_close(app->midi_in[i]);
            app->midi_in[i] = NULL;
        }
    }
}

int dm_app_midi_out_open(DmApp *app, const char *path) {
    if (!app) return 0;
    if (app->midi_out_fd >= 0) { dm_midi_out_close(app->midi_out_fd); app->midi_out_fd = -1; }
    app->midi_out_fd = dm_midi_out_open(path);
    return app->midi_out_fd >= 0;
}

void dm_app_midi_send(DmApp *app, unsigned char status,
                      unsigned char d1, unsigned char d2) {
    if (!app || app->midi_out_fd < 0) return;
    unsigned char buf[3];
    int n = 1;
    buf[0] = status;
    if (status < 0xF8) { /* channel-voice / common: append data bytes */
        unsigned char hi = status & 0xF0;
        int need = (hi == 0xC0 || hi == 0xD0) ? 1 : ((hi >= 0x80 && hi <= 0xE0) ? 2 : 0);
        if (need >= 1) buf[n++] = d1 & 0x7F;
        if (need >= 2) buf[n++] = d2 & 0x7F;
    }
    dm_midi_out_send(app->midi_out_fd, buf, n);
}

void dm_app_gamepad_map(DmApp *app, const char *button, const char *action) {
    if (app && app->gamepad) dm_gamepad_set_action(app->gamepad, button, action);
}

/* Map a keydown to a nav action (DM_NAV_NONE = not a nav key). */
static DmNavAction key_to_nav(SDL_Keycode k, Uint16 mod) {
    switch (k) {
        case SDLK_RIGHT: case SDLK_DOWN:                  return DM_NAV_NEXT;
        case SDLK_LEFT:  case SDLK_UP:                     return DM_NAV_PREV;
        case SDLK_RETURN: case SDLK_KP_ENTER: case SDLK_SPACE:
                                                          return DM_NAV_ACTIVATE;
        case SDLK_ESCAPE: case SDLK_BACKSPACE:            return DM_NAV_BACK;
        case SDLK_TAB:    return (mod & KMOD_SHIFT) ? DM_NAV_TAB_PREV : DM_NAV_TAB;
        case SDLK_PAGEUP:                                 return DM_NAV_TAB_PREV;
        case SDLK_PAGEDOWN:                               return DM_NAV_TAB;
        default:                                          return DM_NAV_NONE;
    }
}

/* ── SDL Event Translation ─────────────────────────────────────────── */

static DmEvent translate_sdl_event(SDL_Event *sdl, DmApp *app) {
    DmEvent e = {0};

    /* SDL reports window-space coords; map to framebuffer (logical) space so
       hit-testing lines up when the framebuffer is capped below the window. */
    const double msx = (app->window_w > 0) ? (double)app->fb->width  / app->window_w : 1.0;
    const double msy = (app->window_h > 0) ? (double)app->fb->height / app->window_h : 1.0;

    switch (sdl->type) {
    case SDL_MOUSEMOTION:
        e.type    = DM_EVENT_MOUSE_MOVE;
        e.mouse.x = (int)(sdl->motion.x * msx);
        e.mouse.y = (int)(sdl->motion.y * msy);
        app->mouse_x = e.mouse.x;
        app->mouse_y = e.mouse.y;
        break;

    case SDL_MOUSEBUTTONDOWN:
        e.type         = DM_EVENT_MOUSE_DOWN;
        e.mouse.x      = (int)(sdl->button.x * msx);
        e.mouse.y      = (int)(sdl->button.y * msy);
        e.mouse.button = sdl->button.button;
        break;

    case SDL_MOUSEBUTTONUP:
        e.type         = DM_EVENT_MOUSE_UP;
        e.mouse.x      = (int)(sdl->button.x * msx);
        e.mouse.y      = (int)(sdl->button.y * msy);
        e.mouse.button = sdl->button.button;
        break;

    case SDL_MOUSEWHEEL:
        e.type      = DM_EVENT_MOUSE_SCROLL;
        e.scroll.x  = app->mouse_x;
        e.scroll.y  = app->mouse_y;
        e.scroll.dx = sdl->wheel.preciseX;
        e.scroll.dy = sdl->wheel.preciseY;
        break;

    case SDL_KEYDOWN:
        e.type          = DM_EVENT_KEY_DOWN;
        e.key.scancode  = sdl->key.keysym.scancode;
        e.key.keycode   = sdl->key.keysym.sym;
        e.key.mod       = sdl->key.keysym.mod;
        e.key.repeat    = sdl->key.repeat != 0;
        break;

    case SDL_KEYUP:
        e.type          = DM_EVENT_KEY_UP;
        e.key.scancode  = sdl->key.keysym.scancode;
        e.key.keycode   = sdl->key.keysym.sym;
        e.key.mod       = sdl->key.keysym.mod;
        break;

    case SDL_TEXTINPUT:
        e.type = DM_EVENT_TEXT_INPUT;
        SDL_strlcpy(e.text.text, sdl->text.text, sizeof(e.text.text));
        break;

    case SDL_WINDOWEVENT:
        if (sdl->window.event == SDL_WINDOWEVENT_SIZE_CHANGED) {
            e.type     = DM_EVENT_RESIZE;
            e.resize.w = sdl->window.data1;
            e.resize.h = sdl->window.data2;
        }
        break;

    default:
        e.type = DM_EVENT_NONE;
        break;
    }
    return e;
}

/* ── Lifecycle ─────────────────────────────────────────────────────── */

DmApp *dm_app_create(DmAppConfig config) {
    DmApp *app = (DmApp *)calloc(1, sizeof(DmApp));
    if (!app) return NULL;

    app->config = config;
    app->midi_out_fd = -1; /* 0 is a valid fd — must not default to calloc's 0 */
    if (config.target_fps <= 0) app->config.target_fps = 60;
    if (config.width <= 0)  app->config.width  = 1280;
    if (config.height <= 0) app->config.height = 720;
    if (!config.title) app->config.title = "DeMoD";

    /* Init SDL */
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_EVENTS) < 0) {
        fprintf(stderr, "[DeMoD] SDL_Init failed: %s\n", SDL_GetError());
        free(app);
        return NULL;
    }

    Uint32 flags = SDL_WINDOW_SHOWN;
    if (config.resizable)  flags |= SDL_WINDOW_RESIZABLE;
    if (config.fullscreen) flags |= SDL_WINDOW_FULLSCREEN_DESKTOP;

    app->window = SDL_CreateWindow(
        app->config.title,
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        app->config.width, app->config.height, flags);
    if (!app->window) {
        fprintf(stderr, "[DeMoD] SDL_CreateWindow failed: %s\n", SDL_GetError());
        SDL_Quit();
        free(app);
        return NULL;
    }

    app->renderer = SDL_CreateRenderer(app->window, -1,
        SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
    if (!app->renderer) {
        /* Fallback to software renderer */
        app->renderer = SDL_CreateRenderer(app->window, -1, SDL_RENDERER_SOFTWARE);
    }

    /* Resolve the render-height cap: explicit env (0 disables) wins, else the
       config field if set, else a sane default for high-DPI desktops. */
    int cap;
    const char *cap_env = getenv("DEMOD_MAX_RENDER_HEIGHT");
    if (cap_env && *cap_env)                  cap = atoi(cap_env);
    else if (app->config.max_render_height > 0) cap = app->config.max_render_height;
    else                                      cap = 1440;
    if (cap < 0) cap = 0;
    app->max_render_h = cap;

    /* Window is native; the framebuffer/texture may be capped below it. */
    app->window_w = app->config.width;
    app->window_h = app->config.height;
    int fb_w, fb_h;
    dm_logical_dims(app->window_w, app->window_h, app->max_render_h, &fb_w, &fb_h);

    app->texture = SDL_CreateTexture(app->renderer,
        SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STREAMING,
        fb_w, fb_h);

    app->fb    = dm_fb_create(fb_w, fb_h);
    app->theme = dm_theme_default();

    /* Create root widget (in framebuffer/logical space) */
    app->root = dm_panel_create("root");
    app->root->bounds = (DmRect){0, 0, fb_w, fb_h};
    DmPanelData *pd = (DmPanelData *)app->root->data;
    pd->draw_bg     = true;
    pd->draw_border = false;
    pd->bg          = app->theme->bg;

    /* Init Lua */
    app->L = luaL_newstate();
    luaL_openlibs(app->L);
    dm_lua_register(app);

    /* Load Lua entry script if specified */
    if (config.lua_entry) {
        if (dm_lua_load_script(app, config.lua_entry) != 0) {
            fprintf(stderr, "[DeMoD] Failed to load Lua script: %s\n", config.lua_entry);
        }
    }

    /* Optional hardware encoder: DEMOD_ENCODER=/dev/ttyACM0[:115200] */
    const char *enc_env = getenv("DEMOD_ENCODER");
    if (enc_env && *enc_env) {
        char path[256]; int baud = 0;
        const char *colon = strrchr(enc_env, ':');
        if (colon && colon != enc_env) {
            size_t n = (size_t)(colon - enc_env);
            if (n >= sizeof(path)) n = sizeof(path) - 1;
            memcpy(path, enc_env, n); path[n] = '\0';
            baud = atoi(colon + 1);
        } else {
            strncpy(path, enc_env, sizeof(path) - 1);
            path[sizeof(path) - 1] = '\0';
        }
        app->encoder = dm_encoder_open(path, baud);
    }

    /* Optional MIDI input: DEMOD_MIDI=/dev/snd/midiC1D0 (ALSA rawmidi), a FIFO,
       or a file. Multiple comma-separated sources may be given. Parsed messages
       reach Lua via on_midi(status, d1, d2). DEMOD_MIDI_OUT opens an output. */
    const char *midi_env = getenv("DEMOD_MIDI");
    if (midi_env && *midi_env) {
        char buf[512];
        strncpy(buf, midi_env, sizeof(buf) - 1);
        buf[sizeof(buf) - 1] = '\0';
        for (char *tok = strtok(buf, ","); tok; tok = strtok(NULL, ",")) {
            while (*tok == ' ') tok++;
            if (*tok) dm_app_midi_open(app, tok);
        }
    }
    const char *midi_out_env = getenv("DEMOD_MIDI_OUT");
    if (midi_out_env && *midi_out_env) {
        app->midi_out_fd = dm_midi_out_open(midi_out_env);
    }

    /* Game controllers (Xbox/PS/generic) → the same nav funnel. Auto-enabled;
       DEMOD_GAMEPAD=0 disables. NULL (headless / no subsystem) is a clean no-op. */
    const char *gp_env = getenv("DEMOD_GAMEPAD");
    if (!(gp_env && gp_env[0] == '0' && gp_env[1] == '\0')) {
        app->gamepad = dm_gamepad_create();
    }

    app->running      = true;
    app->needs_redraw = true;

    SDL_StartTextInput();

    return app;
}

void dm_app_destroy(DmApp *app) {
    if (!app) return;
    demod_params_close();
#ifdef DEMOD_AR
    if (app->ar) dm_ar_close(app->ar);
    if (app->pose) dm_pose_close(app->pose);
#endif
#ifdef DEMOD_XR
    if (app->present_sink && app->present_sink->destroy)
        app->present_sink->destroy(app->present_sink->ctx);
#endif
    if (app->encoder)  dm_encoder_close(app->encoder);
    for (int i = 0; i < DM_MIDI_MAX_IN; i++)
        if (app->midi_in[i]) dm_midi_close(app->midi_in[i]);
    if (app->midi_out_fd >= 0) dm_midi_out_close(app->midi_out_fd);
    if (app->gamepad)  dm_gamepad_destroy(app->gamepad);
    if (app->L)        lua_close(app->L);
    if (app->root)     dm_widget_destroy(app->root);
    if (app->fb)       dm_fb_destroy(app->fb);
    if (app->texture)  SDL_DestroyTexture(app->texture);
    if (app->renderer) SDL_DestroyRenderer(app->renderer);
    if (app->window)   SDL_DestroyWindow(app->window);
    SDL_Quit();
    free(app);
}

/* ── Main Loop ─────────────────────────────────────────────────────── */

/* One iteration of the main loop (everything except the trailing frame
   limiter). Factored out so the Emscripten build can hand it to
   emscripten_set_main_loop_arg (one call per requestAnimationFrame). arg is the
   DmApp*. All per-frame state lives on app->loop_* so it survives across calls;
   native behaviour is byte-identical to the old inline loop body. */
static void dm_app_frame(void *arg) {
    DmApp *app = (DmApp *)arg;
    Uint64 freq = app->loop_freq;

    {
        /* Timing */
        Uint64 now = SDL_GetPerformanceCounter();
        app->dt   = (double)(now - app->loop_last) / (double)freq;
        app->loop_last = now;
        app->time += app->dt;
        app->frame_count++;

        /* Events */
        SDL_Event sdl_e;
        while (SDL_PollEvent(&sdl_e)) {
            if (sdl_e.type == SDL_QUIT) {
                app->running = false;
                break;
            }

            /* Game controllers (hot-plug + discrete buttons) → nav funnel. */
            if (app->gamepad)
                dm_gamepad_handle_event(app->gamepad, &sdl_e, gamepad_emit, app);

            DmEvent e = translate_sdl_event(&sdl_e, app);
            if (e.type == DM_EVENT_NONE) continue;

            /* Handle resize */
            if (e.type == DM_EVENT_RESIZE) {
                app->window_w = e.resize.w;
                app->window_h = e.resize.h;
                int fw, fh;
                dm_logical_dims(app->window_w, app->window_h, app->max_render_h, &fw, &fh);
                dm_fb_resize(app->fb, fw, fh);
                SDL_DestroyTexture(app->texture);
                app->texture = SDL_CreateTexture(app->renderer,
                    SDL_PIXELFORMAT_ARGB8888, SDL_TEXTUREACCESS_STREAMING,
                    fw, fh);
                app->root->bounds = (DmRect){0, 0, fw, fh};
                app->needs_redraw = true;
            }

            /* Dispatch to widget tree */
            dm_widget_dispatch(app->root, &e);
            app->needs_redraw = true;

            /* Keyboard → semantic nav, funnelled to on_nav. Auto-repeat is allowed
               for prev/next (held arrows scrub + accelerate values); activate/back/
               tab stay single-fire. Apps without on_nav simply ignore it. */
            if (e.type == DM_EVENT_KEY_DOWN) {
                DmNavAction a = key_to_nav((SDL_Keycode)e.key.keycode,
                                           (Uint16)e.key.mod);
                if (!e.key.repeat || a == DM_NAV_NEXT || a == DM_NAV_PREV)
                    dispatch_nav(app, a);
            }
        }

        /* Poll the hardware encoder (USB serial / Arduino) → same on_nav. */
        if (app->encoder) {
            DmNavAction a;
            while ((a = dm_encoder_poll(app->encoder)) != DM_NAV_NONE) {
                dispatch_nav(app, a);
            }
        }

        /* Poll every open MIDI input → on_midi(status, d1, d2). */
        for (int i = 0; i < DM_MIDI_MAX_IN; i++) {
            if (!app->midi_in[i]) continue;
            unsigned char st, d1, d2;
            while (dm_midi_poll(app->midi_in[i], &st, &d1, &d2)) {
                dispatch_midi(app, st, d1, d2);
            }
        }

        /* Game controllers: held D-pad/stick → repeating prev/next (scrub + accel). */
        if (app->gamepad) {
            dm_gamepad_update(app->gamepad, app->dt, gamepad_emit, app);
        }

#ifdef DEMOD_AR
        /* AR passthrough: a new camera frame forces a repaint even with no input,
           so the video layer stays live; a stalled source polls false → no spin. */
        if (app->ar && dm_ar_poll(app->ar)) app->needs_redraw = true;
        /* Head tracking: deliver a fresh 6DOF pose to on_pose (same poll cadence). */
        if (app->pose) {
            float pose[DM_POSE_FLOATS];
            if (dm_pose_poll(app->pose, pose)) dispatch_pose(app, pose);
        }
#endif

        /* Call Lua on_update if defined */
        lua_getglobal(app->L, "on_update");
        if (lua_isfunction(app->L, -1)) {
            lua_pushnumber(app->L, app->dt);
            if (lua_pcall(app->L, 1, 0, 0) != LUA_OK) {
                fprintf(stderr, "[Lua] on_update error: %s\n",
                        lua_tostring(app->L, -1));
                lua_pop(app->L, 1);
            }
        } else {
            lua_pop(app->L, 1);
        }

        /* Force a fresh frame on the capture frame so the dump is current. */
        int do_shot = (app->loop_shot_path && !app->loop_shot_done &&
                       (long)app->frame_count >= app->loop_shot_frame);
        if (do_shot) app->needs_redraw = true;

        /* Render */
        if (app->needs_redraw) {
            double pt0 = app->loop_perf_on ? dm_now_ms() : 0.0;
#ifdef DEMOD_AR
            /* Passthrough video is the base layer, replacing the background clear;
               widgets and on_draw paint the HUD on top. Apps that opt into dm.ar
               must keep their root transparent or overlays will hide the feed. */
            if (app->ar && dm_ar_active(app->ar))
                dm_ar_composite_background(app->ar, app->fb);
            else
#endif
                dm_fb_clear(app->fb, app->theme->bg);

            /* Layout pass */
            dm_widget_layout(app->root);
            dm_widget_compute_abs_bounds(app->root, 0, 0);

            /* Draw pass */
            dm_widget_draw(app->root, app->fb, app->theme);

            /* Call Lua on_draw if defined */
            lua_getglobal(app->L, "on_draw");
            if (lua_isfunction(app->L, -1)) {
                if (lua_pcall(app->L, 0, 0, 0) != LUA_OK) {
                    fprintf(stderr, "[Lua] on_draw error: %s\n",
                            lua_tostring(app->L, -1));
                    lua_pop(app->L, 1);
                }
            } else {
                lua_pop(app->L, 1);
            }
            double pt1 = app->loop_perf_on ? dm_now_ms() : 0.0;

            double pt2, pt3;
#ifdef DEMOD_XR
            /* A present sink (e.g. OpenXR quad layer) consumes the CPU
               framebuffer directly, bypassing the SDL window present. */
            if (app->present_sink && app->present_sink->present) {
                app->present_sink->present(app->present_sink->ctx, app->fb);
                pt2 = pt3 = app->loop_perf_on ? dm_now_ms() : 0.0;
            } else
#endif
            {
            /* Present framebuffer to SDL texture */
            void *tex_pixels;
            int   tex_pitch;
            SDL_LockTexture(app->texture, NULL, &tex_pixels, &tex_pitch);
            for (int y = 0; y < app->fb->height; y++) {
                memcpy((uint8_t *)tex_pixels + y * tex_pitch,
                       app->fb->pixels + y * app->fb->stride,
                       app->fb->width * sizeof(uint32_t));
            }
            SDL_UnlockTexture(app->texture);
            pt2 = app->loop_perf_on ? dm_now_ms() : 0.0;

            SDL_RenderClear(app->renderer);
            SDL_RenderCopy(app->renderer, app->texture, NULL, NULL);
            SDL_RenderPresent(app->renderer);
            pt3 = app->loop_perf_on ? dm_now_ms() : 0.0;
            }

            if (app->loop_perf_on) {
                app->loop_perf_fill += pt1 - pt0;
                app->loop_perf_up   += pt2 - pt1;
                app->loop_perf_pres += pt3 - pt2;
                if (++app->loop_perf_n >= 60) {
                    fprintf(stderr,
                        "[DeMoD] perf %dx%d  fill=%.2fms  upload=%.2fms  present=%.2fms  (avg of %ld redraws)\n",
                        app->fb->width, app->fb->height,
                        app->loop_perf_fill / app->loop_perf_n,
                        app->loop_perf_up / app->loop_perf_n,
                        app->loop_perf_pres / app->loop_perf_n, app->loop_perf_n);
                    app->loop_perf_fill = app->loop_perf_up = app->loop_perf_pres = 0;
                    app->loop_perf_n = 0;
                }
            }

            app->needs_redraw = false;
        }

        /* Capture the just-rendered framebuffer, then optionally quit. */
        if (do_shot) {
            dm_fb_write_ppm(app->fb, app->loop_shot_path);
            app->loop_shot_done = 1;
            fprintf(stderr, "[DeMoD] screenshot -> %s (%dx%d, frame %ld)\n",
                    app->loop_shot_path, app->fb->width, app->fb->height,
                    (long)app->frame_count);
            if (app->loop_shot_quit) app->running = false;
        }
    }
}

int dm_app_run(DmApp *app) {
    app->loop_freq      = SDL_GetPerformanceFrequency();
    app->loop_last      = SDL_GetPerformanceCounter();
    app->loop_target_dt = 1.0 / app->config.target_fps;

    /* Headless screenshot: DEMOD_SHOT=<path> dumps the framebuffer as a PPM on
       frame DEMOD_SHOT_FRAME (default 90, ~1.5 s so animation/count-in settles)
       and then quits unless DEMOD_SHOT_QUIT=0. Inert when DEMOD_SHOT is unset. */
    const char *shot_fr_e  = getenv("DEMOD_SHOT_FRAME");
    const char *shot_qt_e  = getenv("DEMOD_SHOT_QUIT");
    app->loop_shot_path  = getenv("DEMOD_SHOT");
    app->loop_shot_frame = (shot_fr_e && *shot_fr_e) ? atol(shot_fr_e) : 90;
    app->loop_shot_quit  = !(shot_qt_e && shot_qt_e[0] == '0' && shot_qt_e[1] == '\0');
    app->loop_shot_done  = 0;

    /* Frame-time probe: DEMOD_PERF=1 logs a rolling average of the render cost,
       split into fill (software rasterize) / upload (fb->texture) / present (GPU
       blit+swap), to decide whether the software path is the bottleneck. */
    const char *perf_env = getenv("DEMOD_PERF");
    app->loop_perf_on = (perf_env && perf_env[0] && !(perf_env[0] == '0' && perf_env[1] == '\0'));
    app->loop_perf_fill = app->loop_perf_up = app->loop_perf_pres = 0;
    app->loop_perf_n = 0;

#ifdef DEMOD_XR
    /* DEMOD_XR=1 routes the framebuffer to an OpenXR headset (quad layer) instead
       of the SDL window. Falls back to SDL if the runtime/headset is absent. */
    {
        const char *xr_env = getenv("DEMOD_XR");
        if (xr_env && xr_env[0] && !(xr_env[0] == '0' && xr_env[1] == '\0'))
            app->present_sink = dm_xr_sink_create(app);
    }
#endif

#ifdef __EMSCRIPTEN__
    /* Browser: hand the loop to requestAnimationFrame (fps 0 = rAF cadence) and
       simulate an infinite loop (1) so the runtime keeps the stack alive. There
       is no frame limiter — rAF paces us — and no teardown (the tab owns it). */
    emscripten_set_main_loop_arg(dm_app_frame, app, 0, 1);
    return 0;
#else
    while (app->running) {
        dm_app_frame(app);

        /* Frame rate limiting. dm_app_frame stamped app->loop_last with this
           frame's start, so measure the work done and sleep the remainder. */
        double elapsed = (double)(SDL_GetPerformanceCounter() - app->loop_last) /
                         (double)app->loop_freq;
        if (elapsed < app->loop_target_dt) {
            SDL_Delay((Uint32)((app->loop_target_dt - elapsed) * 1000.0));
        }
    }

    return 0;
#endif
}

/* ── Utility ───────────────────────────────────────────────────────── */

void dm_app_set_root(DmApp *app, DmWidget *root) {
    if (app->root) dm_widget_destroy(app->root);
    app->root = root;
    app->needs_redraw = true;
}

void dm_app_request_redraw(DmApp *app) {
    app->needs_redraw = true;
}

DmWidget *dm_app_find_widget(DmApp *app, const char *id) {
    return dm_widget_find(app->root, id);
}
