/* demod_bt_ffi.h — Thin C declarations for the demod-bt BLE-MIDI FFI.
 *
 * Copyright (C) 2025–2026 DeMoD LLC
 * SPDX-License-Identifier: GPL-3.0-only
 *
 * Mirrors a subset of <demod_bt.h> — only the BLE-MIDI surface used by
 * DeMoD.BT.FFI. The orchestrator does not link the audio plane (A2DP);
 * libdemod_bt is brought in solely for the BLE-MIDI peripheral.
 *
 * The actual symbols are provided by libdemod_bt.so (or .a). This
 * header just gives the cabal `c-sources` translation unit something
 * to compile against without pulling demod-bt's full include directory.
 */

#ifndef DEMOD_BT_FFI_H
#define DEMOD_BT_FFI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int  demod_bt_midi_start(const char *device_name);
int  demod_bt_midi_send(const uint8_t *bytes, unsigned len);
void demod_bt_midi_stop(void);

#ifdef __cplusplus
}
#endif

#endif /* DEMOD_BT_FFI_H */
