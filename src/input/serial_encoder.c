// SPDX-License-Identifier: MPL-2.0
/*
 * DeMoD UI Framework — USB serial / Arduino encoder reader.
 * POSIX termios, non-blocking. Parses a forgiving token protocol into
 * DmNavAction events so it integrates with many encoders/interfaces.
 * No external dependencies.
 * Copyright (c) 2026 DeMoD LLC.
 * Licensed under the Mozilla Public License, v. 2.0; see LICENSE.
 *
 * Wire protocol — deliberately lenient (one focus field, every input):
 *   • Single self-delimiting symbols, no framing needed (low latency):
 *       '+' '>'  → NEXT      '-' '<'  → PREV
 *       '*' '!'  → ACTIVATE  '~' '^'  → BACK
 *   • Whitespace/comma/semicolon-delimited words, case-insensitive (verbose):
 *       NEXT  cw  right down  fwd  r   → NEXT
 *       PREV  ccw left  up    rev  l   → PREV
 *       ACTIVATE select sel ok enter push press click s p → ACTIVATE
 *       BACK  esc cancel long home exit b               → BACK
 *   Unknown bytes are ignored, so a sketch may also print debug text harmlessly.
 *   Works from firmware (Serial.println("CW")), a shell (printf 'cw\n' > dev),
 *   a socat/network bridge, or any other byte source.
 */
#include "demod/input.h"

#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <ctype.h>

/* termios/serial device I/O is POSIX-only (works on Linux + macOS). The token
 * parser below (dm_nav_from_name/dm_nav_name) is pure and stays portable — it
 * is the funnel every input source (Lua, MIDI, network, touch) reaches, so it
 * must be available on Windows too. */
#ifndef _WIN32

#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <termios.h>

#define DM_ENC_RING  256   /* power of two */
#define DM_ENC_TOK   31

struct DmEncoder {
    int          fd;
    DmNavAction  q[DM_ENC_RING];
    int          head, tail;
    char         tok[DM_ENC_TOK + 1];   /* in-progress word token */
    int          toklen;
};

static speed_t baud_to_speed(int baud) {
    switch (baud) {
        case 9600:   return B9600;
        case 19200:  return B19200;
        case 38400:  return B38400;
        case 57600:  return B57600;
        case 115200: return B115200;
        case 230400: return B230400;
        default:     return B115200;
    }
}

#endif /* !_WIN32 */

/* ── Token → action (shared with dm_nav_from_name) ─────────────────────── */

static int ieq(const char *a, const char *b) {
    for (; *a && *b; a++, b++)
        if (tolower((unsigned char)*a) != tolower((unsigned char)*b)) return 0;
    return *a == *b;
}

DmNavAction dm_nav_from_name(const char *t) {
    if (!t || !*t) return DM_NAV_NONE;
    /* single self-delimiting symbols */
    if (!t[1]) {
        switch (t[0]) {
            case '+': case '>':  return DM_NAV_NEXT;
            case '-': case '<':  return DM_NAV_PREV;
            case '*': case '!':  return DM_NAV_ACTIVATE;
            case '~': case '^':  return DM_NAV_BACK;
            default: break;
        }
    }
    static const char *next_w[] = {"next","cw","right","down","fwd","forward","inc","r",0};
    static const char *prev_w[] = {"prev","ccw","left","up","rev","reverse","dec","l",0};
    static const char *act_w[]  = {"activate","select","sel","ok","enter","push","press",
                                   "click","fire","s","p",0};
    static const char *back_w[] = {"back","esc","escape","cancel","long","longpress",
                                   "home","exit","b",0};
    static const char *tab_w[]  = {"tab","screen","screen_next","page","page_next","t",0};
    static const char *tabp_w[] = {"tab_prev","screen_prev","page_prev","shift_tab","y",0};
    for (int i = 0; next_w[i]; i++) if (ieq(t, next_w[i])) return DM_NAV_NEXT;
    for (int i = 0; prev_w[i]; i++) if (ieq(t, prev_w[i])) return DM_NAV_PREV;
    for (int i = 0; act_w[i];  i++) if (ieq(t, act_w[i]))  return DM_NAV_ACTIVATE;
    for (int i = 0; back_w[i]; i++) if (ieq(t, back_w[i])) return DM_NAV_BACK;
    for (int i = 0; tab_w[i];  i++) if (ieq(t, tab_w[i]))  return DM_NAV_TAB;
    for (int i = 0; tabp_w[i]; i++) if (ieq(t, tabp_w[i])) return DM_NAV_TAB_PREV;
    return DM_NAV_NONE;
}

