/*
 * test_shm.c — Shared Memory IPC Tests
 *
 * Copyright (C) 2025–2026 DeMoD LLC
 * SPDX-License-Identifier: GPL-3.0-only
 */

#include "demod_shm.h"
#include <stdio.h>
#include <assert.h>
#include <sys/wait.h>
#include <unistd.h>

static int tests_passed = 0;
static int tests_failed = 0;

#define TEST(name) do { printf("  %-40s ", name); } while(0)
#define PASS()     do { printf("PASS\n"); tests_passed++; } while(0)
#define FAIL(msg)  do { printf("FAIL: %s\n", msg); tests_failed++; } while(0)
#define ASSERT(cond, msg) do { if (!(cond)) { FAIL(msg); return; } } while(0)

static void test_create_open_close(void) {
    TEST("create → open → close");
    DemodShmRegion region;
    int rc = demod_shm_create(&region, "/demod-test-1", 4096);
    ASSERT(rc == 0, "create failed");
    ASSERT(region.addr != NULL, "addr is NULL");
    ASSERT(region.size == 4096, "size mismatch");

    /* Open same region from "child" perspective */
    DemodShmRegion child_region;
    rc = demod_shm_open(&child_region, "/demod-test-1", 4096);
    ASSERT(rc == 0, "open failed");

    /* Write from parent, read from child */
    ((char *)region.addr)[0] = 'X';
    ASSERT(((char *)child_region.addr)[0] == 'X', "cross-process read failed");

    demod_shm_close(&child_region);
    demod_shm_close(&region);
    demod_shm_unlink("/demod-test-1");
    PASS();
}

static void test_full_ipc_create(void) {
    TEST("full IPC create/destroy");
    DemodIpc ipc;
    int rc = demod_ipc_create(&ipc, DEMOD_SPSC_DEFAULT_CAPACITY);
    ASSERT(rc == 0, "ipc_create failed");
    ASSERT(ipc.params != NULL, "params NULL");
    ASSERT(ipc.cmd_ring != NULL, "cmd_ring NULL");
    ASSERT(ipc.evt_ring != NULL, "evt_ring NULL");
    ASSERT(ipc.heartbeat != NULL, "heartbeat NULL");

    /* Verify triple buffer is initialized */
    const DemodParamSnapshot *snap = demod_triple_buf_read_active(ipc.params);
    ASSERT(snap->detected_pitch_hz == 0.0f, "params not zeroed");

    /* Verify SPSC is initialized */
    ASSERT(demod_spsc_available_read(ipc.cmd_ring) == 0, "cmd ring not empty");
    ASSERT(demod_spsc_available_write(ipc.cmd_ring) == DEMOD_SPSC_DEFAULT_CAPACITY,
           "cmd ring not at capacity");

    demod_ipc_destroy(&ipc);
    PASS();
}

static void test_cross_process_ipc(void) {
    TEST("cross-process param publish");
    DemodIpc parent_ipc;
    int rc = demod_ipc_create(&parent_ipc, DEMOD_SPSC_DEFAULT_CAPACITY);
    ASSERT(rc == 0, "parent create failed");

    /* Write params */
    DemodParamSnapshot *snap = demod_triple_buf_begin_write(parent_ipc.params);
    snap->detected_pitch_hz = 440.0f;
    snap->bpm = 120.0f;
    snap->midi_note = 69;
    demod_triple_buf_publish(parent_ipc.params);

    /* Simulate child opening */
    DemodIpc child_ipc;
    rc = demod_ipc_open(&child_ipc, DEMOD_SPSC_DEFAULT_CAPACITY);
    ASSERT(rc == 0, "child open failed");

    const DemodParamSnapshot *read = demod_triple_buf_read_active(child_ipc.params);
    ASSERT(read->detected_pitch_hz == 440.0f, "pitch mismatch");
    ASSERT(read->bpm == 120.0f, "bpm mismatch");
    ASSERT(read->midi_note == 69, "midi note mismatch");

    /* SPSC command from parent to child */
    float cmd = 99.0f;
    uint64_t pushed = demod_spsc_push(parent_ipc.cmd_ring, &cmd, 1);
    ASSERT(pushed == 1, "cmd push failed");

    float out;
    uint64_t popped = demod_spsc_pop(child_ipc.cmd_ring, &out, 1);
    ASSERT(popped == 1, "cmd pop failed");
    ASSERT(out == 99.0f, "cmd value mismatch");

    demod_shm_close(&child_ipc.params_region);
    demod_shm_close(&child_ipc.cmd_region);
    demod_shm_close(&child_ipc.evt_region);
    demod_shm_close(&child_ipc.hb_region);
    demod_ipc_destroy(&parent_ipc);
    PASS();
}

static void test_heartbeat(void) {
    TEST("heartbeat read/write");
    DemodIpc ipc;
    int rc = demod_ipc_create(&ipc, DEMOD_SPSC_DEFAULT_CAPACITY);
    ASSERT(rc == 0, "create failed");

    atomic_store_explicit(&ipc.heartbeat->rt_alive, 1, memory_order_release);
    atomic_store_explicit(&ipc.heartbeat->rt_timestamp_us, 12345, memory_order_release);
    atomic_store_explicit(&ipc.heartbeat->rt_callback_count, 100, memory_order_release);

    uint32_t alive = atomic_load_explicit(&ipc.heartbeat->rt_alive, memory_order_acquire);
    ASSERT(alive == 1, "alive flag");
    uint64_t ts = atomic_load_explicit(&ipc.heartbeat->rt_timestamp_us, memory_order_acquire);
    ASSERT(ts == 12345, "timestamp");

    demod_ipc_destroy(&ipc);
    PASS();
}

int main(void) {
    printf("=== Shared Memory IPC Tests ===\n");
    test_create_open_close();
    test_full_ipc_create();
    test_cross_process_ipc();
    test_heartbeat();
    printf("\n%d passed, %d failed\n", tests_passed, tests_failed);
    return tests_failed > 0 ? 1 : 0;
}
