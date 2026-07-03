/* demod_bt_ffi.c — translation unit that declares the demod-bt BLE-MIDI
 * symbols so the cabal build links against libdemod_bt.
 *
 * Copyright (C) 2025–2026 DeMoD LLC
 * SPDX-License-Identifier: GPL-3.0-only
 *
 * No wrappers are defined here — Haskell calls the upstream symbols
 * directly via foreign import ccall. The TU exists only to give the
 * cabal `c-sources` field a file to compile, ensuring the include
 * path is wired through. Linking against libdemod_bt.so is handled by
 * the cabal `extra-libraries: demod_bt` field.
 */

#include "demod_bt_ffi.h"

/* Anchor symbol — keeps the TU from being empty in pedantic builds. */
const char demod_bt_ffi_module[] = "demod-bt-ffi";
