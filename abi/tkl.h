#ifndef TKL_H
#define TKL_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
#define TKL_ABI_VERSION 3u
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
/* Which copy of a list a load body is. */
enum { TKL_BODY_BUNDLED = 0, TKL_BODY_STORED = 1 };
/* Owned malloc buffer, not NUL terminated. Always free with tkl_buf_free,
   including on errors. Pass an empty output; never overwrite a live buffer.
   No caller pointers are retained. All functions are safe on foreign threads.
   Invalid non-NULL pointers remain the caller's responsibility. */
typedef struct TklBuf { uint8_t* data; size_t len; size_t cap; } TklBuf;
uint32_t tkl_abi_version(void);
int32_t tkl_lib_version(TklBuf* out);
/* Config: {"config": CatalogueConfig, "limits"?: ParseLimits}. List entries
   are metadata only; no list body is ever retained by the library.
   Create's JSON envelope is bounded to 16 MiB. Limits default when omitted.
   A created handle has revision zero; load_finish publishes revision one. */
int32_t tkl_create(uint32_t abiVer, const char* json, size_t len,
                   uint64_t* outHandle, TklBuf* error);
/* Destroy rejects new calls, drains in-flight calls and invalidates generation.
   Repeated destroy returns TKL_INVALID_HANDLE. */
int32_t tkl_destroy(uint64_t handle);
/* All operations accept UTF-8 JSON objects and return UTF-8 JSON.
   Use {} for operations without arguments; zero-length input is invalid.
   Nonzero status may return {code,detail,sourceId}; always free the output.
   Input envelope and nested document limits are applied per instance.
   Queries return {revision,total,items}; limit=0 means all.
   Mutations return Change or a prepare/refresh report. Void calls return true.
   The host must serialize persistence+commit against competing mutations. */
/* Load: begin with {"stored": [ListContent], "customs": [Token], "state":
   RefreshState}, then pass each body (stored ones first) and finish once.
   Bodies are parsed during load_list and never retained; len 0 is an empty
   body. A new begin, finish (even failed), abort or destroy ends the load and
   its id is rejected afterwards. Begin, list and abort return no output body
   on success; finish returns the bootstrap change page. */
int32_t tkl_load_begin(uint64_t handle, const char* json, size_t len,
                       uint64_t* outTxn, TklBuf* out);
int32_t tkl_load_list(uint64_t handle, uint64_t txn, const char* id, size_t idLen,
                      uint32_t origin, const char* body, size_t bodyLen, TklBuf* out);
int32_t tkl_load_finish(uint64_t handle, uint64_t txn, TklBuf* out);
int32_t tkl_load_abort(uint64_t handle, uint64_t txn, TklBuf* out);
int32_t tkl_set_chains(uint64_t handle, const char* json, size_t len, TklBuf* out);
int32_t tkl_set_policy(uint64_t handle, const char* json, size_t len, TklBuf* out);
int32_t tkl_get_by_key(uint64_t handle, const char* json, size_t len, TklBuf* out);
int32_t tkl_get_by_chain_address(uint64_t handle, const char* json, size_t len, TklBuf* out);
int32_t tkl_get_by_keys(uint64_t handle, const char* json, size_t len, TklBuf* out);
/* {"chainIds": [...], "addresses": [...]}, parallel arrays of equal length:
   the tokens found, in request order. */
int32_t tkl_get_by_chain_addresses(uint64_t handle, const char* json, size_t len, TklBuf* out);
int32_t tkl_get_by_chains(uint64_t handle, const char* json, size_t len, TklBuf* out);
/* get_by_chains narrowed to what balance code needs, without JSON: the same
   tokens in the same order (policy, skips, natives and customs applied) as
   fixed little-endian records. `chainIds` holds `count` ids; count 0 (NULL
   allowed) answers no tokens. On TKL_OK `out` is exactly
     header  16 bytes: magic u32 = TKL_PACKED_MAGIC ("TKP1"), count u32,
                       revision u64
     count x 32 bytes: chainId u64, address u8[20], decimals u8, 3 zero bytes
   Errors return JSON as other calls do. */
#define TKL_PACKED_MAGIC 0x31504B54u
#define TKL_PACKED_HEADER_BYTES 16u
#define TKL_PACKED_RECORD_BYTES 32u
int32_t tkl_get_by_chains_packed(uint64_t handle, const uint64_t* chainIds,
                                 size_t count, TklBuf* out);
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
/* Pass the body of each 200 response of the current round before applying
   it; it is validated and parsed in this call and never retained. Results
   carry no bodies, and report writes are metadata: the host persists the
   bytes it fetched under each write's id. Returns no output body on success. */
int32_t tkl_refresh_put_body(uint64_t handle, uint64_t planId, const char* id,
                             size_t idLen, const char* body, size_t bodyLen,
                             TklBuf* out);
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
