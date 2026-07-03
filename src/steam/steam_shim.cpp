// SPDX-License-Identifier: MPL-2.0
/*
 * steam_shim.cpp — C-ABI wrapper around the Steamworks SDK (C++).
 *
 * Built only when STEAM=1 (Makefile). Includes the out-of-tree Steamworks SDK
 * (DEMOD_STEAM_SDK/public on the include path) and links libsteam_api.so. Owns
 * the Steam runtime for the demod-ui Steam edition and exposes a flat C ABI
 * (demod/steam_api_shim.h) the Lua binding calls; mirrors src/dsp/local_dsp_shim.cpp.
 *
 * Ownership model: DLC ownership (ISteamApps::BIsDlcInstalled) is the entitlement
 * authority, Workshop (ISteamUGC) is the free community-patch channel. No off-Steam
 * commerce — overlay links only ever point at Steam's own pages.
 *
 * Copyright (c) 2026 DeMoD LLC. Licensed under the Mozilla Public License, v. 2.0 (see LICENSE).
 */
#include "demod/steam_api_shim.h"

#include <cstring>
#include <string>
#include <vector>

#include "steam/steam_api.h"

namespace {

/* One Workshop item, with owned storage for the strings the C ABI hands back. */
struct WsItem {
    uint64_t    id    = 0;
    std::string title;
    int         installed = 0;
    std::string install_path;
    uint32_t    state = 0;
};

/* Fill a demod_steam_ws_item view over a WsItem (strings borrow the vector entry,
 * which lives as long as the cache isn't rebuilt — matching the header contract). */
void fill_view(const WsItem &it, demod_steam_ws_item *out) {
    out->id           = it.id;
    out->title        = it.title.c_str();
    out->installed    = it.installed;
    out->install_path = it.install_path.c_str();
    out->state        = it.state;
}

/* Resolve install state + path for a published file id into a WsItem. */
WsItem describe_item(PublishedFileId_t id) {
    WsItem it;
    it.id = id;
    ISteamUGC *ugc = SteamUGC();
    if (!ugc) return it;
    uint32 state = ugc->GetItemState(id);
    it.state     = state;
    it.installed = (state & k_EItemStateInstalled) ? 1 : 0;
    if (it.installed) {
        uint64 sizeOnDisk = 0;
        uint32 ts = 0;
        char folder[1024] = {0};
        if (ugc->GetItemInstallInfo(id, &sizeOnDisk, folder, sizeof(folder), &ts))
            it.install_path = folder;
    }
    return it;
}

/* The shim singleton — holds Steam init state + the async featured-query cache and
 * its CCallResult (Steam callbacks need a live object; run_callbacks pumps it). */
class SteamShim {
public:
    bool init() {
        if (m_inited) return true;
        if (!SteamAPI_Init()) return false;   // needs steam_appid.txt or launch via Steam
        m_inited = true;
        return true;
    }
    bool available() const { return m_inited && SteamAPI_IsSteamRunning(); }
    void run_callbacks() { if (m_inited) SteamAPI_RunCallbacks(); }

    /* Featured: kick an async "all UGC, ranked by vote" query for this app; serve the
     * cache once it lands. Re-issues only when idle + cache is empty/stale. */
    int featured_count() {
        if (!available()) return 0;
        if (!m_featuredPending && m_featured.empty())
            issue_featured_query();
        return (int)m_featured.size();
    }
    const std::vector<WsItem> &featured() const { return m_featured; }
    const std::vector<WsItem> &subscribed() {
        rebuild_subscribed();
        return m_subscribed;
    }

private:
    void issue_featured_query() {
        ISteamUGC *ugc = SteamUGC();
        if (!ugc) return;
        AppId_t app = SteamUtils() ? SteamUtils()->GetAppID() : 0;
        if (app == 0) return;
        UGCQueryHandle_t h = ugc->CreateQueryAllUGCRequest(
            k_EUGCQuery_RankedByVote, k_EUGCMatchingUGCType_Items_ReadyToUse,
            app, app, 1);
        if (h == k_UGCQueryHandleInvalid) return;
        SteamAPICall_t call = ugc->SendQueryUGCRequest(h);
        if (call == k_uAPICallInvalid) { ugc->ReleaseQueryUGCRequest(h); return; }
        m_featuredPending = true;
        m_featuredCall.Set(call, this, &SteamShim::on_featured);
    }

