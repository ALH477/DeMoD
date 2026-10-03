# SPDX-License-Identifier: LGPL-3.0-only
# demod-remote-bridge — engine-side UDP bridge for the DCF remote transport.
# Copyright (C) 2025-2026 DeMoD LLC. LGPL-3.0-only; see LICENSES/LGPL-3.0-only.txt.

CC     ?= cc
CFLAGS ?= -Wall -Wextra -O2 -std=c11
# vendored DCF codecs (../../third_party/hydramesh), the meters struct
# (../ipc/include), and framework headers (../../include).
INCS   := -I../../third_party -I../ipc/include -I../../include
LDLIBS := -lm

BIN := demod-remote-bridge

# The datagram gate: Exsecutor's custos, emitted as C (see
# ../../web/bridge/custos/PROVENANCE.md). One copy serves both relays: the
# browser's dcf-ws-bridge compiles it from build.rs, this bridge from here.
# Its own flags, not $(CFLAGS): the emitted prologue #errors on -ffast-math
# (Exsecutor spec 5.4), and every unit carries helpers it does not call.
CUSTOS        := ../../web/bridge/custos/custos.gen.c
CUSTOS_CFLAGS ?= -std=c11 -O2 -fno-fast-math -Wno-unused-function

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

custos.o: $(CUSTOS)
	$(CC) $(CUSTOS_CFLAGS) -c -o $@ $<

$(BIN): demod-remote-bridge.c custos.o
	$(CC) $(CFLAGS) $(INCS) -o $@ demod-remote-bridge.c custos.o $(LDLIBS)

audiocast: demod-dcf-audiocast
demod-dcf-audiocast: demod-dcf-audiocast.c
	$(CC) $(CFLAGS) $(CAST_INCS) -o $@ $< $(CAST_LIBS)

clean:
	rm -f $(BIN) custos.o demod-dcf-audiocast
