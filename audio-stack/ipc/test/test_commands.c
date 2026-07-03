/*
 * test_commands.c — RT Command Handler Tests
 *
 * Copyright (C) 2025–2026 DeMoD LLC
 * SPDX-License-Identifier: GPL-3.0-only
 *
 * Tests the IPC command protocol: push commands to the SPSC command ring,
 * verify they can be read back correctly, and validate command encoding.
 */

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "demod_shm.h"
#include "demod_commands.h"
#include <stdio.h>
#include <math.h>

static int tests_passed = 0;
static int tests_failed = 0;

#define TEST(name) do { printf("  %-44s ", name); } while(0)
#define PASS()     do { printf("PASS\n"); tests_passed++; } while(0)
#define FAIL(msg)  do { printf("FAIL: %s\n", msg); tests_failed++; return; } while(0)
#define ASSERT(cond, msg) do { if (!(cond)) { FAIL(msg); } } while(0)

static void test_fx_bypass_cmd(void) {
    TEST("CMD: FX bypass encode/decode");
    DemodIpc ipc;
    int rc = demod_ipc_create(&ipc, 4096);
    ASSERT(rc == 0, "create");

    /* Encode: [CMD_FX_BYPASS, slot=3, on=1] */
    float cmd[3] = { DEMOD_CMD_FX_BYPASS, 3.0f, 1.0f };
    uint64_t pushed = demod_spsc_push(ipc.cmd_ring, cmd, 3);
    ASSERT(pushed == 3, "push");

    /* Decode */
    float type_f;
    demod_spsc_pop(ipc.cmd_ring, &type_f, 1);
    ASSERT(type_f == DEMOD_CMD_FX_BYPASS, "type");

    float args[2];
    demod_spsc_pop(ipc.cmd_ring, args, 2);
    ASSERT((int)args[0] == 3, "slot");
    ASSERT((int)args[1] == 1, "on");

    demod_ipc_destroy(&ipc);
    PASS();
}

static void test_fx_param_cmd(void) {
    TEST("CMD: FX param encode/decode");
    DemodIpc ipc;
    int rc = demod_ipc_create(&ipc, 4096);
    ASSERT(rc == 0, "create");

    float cmd[4] = { DEMOD_CMD_FX_PARAM, 5.0f, 2.0f, 0.75f };
    demod_spsc_push(ipc.cmd_ring, cmd, 4);

    float buf[4];
    demod_spsc_pop(ipc.cmd_ring, buf, 4);
    ASSERT(buf[0] == DEMOD_CMD_FX_PARAM, "type");
    ASSERT((int)buf[1] == 5, "slot");
    ASSERT((int)buf[2] == 2, "param_idx");
    ASSERT(fabsf(buf[3] - 0.75f) < 0.001f, "value");

    demod_ipc_destroy(&ipc);
    PASS();
}

static void test_set_bpm_cmd(void) {
    TEST("CMD: set BPM");
    DemodIpc ipc;
    int rc = demod_ipc_create(&ipc, 4096);
    ASSERT(rc == 0, "create");

    float cmd[2] = { DEMOD_CMD_SET_BPM, 140.0f };
    demod_spsc_push(ipc.cmd_ring, cmd, 2);

    float buf[2];
    demod_spsc_pop(ipc.cmd_ring, buf, 2);
    ASSERT(buf[0] == DEMOD_CMD_SET_BPM, "type");
    ASSERT(fabsf(buf[1] - 140.0f) < 0.001f, "bpm");

    demod_ipc_destroy(&ipc);
    PASS();
}

static void test_multiple_commands(void) {
    TEST("CMD: 100 sequential commands");
    DemodIpc ipc;
    int rc = demod_ipc_create(&ipc, 4096);
    ASSERT(rc == 0, "create");

    /* Push 100 bypass commands */
    for (int i = 0; i < 100; i++) {
        float cmd[3] = { DEMOD_CMD_FX_BYPASS, (float)(i % 16), (float)(i % 2) };
        uint64_t pushed = demod_spsc_push(ipc.cmd_ring, cmd, 3);
        ASSERT(pushed == 3, "push");
    }

    /* Pop and verify all */
    for (int i = 0; i < 100; i++) {
        float buf[3];
        uint64_t popped = demod_spsc_pop(ipc.cmd_ring, buf, 3);
        ASSERT(popped == 3, "pop");
        ASSERT(buf[0] == DEMOD_CMD_FX_BYPASS, "type");
        ASSERT((int)buf[1] == i % 16, "slot");
        ASSERT((int)buf[2] == i % 2, "on/off");
    }

    demod_ipc_destroy(&ipc);
    PASS();
}

static void test_ping_pong(void) {
    TEST("CMD: ping (1-float command)");
    DemodIpc ipc;
    int rc = demod_ipc_create(&ipc, 4096);
    ASSERT(rc == 0, "create");

    float cmd = DEMOD_CMD_PING;
    demod_spsc_push(ipc.cmd_ring, &cmd, 1);

    float out;
    demod_spsc_pop(ipc.cmd_ring, &out, 1);
    ASSERT(out == DEMOD_CMD_PING, "ping value");

    demod_ipc_destroy(&ipc);
    PASS();
}

static void test_shutdown_cmd(void) {
    TEST("CMD: shutdown");
    DemodIpc ipc;
    int rc = demod_ipc_create(&ipc, 4096);
    ASSERT(rc == 0, "create");

    float cmd = DEMOD_CMD_SHUTDOWN;
    demod_spsc_push(ipc.cmd_ring, &cmd, 1);

    float out;
    demod_spsc_pop(ipc.cmd_ring, &out, 1);
    ASSERT(out == DEMOD_CMD_SHUTDOWN, "shutdown value");

    demod_ipc_destroy(&ipc);
    PASS();
}

static void test_interleaved_cmds_and_params(void) {
    TEST("CMD + params: interleaved operations");
    DemodIpc ipc;
    int rc = demod_ipc_create(&ipc, 4096);
    ASSERT(rc == 0, "create");

    for (int i = 0; i < 50; i++) {
        /* Command */
        float cmd[3] = { DEMOD_CMD_FX_BYPASS, (float)(i % 8), 1.0f };
        demod_spsc_push(ipc.cmd_ring, cmd, 3);

        /* Param update via triple buffer */
        DemodParamSnapshot *snap = demod_triple_buf_begin_write(ipc.params);
        snap->bpm = (float)(100 + i);
        demod_triple_buf_publish(ipc.params);
    }

    /* Verify triple buffer has latest */
    const DemodParamSnapshot *read = demod_triple_buf_read_active(ipc.params);
    ASSERT(fabsf(read->bpm - 149.0f) < 0.001f, "params");

    /* Drain commands */
    int count = 0;
    float buf[3];
    while (demod_spsc_pop(ipc.cmd_ring, buf, 3) == 3) count++;
    ASSERT(count == 50, "command count");

    demod_ipc_destroy(&ipc);
    PASS();
}

int main(void) {
    printf("=== RT Command Handler Tests ===\n");
    test_fx_bypass_cmd();
    test_fx_param_cmd();
    test_set_bpm_cmd();
    test_multiple_commands();
    test_ping_pong();
    test_shutdown_cmd();
    test_interleaved_cmds_and_params();
    printf("\n%d passed, %d failed\n", tests_passed, tests_failed);
    return tests_failed > 0 ? 1 : 0;
}
