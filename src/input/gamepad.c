// SPDX-License-Identifier: MPL-2.0
/*
 * DeMoD UI Framework — SDL GameController reader.
 * Maps Xbox/PS/generic pads to the semantic nav funnel (see demod/gamepad.h).
 * The button -> action table is data-driven (dm_gamepad_set_action), so the UI
 * can remap it. Held directions stream prev/next so they scrub + accelerate like
 * a held key, following whatever button is bound to move.
 * Copyright (c) 2026 DeMoD LLC. Licensed under the Mozilla Public License, v. 2.0 (see LICENSE).
 */
#include "demod/gamepad.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define DM_GP_MAX 4
#define DM_GP_DEADZONE 16384 /* ~0.5 of a 32767 stick axis */
#define DM_GP_INITIAL_DELAY 0.35 /* s held before auto-repeat begins (precise first step) */
#define DM_GP_REPEAT_INTERVAL 0.05 /* s between repeats once started (~20/s; under U.ACCEL_GAP) */
#define DM_GP_ACTION_LEN 16

struct DmGamepad {
    SDL_GameController *pads[DM_GP_MAX];
    SDL_JoystickID ids[DM_GP_MAX];
    Uint8 btn_prev[DM_GP_MAX][SDL_CONTROLLER_BUTTON_MAX]; /* edge detection per pad */
    int npads;

    /* remappable button -> action (e.g. "activate","back","prev","next","wet"; "" = none) */
    char actions[SDL_CONTROLLER_BUTTON_MAX][DM_GP_ACTION_LEN];

    /* held-direction repeat state for whatever is bound to prev/next (+ left stick) */
    int held_dir; /* -1 = prev, +1 = next, 0 = none */
    double held_accum; /* time since the last emit / since the press began */
    int repeat_started; /* past the initial delay */
};

static void gp_set(DmGamepad *gp, SDL_GameControllerButton b, const char *a) {
    if (b < 0 || b >= SDL_CONTROLLER_BUTTON_MAX) return;
    strncpy(gp->actions[b], a ? a : "", DM_GP_ACTION_LEN - 1);
    gp->actions[b][DM_GP_ACTION_LEN - 1] = '\0';
}

static void gp_set_defaults(DmGamepad *gp) {
    for (int i = 0; i < SDL_CONTROLLER_BUTTON_MAX; i++) gp->actions[i][0] = '\0';
    gp_set(gp, SDL_CONTROLLER_BUTTON_A, "activate");
    gp_set(gp, SDL_CONTROLLER_BUTTON_B, "back");
    gp_set(gp, SDL_CONTROLLER_BUTTON_X, "wet");
    gp_set(gp, SDL_CONTROLLER_BUTTON_DPAD_UP, "prev");
    gp_set(gp, SDL_CONTROLLER_BUTTON_DPAD_DOWN, "next");
    gp_set(gp, SDL_CONTROLLER_BUTTON_DPAD_LEFT, "tab_prev");
    gp_set(gp, SDL_CONTROLLER_BUTTON_DPAD_RIGHT, "tab");
    gp_set(gp, SDL_CONTROLLER_BUTTON_LEFTSHOULDER, "tab_prev");
    gp_set(gp, SDL_CONTROLLER_BUTTON_RIGHTSHOULDER, "tab");
}

void dm_gamepad_set_action(DmGamepad *gp, const char *button, const char *action) {
    if (!gp || !button) return;
    SDL_GameControllerButton b = SDL_GameControllerGetButtonFromString(button);
    if (b == SDL_CONTROLLER_BUTTON_INVALID) return;
    if (action && strcmp(action, "none") == 0) action = "";
    gp_set(gp, b, action);
}

static void gp_open(DmGamepad *gp, int device_index) {
    if (gp->npads >= DM_GP_MAX) return;
    SDL_GameController *c = SDL_GameControllerOpen(device_index);
    if (!c) return;
    gp->pads[gp->npads] = c;
    gp->ids[gp->npads] = SDL_JoystickInstanceID(SDL_GameControllerGetJoystick(c));
    memset(gp->btn_prev[gp->npads], 0, sizeof(gp->btn_prev[gp->npads]));
    gp->npads++;
    const char *name = SDL_GameControllerName(c);
    fprintf(stderr, "[DeMoD] controller connected: %s\n", name ? name : "unknown");
}

static void gp_close_id(DmGamepad *gp, SDL_JoystickID id) {
    for (int i = 0; i < gp->npads; i++) {
        if (gp->ids[i] != id) continue;
        SDL_GameControllerClose(gp->pads[i]);
        for (int j = i; j < gp->npads - 1; j++) {
            gp->pads[j] = gp->pads[j + 1];
            gp->ids[j] = gp->ids[j + 1];
            memcpy(gp->btn_prev[j], gp->btn_prev[j + 1], sizeof(gp->btn_prev[j]));
        }
        gp->npads--;
        gp->held_dir = 0; /* a removed pad shouldn't leave a stuck repeat */
        fprintf(stderr, "[DeMoD] controller disconnected\n");
        return;
    }
}

