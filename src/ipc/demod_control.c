// SPDX-License-Identifier: MPL-2.0
/*
 * demod_control.c — JSON-lines client for the orchestrator control socket
 * (/run/demod/control.sock). UI command rate is low, so we connect/send/close
 * per command for robustness (auto-reconnects, survives orchestrator restarts).
 *
 * Matches demod5 orchestrator/src/DeMoD/Control.hs ops:
 *   {"cmd":"set_param","slot":S,"idx":I,"value":V}
 *   {"cmd":"bypass_fx","slot":S,"on":true|false}
 *   {"cmd":"set_bpm","bpm":B}
 *   {"cmd":"set_gain","gain":G}
 *
 * Copyright (c) 2026 DeMoD LLC. Licensed under the Mozilla Public License, v. 2.0 (see LICENSE).
 */
#include "demod/ipc.h"

#ifdef __linux__ /* ── real body: AF_UNIX control socket (orchestrator on device) ── */

#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>

static const char *control_path(void) {
    const char *p = getenv("DEMOD_CONTROL_SOCK");
    return (p && *p) ? p : "/run/demod/control.sock";
}

int demod_control_send_raw(const char *json_line) {
    if (!json_line) return -1;

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, control_path(), sizeof(addr.sun_path) - 1);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }

    /* one command per line */
    size_t len = strlen(json_line);
    char buf[512];
    int n = snprintf(buf, sizeof(buf), "%s\n", json_line);
    int rc = 0;
    if (n > 0 && (size_t)n < sizeof(buf)) {
        ssize_t w = write(fd, buf, (size_t)n);
        rc = (w == n) ? 0 : -1;
    } else {
        /* oversized: write the raw line then a newline */
        ssize_t w = write(fd, json_line, len);
        if (w == (ssize_t)len) { (void)!write(fd, "\n", 1); rc = 0; } else rc = -1;
    }

    /* Wait for the orchestrator's reply line before closing. The control protocol
     * is one JSON reply per command, emitted AFTER the op is applied server-side,
     * so blocking here serializes back-to-back commands: a boot burst of load_fx
     * (each of which restarts demod-rt) no longer races those restarts and drops
     * all-but-one slot. The old MSG_DONTWAIT drain closed before the reply, which
     * is what caused that. Bounded by a recv timeout so a silent/legacy/absent
     * orchestrator can never hang the UI; every real op replies in well under it. */
    if (rc == 0) {
        struct timeval tv = { .tv_sec = 1, .tv_usec = 0 };
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
        char reply[256];
        size_t off = 0;
        for (;;) {
            ssize_t r = recv(fd, reply + off, sizeof(reply) - 1 - off, 0);
            if (r <= 0) break;                      /* EOF, error, or timeout */
            off += (size_t)r;
            reply[off] = '\0';
            if (memchr(reply, '\n', off)) break;    /* got the full reply line */
            if (off >= sizeof(reply) - 1) break;    /* enough to inspect */
        }
        /* Surface an explicit rejection so dm.ctl() returns false to Lua. */
        if (off > 0 && strstr(reply, "\"ok\":false")) rc = -1;
    }

    close(fd);
    return rc;
}

int demod_control_set_param(int slot, int idx, float value) {
    char j[160];
    snprintf(j, sizeof(j),
             "{\"cmd\":\"set_param\",\"slot\":%d,\"idx\":%d,\"value\":%.6g}",
             slot, idx, value);
    return demod_control_send_raw(j);
}

int demod_control_bypass(int slot, int on) {
    char j[96];
    snprintf(j, sizeof(j), "{\"cmd\":\"bypass_fx\",\"slot\":%d,\"on\":%s}",
             slot, on ? "true" : "false");
    return demod_control_send_raw(j);
}

int demod_control_set_bpm(float bpm) {
    char j[64];
    snprintf(j, sizeof(j), "{\"cmd\":\"set_bpm\",\"bpm\":%.6g}", bpm);
    return demod_control_send_raw(j);
}

int demod_control_set_gain(float gain) {
    char j[64];
    snprintf(j, sizeof(j), "{\"cmd\":\"set_gain\",\"gain\":%.6g}", gain);
    return demod_control_send_raw(j);
}

#else /* ── non-Linux stub: no local orchestrator; Lua falls back to remote ── */

int demod_control_send_raw(const char *json_line) { (void)json_line; return -1; }
int demod_control_set_param(int slot, int idx, float value) {
    (void)slot; (void)idx; (void)value; return -1;
}
int demod_control_bypass(int slot, int on) { (void)slot; (void)on; return -1; }
int demod_control_set_bpm(float bpm)  { (void)bpm;  return -1; }
int demod_control_set_gain(float gain) { (void)gain; return -1; }

#endif /* __linux__ */
