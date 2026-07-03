/*
 * test_audio_tap.c — Audio Tap Pipeline Test
 * Copyright (C) 2025–2026 DeMoD LLC
 * SPDX-License-Identifier: GPL-3.0-only
 */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "demod_shm.h"
#include <stdio.h>
#include <stdlib.h>
#include <math.h>

static int tests_passed = 0;
static int tests_failed = 0;

#define TEST(name) do { printf("  %-44s ", name); } while(0)
#define PASS()     do { printf("PASS\n"); tests_passed++; } while(0)
#define FAIL(msg)  do { printf("FAIL: %s\n", msg); tests_failed++; return; } while(0)
#define ASSERT(cond, msg) do { if (!(cond)) { FAIL(msg); } } while(0)

#define SR 48000.0f
#define PI 3.14159265358979323846f

static void gen_sine(float *buf, int n, float freq, int *phase) {
    for (int i = 0; i < n; i++)
        buf[i] = sinf(2.0f * PI * freq * (float)(*phase + i) / SR);
    *phase += n;
}

static void test_evt_ring_round_trip(void) {
    TEST("440Hz sine: push 2048 → pop 2048 via evt ring");
    DemodIpc ipc;
    int rc = demod_ipc_create(&ipc, 4096);
    ASSERT(rc == 0, "ipc create failed");

    float sine[64];
    int phase = 0, total = 0;
    for (int b = 0; b < 32; b++) {
        gen_sine(sine, 64, 440.0f, &phase);
        total += (int)demod_spsc_push(ipc.evt_ring, sine, 64);
    }
    ASSERT(total == 2048, "push count");

    float rb[2048];
    int rd = 0;
    while (rd < 2048) {
        float chunk[256];
        uint64_t n = demod_spsc_pop(ipc.evt_ring, chunk, 256);
        for (uint64_t i = 0; i < n; i++) rb[rd + (int)i] = chunk[i];
        rd += (int)n;
        if (n == 0) break;
    }
    ASSERT(rd == 2048, "read count");

    float ref[2048];
    int rp = 0;
    gen_sine(ref, 2048, 440.0f, &rp);

    float max_err = 0.0f;
    for (int i = 0; i < 2048; i++) {
        float e = fabsf(rb[i] - ref[i]);
        if (e > max_err) max_err = e;
    }
    ASSERT(max_err < 1e-6f, "signal corrupted through SPSC");

    demod_ipc_destroy(&ipc);
    PASS();
}

static void test_mono_mix(void) {
    TEST("mono mix: (L+R)/2 preserves identical signals");
    float l[64], r[64], mono[64];
    int p1 = 0, p2 = 0;
    gen_sine(l, 64, 440.0f, &p1);
    gen_sine(r, 64, 440.0f, &p2);
    for (int i = 0; i < 64; i++) mono[i] = (l[i] + r[i]) * 0.5f;
    float max_err = 0.0f;
    for (int i = 0; i < 64; i++) {
        float e = fabsf(mono[i] - l[i]);
        if (e > max_err) max_err = e;
    }
    ASSERT(max_err < 1e-6f, "mono mix error");
    demod_shm_unlink(DEMOD_SHM_PARAMS);
    demod_shm_unlink(DEMOD_SHM_AUDIO_CMD);
    demod_shm_unlink(DEMOD_SHM_AUDIO_EVT);
    demod_shm_unlink(DEMOD_SHM_HEARTBEAT);
    PASS();
}

static void test_one_second_throughput(void) {
    TEST("1 second (48000 samples) through evt ring");
    DemodIpc ipc;
    int rc = demod_ipc_create(&ipc, 4096);
    ASSERT(rc == 0, "create");

    float buf[64];
    int phase = 0, total = 0;
    for (int b = 0; b < 750; b++) {
        gen_sine(buf, 64, 440.0f, &phase);
        uint64_t pushed = demod_spsc_push(ipc.evt_ring, buf, 64);
        if (pushed == 0) {
            float drain[256];
            demod_spsc_pop(ipc.evt_ring, drain, 256);
            pushed = demod_spsc_push(ipc.evt_ring, buf, 64);
        }
        total += (int)pushed;
    }
    float drain[256];
    while (demod_spsc_pop(ipc.evt_ring, drain, 256) > 0) {}
    ASSERT(total == 48000, "total samples");

    demod_ipc_destroy(&ipc);
    PASS();
}

static void test_guitar_frequencies(void) {
    TEST("all guitar frequencies survive SPSC");
    DemodIpc ipc;
    int rc = demod_ipc_create(&ipc, 4096);
    ASSERT(rc == 0, "create");

    float freqs[] = { 82.41f, 110.0f, 146.83f, 196.0f, 246.94f, 329.63f };
    for (int f = 0; f < 6; f++) {
        float buf[64], rb[64];
        int p = 0;
        gen_sine(buf, 64, freqs[f], &p);
        demod_spsc_push(ipc.evt_ring, buf, 64);
        uint64_t n = demod_spsc_pop(ipc.evt_ring, rb, 64);
        ASSERT(n == 64, "pop count");
        for (int i = 0; i < 64; i++)
            ASSERT(fabsf(rb[i] - buf[i]) < 1e-6f, "freq mismatch");
    }

    demod_ipc_destroy(&ipc);
    PASS();
}

static void test_param_publish_with_audio(void) {
    TEST("simultaneous param publish + audio tap");
    DemodIpc ipc;
    int rc = demod_ipc_create(&ipc, 4096);
    ASSERT(rc == 0, "create");

    /* Simulate: write params while also pushing audio */
    for (int i = 0; i < 100; i++) {
        /* Param write */
        DemodParamSnapshot *snap = demod_triple_buf_begin_write(ipc.params);
        snap->detected_pitch_hz = 440.0f;
        snap->bpm = 120.0f;
        demod_triple_buf_publish(ipc.params);

        /* Audio push */
        float buf[64];
        int p = i * 64;
        gen_sine(buf, 64, 440.0f, &p);
        demod_spsc_push(ipc.evt_ring, buf, 64);

        /* Audio pop */
        float rb[64];
        demod_spsc_pop(ipc.evt_ring, rb, 64);
    }

    /* Verify params survived */
    const DemodParamSnapshot *read = demod_triple_buf_read_active(ipc.params);
    ASSERT(fabsf(read->detected_pitch_hz - 440.0f) < 0.001f, "params corrupted");
    ASSERT(demod_triple_buf_sequence(ipc.params) == 100, "sequence");

    demod_ipc_destroy(&ipc);
    PASS();
}

int main(void) {
    printf("=== Audio Tap Pipeline Tests ===\n");
    test_evt_ring_round_trip();
    test_mono_mix();
    test_one_second_throughput();
    test_guitar_frequencies();
    test_param_publish_with_audio();
    printf("\n%d passed, %d failed\n", tests_passed, tests_failed);
    return tests_failed > 0 ? 1 : 0;
}
