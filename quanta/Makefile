# demod-quanta v0.1.0 — Copyright (c) 2026 DeMoD LLC
CC      ?= gcc
CFLAGS  ?= -O2 -std=c11 -Wall -Wextra -Iinclude \
           -ffp-contract=off -fno-fast-math -fwrapv
BINS = bin/quanta-analyzer bin/quanta-render bin/quanta-freeze bin/quanta-stream bin/quanta-stream-decode bin/quanta-pack bin/quanta-score bin/quanta-speech-analyze bin/quanta-speech-render bin/quanta-speech-sines bin/quanta-unit-render bin/quanta-unit-enroll bin/quanta-unit-encode bin/quanta-unit-freeze

all: $(BINS)
bin/quanta-%: src/%.c include/qsc.h include/qrender.h include/mp.h include/qss.h include/qbits.h include/qsp.h include/qlsf.h include/qvq.h include/qspu.h include/qva.h include/qunit.h
	@mkdir -p bin
	$(CC) $(CFLAGS) $< -o $@ -lm

test: all
	bash test/run.sh

unit-null: all
	bash test/unit_null.sh

transparency: all
	bash test/transparency.sh

coherent: all
	bash test/coherent.sh

throughline: all
	bash test/throughline.sh

clean:
	rm -rf bin test/*.f64 test/*.wav test/*.qsc test/gen.c test/harness \
	       test/out.dsp test/src.wav
.PHONY: all test unit-null transparency coherent throughline clean
