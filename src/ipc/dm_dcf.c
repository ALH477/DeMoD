/* SPDX-License-Identifier: LGPL-3.0-only */
/*
 * dm_dcf.c — dm.dcf.* Lua binding: DCF (HydraMesh/UDP) remote transport client.
 *
 * A small blocking UDP client that lets the UI drive a *remote* engine over
 * UDP instead of the local AF_UNIX control socket + /dev/shm meters. Control
 * ops travel as DCF-Text CTRL fragments; live meter telemetry arrives as a
 * codec_id-16 DCF-Audio block (see the bridge for the writer side). Gated
 * ENTIRELY by DEMOD_DCF (compiled only with DCF=1); dm.dcf is otherwise absent
 * and the Lua backends fall back to the socket path exactly as before.
 *
 * Copyright (C) 2025-2026 DeMoD LLC.
 * Licensed under the GNU Lesser General Public License v3.0 only; see LICENSE.
 */
#define _GNU_SOURCE 1   /* getaddrinfo, recv/sendto flags under -std=c11 */
#include "demod/app.h" /* lua_State + luaL_* (pulls in lua.h/lauxlib.h) */

#include "hydramesh/demod_frame.h"
#include "hydramesh/demod_text.h"
#include "hydramesh/demod_audio.h"

#include "../platform/compat.h" /* dm_socket_t, dm_net_init/cleanup, dm_now_ms */

#include <errno.h>
#include <stdint.h>
#include <string.h>
#include <time.h>

/* ── Wire conventions (must match demod-remote-bridge) ─────────────────── */
#define DCF_UI_SRC_ID      2u   /* this UI node                              */
#define DCF_CTRL_CHAN_ID   1u   /* fixed control-channel dst for ops + ping  */
#define DCF_METERS_CODEC   16u  /* codec_id of the meters telemetry block    */
#define DCF_METERS_MAX_SLOTS 27u

/* ── Module-global single connection ───────────────────────────────────── */
static dm_socket_t      g_sock = DM_INVALID_SOCKET;
static struct sockaddr_in g_peer;
static uint16_t         g_seq      = 0;   /* rolling frame seq                */
static uint16_t         g_text_pid = 0;   /* 6-bit DCF-Text packet id cycle   */
static dcf_audio_reasm_t g_reasm;         /* telemetry reassembly state       */
static int              g_reasm_init = 0;

/* Monotonic clock comes from platform/compat.h (clock_gettime on POSIX,
 * QueryPerformanceCounter on Windows) so this builds on all three OSes. */
static uint32_t dcf_now_us(void) {
    uint64_t us = (uint64_t)(dm_now_ms() * 1000.0);
    return (uint32_t)(us & 0xFFFFFFu); /* 24-bit wire timestamp */
}

static double dcf_now_ms(void) {
    return dm_now_ms();
}

/* ── dm.dcf.open(host, port) -> bool ───────────────────────────────────── */
static int l_dcf_open(lua_State *L) {
    const char *host = luaL_checkstring(L, 1);
    int         port = (int)luaL_checkinteger(L, 2);
    dm_net_init(); /* WSAStartup on Windows; no-op on POSIX (ref-counted) */
    if (dm_socket_valid(g_sock)) { dm_closesocket(g_sock); g_sock = DM_INVALID_SOCKET; }

    char portstr[16];
    snprintf(portstr, sizeof(portstr), "%d", port);
    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family   = AF_INET;
    hints.ai_socktype = SOCK_DGRAM;
    if (getaddrinfo(host, portstr, &hints, &res) != 0 || !res) {
        dm_net_cleanup();
        lua_pushboolean(L, 0);
        return 1;
    }

    dm_socket_t fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (!dm_socket_valid(fd)) {
        freeaddrinfo(res);
        dm_net_cleanup();
        lua_pushboolean(L, 0);
        return 1;
    }

    /* 200 ms recv timeout for the blocking ping path. On Windows SO_RCVTIMEO
     * takes a DWORD of milliseconds, not a struct timeval. */
#ifdef _WIN32
    DWORD tv = 200;
#else
    struct timeval tv = { .tv_sec = 0, .tv_usec = 200000 };
#endif
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, (const char *)&tv, sizeof(tv));

    memcpy(&g_peer, res->ai_addr, sizeof(struct sockaddr_in));
    freeaddrinfo(res);
    g_sock = fd;
    dcf_audio_reasm_init(&g_reasm);
    g_reasm_init = 1;
    lua_pushboolean(L, 1);
    return 1;
}

