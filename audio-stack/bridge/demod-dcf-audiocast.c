/* SPDX-License-Identifier: GPL-3.0-only OR LicenseRef-DeMoD-Commercial */
/*
 * demod-dcf-audiocast.c — cast the engine's JACK output over the DCF-Audio wire.
 *
 * Reads the running engine's output (JACK ports demod-rt:out_L / out_R), downmixes
 * to 48 kHz mono, Opus-encodes each 20 ms / 960-sample block at 24 kbps, and
 * serialises it into 17-byte DeModFrame CTRL frames via the byte-certified L2
 * packetizer (third_party/hydramesh/demod_audio.h, codec_id 0). The frame stream is
 * written either:
 *   --out stdout            a raw .dcf frame dump for `dcf-ffmpeg -f dcf -i pipe:0`
 *                           (default; the HLS-monitor path — no UDP envelope needed)
 *   --out udp:HOST:PORT     one bare DeModFrame per UDP datagram (mesh transport)
 *
 * This is the capture/encode half of the DCF-Audio path (the serve/decode half ships
 * as HydraMesh's dcf-ffmpeg / dcf-radio). It is a MONITOR feed: 24 kbps compressed
 * mono, NOT full fidelity — use WAV render / a host-audio socket for that.
 *
 * RT hygiene: the JACK process callback only writes a lock-free jack_ringbuffer; a
 * worker thread does all encoding, packetizing, and I/O off the audio thread. Nothing
 * in the callback allocates, locks, or blocks. (The engine itself keeps its "no
 * sockets in the RT callback" rule; this is a separate, ordinary-priority client.)
 *
 * Links libjack, libopus, libm and the vendored LGPL DCF codec headers.
 * Copyright (C) 2026 DeMoD LLC. GPL-3.0-only OR LicenseRef-DeMoD-Commercial; see LICENSING.md.
 */
#define _GNU_SOURCE 1
#define DCF_AUDIO_OPUS 1   /* pull in the codec_id-0 Opus vtable (needs -lopus) */

#include "hydramesh/demod_frame.h"
#include "hydramesh/demod_audio.h"

#include <jack/jack.h>
#include <jack/ringbuffer.h>

#include <arpa/inet.h>
#include <errno.h>
#include <math.h>
#include <netdb.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

/* Wire ids: keep the caster distinct from the control bridge (SRC 3) / UI (DST 2). */
#define AUDIOCAST_SRC_ID   4u
#define AUDIOCAST_DST_ID   0xFFFFu   /* broadcast */
#define BLOCK              DCF_OPUS_BLOCK   /* 960 samples @ 48 kHz = 20 ms */
#define RB_FLOATS          (1u << 16)       /* ~1.36 s of mono float slack */

/* ── config (set once from argv, read-only thereafter) ─────────────────────── */
static const char *g_connect_l = "demod-rt:out_L";
static const char *g_connect_r = "demod-rt:out_R";
static bool        g_autoconnect = true;
static bool        g_verbose     = false;
static bool        g_test_tone   = false;  /* synthesize a sine instead of reading JACK */
static double      g_tone_hz     = 440.0;
static uint16_t    g_src_id      = AUDIOCAST_SRC_ID;
static uint16_t    g_dst_id      = AUDIOCAST_DST_ID;
enum { OUT_STDOUT, OUT_UDP } g_out_mode = OUT_STDOUT;
static int         g_udp_fd = -1;              /* UDP mode only */

/* ── runtime state ─────────────────────────────────────────────────────────── */
static volatile sig_atomic_t g_run = 1;
static jack_client_t  *g_client;
static jack_port_t    *g_in_l, *g_in_r;
static jack_ringbuffer_t *g_rb;                /* audio-thread -> worker, mono floats */
static atomic_ullong   g_dropped = 0;          /* frames of audio dropped (rb overrun) */
static atomic_ullong   g_blocks  = 0;          /* opus blocks emitted */
static atomic_ullong   g_frames  = 0;          /* DeModFrames emitted */

static void on_signal(int sig) { (void)sig; g_run = 0; }

