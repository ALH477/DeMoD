# DeMoD — Makefile (for quick iteration without cmake)
# Production builds should use: cmake -B build -G Ninja && cmake --build build

CC      := gcc
CFLAGS  := -std=c17 -Wall -Wextra -Wpedantic -Wshadow -Wconversion \
           -Wdouble-promotion -Wformat=2 -Wundef -Wnull-dereference \
           -fstack-protector-strong -D_GNU_SOURCE
LDFLAGS := -lpthread -lrt -lm
IPC_INC := -Iipc/include
RT_INC  := -Irt-audio/include $(IPC_INC)

.PHONY: all test clean

all: test

# ── IPC Tests ──────────────────────────────────────────────
build/test-spsc: ipc/test/test_spsc.c ipc/include/demod_spsc.h
	@mkdir -p build
	$(CC) $(CFLAGS) $(IPC_INC) -o $@ $< $(LDFLAGS)

build/test-triple: ipc/test/test_triple_buf.c ipc/include/demod_triple_buf.h
	@mkdir -p build
	$(CC) $(CFLAGS) $(IPC_INC) -o $@ $< $(LDFLAGS)

build/test-shm: ipc/test/test_shm.c ipc/include/demod_shm.h ipc/include/demod_triple_buf.h ipc/include/demod_spsc.h
	@mkdir -p build
	$(CC) $(CFLAGS) $(IPC_INC) -o $@ $< $(LDFLAGS)

build/test-ffi: orchestrator/test/test_ffi_helpers.c orchestrator/cbits/demod_ffi_helpers.c
	@mkdir -p build
	$(CC) $(CFLAGS) $(IPC_INC) -Iorchestrator/cbits -o $@ $^ $(LDFLAGS)

build/test-audio-tap: ipc/test/test_audio_tap.c
	@mkdir -p build
	$(CC) $(CFLAGS) $(IPC_INC) -o $@ $< $(LDFLAGS)

build/test-commands: ipc/test/test_commands.c
	@mkdir -p build
	$(CC) $(CFLAGS) $(IPC_INC) -o $@ $< $(LDFLAGS)

test: build/test-spsc build/test-triple build/test-shm build/test-ffi build/test-audio-tap build/test-commands
	@echo "══════════════════════════════════════════"
	@echo "  DeMoD Test Suite"
	@echo "══════════════════════════════════════════"
	@./build/test-spsc && ./build/test-triple && ./build/test-shm && ./build/test-ffi && ./build/test-audio-tap && ./build/test-commands
	@echo "══════════════════════════════════════════"
	@echo "  All tests passed."
	@echo "══════════════════════════════════════════"

clean:
	rm -rf build/ build_test_*