/* ── dm.dcf.ping() -> rtt_ms | nil ─────────────────────────────────────── */
static int l_dcf_ping(lua_State *L) {
    if (!dm_socket_valid(g_sock)) { lua_pushnil(L); return 1; }

    dcf_frame_t f;
    dcf_frame_init(&f, 1u, DCF_TYPE_CTRL, g_seq++, DCF_UI_SRC_ID, DCF_CTRL_CHAN_ID);
    f.payload[0] = 'P'; f.payload[1] = 'I'; f.payload[2] = 'N'; f.payload[3] = 'G';
    f.timestamp_us = dcf_now_us();
    uint8_t buf[DCF_FRAME_SIZE];
    dcf_frame_encode(&f, buf);

    double t0 = dcf_now_ms();
    if (sendto(g_sock, (const char *)buf, DCF_FRAME_SIZE, 0,
               (struct sockaddr *)&g_peer, sizeof(g_peer)) != (ssize_t)DCF_FRAME_SIZE) {
        lua_pushnil(L);
        return 1;
    }

    /* Read frames until a CTRL 'PONG' arrives or the recv timeout fires.
     * Interleaved telemetry frames are fed to the reassembler so poll() can
     * still surface them. Bound the spin so a silent peer can't hang the UI. */
    for (int i = 0; i < 64; i++) {
        uint8_t rb[DCF_FRAME_SIZE];
        ssize_t n = recv(g_sock, (char *)rb, sizeof(rb), 0);
        if (n != (ssize_t)DCF_FRAME_SIZE) break; /* EOF / error / timeout */
        dcf_frame_t d;
        if (!dcf_frame_decode(rb, &d)) continue;
        if (d.type == DCF_TYPE_CTRL &&
            d.payload[0] == 'P' && d.payload[1] == 'O' &&
            d.payload[2] == 'N' && d.payload[3] == 'G') {
            lua_pushnumber(L, dcf_now_ms() - t0);
            return 1;
        }
        /* not a PONG — it may be a telemetry CTRL frame; keep it. */
        if (g_reasm_init) {
            dcf_audio_packet_t pkt;
            dcf_audio_reasm_push(&g_reasm, rb, &pkt);
        }
    }
    lua_pushnil(L);
    return 1;
}

/* ── dm.dcf.send(op_json) -> bool ──────────────────────────────────────── */
static int l_dcf_send(lua_State *L) {
    size_t      len;
    const char *op = luaL_checklstring(L, 1, &len);
    if (!dm_socket_valid(g_sock)) { lua_pushboolean(L, 0); return 1; }
    if (len > DCF_TEXT_MAX_PAYLOAD) { lua_pushboolean(L, 0); return 1; }

    /* Enough rows for the largest op we accept: descriptor + ceil(len/4). */
    static uint8_t frames[1 + 256][DCF_FRAME_SIZE];
    size_t need = 1u + (len + 3u) / 4u;
    if (need > (1u + 256u)) { lua_pushboolean(L, 0); return 1; }

    uint16_t pid = (uint16_t)(g_text_pid & DCF_TEXT_MAX_PACKETID);
    g_text_pid   = (uint16_t)((g_text_pid + 1u) & DCF_TEXT_MAX_PACKETID);

    size_t nframes = 0;
    if (!dcf_text_packetize((const uint8_t *)op, len, pid, dcf_now_us(),
                            DCF_UI_SRC_ID, DCF_CTRL_CHAN_ID, DCF_TEXT_FLAG_RELIABLE,
                            frames, need, &nframes)) {
        lua_pushboolean(L, 0);
        return 1;
    }

    for (size_t i = 0; i < nframes; i++) {
        if (sendto(g_sock, (const char *)frames[i], DCF_FRAME_SIZE, 0,
                   (struct sockaddr *)&g_peer, sizeof(g_peer)) != (ssize_t)DCF_FRAME_SIZE) {
            lua_pushboolean(L, 0);
            return 1;
        }
    }
    lua_pushboolean(L, 1);
    return 1;
}

/* Decode a codec_id-16 meters block (see the bridge / brief for the layout)
 * into a Lua table on the stack. Returns 1 on success, 0 on a malformed block. */
