// SPDX-License-Identifier: MPL-2.0
/*
 * DeMoD UI Framework — MIDI input reader (ALSA rawmidi / any byte source).
 * Non-blocking, dependency-free. Parses a raw MIDI byte stream (with running
 * status) into channel-voice messages and queues them for the app loop, which
 * delivers each as on_midi(status, data1, data2) to Lua. One focus field, every
 * input — a hardware controller drives the same apps as the encoder/keyboard.
 *
 * Source is anything readable: an ALSA rawmidi device ("/dev/snd/midiC1D0" or,
 * via a helper, "hw:1,0"), a FIFO, or a plain file of bytes (handy for tests).
 *
 * Copyright (c) 2026 DeMoD LLC.
 * Licensed under the Mozilla Public License, v. 2.0; see LICENSE.
 */
#include "demod/input.h"

#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <dirent.h>

#define DM_MIDI_RING 256 /* power of two — queued messages */

typedef struct {
    unsigned char status, d1, d2;
} DmMidiMsg;

struct DmMidi {
    int       fd;
    char      path[96];       /* source path (for dedup / close-by-id / reporting) */
    DmMidiMsg q[DM_MIDI_RING];
    int       head, tail;
    /* running parser state */
    unsigned char run_status; /* last channel-voice status byte (0 = none) */
    unsigned char data[2];
    int           data_have;
    int           data_need;
    int           in_sysex;
};

/* data bytes expected for a channel-voice status byte (high nibble) */
static int voice_data_len(unsigned char status) {
    switch (status & 0xF0) {
        case 0x80: /* note off            */
        case 0x90: /* note on             */
        case 0xA0: /* poly aftertouch     */
        case 0xB0: /* control change      */
        case 0xE0: /* pitch bend          */
            return 2;
        case 0xC0: /* program change      */
        case 0xD0: /* channel aftertouch  */
            return 1;
        default:
            return 0;
    }
}

static void midi_push(DmMidi *m, unsigned char s, unsigned char d1, unsigned char d2) {
    int next = (m->head + 1) & (DM_MIDI_RING - 1);
    if (next == m->tail) return; /* full — drop newest */
    m->q[m->head].status = s;
    m->q[m->head].d1 = d1;
    m->q[m->head].d2 = d2;
    m->head = next;
}

static void midi_feed(DmMidi *m, unsigned char c) {
    if (c & 0x80) { /* status byte */
        if (c >= 0xF8) {
            /* system real-time: single byte, does NOT disturb running status.
               Forward transport-relevant ones (clock 0xF8, start 0xFA, continue
               0xFB, stop 0xFC) as on_midi(status,0,0) so the Lua MIDI subsystem
               can sync to an external clock. Channel-voice consumers that mask
               status & 0xF0 see nibble 0xF0 and harmlessly ignore them. The rest
               (0xF9/0xFD undefined, 0xFE active-sensing, 0xFF reset) are dropped. */
            if (c == 0xF8 || c == 0xFA || c == 0xFB || c == 0xFC) {
                midi_push(m, c, 0, 0);
            }
            return;
        }
        if (c == 0xF0) { m->in_sysex = 1; return; }      /* sysex begin */
        if (c == 0xF7) { m->in_sysex = 0; return; }      /* sysex end   */
        if (c >= 0xF1 && c <= 0xF6) {                    /* system common */
            m->run_status = 0;                           /* cancels running status */
            m->data_need = 0;
            m->data_have = 0;
            return;
        }
        /* channel-voice status */
        m->run_status = c;
        m->data_need  = voice_data_len(c);
        m->data_have  = 0;
        return;
    }
    /* data byte */
    if (m->in_sysex) return;
    if (m->run_status == 0) return; /* no context */
    if (m->data_have < 2) m->data[m->data_have] = c;
    m->data_have++;
    if (m->data_have >= m->data_need) {
        unsigned char d1 = m->data[0];
        unsigned char d2 = (m->data_need == 2) ? m->data[1] : 0;
        midi_push(m, m->run_status, d1, d2);
        m->data_have = 0; /* running status: next bytes are a new message */
    }
}

DmMidi *dm_midi_open(const char *path) {
    if (!path || !*path) return NULL;

    int fd = open(path, O_RDONLY | O_NONBLOCK);
    if (fd < 0) {
        fprintf(stderr, "[DeMoD] midi: cannot open %s: %s\n", path, strerror(errno));
        return NULL;
    }
    DmMidi *m = (DmMidi *)calloc(1, sizeof(DmMidi));
    if (!m) { close(fd); return NULL; }
    m->fd = fd;
    strncpy(m->path, path, sizeof(m->path) - 1);
    m->path[sizeof(m->path) - 1] = '\0';
    fprintf(stderr, "[DeMoD] midi: listening on %s\n", path);
    return m;
}

