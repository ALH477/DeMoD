cmake_minimum_required(VERSION 3.20)
project(demod
    VERSION     0.4.0
    DESCRIPTION "DeMoD — Deterministic Music Operating Domain"
    LANGUAGES   C
)

set(CMAKE_C_STANDARD 17)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

option(
    DEMOD_NATIVE_OPTIMIZATIONS
    "Enable host-specific -march=native optimizations in release builds"
    OFF
)

set(DEMOD_RELEASE_COMPILE_OPTIONS
    -Wall -Wextra -Wpedantic -Wshadow -Wconversion
    -Wdouble-promotion -Wformat=2 -Wundef -Wnull-dereference
    -fstack-protector-strong
    -Werror -O2
)

if(DEMOD_NATIVE_OPTIMIZATIONS)
    list(APPEND DEMOD_RELEASE_COMPILE_OPTIONS -march=native)
endif()

# ── Strict warnings (DeMoD standard) ─────────────────────────────
if(CMAKE_BUILD_TYPE STREQUAL "Release")
    add_compile_options(${DEMOD_RELEASE_COMPILE_OPTIONS})
elseif(CMAKE_BUILD_TYPE STREQUAL "Debug")
    add_compile_options(
        -Wall -Wextra -Wpedantic -Wshadow -Wconversion
        -Wdouble-promotion -Wformat=2 -Wundef -Wnull-dereference
        -fstack-protector-strong
        -g -O0 -fsanitize=address,undefined
    )
    add_link_options(-fsanitize=address,undefined)
endif()

add_compile_definitions(_GNU_SOURCE _POSIX_C_SOURCE=200809L)

option(
    DEMOD_REQUIRE_RT_AUDIO
    "Fail configuration if demod-rt cannot be built"
    ON
)

# ── Dependencies ──────────────────────────────────────────────────
find_package(PkgConfig REQUIRED)
pkg_check_modules(JACK IMPORTED_TARGET jack)

# ── IPC Library (header-only) ─────────────────────────────────────
add_library(demod-ipc INTERFACE)
target_include_directories(demod-ipc INTERFACE ipc/include)

# ── FFI Helpers Library ───────────────────────────────────────────
add_library(demod-ffi-helpers STATIC orchestrator/cbits/demod_ffi_helpers.c)
target_include_directories(demod-ffi-helpers PUBLIC
    orchestrator/cbits
    ipc/include
)
target_link_libraries(demod-ffi-helpers PUBLIC rt pthread)

# ── RT Audio Binary ───────────────────────────────────────────────
if(JACK_FOUND)
    add_executable(demod-rt rt-audio/src/main.c)
    target_include_directories(demod-rt PRIVATE rt-audio/include ipc/include dsp/include)
    target_link_libraries(demod-rt PRIVATE PkgConfig::JACK dl rt pthread m)
    install(TARGETS demod-rt RUNTIME DESTINATION bin)
else()
    if(DEMOD_REQUIRE_RT_AUDIO)
        message(FATAL_ERROR
            "JACK not found — demod-rt is required. Install JACK development "
            "headers/libraries or configure with -DDEMOD_REQUIRE_RT_AUDIO=OFF "
            "to build only the non-RT components."
        )
    else()
        message(WARNING "JACK not found — skipping demod-rt")
    endif()
endif()

# ── Tests ─────────────────────────────────────────────────────────
option(BUILD_TESTING "Build tests" ON)
if(BUILD_TESTING)
    enable_testing()

    # IPC tests
    add_executable(test-spsc       ipc/test/test_spsc.c)
    add_executable(test-triple     ipc/test/test_triple_buf.c)
    add_executable(test-shm        ipc/test/test_shm.c)
    add_executable(test-audio-tap  ipc/test/test_audio_tap.c)
    add_executable(test-commands   ipc/test/test_commands.c)

    foreach(t test-spsc test-triple test-shm test-audio-tap test-commands)
        target_link_libraries(${t} PRIVATE demod-ipc pthread rt m)
        add_test(NAME ${t} COMMAND ${t})
    endforeach()
    set_tests_properties(test-shm test-audio-tap test-commands
        PROPERTIES RESOURCE_LOCK demod-ipc-shm)

    # FFI helpers test
    add_executable(test-ffi orchestrator/test/test_ffi_helpers.c)
    target_link_libraries(test-ffi PRIVATE demod-ffi-helpers m)
    add_test(NAME test-ffi COMMAND test-ffi)
endif()