    void on_featured(SteamUGCQueryCompleted_t *cb, bool ioFailure) {
        m_featuredPending = false;
        ISteamUGC *ugc = SteamUGC();
        if (!ugc) return;
        m_featured.clear();
        if (!ioFailure && cb->m_eResult == k_EResultOK) {
            for (uint32 i = 0; i < cb->m_unNumResultsReturned; i++) {
                SteamUGCDetails_t d;
                if (!ugc->GetQueryUGCResult(cb->m_handle, i, &d)) continue;
                WsItem it = describe_item(d.m_nPublishedFileId);
                it.title  = d.m_rgchTitle;
                m_featured.push_back(std::move(it));
            }
        }
        ugc->ReleaseQueryUGCRequest(cb->m_handle);
    }

    void rebuild_subscribed() {
        m_subscribed.clear();
        if (!available()) return;
        ISteamUGC *ugc = SteamUGC();
        if (!ugc) return;
        uint32 n = ugc->GetNumSubscribedItems();
        if (n == 0) return;
        std::vector<PublishedFileId_t> ids(n);
        uint32 got = ugc->GetSubscribedItems(ids.data(), n);
        for (uint32 i = 0; i < got; i++)
            m_subscribed.push_back(describe_item(ids[i]));
    }

    bool m_inited = false;
    bool m_featuredPending = false;
    std::vector<WsItem> m_featured;
    std::vector<WsItem> m_subscribed;
    CCallResult<SteamShim, SteamUGCQueryCompleted_t> m_featuredCall;
};

SteamShim g_shim;

} // namespace

extern "C" {

int  demod_steam_init(void)          { return g_shim.init() ? 1 : 0; }
int  demod_steam_available(void)     { return g_shim.available() ? 1 : 0; }
void demod_steam_run_callbacks(void) { g_shim.run_callbacks(); }

uint32_t demod_steam_app_id(void) {
    if (!g_shim.available() || !SteamUtils()) return 0u;
    return (uint32_t)SteamUtils()->GetAppID();
}
int demod_steam_dlc_owned(uint32_t appid) {
    if (!g_shim.available() || !SteamApps()) return 0;
    return SteamApps()->BIsDlcInstalled((AppId_t)appid) ? 1 : 0;
}
int demod_steam_overlay_url(const char *url) {
    if (!url || !*url || !g_shim.available() || !SteamFriends()) return 0;
    SteamFriends()->ActivateGameOverlayToWebPage(url);
    return 1;
}

int demod_steam_ws_subscribed_count(void) {
    return (int)g_shim.subscribed().size();
}
int demod_steam_ws_subscribed_get(int i, demod_steam_ws_item *out) {
    const auto &v = g_shim.subscribed();
    if (!out || i < 0 || (size_t)i >= v.size()) return 0;
    fill_view(v[i], out);
    return 1;
}
int demod_steam_ws_subscribe(uint64_t id) {
    if (!demod_steam_available() || !SteamUGC()) return 0;
    SteamUGC()->SubscribeItem((PublishedFileId_t)id);
    return 1;
}
int demod_steam_ws_unsubscribe(uint64_t id) {
    if (!demod_steam_available() || !SteamUGC()) return 0;
    SteamUGC()->UnsubscribeItem((PublishedFileId_t)id);
    return 1;
}
int demod_steam_ws_featured_count(void) {
    return g_shim.featured_count();
}
int demod_steam_ws_featured_get(int i, demod_steam_ws_item *out) {
    const auto &v = g_shim.featured();
    if (!out || i < 0 || (size_t)i >= v.size()) return 0;
    fill_view(v[i], out);
    return 1;
}

} // extern "C"
