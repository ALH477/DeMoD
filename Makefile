# SPDX-License-Identifier: MPL-2.0
# DeMoD UI Framework — Makefile
# Copyright (c) 2026 DeMoD LLC. Licensed under the Mozilla Public License, v. 2.0 (see LICENSE).

CC      ?= gcc
CFLAGS  = -Wall -Wextra -O2 -std=c11 -Iinclude -Isrc/crypto -Isrc/db
LDFLAGS = -lSDL2 -llua -lm

# Detect Lua version (distro-dependent pkg names)
LUA_CFLAGS  := $(shell pkg-config --cflags lua5.4 2>/dev/null || pkg-config --cflags lua 2>/dev/null)
LUA_LDFLAGS := $(shell pkg-config --libs   lua5.4 2>/dev/null || pkg-config --libs   lua 2>/dev/null)
SDL_CFLAGS  := $(shell pkg-config --cflags sdl2   2>/dev/null || echo "-I/usr/include/SDL2")
SDL_LDFLAGS := $(shell pkg-config --libs   sdl2   2>/dev/null || echo "-lSDL2")

CFLAGS  += $(LUA_CFLAGS) $(SDL_CFLAGS)
LDFLAGS  = $(LUA_LDFLAGS) $(SDL_LDFLAGS) -lm

SRCS = src/core/framebuffer.c \
       src/core/font.c \
       src/widgets/widgets.c \
        src/widgets/dsp_widgets.c \
        src/lua/lua_bindings.c \
        src/app/app.c \
        src/input/serial_encoder.c \
        src/input/midi_input.c \
        src/input/gamepad.c \
        src/ipc/demod_params.c \
        src/ipc/demod_rt_meters.c \
        src/ipc/demod_control.c \
        src/crypto/monocypher.c \
        src/crypto/monocypher-ed25519.c \
        src/db/streamdb.c \
        src/main.c \
        src/dsl/system_dsl.c \
        src/dsl/control_dsl.c

OBJS = $(SRCS:.c=.o)
BIN  = demod-ui
LINK = $(CC)

# ── Optional: local DSP backend (demodoom_core), enabled with LOCAL_DSP=1 ──
# Embeds the demod-dsp-gui ("demodoom") C++ engine for a real-audio desktop
# build. Requires that source tree, PipeWire, and optionally libfaust. The
# default (C-only) build is unaffected.
DEMODOOM_SRC ?= /path/to/demodoom/src
ifeq ($(LOCAL_DSP),1)
  CXX      ?= g++
  CFLAGS   += -DDEMOD_LOCAL_DSP
  CXXFLAGS  = -Wall -O2 -std=c++17 -Iinclude -I$(DEMODOOM_SRC) -DDEMOD_LOCAL_DSP \
              $(LUA_CFLAGS) $(SDL_CFLAGS) $(shell pkg-config --cflags libpipewire-0.3 2>/dev/null)
  LOCAL_OBJS = src/dsp/local_dsp_shim.o \
               $(DEMODOOM_SRC)/audio/fx_chain.o \
               $(DEMODOOM_SRC)/audio/faust_bridge.o \
               $(DEMODOOM_SRC)/audio/chiptune.o \
               $(DEMODOOM_SRC)/audio/audio_engine.o
  OBJS += $(LOCAL_OBJS)
  LDFLAGS += $(shell pkg-config --libs libpipewire-0.3 2>/dev/null) \
             $(shell pkg-config --libs faust 2>/dev/null) -lstdc++ -ldl -lpthread
  LINK = $(CXX)
endif

# ── Optional: Steam edition runtime (Steamworks SDK), enabled with STEAM=1 ──
# Links libsteam_api.so from the out-of-tree Steamworks SDK (DEMOD_STEAM_SDK,
# gitignored — Valve's redistributable is never committed). Compiles the C++
# shim (src/steam/steam_shim.cpp) and registers dm.steam; steam.lua drives it.
# The default (C-only, non-Steam) build is unaffected — dm.steam is then absent.
DEMOD_STEAM_SDK ?= /path/to/steamworks-sdk
STEAM_SDK_LIB   := $(DEMOD_STEAM_SDK)/redistributable_bin/linux64
ifeq ($(STEAM),1)
  CXX      ?= g++
  CFLAGS   += -DDEMOD_STEAM -I$(DEMOD_STEAM_SDK)/public
  CXXFLAGS += -Wall -O2 -std=c++17 -Iinclude -I$(DEMOD_STEAM_SDK)/public -DDEMOD_STEAM \
              $(LUA_CFLAGS) $(SDL_CFLAGS)
  OBJS += src/steam/steam_shim.o
  # rpath lets a locally-built binary find libsteam_api.so without LD_LIBRARY_PATH
  # (the Nix/AppImage path ships the .so + sets LD_LIBRARY_PATH instead).
  LDFLAGS += -L$(STEAM_SDK_LIB) -Wl,-rpath,$(STEAM_SDK_LIB) -lsteam_api -lstdc++
  LINK = $(CXX)
