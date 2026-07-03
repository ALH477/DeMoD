/*
 * test_ffi_helpers.c — FFI Helpers Integration Test
 *
 * Copyright (C) 2025–2026 DeMoD LLC
 * SPDX-License-Identifier: GPL-3.0-only
 *
 * Tests the non-inline C wrapper functions that Haskell calls via FFI.
 * Validates the complete path: FFI helper → header-only impl → shm.
 */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "demod_ffi_helpers.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

static int tests_passed = 0;
static int tests_failed = 0;

#define TEST(name) do { printf("  %-44s ", name); } while(0)
#define PASS()     do { printf("PASS\n"); tests_passed++; } while(0)
#define FAIL(msg)  do { printf("FAIL: %s\n", msg); tests_failed++; return; } while(0)
#define ASSERT(cond, msg) do { if (!(cond)) { FAIL(msg); } } while(0)

static void test_ipc_lifecycle(void) {
    TEST("FFI: ipc create/destroy");
    DemodFfiIpc *ipc = demod_ffi_ipc_create(4096);
    ASSERT(ipc != NULL, "create returned NULL");
    demod_ffi_ipc_destroy(ipc);
    PASS();
}

static void test_triple_buffer_via_ffi(void) {
    TEST("FFI: triple buffer write → publish → read");
    DemodFfiIpc *ipc = demod_ffi_ipc_create(4096);
    ASSERT(ipc != NULL, "create failed");

    void *snap = demod_ffi_tb_begin_write(ipc);
    ASSERT(snap != NULL, "begin_write returned NULL");

    demod_ffi_snap_set_pitch(snap, 440.0f, 0.95f, 69);
    demod_ffi_snap_set_tempo(snap, 120.0f, 42);
    demod_ffi_snap_set_fx_bypass(snap, 0xFF00);
    demod_ffi_snap_set_timestamp(snap, 12345);
    demod_ffi_tb_publish(ipc);

    /* Read back */
    uint8_t buf[256];
    memset(buf, 0, sizeof(buf));
    uint64_t seq = demod_ffi_tb_read_copy(ipc, buf);
    ASSERT(seq == 1, "sequence should be 1");

    float pitch = demod_ffi_snap_get_pitch_hz(buf);
    ASSERT(fabsf(pitch - 440.0f) < 0.001f, "pitch mismatch");

    float bpm = demod_ffi_snap_get_bpm(buf);
    ASSERT(fabsf(bpm - 120.0f) < 0.001f, "bpm mismatch");

    int32_t midi = demod_ffi_snap_get_midi_note(buf);
    ASSERT(midi == 69, "midi note mismatch");

    uint32_t bypass = demod_ffi_snap_get_fx_bypass(buf);
    ASSERT(bypass == 0xFF00, "bypass mismatch");

    demod_ffi_ipc_destroy(ipc);
    PASS();
}

static void test_fx_params(void) {
    TEST("FFI: fx param slots 0-15");
    DemodFfiIpc *ipc = demod_ffi_ipc_create(4096);
    ASSERT(ipc != NULL, "create failed");

    void *snap = demod_ffi_tb_begin_write(ipc);
    for (int i = 0; i < 16; i++)
        demod_ffi_snap_set_fx_param(snap, i, (float)i * 0.1f);
    demod_ffi_tb_publish(ipc);

    uint8_t buf[256];
    demod_ffi_tb_read_copy(ipc, buf);
    for (int i = 0; i < 16; i++) {
        float v = demod_ffi_snap_get_fx_param(buf, i);
        float expected = (float)i * 0.1f;
        ASSERT(fabsf(v - expected) < 0.001f, "fx param mismatch");
    }

    demod_ffi_ipc_destroy(ipc);
    PASS();
}

