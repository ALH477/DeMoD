/*
 * demod_marketplace_shm.h -- shared UI/orchestrator Marketplace payload IPC.
 *
 * Copyright (C) 2025-2026 DeMoD LLC
 * SPDX-License-Identifier: GPL-3.0-only
 */

#ifndef DEMOD_MARKETPLACE_SHM_H
#define DEMOD_MARKETPLACE_SHM_H

#include <stdatomic.h>
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define DEMOD_MKT_SHM_NAME "/demod-mkt-shm"
#define DEMOD_MKT_SHM_SIZE 65536u
#define DEMOD_MKT_PAYLOAD_MAX (DEMOD_MKT_SHM_SIZE - 64u)

typedef enum DemodMktPayloadType {
    DEMOD_MKT_PAYLOAD_NONE    = 0,
    DEMOD_MKT_PAYLOAD_CATALOG = 1,
    DEMOD_MKT_PAYLOAD_DETAIL  = 2,
    DEMOD_MKT_PAYLOAD_LIBRARY = 3,
    DEMOD_MKT_PAYLOAD_STATUS  = 4,
    DEMOD_MKT_PAYLOAD_EVENT   = 5,
    DEMOD_MKT_PAYLOAD_OFFLINE = 6,
} DemodMktPayloadType;

typedef struct DemodMktShmHeader {
    _Atomic uint32_t generation;
    uint32_t payload_type;
    uint32_t payload_len;
    uint32_t _reserved;
    uint8_t payload[DEMOD_MKT_PAYLOAD_MAX];
} DemodMktShmHeader;

typedef struct DemodMktShm DemodMktShm;

DemodMktShm *demod_mkt_shm_create(const char *name);
void demod_mkt_shm_destroy(DemodMktShm *handle);
int demod_mkt_shm_write_json(
    DemodMktShm *handle,
    uint32_t payload_type,
    const uint8_t *payload,
    size_t payload_len);

#ifdef __cplusplus
}
#endif

#endif /* DEMOD_MARKETPLACE_SHM_H */