endif

# ── Optional: DCF (HydraMesh/UDP) remote transport, enabled with DCF=1 ──
# Adds the dm.dcf Lua binding (src/ipc/dm_dcf.c) — a UDP client that drives a
# remote engine over the DeMoD 17-byte frame codec (vendored, header-only, in
# third_party/hydramesh). Links libc only. The default build is byte-unchanged
# (dm.dcf is then absent and the DSP backends use the local socket path).
ifeq ($(DCF),1)
  CFLAGS += -DDEMOD_DCF -Ithird_party
  OBJS += src/ipc/dm_dcf.o
endif

# ── Targets ──────────────────────────────────────────────────────────

.PHONY: all clean run run-dsp run-studio run-viz run-launcher test font font-subset

all: $(BIN)

# ── Fonts (UTF-8 / CJK glyph blob, built from GNU Unifont) ───────────
# ASCII 32-126 is compiled in; all other Unicode BMP glyphs load at runtime
# from a .dmf blob (built here, autoloaded by src/core/font.c from $DEMOD_FONT
# -> ~/.local/share/demod/unifont.dmf -> ./unifont.dmf). GNU Unifont is OFL-1.1
# (see THIRD_PARTY_LICENSES.md). `make font` = full BMP (~2 MB, incl. CJK);
# `make font-subset` = Latin/Greek/Cyrillic + CJK only (~1.2 MB).
UNIFONT_VER ?= 16.0.04
UNIFONT_URL ?= https://unifoundry.com/pub/unifont/unifont-$(UNIFONT_VER)/font-builds/unifont_all-$(UNIFONT_VER).hex.gz
FONT_DIR    ?= $(HOME)/.local/share/demod

font: tools/genfont.py
	@mkdir -p $(FONT_DIR)
	curl -fsSL "$(UNIFONT_URL)" -o unifont_all.hex.gz
	gunzip -f unifont_all.hex.gz
	python3 tools/genfont.py unifont_all.hex $(FONT_DIR)/unifont.dmf
	@echo "installed $(FONT_DIR)/unifont.dmf"

font-subset: tools/genfont.py
	@mkdir -p $(FONT_DIR)
	curl -fsSL "$(UNIFONT_URL)" -o unifont_all.hex.gz
	gunzip -f unifont_all.hex.gz
	python3 tools/genfont.py unifont_all.hex $(FONT_DIR)/unifont-subset.dmf --subset eu --subset cjk
	@echo "installed $(FONT_DIR)/unifont-subset.dmf"

# ── Tests (display-free: measurement/decode paths only) ─────────────
TEST_BIN = tests/test_font_utf8
test: $(TEST_BIN)
	./$(TEST_BIN)

$(TEST_BIN): tests/test_font_utf8.c src/core/font.o src/core/framebuffer.o
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

$(BIN): $(OBJS)
	$(LINK) -o $@ $^ $(LDFLAGS)

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

%.o: %.cpp
	$(CXX) $(CXXFLAGS) -c -o $@ $<

clean:
	rm -f $(OBJS) $(BIN)

run: $(BIN)
	./$(BIN) examples/hello.lua

run-dsp: $(BIN)
	./$(BIN) examples/dsp_panel.lua

run-studio: $(BIN)
	./$(BIN) examples/dsp_studio.lua

run-viz: $(BIN)
	./$(BIN) examples/systems_viz.lua

run-launcher: $(BIN)
	./$(BIN) examples/card_launcher.lua

# ── Dependencies ─────────────────────────────────────────────────────

src/core/framebuffer.o:     include/demod/framebuffer.h
src/core/font.o:            include/demod/framebuffer.h include/demod/font.h
src/widgets/widgets.o:      include/demod/framebuffer.h include/demod/font.h include/demod/widget.h
src/widgets/dsp_widgets.o:  include/demod/framebuffer.h include/demod/font.h include/demod/widget.h
src/lua/lua_bindings.o:     include/demod/app.h include/demod/widget.h
src/app/app.o:              include/demod/app.h include/demod/widget.h
src/main.o:                 include/demod/app.h
