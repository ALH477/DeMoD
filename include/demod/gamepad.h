// SPDX-License-Identifier: MPL-2.0
/*
 * DeMoD UI Framework — Game controller input (SDL GameController).
 * Xbox / PlayStation / generic pads funnel into the same semantic "nav" actions
 * the keyboard and serial encoder produce — one focus field, every input.
 *
 * Default mapping (console-standard; remappable at runtime via dm_gamepad_set_action):
 *   A           -> activate          B            -> back
 *   D-pad Up    -> prev (repeats)    D-pad Down   -> next (repeats)
 *   Left stick  -> prev/next (repeats, mirrors the D-pad)
 *   D-pad L/R, LB/RB -> tab_prev / tab (switch screens)
 *   X           -> wet (secondary action)
 * Holding a direction streams nav at a fixed cadence so list-scrubbing and the
 * Lua hold-to-accelerate (U.accel) work the same as a held key — following whatever
 * button is bound to prev/next.
 *
 * Self-contained and failure-isolated: dm_gamepad_create() returns NULL if the
 * controller subsystem is unavailable (e.g. headless), and every call no-ops on
 * NULL, so a host without controllers is unaffected.
 * Copyright (c) 2026 DeMoD LLC. Licensed under the Mozilla Public License, v. 2.0 (see LICENSE).
 */
#ifndef DEMOD_GAMEPAD_H
#define DEMOD_GAMEPAD_H

#include <SDL2/SDL.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DmGamepad DmGamepad;

/* Called by the gamepad layer to deliver an action string (e.g. "next", "back",
 * "wet") to the focus-field funnel. `ud` is the opaque pointer passed through. */
typedef void (*DmGamepadEmit)(void *ud, const char *action);

/* Initialise the controller subsystem and open any already-connected pads.
 * Returns NULL if the subsystem can't start (headless / no udev) — non-fatal. */
DmGamepad *dm_gamepad_create(void);

/* Process one SDL event: device add/remove (hot-plug) and discrete buttons.
 * Directional held-repeat is handled by dm_gamepad_update, not here. No-op on NULL. */
void dm_gamepad_handle_event(DmGamepad *gp, const SDL_Event *e,
                             DmGamepadEmit emit, void *ud);

/* Per-frame: poll the D-pad/left-stick vertical direction and emit prev/next with
 * an initial-delay-then-repeat cadence (so a held direction scrubs + accelerates).
 * `dt` is the frame time in seconds. No-op on NULL. */
void dm_gamepad_update(DmGamepad *gp, double dt, DmGamepadEmit emit, void *ud);

/* Remap a button to an action. `button` is an SDL controller button name
 * ("a","b","x","y","dpup","dpdown","dpleft","dpright","leftshoulder",
 * "rightshoulder","start","back",…); `action` is a nav action string
 * ("prev","next","activate","back","tab","tab_prev","wet") or "none"/"" to unbind.
 * Unknown buttons are ignored. No-op on NULL. */
void dm_gamepad_set_action(DmGamepad *gp, const char *button, const char *action);

/* Close all pads and shut the subsystem down. No-op on NULL. */
void dm_gamepad_destroy(DmGamepad *gp);

#ifdef __cplusplus
}
#endif
#endif /* DEMOD_GAMEPAD_H */
