# SPDX-License-Identifier: MPL-2.0
# DeMoD UI Framework — portable CMake build (ADDITIVE; the Unix Makefile is
# unchanged and remains the canonical Linux/Nix/AppImage build).
#
# This CMake path exists to build the framework as a cross-platform *remote GUI
# client* (Linux / macOS / Windows) that drives a Linux engine over DCF/UDP. The
# Linux-only local backend (AF_UNIX control socket, /dev/shm param+meter bus,
# ALSA rawmidi) and the POSIX-only serial encoder are compiled everywhere but
# gate to harmless stubs off their supported platform (see src/ipc/*, src/input/*),
# so the Lua side transparently falls back to the remote (dm.dcf) transport.
#
# Copyright (c) 2026 DeMoD LLC. Licensed under the Mozilla Public License, v. 2.0.

cmake_minimum_required(VERSION 3.16)
project(demod-ui C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

# ── Emscripten / WebAssembly build ──────────────────────────────────────────
# Additive branch: builds the *real* C/SDL2/Lua UI to WASM so it runs on a
# <canvas> in a browser. Entirely gated on EMSCRIPTEN (set by emcmake), so the
# native find_package(SDL2/Lua) path below is byte-unchanged off Emscripten.
#   emcmake cmake -S . -B build-wasm && cmake --build build-wasm
# Produces build-wasm/demod-ui.{js,wasm,data}. No DCF (phase B), no pthreads.
if(EMSCRIPTEN)
  include(FetchContent)

  # Lua 5.4.7 from source — Emscripten ships no Lua. Build the library .c files
  # (excluding the lua.c / luac.c CLI drivers) into a static lib.
  FetchContent_Declare(lua_upstream
    URL      https://www.lua.org/ftp/lua-5.4.7.tar.gz
    URL_HASH SHA256=9fbf5e28ef86c69858f6d3d34eccc32e911c1a28b4120ff3e84aaa70cfbf1e30
  )
  FetchContent_MakeAvailable(lua_upstream)
  set(LUA_SRC_DIR ${lua_upstream_SOURCE_DIR}/src)
  set(LUA_LIB_C
    lapi lcode lctype ldebug ldo ldump lfunc lgc llex lmem lobject lopcodes
    lparser lstate lstring ltable ltm lundump lvm lzio
    lauxlib lbaselib lcorolib ldblib liolib lmathlib loadlib loslib lstrlib
    ltablib lutf8lib linit)
  set(LUA_SOURCES "")
  foreach(u ${LUA_LIB_C})
    list(APPEND LUA_SOURCES ${LUA_SRC_DIR}/${u}.c)
  endforeach()
  add_library(demod_lua STATIC ${LUA_SOURCES})
  target_include_directories(demod_lua PUBLIC ${LUA_SRC_DIR})

  # demod sources: CORE + the (stubbed-off-platform) IPC/input + crypto +
  # streamdb. No dm_dcf.c (phase B). streamdb runs its inline-flush no-thread
  # path (also selected by the __EMSCRIPTEN__ guard in streamdb.c).
  set(WASM_SOURCES
    src/core/framebuffer.c
    src/core/font.c
    src/widgets/widgets.c
    src/widgets/dsp_widgets.c
    src/lua/lua_bindings.c
    src/app/app.c
    src/main.c
    src/dsl/system_dsl.c
    src/dsl/control_dsl.c
    src/crypto/monocypher.c
    src/crypto/monocypher-ed25519.c
    src/db/streamdb.c
    src/input/gamepad.c
    src/ipc/demod_control.c
    src/ipc/demod_params.c
    src/ipc/demod_rt_meters.c
    src/input/midi_input.c
    src/input/serial_encoder.c
  )

  add_executable(demod-ui ${WASM_SOURCES})
  target_include_directories(demod-ui PRIVATE
    ${CMAKE_SOURCE_DIR}/include
    ${CMAKE_SOURCE_DIR}/src
    ${CMAKE_SOURCE_DIR}/src/crypto
    ${CMAKE_SOURCE_DIR}/src/db
    ${LUA_SRC_DIR}
  )
  target_compile_definitions(demod-ui PRIVATE STREAMDB_NO_THREADS)
  # -sUSE_SDL=2 in CFLAGS so <SDL2/SDL.h> resolves from the emscripten port.
  target_compile_options(demod-ui PRIVATE "SHELL:-sUSE_SDL=2")
  target_link_libraries(demod-ui PRIVATE demod_lua)

  # The dsp_studio example is preloaded into MEMFS as main.lua (main.c's default
  # entry when no argv is given, which is the case in the browser).
  target_link_options(demod-ui PRIVATE
    "SHELL:-sUSE_SDL=2"
    "SHELL:-sALLOW_MEMORY_GROWTH=1"
    "SHELL:-sEXIT_RUNTIME=0"
    "SHELL:-sEXPORTED_RUNTIME_METHODS=['callMain','FS']"
    "SHELL:--preload-file ${CMAKE_SOURCE_DIR}/examples/dsp_studio.lua@main.lua"
  )
  # Emit demod-ui.js (+ .wasm + .data), not an .html shell (web/index.html hosts).
  set_target_properties(demod-ui PROPERTIES OUTPUT_NAME demod-ui SUFFIX ".js")

  return()  # Skip the native find_package path entirely on Emscripten.
endif()

# ── Options ────────────────────────────────────────────────────────────────
# DEMOD_CLIENT: build as a remote GUI client. Defaults ON off-Linux (where there
# is no local engine to talk to) and OFF on Linux (the device/desktop can host
# the local backend). It forces the DCF transport on so the client can reach a
# remote engine.
if(CMAKE_SYSTEM_NAME MATCHES "Linux")
  option(DEMOD_CLIENT "Build as a remote GUI client (DCF transport)" OFF)
else()
  option(DEMOD_CLIENT "Build as a remote GUI client (DCF transport)" ON)
endif()

# DEMOD_DCF: compile the dm.dcf UDP transport binding. Independently toggleable.
option(DEMOD_DCF "Build the DCF/UDP remote transport (dm.dcf)" ON)
if(DEMOD_CLIENT)
  set(DEMOD_DCF ON CACHE BOOL "Build the DCF/UDP remote transport (dm.dcf)" FORCE)
endif()

# ── Dependencies: SDL2 + Lua 5.4 ────────────────────────────────────────────
find_package(SDL2 QUIET)
find_package(Lua QUIET)  # provides LUA_INCLUDE_DIR / LUA_LIBRARIES

# pkg-config fallback (Linux/macOS distros where the CMake configs are absent).
find_package(PkgConfig QUIET)
if(NOT SDL2_FOUND AND PkgConfig_FOUND)
  pkg_check_modules(SDL2PC QUIET sdl2)
endif()
if(NOT LUA_FOUND AND PkgConfig_FOUND)
  pkg_check_modules(LUAPC QUIET lua5.4)
  if(NOT LUAPC_FOUND)
    pkg_check_modules(LUAPC QUIET lua)
  endif()
endif()

# Normalize into DEMOD_SDL2_* / DEMOD_LUA_* used below.
if(SDL2_FOUND)
  set(DEMOD_SDL2_INCLUDE ${SDL2_INCLUDE_DIRS})
  if(TARGET SDL2::SDL2)
    set(DEMOD_SDL2_LIBS SDL2::SDL2)
  else()
    set(DEMOD_SDL2_LIBS ${SDL2_LIBRARIES})
  endif()
elseif(SDL2PC_FOUND)
  set(DEMOD_SDL2_INCLUDE ${SDL2PC_INCLUDE_DIRS})
  set(DEMOD_SDL2_LIBS ${SDL2PC_LIBRARIES})
  link_directories(${SDL2PC_LIBRARY_DIRS})
else()
  message(FATAL_ERROR "SDL2 not found (tried find_package(SDL2) and pkg-config sdl2)")
endif()

if(LUA_FOUND)
  set(DEMOD_LUA_INCLUDE ${LUA_INCLUDE_DIR})
  set(DEMOD_LUA_LIBS ${LUA_LIBRARIES})
elseif(LUAPC_FOUND)
  set(DEMOD_LUA_INCLUDE ${LUAPC_INCLUDE_DIRS})
  set(DEMOD_LUA_LIBS ${LUAPC_LIBRARIES})
  link_directories(${LUAPC_LIBRARY_DIRS})
else()
  message(FATAL_ERROR "Lua 5.4 not found (tried find_package(Lua) and pkg-config lua5.4/lua)")
endif()

# ── Source groups ───────────────────────────────────────────────────────────
# CORE: always portable, no platform code.
set(CORE_SOURCES
  src/core/framebuffer.c
  src/core/font.c
  src/widgets/widgets.c
  src/widgets/dsp_widgets.c
  src/lua/lua_bindings.c
  src/app/app.c
  src/main.c
  src/dsl/system_dsl.c
  src/dsl/control_dsl.c
  src/crypto/monocypher.c
  src/crypto/monocypher-ed25519.c
  src/db/streamdb.c
  src/input/gamepad.c        # pure SDL GameController — portable
)

# LOCAL: Linux/POSIX backends. Compiled EVERYWHERE — they are #ifdef-gated to
# stubs off their platform (Task C), so lua_bindings.c's externs always resolve
# and the same binary runs anywhere (falling back to the remote transport).
set(LOCAL_SOURCES
  src/ipc/demod_control.c
  src/ipc/demod_params.c
  src/ipc/demod_rt_meters.c
  src/input/midi_input.c
  src/input/serial_encoder.c
)

# DCF: the portable UDP remote transport (Winsock-shimmed via platform/compat.h).
set(DCF_SOURCES src/ipc/dm_dcf.c)

set(DEMOD_SOURCES ${CORE_SOURCES} ${LOCAL_SOURCES})
if(DEMOD_DCF)
  list(APPEND DEMOD_SOURCES ${DCF_SOURCES})
endif()

add_executable(demod-ui ${DEMOD_SOURCES})

target_include_directories(demod-ui PRIVATE
  ${CMAKE_SOURCE_DIR}/include
  ${CMAKE_SOURCE_DIR}/src
  ${CMAKE_SOURCE_DIR}/src/crypto
  ${CMAKE_SOURCE_DIR}/src/db
  ${CMAKE_SOURCE_DIR}/third_party   # hydramesh header-only codec for dm_dcf.c
  ${DEMOD_SDL2_INCLUDE}
  ${DEMOD_LUA_INCLUDE}
)

if(DEMOD_DCF)
  target_compile_definitions(demod-ui PRIVATE DEMOD_DCF)
endif()
if(DEMOD_CLIENT)
  target_compile_definitions(demod-ui PRIVATE DEMOD_CLIENT)
endif()

target_link_libraries(demod-ui PRIVATE ${DEMOD_SDL2_LIBS} ${DEMOD_LUA_LIBS})
if(NOT WIN32)
  target_link_libraries(demod-ui PRIVATE m)
endif()
if(WIN32)
  target_link_libraries(demod-ui PRIVATE ws2_32)  # Winsock for dm_dcf.c
endif()

install(TARGETS demod-ui RUNTIME DESTINATION bin)
