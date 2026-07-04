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

# demod-dcf-audiocast is a JACK+Opus client (extra deps), so it is a SEPARATE
# target — the default `all` keeps demod-remote-bridge dependency-free (libc+libm).
# Build it explicitly: `make demod-dcf-audiocast` (needs pkg-config jack + opus).
PKG_CONFIG ?= pkg-config
# demod_audio.h includes <opus/opus.h>; nixpkgs' opus.pc points -I at include/opus,
# so also add its parent so the opus/ prefix resolves (a no-op elsewhere).
OPUS_INCDIR := $(shell $(PKG_CONFIG) --variable=includedir opus 2>/dev/null)
CAST_INCS  := -I../../third_party $(shell $(PKG_CONFIG) --cflags jack opus 2>/dev/null) \
              $(if $(OPUS_INCDIR),-I$(OPUS_INCDIR),)
CAST_LIBS  := $(shell $(PKG_CONFIG) --libs jack opus 2>/dev/null) -lm

.PHONY: all clean audiocast
all: $(BIN)

$(BIN): demod-remote-bridge.c
	$(CC) $(CFLAGS) $(INCS) -o $@ $< $(LDLIBS)

audiocast: demod-dcf-audiocast
demod-dcf-audiocast: demod-dcf-audiocast.c
	$(CC) $(CFLAGS) $(CAST_INCS) -o $@ $< $(CAST_LIBS)

clean:
	rm -f $(BIN) demod-dcf-audiocast
