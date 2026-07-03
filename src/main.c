// SPDX-License-Identifier: MPL-2.0
/*
 * DeMoD UI Framework — Main Entry Point
 * Boots the application and hands control to Lua.
 * Copyright (c) 2026 DeMoD LLC.
 * Licensed under the Mozilla Public License, v. 2.0; see LICENSE.
 */
#include "demod/app.h"
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char *argv[]) {
    const char *script = (argc > 1) ? argv[1] : "main.lua";

    int win_w = 1280, win_h = 720;
    /* Optional window size override (handy for headless capture at panel sizes):
       DEMOD_WIN="WxH", or DEMOD_WIDTH / DEMOD_HEIGHT. */
    const char *win_env = getenv("DEMOD_WIN");
    if (win_env && *win_env) {
        int w = 0, h = 0;
        if (sscanf(win_env, "%dx%d", &w, &h) == 2 && w > 0 && h > 0) {
            win_w = w; win_h = h;
        }
    }
    const char *we = getenv("DEMOD_WIDTH");
    const char *he = getenv("DEMOD_HEIGHT");
    if (we && *we && atoi(we) > 0) win_w = atoi(we);
    if (he && *he && atoi(he) > 0) win_h = atoi(he);

    DmAppConfig config = {
        .title      = "DeMoD",
        .width      = win_w,
        .height     = win_h,
        .resizable  = true,
        .fullscreen = false,
        .target_fps = 60,
        .lua_entry  = script,
    };

    DmApp *app = dm_app_create(config);
    if (!app) {
        fprintf(stderr, "Failed to create DeMoD application\n");
        return 1;
    }

    int ret = dm_app_run(app);
    dm_app_destroy(app);
    return ret;
}