DmGamepad *dm_gamepad_create(void) {
    if (SDL_InitSubSystem(SDL_INIT_GAMECONTROLLER) != 0) {
        fprintf(stderr, "[DeMoD] gamepad: subsystem unavailable (%s)\n", SDL_GetError());
        return NULL;
    }
#ifndef __EMSCRIPTEN__
    /* No filesystem-backed mapping file in the browser build (MEMFS only; the
       Gamepad API supplies mappings). Native/desktop reads the env-pointed file. */
    const char *cfg = getenv("SDL_GAMECONTROLLERCONFIG_FILE");
    if (cfg && *cfg) SDL_GameControllerAddMappingsFromFile(cfg);
#endif

    DmGamepad *gp = (DmGamepad *)calloc(1, sizeof(*gp));
    if (!gp) {
        SDL_QuitSubSystem(SDL_INIT_GAMECONTROLLER);
        return NULL;
    }
    gp_set_defaults(gp);
    for (int i = 0; i < SDL_NumJoysticks(); i++) {
        if (SDL_IsGameController(i)) gp_open(gp, i);
    }
    return gp;
}

void dm_gamepad_handle_event(DmGamepad *gp, const SDL_Event *e,
                             DmGamepadEmit emit, void *ud) {
    (void)emit;
    (void)ud;
    if (!gp || !e) return;
    /* Buttons are read by polling in dm_gamepad_update; here we only track devices. */
    if (e->type == SDL_CONTROLLERDEVICEADDED)
        gp_open(gp, e->cdevice.which); /* device index */
    else if (e->type == SDL_CONTROLLERDEVICEREMOVED)
        gp_close_id(gp, e->cdevice.which); /* instance id */
}

static int gp_is_dir(const char *a) {
    return a[0] && (strcmp(a, "prev") == 0 || strcmp(a, "next") == 0);
}

/* The current move direction: any held button bound to prev/next, else left stick. */
static int gp_dir(DmGamepad *gp) {
    for (int i = 0; i < gp->npads; i++) {
        SDL_GameController *c = gp->pads[i];
        for (int b = 0; b < SDL_CONTROLLER_BUTTON_MAX; b++) {
            if (!gp_is_dir(gp->actions[b])) continue;
            if (SDL_GameControllerGetButton(c, (SDL_GameControllerButton)b))
                return (strcmp(gp->actions[b], "next") == 0) ? 1 : -1;
        }
        Sint16 y = SDL_GameControllerGetAxis(c, SDL_CONTROLLER_AXIS_LEFTY);
        if (y > DM_GP_DEADZONE) return 1;
        if (y < -DM_GP_DEADZONE) return -1;
    }
    return 0;
}

void dm_gamepad_update(DmGamepad *gp, double dt, DmGamepadEmit emit, void *ud) {
    if (!gp) return;

    /* Edge-emit non-directional buttons (prev/next are owned by the repeat machine). */
    for (int i = 0; i < gp->npads; i++) {
        SDL_GameController *c = gp->pads[i];
        for (int b = 0; b < SDL_CONTROLLER_BUTTON_MAX; b++) {
            Uint8 cur = SDL_GameControllerGetButton(c, (SDL_GameControllerButton)b);
            Uint8 was = gp->btn_prev[i][b];
            gp->btn_prev[i][b] = cur;
            if (cur && !was && gp->actions[b][0] && !gp_is_dir(gp->actions[b]))
                emit(ud, gp->actions[b]);
        }
    }

    /* Held move direction → initial press, then delayed auto-repeat (scrub + accel). */
    int dir = gp_dir(gp);
    if (dir == 0) {
        gp->held_dir = 0;
        gp->held_accum = 0;
        gp->repeat_started = 0;
        return;
    }
    if (dir != gp->held_dir) {
        gp->held_dir = dir;
        gp->held_accum = 0;
        gp->repeat_started = 0;
        emit(ud, dir > 0 ? "next" : "prev");
        return;
    }
    gp->held_accum += dt;
    if (!gp->repeat_started) {
        if (gp->held_accum >= DM_GP_INITIAL_DELAY) {
            gp->repeat_started = 1;
            gp->held_accum = 0;
            emit(ud, dir > 0 ? "next" : "prev");
        }
    } else if (gp->held_accum >= DM_GP_REPEAT_INTERVAL) {
        gp->held_accum = 0;
        emit(ud, dir > 0 ? "next" : "prev");
    }
}

void dm_gamepad_destroy(DmGamepad *gp) {
    if (!gp) return;
    for (int i = 0; i < gp->npads; i++) SDL_GameControllerClose(gp->pads[i]);
    free(gp);
    SDL_QuitSubSystem(SDL_INIT_GAMECONTROLLER);
}
