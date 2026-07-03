/*
 * test_spsc.c — SPSC Ring Buffer Tests
 *
 * Copyright (C) 2025–2026 DeMoD LLC
 * SPDX-License-Identifier: GPL-3.0-only
 */

#include "demod_spsc.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <pthread.h>

#define CAP 1024
#define ITERATIONS 1000000

static int tests_passed = 0;
static int tests_failed = 0;

#define TEST(name) do { printf("  %-40s ", name); } while(0)
#define PASS()     do { printf("PASS\n"); tests_passed++; } while(0)
#define FAIL(msg)  do { printf("FAIL: %s\n", msg); tests_failed++; } while(0)
#define ASSERT(cond, msg) do { if (!(cond)) { FAIL(msg); return; } } while(0)

/* ── Basic Operations ────────────────────────────────────────── */

static void test_init(void) {
    TEST("init");
    size_t sz = demod_spsc_alloc_size(CAP);
    void *mem = aligned_alloc(64, sz);
    assert(mem);

    DemodSpsc *rb = demod_spsc_init(mem, CAP);
    ASSERT(rb != NULL, "init returned NULL");
    ASSERT(rb->capacity == CAP, "bad capacity");
    ASSERT(rb->mask == CAP - 1, "bad mask");
    ASSERT(demod_spsc_available_read(rb) == 0, "not empty");
    ASSERT(demod_spsc_available_write(rb) == CAP, "not full capacity");

    free(mem);
    PASS();
}

static void test_push_pop(void) {
    TEST("push/pop single");
    size_t sz = demod_spsc_alloc_size(CAP);
    void *mem = aligned_alloc(64, sz);
    DemodSpsc *rb = demod_spsc_init(mem, CAP);

    float val = 42.0f;
    uint64_t pushed = demod_spsc_push(rb, &val, 1);
    ASSERT(pushed == 1, "push failed");
    ASSERT(demod_spsc_available_read(rb) == 1, "available != 1");

    float out = 0.0f;
    uint64_t popped = demod_spsc_pop(rb, &out, 1);
    ASSERT(popped == 1, "pop failed");
    ASSERT(out == 42.0f, "wrong value");
    ASSERT(demod_spsc_available_read(rb) == 0, "not empty after pop");

    free(mem);
    PASS();
}

static void test_batch(void) {
    TEST("batch push/pop");
    size_t sz = demod_spsc_alloc_size(CAP);
    void *mem = aligned_alloc(64, sz);
    DemodSpsc *rb = demod_spsc_init(mem, CAP);

    float data[64];
    for (int i = 0; i < 64; i++) data[i] = (float)i;

    uint64_t pushed = demod_spsc_push(rb, data, 64);
    ASSERT(pushed == 64, "batch push failed");

    float out[64];
    uint64_t popped = demod_spsc_pop(rb, out, 64);
    ASSERT(popped == 64, "batch pop failed");

    for (int i = 0; i < 64; i++)
        ASSERT(out[i] == (float)i, "batch value mismatch");

    free(mem);
    PASS();
}

static void test_wraparound(void) {
    TEST("wraparound");
    size_t sz = demod_spsc_alloc_size(16); /* tiny ring */
    void *mem = aligned_alloc(64, sz);
    DemodSpsc *rb = demod_spsc_init(mem, 16);

    float data[8], out[8];
    for (int i = 0; i < 8; i++) data[i] = (float)i;

    /* Fill half, drain, fill again to force wrap */
    for (int round = 0; round < 10; round++) {
        uint64_t pushed = demod_spsc_push(rb, data, 8);
        ASSERT(pushed == 8, "wrap push failed");
        uint64_t popped = demod_spsc_pop(rb, out, 8);
        ASSERT(popped == 8, "wrap pop failed");
        for (int i = 0; i < 8; i++)
            ASSERT(out[i] == (float)i, "wrap value mismatch");
    }

    free(mem);
    PASS();
}