#ifndef _WIN32 /* ── serial device lifecycle (POSIX termios) ── */

static void enc_push(DmEncoder *enc, DmNavAction a) {
    if (a == DM_NAV_NONE) return;
    int next = (enc->head + 1) & (DM_ENC_RING - 1);
    if (next == enc->tail) return;   /* full — drop newest */
    enc->q[enc->head] = a;
    enc->head = next;
}

static void flush_token(DmEncoder *enc) {
    if (enc->toklen == 0) return;
    enc->tok[enc->toklen] = '\0';
    enc_push(enc, dm_nav_from_name(enc->tok));
    enc->toklen = 0;
}

static void feed_byte(DmEncoder *enc, unsigned char c) {
    /* self-delimiting symbols: flush any word, emit immediately */
    if (c=='+'||c=='>'||c=='-'||c=='<'||c=='*'||c=='!'||c=='~'||c=='^') {
        flush_token(enc);
        char s[2] = { (char)c, 0 };
        enc_push(enc, dm_nav_from_name(s));
        return;
    }
    /* delimiters close a word token */
    if (c==' '||c=='\t'||c=='\r'||c=='\n'||c==','||c==';') {
        flush_token(enc);
        return;
    }
    /* accumulate printable word chars (bounded) */
    if (isgraph(c) && enc->toklen < DM_ENC_TOK) {
        enc->tok[enc->toklen++] = (char)c;
    }
    /* overflow / control bytes: ignore */
}

/* ── Lifecycle ─────────────────────────────────────────────────────────── */

DmEncoder *dm_encoder_open(const char *path, int baud) {
    if (!path || !*path) return NULL;

    int fd = open(path, O_RDONLY | O_NOCTTY | O_NONBLOCK);
    if (fd < 0) {
        fprintf(stderr, "[DeMoD] encoder: cannot open %s: %s\n",
                path, strerror(errno));
        return NULL;
    }

    struct termios tio;
    if (tcgetattr(fd, &tio) == 0) {            /* a real tty: set raw + baud */
        cfmakeraw(&tio);
        speed_t sp = baud_to_speed(baud);
        cfsetispeed(&tio, sp);
        cfsetospeed(&tio, sp);
        tio.c_cflag |= (CLOCAL | CREAD);
        tio.c_cc[VMIN]  = 0;
        tio.c_cc[VTIME] = 0;
        tcsetattr(fd, TCSANOW, &tio);
    }
    /* non-tty sources (fifo/socket/file for testing) read fine without termios */

    DmEncoder *enc = (DmEncoder *)calloc(1, sizeof(DmEncoder));
    if (!enc) { close(fd); return NULL; }
    enc->fd = fd;
    fprintf(stderr, "[DeMoD] encoder: listening on %s @ %d baud\n",
            path, baud ? baud : 115200);
    return enc;
}

DmNavAction dm_encoder_poll(DmEncoder *enc) {
    if (!enc) return DM_NAV_NONE;

    unsigned char buf[128];
    for (;;) {
        ssize_t n = read(enc->fd, buf, sizeof(buf));
        if (n > 0) {
            for (ssize_t i = 0; i < n; i++) feed_byte(enc, buf[i]);
            if (n < (ssize_t)sizeof(buf)) break;
        } else if (n == 0) {
            break;
        } else {
            break;   /* EAGAIN or device error: stop draining this frame */
        }
    }

    if (enc->tail == enc->head) return DM_NAV_NONE;
    DmNavAction a = enc->q[enc->tail];
    enc->tail = (enc->tail + 1) & (DM_ENC_RING - 1);
    return a;
}

void dm_encoder_close(DmEncoder *enc) {
    if (!enc) return;
    if (enc->fd >= 0) close(enc->fd);
    free(enc);
}

#else /* ── Windows: no termios/serial; encoder input arrives via other paths ── */

DmEncoder  *dm_encoder_open(const char *path, int baud) {
    (void)path; (void)baud; return NULL;
}
DmNavAction dm_encoder_poll(DmEncoder *enc) { (void)enc; return DM_NAV_NONE; }
void        dm_encoder_close(DmEncoder *enc) { (void)enc; }

#endif /* !_WIN32 */

const char *dm_nav_name(DmNavAction a) {
    switch (a) {
        case DM_NAV_PREV:     return "prev";
        case DM_NAV_NEXT:     return "next";
        case DM_NAV_ACTIVATE: return "activate";
        case DM_NAV_BACK:     return "back";
        case DM_NAV_TAB:      return "tab";
        case DM_NAV_TAB_PREV: return "tab_prev";
        default:              return "none";
    }
}