static int push_meters_table(lua_State *L, const uint8_t *p, size_t len) {
    if (len < 15u) return 0;
    if (p[0] != 1u) return 0;               /* version */
    unsigned n = p[1];                      /* slot_count */
    if (n > DCF_METERS_MAX_SLOTS) return 0;
    if (len < 15u + (size_t)n * 4u) return 0;

    uint8_t  master   = p[3];
    uint16_t mute_mask = (uint16_t)(p[11] | ((uint16_t)p[12] << 8));
    uint16_t solo_mask = (uint16_t)(p[13] | ((uint16_t)p[14] << 8));

    lua_newtable(L);

    lua_newtable(L); /* levels_l */
    for (unsigned i = 0; i < n; i++) {
        lua_pushnumber(L, (double)p[15 + i * 4 + 0] / 255.0);
        lua_rawseti(L, -2, (lua_Integer)(i + 1));
    }
    lua_setfield(L, -2, "levels_l");

    lua_newtable(L); /* levels_r */
    for (unsigned i = 0; i < n; i++) {
        lua_pushnumber(L, (double)p[15 + i * 4 + 1] / 255.0);
        lua_rawseti(L, -2, (lua_Integer)(i + 1));
    }
    lua_setfield(L, -2, "levels_r");

    lua_newtable(L); /* gain (dequantised 0..1.5) */
    for (unsigned i = 0; i < n; i++) {
        lua_pushnumber(L, (double)p[15 + i * 4 + 2] / 255.0 * 1.5);
        lua_rawseti(L, -2, (lua_Integer)(i + 1));
    }
    lua_setfield(L, -2, "gain");

    lua_newtable(L); /* pan (signed -1..1) */
    for (unsigned i = 0; i < n; i++) {
        lua_pushnumber(L, (double)(int8_t)p[15 + i * 4 + 3] / 127.0);
        lua_rawseti(L, -2, (lua_Integer)(i + 1));
    }
    lua_setfield(L, -2, "pan");

    lua_pushinteger(L, (lua_Integer)mute_mask); lua_setfield(L, -2, "mute_mask");
    lua_pushinteger(L, (lua_Integer)solo_mask); lua_setfield(L, -2, "solo_mask");
    lua_pushinteger(L, (lua_Integer)n);         lua_setfield(L, -2, "slot_count");
    lua_pushnumber(L, (double)master / 255.0);  lua_setfield(L, -2, "master");
    /* v1: bpm/pitch/beat/cpu/xruns are placeholders (0) in the block. */
    lua_pushinteger(L, (lua_Integer)(p[4] | ((uint16_t)p[5] << 8))); lua_setfield(L, -2, "bpm");
    lua_pushinteger(L, (lua_Integer)p[9]);      lua_setfield(L, -2, "cpu");
    lua_pushinteger(L, (lua_Integer)p[10]);     lua_setfield(L, -2, "xruns");
    return 1;
}

/* ── dm.dcf.poll() -> meters table | nil ───────────────────────────────── */
static int l_dcf_poll(lua_State *L) {
    if (!dm_socket_valid(g_sock) || !g_reasm_init) { lua_pushnil(L); return 1; }

    /* Non-blocking drain; return the first complete meters block. Any other
     * completed blocks in the same drain are dropped (meters are stateless
     * snapshots — the freshest one wins next frame). */
    for (int i = 0; i < 256; i++) {
        uint8_t rb[DCF_FRAME_SIZE];
        ssize_t n = recv(g_sock, (char *)rb, sizeof(rb), MSG_DONTWAIT);
        if (n != (ssize_t)DCF_FRAME_SIZE) break; /* drained / would-block */
        dcf_frame_t d;
        if (!dcf_frame_decode(rb, &d)) continue;
        /* skip stray ping/pong control frames */
        if (d.type == DCF_TYPE_CTRL &&
            d.payload[0] == 'P' && d.payload[3] == 'G' &&
            (d.payload[1] == 'I' || d.payload[1] == 'O'))
            continue;
        dcf_audio_packet_t pkt;
        if (dcf_audio_reasm_push(&g_reasm, rb, &pkt) == DCF_REASM_PACKET &&
            pkt.codec_id == DCF_METERS_CODEC) {
            if (push_meters_table(L, pkt.payload, pkt.payload_len)) return 1;
        }
    }
    lua_pushnil(L);
    return 1;
}

/* ── dm.dcf.close() ────────────────────────────────────────────────────── */
static int l_dcf_close(lua_State *L) {
    (void)L;
    if (dm_socket_valid(g_sock)) {
        dm_closesocket(g_sock);
        g_sock = DM_INVALID_SOCKET;
        dm_net_cleanup(); /* balances the dm_net_init() from open (WSACleanup) */
    }
    return 0;
}

static const luaL_Reg dcf_funcs[] = {
    {"open",  l_dcf_open},
    {"ping",  l_dcf_ping},
    {"send",  l_dcf_send},
    {"poll",  l_dcf_poll},
    {"close", l_dcf_close},
    {NULL, NULL},
};

/* Registered from dm_lua_register (lua_bindings.c) under #ifdef DEMOD_DCF. */
void dm_dcf_register(lua_State *L) {
    luaL_newlib(L, dcf_funcs);
    lua_setfield(L, -2, "dcf");
}