static void test_full(void) {
    TEST("full ring rejects push");
    size_t sz = demod_spsc_alloc_size(16);
    void *mem = aligned_alloc(64, sz);
    DemodSpsc *rb = demod_spsc_init(mem, 16);

    float data[16];
    memset(data, 0, sizeof(data));

    uint64_t pushed = demod_spsc_push(rb, data, 16);
    ASSERT(pushed == 16, "fill push failed");

    float extra = 1.0f;
    pushed = demod_spsc_push(rb, &extra, 1);
    ASSERT(pushed == 0, "push to full ring should return 0");

    free(mem);
    PASS();
}

static void test_empty(void) {
    TEST("empty ring returns 0");
    size_t sz = demod_spsc_alloc_size(16);
    void *mem = aligned_alloc(64, sz);
    DemodSpsc *rb = demod_spsc_init(mem, 16);

    float out;
    uint64_t popped = demod_spsc_pop(rb, &out, 1);
    ASSERT(popped == 0, "pop from empty should return 0");

    free(mem);
    PASS();
}

/* ── Threaded Stress Test ────────────────────────────────────── */

typedef struct {
    DemodSpsc *rb;
    int count;
} ThreadArg;

static void *producer_thread(void *arg) {
    ThreadArg *ta = (ThreadArg *)arg;
    for (int i = 0; i < ta->count; i++) {
        float val = (float)i;
        while (demod_spsc_push(ta->rb, &val, 1) == 0) {
            /* spin — acceptable in test, never in RT */
        }
    }
    return NULL;
}

static void *consumer_thread(void *arg) {
    ThreadArg *ta = (ThreadArg *)arg;
    float out;
    int expected = 0;
    while (expected < ta->count) {
        if (demod_spsc_pop(ta->rb, &out, 1) == 1) {
            if ((int)out != expected) {
                fprintf(stderr, "    MISMATCH: got %d expected %d\n", (int)out, expected);
                return (void *)1;
            }
            expected++;
        }
    }
    return NULL;
}

static void test_threaded(void) {
    TEST("threaded stress (1M items)");
    size_t sz = demod_spsc_alloc_size(CAP);
    void *mem = aligned_alloc(64, sz);
    DemodSpsc *rb = demod_spsc_init(mem, CAP);

    ThreadArg arg = { .rb = rb, .count = ITERATIONS };
    pthread_t prod, cons;

    pthread_create(&cons, NULL, consumer_thread, &arg);
    pthread_create(&prod, NULL, producer_thread, &arg);

    void *prod_ret, *cons_ret;
    pthread_join(prod, &prod_ret);
    pthread_join(cons, &cons_ret);

    ASSERT(cons_ret == NULL, "consumer detected mismatch");

    free(mem);
    PASS();
}

/* ── Invalid Args ────────────────────────────────────────────── */

static void test_invalid_capacity(void) {
    TEST("reject non-power-of-2 capacity");
    size_t sz = demod_spsc_alloc_size(1024);
    void *mem = aligned_alloc(64, sz);

    DemodSpsc *rb = demod_spsc_init(mem, 100); /* not power of 2 */
    ASSERT(rb == NULL, "should reject non-po2");

    rb = demod_spsc_init(mem, 0);
    ASSERT(rb == NULL, "should reject 0");

    rb = demod_spsc_init(NULL, 1024);
    ASSERT(rb == NULL, "should reject NULL");

    free(mem);
    PASS();
}

/* ── Runner ──────────────────────────────────────────────────── */

int main(void) {
    printf("=== SPSC Ring Buffer Tests ===\n");

    test_init();
    test_push_pop();
    test_batch();
    test_wraparound();
    test_full();
    test_empty();
    test_threaded();
    test_invalid_capacity();

    printf("\n%d passed, %d failed\n", tests_passed, tests_failed);
    return tests_failed > 0 ? 1 : 0;
}
