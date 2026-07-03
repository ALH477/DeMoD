# SPDX-License-Identifier: LGPL-3.0-only
# demod-remote-bridge — engine-side UDP bridge for the DCF remote transport.
# Copyright (C) 2025-2026 DeMoD LLC. LGPL-3.0-only; see LICENSE.

CC     ?= cc
CFLAGS ?= -Wall -Wextra -O2 -std=c11
# vendored DCF codecs (../../third_party/hydramesh), the meters struct
# (../ipc/include), and framework headers (../../include).
INCS   := -I../../third_party -I../ipc/include -I../../include
LDLIBS := -lm

BIN := demod-remote-bridge

.PHONY: all clean
all: $(BIN)

$(BIN): demod-remote-bridge.c
	$(CC) $(CFLAGS) $(INCS) -o $@ $< $(LDLIBS)

clean:
	rm -f $(BIN)
