/*
 * demod_marketplace_shm.c -- shared UI/orchestrator Marketplace payload IPC.
 *
 * Copyright (C) 2025-2026 DeMoD LLC
 * SPDX-License-Identifier: GPL-3.0-only
 */

#include "demod_marketplace_shm.h"

#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

struct DemodMktShm {
    int fd;
    size_t size;
    char name[64];
    DemodMktShmHeader *header;
};

DemodMktShm *demod_mkt_shm_create(const char *name) {
    const char *shm_name = (name && name[0]) ? name : DEMOD_MKT_SHM_NAME;
    int fd = shm_open(shm_name, O_CREAT | O_RDWR | O_TRUNC, 0660);
    if (fd < 0) {
        return NULL;
    }

    if (fchmod(fd, 0660) < 0) {
        const int err = errno;
        close(fd);
        shm_unlink(shm_name);
        errno = err;
        return NULL;
    }

    if (ftruncate(fd, (off_t)DEMOD_MKT_SHM_SIZE) < 0) {
        const int err = errno;
        close(fd);
        shm_unlink(shm_name);
        errno = err;
        return NULL;
    }

    void *addr = mmap(
        NULL,
        DEMOD_MKT_SHM_SIZE,
        PROT_READ | PROT_WRITE,
        MAP_SHARED | MAP_POPULATE,
        fd,
        0);
    if (addr == MAP_FAILED) {
        const int err = errno;
        close(fd);
        shm_unlink(shm_name);
        errno = err;
        return NULL;
    }

    (void)mlock(addr, DEMOD_MKT_SHM_SIZE);
    memset(addr, 0, DEMOD_MKT_SHM_SIZE);

    DemodMktShm *handle = calloc(1, sizeof(*handle));
    if (!handle) {
        const int err = errno;
        munmap(addr, DEMOD_MKT_SHM_SIZE);
        close(fd);
        shm_unlink(shm_name);
        errno = err;
        return NULL;
    }

    handle->fd = fd;
    handle->size = DEMOD_MKT_SHM_SIZE;
    handle->header = (DemodMktShmHeader *)addr;
    snprintf(handle->name, sizeof(handle->name), "%s", shm_name);
    atomic_store_explicit(&handle->header->generation, 0, memory_order_release);
    return handle;
}

void demod_mkt_shm_destroy(DemodMktShm *handle) {
    if (!handle) {
        return;
    }
    if (handle->header) {
        munmap(handle->header, handle->size);
    }
    if (handle->fd >= 0) {
        close(handle->fd);
    }
    if (handle->name[0]) {
        shm_unlink(handle->name);
    }
    free(handle);
}

int demod_mkt_shm_write_json(
    DemodMktShm *handle,
    uint32_t payload_type,
    const uint8_t *payload,
    size_t payload_len)
{
    if (!handle || !handle->header || (!payload && payload_len > 0)) {
        return -EINVAL;
    }
    if (payload_len >= DEMOD_MKT_PAYLOAD_MAX) {
        return -EMSGSIZE;
    }

    DemodMktShmHeader *header = handle->header;
    uint32_t generation = atomic_load_explicit(&header->generation, memory_order_acquire);
    if ((generation & 1u) != 0u) {
        generation++;
    }

    atomic_store_explicit(&header->generation, generation + 1u, memory_order_release);
    header->payload_type = payload_type;
    header->payload_len = (uint32_t)payload_len;
    if (payload_len > 0) {
        memcpy(header->payload, payload, payload_len);
    }
    header->payload[payload_len] = 0;
    atomic_store_explicit(&header->generation, generation + 2u, memory_order_release);
    return 0;
}
