#ifndef TKL_H
#define TKL_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
#define TKL_ABI_VERSION 2u
enum {
  TKL_OK = 0,
  TKL_NOT_FOUND = 1,
  TKL_UNCHANGED = 2,
  TKL_ABORTED = 3,
  TKL_SUPERSEDED_PLAN = 4,
  TKL_BUSY = 5,
  TKL_PARTIAL_SUCCESS = 6,
  TKL_INVALID_CONTENT = 7,
  TKL_UNSUPPORTED_SCHEMA = 8,
  TKL_UNSUPPORTED_CHAIN = 9,
  TKL_VALIDATION_FAILED = 10,
  TKL_NETWORK_FAILURE = 11,
  TKL_STORAGE_FAILURE = 12,
  TKL_INVALID_ARGUMENT = 13,
  TKL_INVALID_HANDLE = 14,
  TKL_CLOSED = 15,
  TKL_ABI_MISMATCH = 16,
  TKL_INTERNAL = 17
};
/* Owned malloc buffer, not NUL terminated. Always free with tkl_buf_free,
   including on errors. Pass an empty output; never overwrite a live buffer.
   No caller pointers are retained. All functions are safe on foreign threads.
   Invalid non-NULL pointers remain the caller's responsibility. */
typedef struct TklBuf { uint8_t* data; size_t len; size_t cap; } TklBuf;
uint32_t tkl_abi_version(void);
int32_t tkl_lib_version(TklBuf* out);
/* Config: {"config": CatalogueConfig, "limits"?: ParseLimits}.
   Create's JSON envelope is bounded to 16 MiB. Limits default when omitted.
   A created handle has revision zero; load_stored publishes revision one. */
int32_t tkl_create(uint32_t abiVer, const char* json, size_t len,
                   uint64_t* outHandle, TklBuf* error);
/* Destroy rejects new calls, drains in-flight calls and invalidates generation.
   Repeated destroy returns TKL_INVALID_HANDLE. */
int32_t tkl_destroy(uint64_t handle);
/* All operations accept UTF-8 JSON objects and return UTF-8 JSON.
   Nonzero status may return {code,detail,sourceId}; always free the output.
   Input envelope and nested document limits are applied per instance.
   Queries return {revision,total,items}; limit=0 means all.
   Mutations return Change or a prepare/refresh report. Void calls return true.
   The host must serialize persistence+commit against competing mutations. */
int32_t tkl_load_stored(uint64_t handle, const char* json, size_t len, TklBuf* out);
int32_t tkl_set_chains(uint64_t handle, const char* json, size_t len, TklBuf* out);
int32_t tkl_set_policy(uint64_t handle, const char* json, size_t len, TklBuf* out);
int32_t tkl_get_by_key(uint64_t handle, const char* json, size_t len, TklBuf* out);
int32_t tkl_get_by_chain_address(uint64_t handle, const char* json, size_t len, TklBuf* out);
int32_t tkl_get_by_keys(uint64_t handle, const char* json, size_t len, TklBuf* out);
int32_t tkl_get_by_chains(uint64_t handle, const char* json, size_t len, TklBuf* out);
int32_t tkl_get_all(uint64_t handle, const char* json, size_t len, TklBuf* out);
int32_t tkl_get_native(uint64_t handle, const char* json, size_t len, TklBuf* out);
int32_t tkl_get_list(uint64_t handle, const char* json, size_t len, TklBuf* out);
int32_t tkl_get_lists(uint64_t handle, const char* json, size_t len, TklBuf* out);
int32_t tkl_get_diagnostics(uint64_t handle, const char* json, size_t len, TklBuf* out);
int32_t tkl_custom_validate_upsert(uint64_t handle, const char* json, size_t len, TklBuf* out);
int32_t tkl_custom_validate_delete(uint64_t handle, const char* json, size_t len, TklBuf* out);
int32_t tkl_custom_commit(uint64_t handle, const char* json, size_t len, TklBuf* out);
int32_t tkl_custom_abort(uint64_t handle, const char* json, size_t len, TklBuf* out);
int32_t tkl_refresh_plan(uint64_t handle, const char* json, size_t len, TklBuf* out);
int32_t tkl_refresh_apply(uint64_t handle, const char* json, size_t len, TklBuf* out);
int32_t tkl_refresh_commit(uint64_t handle, const char* json, size_t len, TklBuf* out);
int32_t tkl_refresh_abort(uint64_t handle, const char* json, size_t len, TklBuf* out);
int32_t tkl_set_auto_refresh(uint64_t handle, const char* json, size_t len, TklBuf* out);
int32_t tkl_set_network_allowed(uint64_t handle, const char* json, size_t len, TklBuf* out);
int32_t tkl_next_due(uint64_t handle, const char* json, size_t len, TklBuf* out);
int32_t tkl_changes_since(uint64_t handle, const char* json, size_t len, TklBuf* out);
int32_t tkl_refresh_state(uint64_t handle, const char* json, size_t len, TklBuf* out);
/* 0 for unloaded, closing or invalid handles. */
uint64_t tkl_revision(uint64_t handle);
void tkl_buf_free(TklBuf* buf);
#ifdef __cplusplus
}
#endif
#endif
