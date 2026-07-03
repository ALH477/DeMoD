/*
 * test_triple_buf.c — Triple Buffer Tests
 *
 * Copyright (C) 2025–2026 DeMoD LLC
 * SPDX-License-Identifier: GPL-3.0-only
 */

#include "demod_triple_buf.h"
#include <stdio.h>
#include <assert.h>
#include <pthread.h>

static int tests_passed = 0;
static int tests_failed = 0;

#define TEST(name) do { printf("  %-40s ", name); } while(0)
#define PASS()     do { printf("PASS\n"); tests_passed++; } while(0)
#define FAIL(msg)  do { printf("FAIL: %s\n", msg); tests_failed++; } while(0)
#define ASSERT(cond, msg) do { if (!(cond)) { FAIL(msg); return; } } while(0)

static void test_init(void) {
    TEST("init");
    DemodTripleBuf tb;
    demod_triple_buf_init(&tb);
    ASSERT(demod_triple_buf_sequence(&tb) == 0, "seq should be 0");
    const DemodParamSnapshot *snap = demod_triple_buf_read_active(&tb);
    ASSERT(snap != NULL, "read returned NULL");
    ASSERT(snap->bpm == 0.0f, "should be zeroed");
    PASS();
}

static void test_write_publish_read(void) {
    TEST("write -> publish -> read");
    DemodTripleBuf tb;
    demod_triple_buf_init(&tb);

    DemodParamSnapshot *snap = demod_triple_buf_begin_write(&tb);
    snap->detected_pitch_hz = 440.0f;
    snap->bpm = 120.0f;
    demod_triple_buf_publish(&tb);

    const DemodParamSnapshot *read = demod_triple_buf_read_active(&tb);
    ASSERT(read->detected_pitch_hz == 440.0f, "pitch mismatch");
    ASSERT(read->bpm == 120.0f, "bpm mismatch");
    ASSERT(demod_triple_buf_sequence(&tb) == 1, "seq should be 1");
    PASS();
}

static void test_multiple_writes(void) {
    TEST("multiple writes, reader sees latest");
    DemodTripleBuf tb;
    demod_triple_buf_init(&tb);

    for (int i = 1; i <= 100; i++) {
        DemodParamSnapshot *snap = demod_triple_buf_begin_write(&tb);
        snap->bpm = (float)i;
        demod_triple_buf_publish(&tb);
    }

    const DemodParamSnapshot *read = demod_triple_buf_read_active(&tb);
    ASSERT(read->bpm == 100.0f, "should see latest write");
    ASSERT(demod_triple_buf_sequence(&tb) == 100, "seq should be 100");
    PASS();
}

static void test_no_new_data(void) {
    TEST("reader returns same if no new data");
    DemodTripleBuf tb;
    demod_triple_buf_init(&tb);

    DemodParamSnapshot *snap = demod_triple_buf_begin_write(&tb);
    snap->bpm = 42.0f;
    demod_triple_buf_publish(&tb);

    const DemodParamSnapshot *r1 = demod_triple_buf_read_active(&tb);
    ASSERT(r1->bpm == 42.0f, "first read");
    const DemodParamSnapshot *r2 = demod_triple_buf_read_active(&tb);
    ASSERT(r2->bpm == 42.0f, "second read (no new data)");
    PASS();
}

/* Threaded: writer hammering, reader checking consistency via read_active */
typedef struct { DemodTripleBuf *tb; int count; _Atomic int error; } TbArg;

static void *tb_writer(void *arg) {
    TbArg *a = (TbArg *)arg;
    for (int i = 0; i < a->count; i++) {
        DemodParamSnapshot *snap = demod_triple_buf_begin_write(a->tb);
        float v = (float)i;
        snap->detected_pitch_hz = v;
        snap->bpm = v;
        snap->beat_count = (uint32_t)i;
        demod_triple_buf_publish(a->tb);
    }
    return NULL;
}

static void *tb_reader(void *arg) {
    TbArg *a = (TbArg *)arg;
    for (int i = 0; i < a->count * 10; i++) {
        const DemodParamSnapshot *s = demod_triple_buf_read_active(a->tb);
        /* All fields in a snapshot should be from the same write */
        float pitch = s->detected_pitch_hz;
        float bpm   = s->bpm;
        uint32_t bc = s->beat_count;
        if (pitch != bpm || (uint32_t)pitch != bc) {
            atomic_store(&a->error, 1);
            return NULL;
        }
    }
    return NULL;
}

static void test_threaded_consistency(void) {
    TEST("threaded consistency (no torn reads)");
    DemodTripleBuf tb;
    demod_triple_buf_init(&tb);

    TbArg arg = { .tb = &tb, .count = 500000, .error = 0 };
    pthread_t wr, rd;
    pthread_create(&rd, NULL, tb_reader, &arg);
    pthread_create(&wr, NULL, tb_writer, &arg);
    pthread_join(wr, NULL);
    pthread_join(rd, NULL);

    ASSERT(atomic_load(&arg.error) == 0, "torn read detected");
    PASS();
}

static void test_snapshot_size(void) {
    TEST("snapshot is 256 bytes");
    ASSERT(sizeof(DemodParamSnapshot) == 256, "size mismatch");
    PASS();
}

int main(void) {
    printf("=== Triple Buffer Tests ===\n");
    test_init();
    test_write_publish_read();
    test_multiple_writes();
    test_no_new_data();
    test_threaded_consistency();
    test_snapshot_size();
    printf("\n%d passed, %d failed\n", tests_passed, tests_failed);
    return tests_failed > 0 ? 1 : 0;
}
