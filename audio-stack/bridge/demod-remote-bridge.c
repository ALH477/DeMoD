/* SPDX-License-Identifier: LGPL-3.0-only */
/*
 * demod-remote-bridge.c — engine-side UDP bridge for the DCF remote transport.
 *
 * Lets a *remote* UI (dm.dcf) drive this host's engine over UDP. It is the peer
 * of src/ipc/dm_dcf.c:
 *   • CTRL 'PING'  -> reply CTRL 'PONG' to the sender (rtt probe).
 *   • DCF-Text CTRL/DATA frames -> reassemble a JSON control op, then write it as
 *     one line to the local orchestrator control socket ($DEMOD_CONTROL_SOCK).
 *   • Telemetry loop: every ~33 ms read /dev/shm/demod-rt-meters (seqlock reader,
 *     mirroring src/ipc/demod_rt_meters.c), encode a codec_id-16 meters block, and
 *     dcf_audio_packetize it back to the last peer seen.
 *
 * Links libc only. No engine code is modified; the control-socket connect/write
 * idiom is copied (not shared) from src/ipc/demod_control.c and the seqlock read
 * from src/ipc/demod_rt_meters.c.
 *
 * Copyright (C) 2025-2026 DeMoD LLC.
 * Licensed under the GNU Lesser General Public License v3.0 only; see LICENSE.
 */
#define _GNU_SOURCE 1   /* usleep, ftruncate, sockaddr fields under -std=c11 */
#include "hydramesh/demod_frame.h"
#include "hydramesh/demod_text.h"
#include "hydramesh/demod_audio.h"
#include "demod_rt_meters.h"

#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <netinet/in.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

/* Wire conventions (must match src/ipc/dm_dcf.c). */
#define DCF_BRIDGE_SRC_ID   3u
#define DCF_UI_DST_ID       2u
#define DCF_METERS_CODEC    16u
#define DCF_TELEMETRY_MS    33
#define DCF_DEFAULT_PORT    47000

/* ── control socket (AF_UNIX) — idiom copied from demod_control.c ──────── */
static const char *control_path(void) {
    const char *p = getenv("DEMOD_CONTROL_SOCK");
    return (p && *p) ? p : "/run/demod/control.sock";
}

static int control_send_line(const char *json, size_t len) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, control_path(), sizeof(addr.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) { close(fd); return -1; }
    int rc = 0;
    if (write(fd, json, len) == (ssize_t)len) { (void)!write(fd, "\n", 1); } else rc = -1;
    close(fd);
    return rc;
}

/* ── meters shm reader — seqlock, mirroring demod_rt_meters.c ──────────── */
static const char *meters_path(void) {
    const char *p = getenv("DEMOD_RT_METERS_SHM");
    return (p && *p) ? p : "/dev/shm/demod-rt-meters";
}

static DemodRtMeters *g_meters = NULL;
static int            g_meters_fd = -1;

static int meters_ensure_open(void) {
    if (g_meters) return 1;
    int fd = open(meters_path(), O_RDONLY);
    if (fd < 0) return 0;
    struct stat st;
    if (fstat(fd, &st) != 0 || (size_t)st.st_size < sizeof(DemodRtMeters)) { close(fd); return 0; }
    void *m = mmap(NULL, sizeof(DemodRtMeters), PROT_READ, MAP_SHARED, fd, 0);
    if (m == MAP_FAILED) { close(fd); return 0; }
    g_meters_fd = fd;
    g_meters = (DemodRtMeters *)m;
    return 1;
}

static int meters_read(DemodRtMeters *out) {
    if (!meters_ensure_open()) return 0;
    for (int attempt = 0; attempt < 8; attempt++) {
        uint32_t s0 = atomic_load_explicit(&g_meters->seq, memory_order_acquire);
        if (s0 & 1u) continue;
        memcpy(out, g_meters, sizeof(*out));
        uint32_t s1 = atomic_load_explicit(&g_meters->seq, memory_order_acquire);
        if (s0 == s1) return 1;
    }
    return 0;
}

/* ── quantisation (must match dm.dcf.poll() inverse, byte-for-byte) ────── */
static uint8_t q_unit(float x) {
    if (x < 0.0f) x = 0.0f;
    if (x > 1.0f) x = 1.0f;
    return (uint8_t)lroundf(x * 255.0f);
}
static uint8_t q_gain(float g) {
    if (g < 0.0f) g = 0.0f;
    if (g > 1.5f) g = 1.5f;
    return (uint8_t)lroundf(g / 1.5f * 255.0f);
}
static uint8_t q_pan(float p) {
    if (p < -1.0f) p = -1.0f;
    if (p > 1.0f) p = 1.0f;
    return (uint8_t)(int8_t)lroundf(p * 127.0f);
}