/* JACK process callback — real-time context. Downmix to mono, push to the ring. */
static int process_cb(jack_nframes_t nframes, void *arg) {
    (void)arg;
    const jack_default_audio_sample_t *l = jack_port_get_buffer(g_in_l, nframes);
    const jack_default_audio_sample_t *r = jack_port_get_buffer(g_in_r, nframes);
    for (jack_nframes_t i = 0; i < nframes; i++) {
        float mono = 0.5f * ((float)l[i] + (float)r[i]);
        if (jack_ringbuffer_write(g_rb, (const char *)&mono, sizeof mono) != sizeof mono) {
            atomic_fetch_add(&g_dropped, 1);   /* worker fell behind; drop this sample */
        }
    }
    return 0;
}

/* Parse "udp:HOST:PORT" into a connected UDP socket in g_udp_fd. */
static int open_udp(const char *spec) {
    /* spec points past "udp:" */
    char host[256];
    const char *colon = strrchr(spec, ':');
    if (!colon || colon == spec || (size_t)(colon - spec) >= sizeof host) {
        fprintf(stderr, "audiocast: --out udp needs udp:HOST:PORT\n");
        return -1;
    }
    memcpy(host, spec, (size_t)(colon - spec));
    host[colon - spec] = '\0';
    const char *port = colon + 1;

    struct addrinfo hints, *res = NULL;
    memset(&hints, 0, sizeof hints);
    hints.ai_family   = AF_UNSPEC;
    hints.ai_socktype = SOCK_DGRAM;
    int e = getaddrinfo(host, port, &hints, &res);
    if (e != 0 || !res) {
        fprintf(stderr, "audiocast: resolve %s:%s: %s\n", host, port, gai_strerror(e));
        return -1;
    }
    int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
    if (fd < 0 || connect(fd, res->ai_addr, res->ai_addrlen) != 0) {
        fprintf(stderr, "audiocast: udp connect %s:%s: %s\n", host, port, strerror(errno));
        if (fd >= 0) close(fd);
        freeaddrinfo(res);
        return -1;
    }
    freeaddrinfo(res);
    g_udp_fd = fd;
    fprintf(stderr, "audiocast: sending DeModFrames to udp:%s:%s\n", host, port);
    return 0;
}

/* Emit one 17-byte frame in the selected output mode. */
static void emit_frame(const uint8_t frame[DCF_FRAME_SIZE]) {
    if (g_out_mode == OUT_STDOUT) {
        fwrite(frame, 1, DCF_FRAME_SIZE, stdout);
    } else {
        (void)!send(g_udp_fd, frame, DCF_FRAME_SIZE, 0);
    }
    atomic_fetch_add(&g_frames, 1);
}

/* Worker: pull mono blocks, Opus-encode, packetize, emit. Non-RT thread. */
static void run_worker(void) {
    const dcf_codec_vtable_t *codec = dcf_codec_get(DCF_CODEC_OPUS);
    if (!codec || !codec->encode) {
        fprintf(stderr, "audiocast: Opus codec unavailable (built without DCF_AUDIO_OPUS?)\n");
        g_run = 0;
        return;
    }

    float    block[BLOCK];
    uint8_t  payload[DCF_AUDIO_MAX_PAYLOAD];
    uint8_t  frames[DCF_AUDIO_MAX_FRAMES][DCF_FRAME_SIZE];
    uint16_t packet_id = 0;
    uint32_t ts_us     = 0;

    while (g_run || jack_ringbuffer_read_space(g_rb) >= BLOCK * sizeof(float)) {
        if (jack_ringbuffer_read_space(g_rb) < BLOCK * sizeof(float)) {
            struct timespec ts = { 0, 2 * 1000 * 1000 };  /* 2 ms */
            nanosleep(&ts, NULL);
            continue;
        }
        jack_ringbuffer_read(g_rb, (char *)block, BLOCK * sizeof(float));

        uint16_t out_len = 0;
        if (codec->encode(block, BLOCK, payload, &out_len) != 0) continue;

        size_t nf = 0;
        if (!dcf_audio_packetize(DCF_CODEC_OPUS, payload, out_len, packet_id, ts_us,
                                 g_src_id, g_dst_id, 0, frames, DCF_AUDIO_MAX_FRAMES, &nf))
            continue;
        for (size_t k = 0; k < nf; k++) emit_frame(frames[k]);
        if (g_out_mode == OUT_STDOUT) fflush(stdout);

        packet_id = (uint16_t)((packet_id + 1u) & DCF_AUDIO_MAX_PACKETID);
        ts_us    += 20000u;   /* 20 ms per block */

        unsigned long long b = atomic_fetch_add(&g_blocks, 1) + 1;
        if (g_verbose && (b % 250 == 0))  /* every ~5 s */
            fprintf(stderr, "audiocast: %llu blocks, %llu frames, %llu samples dropped\n",
                    b, (unsigned long long)atomic_load(&g_frames),
                    (unsigned long long)atomic_load(&g_dropped));
    }
}