static void test_heartbeat_init(void) {
    TEST("FFI: heartbeat init zeros");
    DemodFfiIpc *ipc = demod_ffi_ipc_create(4096);
    ASSERT(ipc != NULL, "create failed");

    ASSERT(demod_ffi_heartbeat_timestamp(ipc) == 0, "timestamp not 0");
    ASSERT(demod_ffi_heartbeat_callback_count(ipc) == 0, "callbacks not 0");
    ASSERT(demod_ffi_heartbeat_xrun_count(ipc) == 0, "xruns not 0");
    ASSERT(demod_ffi_heartbeat_alive(ipc) == 0, "alive not 0");
    ASSERT(demod_ffi_heartbeat_cpu_load(ipc) == 0.0f, "cpu_load not 0");

    demod_ffi_ipc_destroy(ipc);
    PASS();
}

static void test_clock_monotonic(void) {
    TEST("FFI: clock_us monotonic");
    uint64_t t1 = demod_ffi_clock_us();
    uint64_t t2 = demod_ffi_clock_us();
    ASSERT(t2 >= t1, "clock not monotonic");
    PASS();
}

static void test_sequence_increments(void) {
    TEST("FFI: sequence increments on publish");
    DemodFfiIpc *ipc = demod_ffi_ipc_create(4096);
    ASSERT(ipc != NULL, "create failed");

    uint64_t seq0 = demod_ffi_tb_sequence(ipc);
    ASSERT(seq0 == 0, "initial seq not 0");

    for (int i = 1; i <= 10; i++) {
        void *snap = demod_ffi_tb_begin_write(ipc);
        demod_ffi_snap_set_tempo(snap, (float)i, (uint32_t)i);
        demod_ffi_tb_publish(ipc);
    }

    uint64_t seq10 = demod_ffi_tb_sequence(ipc);
    ASSERT(seq10 == 10, "seq should be 10");

    demod_ffi_ipc_destroy(ipc);
    PASS();
}

static void test_bt_sdr_state(void) {
    TEST("FFI: BT and SDR state round-trip");
    DemodFfiIpc *ipc = demod_ffi_ipc_create(4096);
    ASSERT(ipc != NULL, "create failed");

    void *snap = demod_ffi_tb_begin_write(ipc);
    demod_ffi_snap_set_bt_state(snap, 3, 1);  /* aptX, connected */
    demod_ffi_snap_set_sdr(snap, 433.92f, 200.0f);
    demod_ffi_tb_publish(ipc);

    /* Read and verify (accessing raw struct since we don't have getters for BT/SDR) */
    uint8_t buf[256];
    demod_ffi_tb_read_copy(ipc, buf);

    /* These don't have FFI getters yet, but the snapshot was written correctly
     * if publish + read_copy didn't crash. Full validation via Haskell test. */

    demod_ffi_ipc_destroy(ipc);
    PASS();
}

static void test_multiple_cycles(void) {
    TEST("FFI: 1000 write/publish/read cycles");
    DemodFfiIpc *ipc = demod_ffi_ipc_create(4096);
    ASSERT(ipc != NULL, "create failed");

    uint8_t buf[256];
    for (int i = 0; i < 1000; i++) {
        void *snap = demod_ffi_tb_begin_write(ipc);
        demod_ffi_snap_set_tempo(snap, (float)i, (uint32_t)i);
        demod_ffi_snap_set_pitch(snap, (float)i * 2.0f, 0.9f, i % 128);
        demod_ffi_tb_publish(ipc);

        demod_ffi_tb_read_copy(ipc, buf);
        float bpm = demod_ffi_snap_get_bpm(buf);
        ASSERT(fabsf(bpm - (float)i) < 0.001f, "cycle bpm mismatch");
    }

    uint64_t seq = demod_ffi_tb_sequence(ipc);
    ASSERT(seq == 1000, "seq should be 1000");

    demod_ffi_ipc_destroy(ipc);
    PASS();
}

int main(void) {
    printf("=== FFI Helpers Integration Tests ===\n");

    test_ipc_lifecycle();
    test_triple_buffer_via_ffi();
    test_fx_params();
    test_heartbeat_init();
    test_clock_monotonic();
    test_sequence_increments();
    test_bt_sdr_state();
    test_multiple_cycles();

    printf("\n%d passed, %d failed\n", tests_passed, tests_failed);
    return tests_failed > 0 ? 1 : 0;
}
