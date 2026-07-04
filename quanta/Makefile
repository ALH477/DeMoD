# demod-quanta v0.1.0 — Copyright (c) 2026 DeMoD LLC
CC      ?= gcc
CFLAGS  ?= -O2 -std=c11 -Wall -Wextra -Iinclude \
           -ffp-contract=off -fno-fast-math -fwrapv
BINS = bin/quanta-analyzer bin/quanta-render bin/quanta-freeze

all: $(BINS)
bin/quanta-%: src/%.c include/qsc.h
	@mkdir -p bin
	$(CC) $(CFLAGS) $< -o $@ -lm

test: all
	bash test/run.sh

clean:
	rm -rf bin test/*.f64 test/*.wav test/*.qsc test/gen.c test/harness \
	       test/out.dsp test/src.wav
.PHONY: all test clean