/* Test-tone worker: synthesize a sine and cast it over DCF-Audio without JACK or
 * an engine — a privilege-free, cross-platform "the DCF-Audio → HLS path works"
 * demo. libm sin() here is fine: this is not the deterministic audio path. */
static void run_tone(void) {
    const dcf_codec_vtable_t *codec = dcf_codec_get(DCF_CODEC_OPUS);
    if (!codec || !codec->encode) {
        fprintf(stderr, "audiocast: Opus codec unavailable\n"); g_run = 0; return;
    }
    float    block[BLOCK];
    uint8_t  payload[DCF_AUDIO_MAX_PAYLOAD];
    uint8_t  frames[DCF_AUDIO_MAX_FRAMES][DCF_FRAME_SIZE];
    uint16_t packet_id = 0;
    uint32_t ts_us     = 0;
    double   phase = 0.0;
    const double w = 2.0 * M_PI * g_tone_hz / (double)DCF_OPUS_RATE;

    fprintf(stderr, "audiocast: TEST TONE %.0f Hz -> DCF-Audio Opus/24k (no JACK, no engine)\n", g_tone_hz);
    while (g_run) {
        for (int i = 0; i < BLOCK; i++) {
            block[i] = 0.2f * (float)sin(phase);
            phase += w; if (phase > 2.0 * M_PI) phase -= 2.0 * M_PI;
        }
        uint16_t out_len = 0;
        if (codec->encode(block, BLOCK, payload, &out_len) == 0) {
            size_t nf = 0;
            if (dcf_audio_packetize(DCF_CODEC_OPUS, payload, out_len, packet_id, ts_us,
                                    g_src_id, g_dst_id, 0, frames, DCF_AUDIO_MAX_FRAMES, &nf)) {
                for (size_t k = 0; k < nf; k++) emit_frame(frames[k]);
                if (g_out_mode == OUT_STDOUT) fflush(stdout);
            }
        }
        packet_id = (uint16_t)((packet_id + 1u) & DCF_AUDIO_MAX_PACKETID);
        ts_us    += 20000u;
        atomic_fetch_add(&g_blocks, 1);
        struct timespec ts = { 0, 20 * 1000 * 1000 };  /* ~20 ms real-time pacing */
        nanosleep(&ts, NULL);
    }
}

static void connect_ports(void) {
    if (!g_autoconnect) return;
    if (jack_connect(g_client, g_connect_l, jack_port_name(g_in_l)) != 0)
        fprintf(stderr, "audiocast: warn: could not connect %s -> in_L\n", g_connect_l);
    if (jack_connect(g_client, g_connect_r, jack_port_name(g_in_r)) != 0)
        fprintf(stderr, "audiocast: warn: could not connect %s -> in_R\n", g_connect_r);
}

