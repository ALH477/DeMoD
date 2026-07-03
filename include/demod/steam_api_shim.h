// SPDX-License-Identifier: MPL-2.0
/*
 * steam_api_shim.h — C ABI over the Steamworks SDK (C++).
 *
 * Implemented by src/steam/steam_shim.cpp, which wraps steam_api.h
 * (ISteamApps / ISteamUGC / ISteamFriends / ISteamUtils). Compiled into
 * demod-ui only when built with STEAM=1 (it links libsteam_api.so from the
 * out-of-tree Steamworks SDK, DEMOD_STEAM_SDK). When absent, dm.steam is not
 * registered at all and steam.lua no-ops everywhere (mirrors dm.crypto / the
 * LOCAL_DSP shim). Lua side: steam.lua.
 *
 * This is the entitlement authority for the Steam edition: DLC ownership
 * (BIsDlcInstalled) replaces the Ed25519/marketplace gate, and free community
 * patches come from Workshop (ISteamUGC). No off-Steam commerce.
 *
 * Copyright (c) 2026 DeMoD LLC. Licensed under the Mozilla Public License, v. 2.0 (see LICENSE).
 */
#ifndef DEMOD_STEAM_API_SHIM_H
#define DEMOD_STEAM_API_SHIM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ── lifecycle ──────────────────────────────────────────────────────── */
/* SteamAPI_Init(); a steam_appid.txt next to the binary lets it init without
 * launching through the Steam client (dev). Returns 1 on success. Idempotent. */
int  demod_steam_init(void);
/* 1 once init succeeded and the Steam client is reachable. */
int  demod_steam_available(void);
/* Pump Steam callbacks — call once per frame (steam.lua M.run_callbacks). */
void demod_steam_run_callbacks(void);

/* ── identity / ownership ───────────────────────────────────────────── */
/* This app's numeric Steam AppID, or 0 if unknown. */
uint32_t demod_steam_app_id(void);
/* 1 if the given DLC AppID is owned + installed (BIsDlcInstalled). */
int  demod_steam_dlc_owned(uint32_t appid);

/* ── overlay ────────────────────────────────────────────────────────── */
/* Open a web page in the Steam overlay. Returns 1 if dispatched. */
int  demod_steam_overlay_url(const char *url);

/* ── Workshop (ISteamUGC) ───────────────────────────────────────────── */
/* One Workshop item as the Lua layer surfaces it. `install_path` points into a
 * static buffer owned by the shim, valid until the next demod_steam_ws_get. */
typedef struct {
    uint64_t    id;            /* PublishedFileId_t */
    const char *title;         /* may be "" when not yet queried */
    int         installed;     /* k_EItemStateInstalled set */
    const char *install_path;  /* absolute folder, or "" */
    uint32_t    state;         /* raw EItemState bitmask */
} demod_steam_ws_item;

/* Count of the local user's subscribed Workshop items (synchronous). */
int  demod_steam_ws_subscribed_count(void);
/* Fill `out` for subscribed item `i` (0-based). Returns 1 on success. */
int  demod_steam_ws_subscribed_get(int i, demod_steam_ws_item *out);

/* Subscribe / unsubscribe (async dispatch). Returns 1 if the call was issued. */
int  demod_steam_ws_subscribe(uint64_t id);
int  demod_steam_ws_unsubscribe(uint64_t id);

/* Featured/all Workshop items. The first call kicks an async UGC query and
 * returns 0 (cache empty); once it lands, later calls return the cached count.
 * Re-issues the query when the cache is stale. */
int  demod_steam_ws_featured_count(void);
int  demod_steam_ws_featured_get(int i, demod_steam_ws_item *out);

#ifdef __cplusplus
}
#endif
#endif /* DEMOD_STEAM_API_SHIM_H */