/* Build the codec_id-16 meters block. Returns payload length. */
static size_t build_meters_block(const DemodRtMeters *m, uint8_t *out) {
    unsigned n = DEMOD_RT_METERS_SLOTS;
    if (n > 27u) n = 27u;

    float master = 0.0f;
    for (unsigned i = 0; i < n; i++) {
        if (m->fx_levels_l[i] > master) master = m->fx_levels_l[i];
        if (m->fx_levels_r[i] > master) master = m->fx_levels_r[i];
    }

    uint16_t mute = (uint16_t)(m->slot_mute_mask & 0xFFFFu);
    uint16_t solo = (uint16_t)(m->slot_solo_mask & 0xFFFFu);

    out[0]  = 1u;                 /* version                */
    out[1]  = (uint8_t)n;         /* slot_count             */
    out[2]  = 0u;                 /* flags: linear levels   */
    out[3]  = q_unit(master);     /* master_level           */
    out[4]  = 0u; out[5] = 0u;    /* bpm (v1: 0)            */
    out[6]  = 0u; out[7] = 0u;    /* pitch_hz (v1: 0)      */
    out[8]  = 0u;                 /* beat                   */
    out[9]  = 0u;                 /* cpu                    */
    out[10] = 0u;                 /* xruns                  */
    out[11] = (uint8_t)(mute & 0xFFu); out[12] = (uint8_t)(mute >> 8);
    out[13] = (uint8_t)(solo & 0xFFu); out[14] = (uint8_t)(solo >> 8);

    for (unsigned i = 0; i < n; i++) {
        uint8_t *s = out + 15u + i * 4u;
        s[0] = q_unit(m->fx_levels_l[i]);
        s[1] = q_unit(m->fx_levels_r[i]);
        s[2] = q_gain(m->slot_gain[i]);
        s[3] = q_pan(m->slot_pan[i]);
    }
    return 15u + (size_t)n * 4u;
}

static uint32_t now_us(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    uint64_t us = (uint64_t)ts.tv_sec * 1000000ull + (uint64_t)(ts.tv_nsec / 1000);
    return (uint32_t)(us & 0xFFFFFFu);
}
static long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long)ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
}

int main(void) {
    const char *pe = getenv("DEMOD_DCF_PORT");
    int port = (pe && *pe) ? atoi(pe) : DCF_DEFAULT_PORT;

    int sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) { perror("socket"); return 1; }
    struct sockaddr_in me;
    memset(&me, 0, sizeof(me));
    me.sin_family = AF_INET;
    me.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    me.sin_port = htons((uint16_t)port);
    if (bind(sock, (struct sockaddr *)&me, sizeof(me)) != 0) { perror("bind"); return 1; }
    fprintf(stderr, "[bridge] listening udp 127.0.0.1:%d\n", port);

    dcf_text_reasm_t reasm;
    dcf_text_reasm_init(&reasm);

    struct sockaddr_in peer;
    socklen_t peer_len = 0;
    int have_peer = 0;
    uint16_t tele_pid = 0;
    long last_tele = now_ms();

    for (;;) {
        /* Drain any received frames (non-blocking). */
        for (;;) {
            uint8_t rb[DCF_FRAME_SIZE];
            struct sockaddr_in src;
            socklen_t sl = sizeof(src);
            ssize_t n = recvfrom(sock, rb, sizeof(rb), MSG_DONTWAIT,
                                 (struct sockaddr *)&src, &sl);
            if (n != (ssize_t)DCF_FRAME_SIZE) break;
            memcpy(&peer, &src, sizeof(src));
            peer_len = sl;
            have_peer = 1;

            dcf_frame_t d;
            if (!dcf_frame_decode(rb, &d)) continue;

            /* CTRL 'PING' -> 'PONG' back to the sender. */
            if (d.type == DCF_TYPE_CTRL &&
                d.payload[0] == 'P' && d.payload[1] == 'I' &&
                d.payload[2] == 'N' && d.payload[3] == 'G') {
                dcf_frame_t p;
                dcf_frame_init(&p, 1u, DCF_TYPE_CTRL, d.seq, DCF_BRIDGE_SRC_ID, d.src_id);
                p.payload[0] = 'P'; p.payload[1] = 'O'; p.payload[2] = 'N'; p.payload[3] = 'G';
                p.timestamp_us = now_us();
                uint8_t pb[DCF_FRAME_SIZE];
                dcf_frame_encode(&p, pb);
                sendto(sock, pb, DCF_FRAME_SIZE, 0, (struct sockaddr *)&src, sl);
                continue;
            }

            /* DCF-Text (DATA) fragments -> reassemble a JSON op. */
            dcf_text_packet_t msg;
            if (dcf_text_reasm_push(&reasm, rb, &msg) == DCF_TEXT_REASM_MESSAGE) {
                if (control_send_line((const char *)msg.payload, msg.payload_len) == 0)
                    fprintf(stderr, "[bridge] op -> control.sock (%u B)\n", msg.payload_len);
                else
                    fprintf(stderr, "[bridge] op dropped (control.sock unavailable)\n");
            }
        }

        /* Telemetry: emit a meters block roughly every DCF_TELEMETRY_MS. */
        long t = now_ms();
        if (have_peer && (t - last_tele) >= DCF_TELEMETRY_MS) {
            last_tele = t;
            DemodRtMeters m;
            if (meters_read(&m)) {
                uint8_t block[15u + 27u * 4u];
                size_t len = build_meters_block(&m, block);
                uint8_t frames[DCF_AUDIO_MAX_FRAMES][DCF_FRAME_SIZE];
                size_t nf = 0;
                uint16_t pid = (uint16_t)(tele_pid & DCF_AUDIO_MAX_PACKETID);
                tele_pid = (uint16_t)((tele_pid + 1u) & DCF_AUDIO_MAX_PACKETID);
                if (dcf_audio_packetize(DCF_METERS_CODEC, block, len, pid, now_us(),
                                        DCF_BRIDGE_SRC_ID, DCF_UI_DST_ID, 0,
                                        frames, DCF_AUDIO_MAX_FRAMES, &nf)) {
                    for (size_t i = 0; i < nf; i++)
                        sendto(sock, frames[i], DCF_FRAME_SIZE, 0,
                               (struct sockaddr *)&peer, peer_len);
                }
            }
        }

        usleep(2000);
    }
    return 0;
}
