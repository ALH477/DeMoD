// SPDX-License-Identifier: MPL-2.0
/*
 * DeMoD UI Framework — Hardware Input (USB serial / Arduino encoder)
 * A tiny, dependency-free reader that turns a rotary encoder + buttons on a
 * USB-CDC serial port (e.g. an Arduino) into the same semantic "nav" actions
 * the keyboard produces. One focus field, every input.
 * Copyright (c) 2026 DeMoD LLC.
 * Licensed under the Mozilla Public License, v. 2.0; see LICENSE.
 */
#ifndef DEMOD_INPUT_H
#define DEMOD_INPUT_H

#ifdef __cplusplus
extern "C" {
#endif

/* The semantic actions every input source funnels into. */
typedef enum {
    DM_NAV_NONE = 0,
    DM_NAV_PREV,      /* encoder CCW / left / up      */
    DM_NAV_NEXT,      /* encoder CW  / right / down    */
    DM_NAV_ACTIVATE,  /* encoder push / enter / select */
    DM_NAV_BACK,      /* long-press / esc / back button */
    DM_NAV_TAB,       /* tab / next page / next screen */
    DM_NAV_TAB_PREV   /* shift-tab / prev page / prev screen */
} DmNavAction;

typedef struct DmEncoder DmEncoder;

/*
 * Open a serial encoder device (e.g. "/dev/ttyACM0", "/dev/ttyUSB0").
 * baud 0 selects the default (115200). Non-blocking; returns NULL on failure.
 *
 * Wire protocol (single bytes, newline optional — robust + trivial on Arduino):
 *   'R' / '+'  → NEXT      'L' / '-'  → PREV
 *   'S' / 'P'  → ACTIVATE  'B'        → BACK
 * Whitespace and unknown bytes are ignored, so a sketch can also print
 * human-readable debug lines harmlessly.
 */
DmEncoder  *dm_encoder_open(const char *path, int baud);

/* Drain one pending action. Returns DM_NAV_NONE when the buffer is empty.
 * Call in a loop each frame until it returns DM_NAV_NONE. */
DmNavAction dm_encoder_poll(DmEncoder *enc);

void        dm_encoder_close(DmEncoder *enc);

/* Human-readable name for an action ("prev"/"next"/"activate"/"back"). */
const char *dm_nav_name(DmNavAction a);

/* Parse a token/synonym (case-insensitive) into an action — the same lenient
 * vocabulary the serial protocol accepts ("cw","ccw","push","back","+", ...).
 * Lets any interface (Lua, MIDI, network, touch) reach the focus-field funnel.
 * Returns DM_NAV_NONE for unknown tokens. */
DmNavAction dm_nav_from_name(const char *name);

/* ── MIDI input (ALSA rawmidi / any byte source) ───────────────────────────
 * A non-blocking reader that parses a raw MIDI byte stream (running-status
 * aware) into channel-voice messages, delivered to Lua as on_midi(status, d1,
 * d2). System real-time and sysex bytes are filtered out. */
typedef struct DmMidi DmMidi;

/* Open a MIDI byte source: an ALSA rawmidi device ("/dev/snd/midiC1D0"), a
 * FIFO, or a plain file (useful for tests). Non-blocking; NULL on failure. */
DmMidi *dm_midi_open(const char *path);

/* Drain the device, then dequeue one parsed message. Returns 1 and fills the
 * out params when a message is available, else 0. Call in a loop each frame.
 * Transport real-time bytes (clock 0xF8, start 0xFA, continue 0xFB, stop 0xFC)
 * are delivered as messages with d1=d2=0; other real-time/sysex are filtered. */
int     dm_midi_poll(DmMidi *m, unsigned char *status,
                     unsigned char *d1, unsigned char *d2);

void    dm_midi_close(DmMidi *m);

/* The source path this handle was opened with (for dedup / close-by-id). */
const char *dm_midi_path(const DmMidi *m);

/* Enumerate ALSA rawmidi inputs. Fills up to `max` entries, returns the count.
 * `id` is the device path (pass to dm_midi_open); `name` is a friendly label. */
typedef struct { char id[64]; char name[96]; } DmMidiInfo;
int     dm_midi_enumerate(DmMidiInfo *out, int max);

/* Optional MIDI output (controller LED feedback). Write-only rawmidi fd; -1 on
 * failure. dm_midi_out_send writes a raw message; best-effort, non-blocking. */
int     dm_midi_out_open(const char *path);
void    dm_midi_out_send(int fd, const unsigned char *bytes, int n);
void    dm_midi_out_close(int fd);

#ifdef __cplusplus
}
#endif
#endif /* DEMOD_INPUT_H */
