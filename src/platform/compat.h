// SPDX-License-Identifier: MPL-2.0
/*
 * DeMoD UI Framework — platform compatibility shim.
 *
 * Abstracts the handful of non-portable calls the remote GUI client needs
 * (BSD sockets, sleep, monotonic clock) so the portable transport (dm_dcf.c)
 * and app loop (app.c) build unchanged on Linux, macOS and Windows.
 *
 * On POSIX this is a thin, zero-overhead pass-through — Linux behavior is
 * byte-identical. On _WIN32 it pulls in Winsock and provides the equivalents.
 *
 * Copyright (c) 2026 DeMoD LLC.
 * Licensed under the Mozilla Public License, v. 2.0; see LICENSE.
 */
#pragma once

#ifdef _WIN32

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN 1
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>

typedef SOCKET dm_socket_t;
#define DM_INVALID_SOCKET INVALID_SOCKET
#define dm_closesocket    closesocket

/* WSAStartup/WSACleanup, ref-counted so open/close pairs nest safely. */
static int g_dm_net_refs = 0;
static inline void dm_net_init(void) {
    if (g_dm_net_refs++ == 0) {
        WSADATA wsa;
        WSAStartup(MAKEWORD(2, 2), &wsa);
    }
}
static inline void dm_net_cleanup(void) {
    if (g_dm_net_refs > 0 && --g_dm_net_refs == 0) {
        WSACleanup();
    }
}

static inline void dm_sleep_ms(unsigned ms) { Sleep(ms); }

static inline double dm_now_ms(void) {
    static LARGE_INTEGER freq = { 0 };
    LARGE_INTEGER now;
    if (freq.QuadPart == 0) QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&now);
    return (double)now.QuadPart * 1000.0 / (double)freq.QuadPart;
}

/* Winsock has no per-call MSG_DONTWAIT; a non-blocking drain must set the
 * socket to non-blocking (ioctlsocket FIONBIO). For compile-compat we map it to
 * 0; the recv then honors SO_RCVTIMEO instead. (Follow-up: FIONBIO in poll.) */
#ifndef MSG_DONTWAIT
#define MSG_DONTWAIT 0
#endif

#else /* POSIX (Linux, macOS) */

#include <sys/socket.h>
#include <netinet/in.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <time.h>

typedef int dm_socket_t;
#define DM_INVALID_SOCKET (-1)
#define dm_closesocket    close

static inline void dm_net_init(void) {}
static inline void dm_net_cleanup(void) {}

static inline void dm_sleep_ms(unsigned ms) { usleep((useconds_t)ms * 1000u); }

static inline double dm_now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec * 1000.0 + (double)t.tv_nsec / 1.0e6;
}

#endif /* _WIN32 */

/* Truthy test for a live socket handle (SOCKET is unsigned on Windows, so a
 * raw >= 0 check is wrong there). */
static inline int dm_socket_valid(dm_socket_t s) { return s != DM_INVALID_SOCKET; }