const char *dm_midi_path(const DmMidi *m) {
    return m ? m->path : "";
}

/* Drain the device into the queue, then dequeue one message. Returns 1 and
 * fills the status/d1/d2 out-params when a message is available, else 0. */
int dm_midi_poll(DmMidi *m, unsigned char *status, unsigned char *d1, unsigned char *d2) {
    if (!m) return 0;

    unsigned char buf[256];
    for (;;) {
        ssize_t n = read(m->fd, buf, sizeof(buf));
        if (n > 0) {
            for (ssize_t i = 0; i < n; i++) midi_feed(m, buf[i]);
            if (n < (ssize_t)sizeof(buf)) break;
        } else {
            break; /* 0 = EOF this frame, <0 = EAGAIN/error: stop draining */
        }
    }

    if (m->tail == m->head) return 0;
    DmMidiMsg msg = m->q[m->tail];
    m->tail = (m->tail + 1) & (DM_MIDI_RING - 1);
    if (status) *status = msg.status;
    if (d1) *d1 = msg.d1;
    if (d2) *d2 = msg.d2;
    return 1;
}

void dm_midi_close(DmMidi *m) {
    if (!m) return;
    if (m->fd >= 0) close(m->fd);
    free(m);
}

/* ── enumeration ───────────────────────────────────────────────────────────
 * Discover ALSA rawmidi devices (/dev/snd/midiC<card>D<dev>) and resolve a
 * friendly card name from /proc/asound/cards. Dependency-free; Linux-only. */

/* Friendly name for ALSA card index `card` from /proc/asound/cards. The format is
 *   " N [shortid        ]: Driver - Long Card Name"
 * We prefer the "Long Card Name" after "- "; fall back to the bracket short id. */
static void card_name(int card, char *out, size_t cap) {
    out[0] = '\0';
    FILE *f = fopen("/proc/asound/cards", "r");
    if (!f) return;
    char line[256];
    while (fgets(line, sizeof(line), f)) {
        int n = -1;
        if (sscanf(line, " %d [", &n) == 1 && n == card) {
            char *dash = strstr(line, "- ");
            if (dash) {
                dash += 2;
                size_t len = strcspn(dash, "\r\n");
                if (len >= cap) len = cap - 1;
                memcpy(out, dash, len);
                out[len] = '\0';
            } else {
                char *lb = strchr(line, '[');
                if (lb) {
                    lb++;
                    size_t len = strcspn(lb, "]");
                    while (len > 0 && lb[len - 1] == ' ') len--; /* trim pad */
                    if (len >= cap) len = cap - 1;
                    memcpy(out, lb, len);
                    out[len] = '\0';
                }
            }
            break;
        }
    }
    fclose(f);
}

int dm_midi_enumerate(DmMidiInfo *out, int max) {
    if (!out || max <= 0) return 0;
    DIR *d = opendir("/dev/snd");
    if (!d) return 0;
    int count = 0;
    struct dirent *e;
    while ((e = readdir(d)) && count < max) {
        int card = -1, dev = -1;
        if (sscanf(e->d_name, "midiC%dD%d", &card, &dev) == 2) {
            snprintf(out[count].id, sizeof(out[count].id), "/dev/snd/%s", e->d_name);
            char name[80];
            card_name(card, name, sizeof(name));
            if (name[0])
                snprintf(out[count].name, sizeof(out[count].name), "%s", name);
            else
                snprintf(out[count].name, sizeof(out[count].name), "MIDI %d:%d", card, dev);
            count++;
        }
    }
    closedir(d);
    return count;
}

/* ── output (controller feedback: pad LEDs etc.) ───────────────────────────
 * A single optional output handle is enough for v1. rawmidi out is write-only. */
int dm_midi_out_open(const char *path) {
    if (!path || !*path) return -1;
    int fd = open(path, O_WRONLY | O_NONBLOCK);
    if (fd < 0) {
        fprintf(stderr, "[DeMoD] midi: cannot open output %s: %s\n", path, strerror(errno));
        return -1;
    }
    fprintf(stderr, "[DeMoD] midi: output on %s\n", path);
    return fd;
}

void dm_midi_out_send(int fd, const unsigned char *bytes, int n) {
    if (fd < 0 || !bytes || n <= 0) return;
    ssize_t w = write(fd, bytes, (size_t)n);
    (void)w; /* best-effort; non-blocking, drop on backpressure */
}

void dm_midi_out_close(int fd) {
    if (fd >= 0) close(fd);
}
