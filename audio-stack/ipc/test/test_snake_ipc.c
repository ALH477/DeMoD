// Test for snake_ipc.h SPSC ring buffer
// Compile: gcc -std=c11 -I../include -I. -pthread test_snake_ipc.c -o test_snake_ipc
#include "../include/snake_ipc.h"
#include <stdio.h>
#include <stdlib.h>
#include <assert.h>
#include <string.h>
#include <pthread.h>

#define TEST_CAP 4096u

static void test_init(void) {
    size_t sz = snake_spsc_alloc_size(TEST_CAP);
    void *mem = calloc(1, sz);
    assert(mem);
    
    SnakeSpsc *rb = snake_spsc_init(mem, TEST_CAP);
    assert(rb != NULL);
    assert(rb->capacity == TEST_CAP);
    assert(rb->mask == TEST_CAP - 1);
    
    // Empty ring
    assert(snake_spsc_available_read(rb) == 0);
    assert(snake_spsc_available_write(rb) == TEST_CAP);
    
    // Pop from empty returns 0
    float buf[64];
    assert(snake_spsc_pop(rb, buf, 64) == 0);
    
    free(mem);
    printf("  PASS: test_init\n");
}

static void test_push_pop(void) {
    size_t sz = snake_spsc_alloc_size(TEST_CAP);
    void *mem = calloc(1, sz);
    SnakeSpsc *rb = snake_spsc_init(mem, TEST_CAP);
    
    // Push 100 samples
    float data[100];
    for (int i = 0; i < 100; i++) data[i] = (float)i;
    assert(snake_spsc_push(rb, data, 100) == 100);
    assert(snake_spsc_available_read(rb) == 100);
    
    // Pop 50
    float buf[50];
    assert(snake_spsc_pop(rb, buf, 50) == 50);
    for (int i = 0; i < 50; i++) assert(buf[i] == (float)i);
    
    // Pop remaining 50
    assert(snake_spsc_pop(rb, buf, 50) == 50);
    for (int i = 0; i < 50; i++) assert(buf[i] == (float)(i + 50));
    
    // Empty again
    assert(snake_spsc_pop(rb, buf, 1) == 0);
    
    free(mem);
    printf("  PASS: test_push_pop\n");
}

static void test_wrap_around(void) {
    size_t sz = snake_spsc_alloc_size(TEST_CAP);
    void *mem = calloc(1, sz);
    SnakeSpsc *rb = snake_spsc_init(mem, TEST_CAP);
    
    // Fill to near capacity
    float *data = malloc(TEST_CAP * sizeof(float));
    for (uint64_t i = 0; i < TEST_CAP - 10; i++) data[i] = (float)i;
    assert(snake_spsc_push(rb, data, TEST_CAP - 10) == TEST_CAP - 10);
    
    // Pop half
    float *buf = malloc(TEST_CAP * sizeof(float));
    assert(snake_spsc_pop(rb, buf, (TEST_CAP - 10) / 2) == (TEST_CAP - 10) / 2);
    
    // Push more (wraps around)
    for (uint64_t i = 0; i < TEST_CAP / 2; i++) data[i] = 1000.0f + (float)i;
    assert(snake_spsc_push(rb, data, TEST_CAP / 2) == TEST_CAP / 2);
    
    // Pop all and verify
    uint64_t total = snake_spsc_available_read(rb);
    uint64_t popped = 0;
    while (popped < total) {
        uint64_t n = snake_spsc_pop(rb, buf, 256);
        if (n == 0) break;
        popped += n;
    }
    assert(popped == total);
    
    free(data);
    free(buf);
    free(mem);
    printf("  PASS: test_wrap_around\n");
}

static void test_full_ring(void) {
    size_t sz = snake_spsc_alloc_size(TEST_CAP);
    void *mem = calloc(1, sz);
    SnakeSpsc *rb = snake_spsc_init(mem, TEST_CAP);
    
    // Fill completely
    float *data = malloc(TEST_CAP * sizeof(float));
    for (uint64_t i = 0; i < TEST_CAP; i++) data[i] = (float)i;
    assert(snake_spsc_push(rb, data, TEST_CAP) == TEST_CAP);
    
    // Push more should return 0
    assert(snake_spsc_push(rb, data, 1) == 0);
    
    free(data);
    free(mem);
    printf("  PASS: test_full_ring\n");
}

// Threaded stress test
typedef struct {
    SnakeSpsc *rb;
    uint64_t count;
} thread_arg_t;

static void *producer_thread(void *arg) {
    thread_arg_t *ta = (thread_arg_t *)arg;
    float buf[64];
    uint64_t produced = 0;
    
    while (produced < ta->count) {
        uint64_t n = 64;
        if (n > ta->count - produced) n = ta->count - produced;
        for (uint64_t i = 0; i < n; i++) buf[i] = (float)(produced + i);
        uint64_t pushed = snake_spsc_push(ta->rb, buf, n);
        if (pushed > 0) {
            produced += pushed;
        } else {
            // Spin (simulates RT callback retry)
            __asm__ volatile("pause" ::: "memory");
        }
    }
    return NULL;
}

static void *consumer_thread(void *arg) {
    thread_arg_t *ta = (thread_arg_t *)arg;
    float buf[64];
    uint64_t consumed = 0;
    
    while (consumed < ta->count) {
        uint64_t n = snake_spsc_pop(ta->rb, buf, 64);
        if (n > 0) {
            // Verify ordering
            for (uint64_t i = 0; i < n; i++) {
                assert(buf[i] == (float)(consumed + i));
            }
            consumed += n;
        } else {
            __asm__ volatile("pause" ::: "memory");
        }
    }
    return NULL;
}

static void test_threaded(void) {
    size_t sz = snake_spsc_alloc_size(TEST_CAP);
    void *mem = calloc(1, sz);
    SnakeSpsc *rb = snake_spsc_init(mem, TEST_CAP);
    
    uint64_t count = 1000000;
    thread_arg_t prod_arg = { .rb = rb, .count = count };
    thread_arg_t cons_arg = { .rb = rb, .count = count };
    
    pthread_t prod, cons;
    pthread_create(&prod, NULL, producer_thread, &prod_arg);
    pthread_create(&cons, NULL, consumer_thread, &cons_arg);
    pthread_join(prod, NULL);
    pthread_join(cons, NULL);
    
    // Ring should be empty
    assert(snake_spsc_available_read(rb) == 0);
    
    free(mem);
    printf("  PASS: test_threaded (1M samples, ordered)\n");
}

int main(void) {
    printf("snake_ipc SPSC ring buffer tests:\n");
    test_init();
    test_push_pop();
    test_wrap_around();
    test_full_ring();
    test_threaded();
    printf("All tests passed.\n");
    return 0;
}
