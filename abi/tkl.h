#ifndef TKL_H
#define TKL_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TKL_ABI_VERSION 1u

/* Input byte lengths are capped at 16 MiB by default. The spike build may
   override this with Nim -d:TklMaxInputBytes=<positive integer>.
   Oversized inputs return TKL_INVALID_ARGUMENT before reading the pointer.
   Stage 1 must expose the agreed per-instance maxBytes configuration. */

enum {
  TKL_OK = 0, TKL_NOT_FOUND = 1, TKL_UNCHANGED = 2, TKL_ABORTED = 3,
  TKL_SUPERSEDED_PLAN = 4, TKL_BUSY = 5, TKL_PARTIAL_SUCCESS = 6,
  TKL_INVALID_CONTENT = 7, TKL_UNSUPPORTED_SCHEMA = 8, TKL_UNSUPPORTED_CHAIN = 9,
  TKL_VALIDATION_FAILED = 10, TKL_NETWORK_FAILURE = 11, TKL_STORAGE_FAILURE = 12,
  TKL_INVALID_ARGUMENT = 13, TKL_INVALID_HANDLE = 14, TKL_CLOSED = 15,
  TKL_ABI_MISMATCH = 16, TKL_INTERNAL = 17
};

/* Allocated by the library with malloc. Free ONLY with tkl_buf_free. */
typedef struct TklBuf {
  uint8_t* data;
  size_t len;
  size_t cap;
} TklBuf;

uint32_t tkl_abi_version(void);

/* abiVer must equal TKL_ABI_VERSION, else TKL_ABI_MISMATCH. Handle 0 is never valid. */
int32_t tkl_create(uint32_t abiVer, uint64_t* outHandle);

/* Marks the handle closing, waits for in-flight calls, frees it. Idempotent:
   a second call returns TKL_INVALID_HANDLE. */
int32_t tkl_destroy(uint64_t handle);

/* Phase 1: parse + build a staged snapshot. Nothing is published.
   TKL_BUSY if something is already staged. TKL_INVALID_CONTENT on bad JSON. */
int32_t tkl_stage_tokens(uint64_t handle, const char* json, size_t len, uint64_t* outStagedId);

/* Phase 2a: host persisted durably -> publish atomically, revision + 1. */
int32_t tkl_commit(uint64_t handle, uint64_t stagedId, uint64_t* outRevision);

/* Phase 2b: host failed to persist -> drop staged data, catalogue unchanged. */
int32_t tkl_abort(uint64_t handle, uint64_t stagedId);

int32_t tkl_get_by_key(uint64_t handle, const char* key, size_t keyLen, TklBuf* out);
int32_t tkl_get_all(uint64_t handle, TklBuf* out);

/* 0 when the handle is invalid. */
uint64_t tkl_revision(uint64_t handle);

void tkl_buf_free(TklBuf* buf);

#ifdef __cplusplus
}
#endif
#endif