static void usage(const char *me) {
    fprintf(stderr,
        "usage: %s [--out stdout|udp:HOST:PORT] [--connect L,R | --no-connect]\n"
        "          [--test-tone | --tone-hz HZ] [--src ID] [--dst ID] [--verbose]\n"
        "\n"
        "  Casts the engine's JACK output (default demod-rt:out_L,out_R) over the\n"
        "  DCF-Audio wire as 24 kbps Opus (codec_id 0), 20 ms blocks. Pipe --out\n"
        "  stdout into `dcf-ffmpeg -f dcf -i pipe:0` to serve HLS. 48 kHz mono.\n"
        "  --test-tone synthesizes a sine and needs no JACK/engine (a cap-free demo).\n",
        me);
}

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--out") && i + 1 < argc) {
            const char *v = argv[++i];
            if (!strcmp(v, "stdout")) {
                g_out_mode = OUT_STDOUT;
            } else if (!strncmp(v, "udp:", 4)) {
                g_out_mode = OUT_UDP;
                if (open_udp(v + 4) != 0) return 1;
            } else {
                fprintf(stderr, "audiocast: unknown --out %s\n", v);
                return 2;
            }
        } else if (!strcmp(argv[i], "--connect") && i + 1 < argc) {
            char *spec = argv[++i];
            char *comma = strchr(spec, ',');
            if (!comma) { fprintf(stderr, "audiocast: --connect needs L,R\n"); return 2; }
            *comma = '\0';
            g_connect_l = spec;
            g_connect_r = comma + 1;
            g_autoconnect = true;
        } else if (!strcmp(argv[i], "--no-connect")) {
            g_autoconnect = false;
        } else if (!strcmp(argv[i], "--test-tone")) {
            g_test_tone = true;
        } else if (!strcmp(argv[i], "--tone-hz") && i + 1 < argc) {
            g_tone_hz = strtod(argv[++i], NULL);
            g_test_tone = true;
        } else if (!strcmp(argv[i], "--src") && i + 1 < argc) {
            g_src_id = (uint16_t)strtoul(argv[++i], NULL, 0);
        } else if (!strcmp(argv[i], "--dst") && i + 1 < argc) {
            g_dst_id = (uint16_t)strtoul(argv[++i], NULL, 0);
        } else if (!strcmp(argv[i], "--verbose") || !strcmp(argv[i], "-v")) {
            g_verbose = true;
        } else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
            usage(argv[0]);
            return 0;
        } else {
            fprintf(stderr, "audiocast: unknown arg %s\n", argv[i]);
            usage(argv[0]);
            return 2;
        }
    }

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGPIPE, SIG_IGN);   /* downstream ffmpeg/pipe may close first */

    /* Test-tone mode needs neither JACK nor the engine. */
    if (g_test_tone) {
        run_tone();
        if (g_udp_fd >= 0) close(g_udp_fd);
        fprintf(stderr, "audiocast: stopped — %llu blocks, %llu frames\n",
                (unsigned long long)atomic_load(&g_blocks),
                (unsigned long long)atomic_load(&g_frames));
        return 0;
    }

    jack_status_t status;
    g_client = jack_client_open("demod-dcf-audiocast", JackNoStartServer, &status);
    if (!g_client) {
        fprintf(stderr, "audiocast: no JACK server (status 0x%x)\n", status);
        return 1;
    }
    if (jack_get_sample_rate(g_client) != DCF_OPUS_RATE)
        fprintf(stderr, "audiocast: warn: JACK is %u Hz, Opus expects %u Hz — pitch/timing will be off\n",
                jack_get_sample_rate(g_client), DCF_OPUS_RATE);

    g_rb = jack_ringbuffer_create(RB_FLOATS * sizeof(float));
    if (!g_rb) { fprintf(stderr, "audiocast: ringbuffer alloc failed\n"); return 1; }
    jack_ringbuffer_mlock(g_rb);

    g_in_l = jack_port_register(g_client, "in_L", JACK_DEFAULT_AUDIO_TYPE, JackPortIsInput, 0);
    g_in_r = jack_port_register(g_client, "in_R", JACK_DEFAULT_AUDIO_TYPE, JackPortIsInput, 0);
    if (!g_in_l || !g_in_r) { fprintf(stderr, "audiocast: port register failed\n"); return 1; }

    jack_set_process_callback(g_client, process_cb, NULL);
    if (jack_activate(g_client) != 0) { fprintf(stderr, "audiocast: activate failed\n"); return 1; }
    connect_ports();

    fprintf(stderr, "audiocast: casting %s+%s -> DCF-Audio Opus/24k (src=%u dst=%u, %s)\n",
            g_connect_l, g_connect_r, g_src_id, g_dst_id,
            g_out_mode == OUT_STDOUT ? "stdout .dcf" : "udp");

    run_worker();

    jack_deactivate(g_client);
    jack_client_close(g_client);
    jack_ringbuffer_free(g_rb);
    if (g_udp_fd >= 0) close(g_udp_fd);
    fprintf(stderr, "audiocast: stopped — %llu blocks, %llu frames, %llu samples dropped\n",
            (unsigned long long)atomic_load(&g_blocks),
            (unsigned long long)atomic_load(&g_frames),
            (unsigned long long)atomic_load(&g_dropped));
    return 0;
}
