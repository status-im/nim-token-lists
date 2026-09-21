#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include "tkl.h"

static const char* TOKENS =
  "[{\"chainId\":1,\"address\":\"0xAbCdEf0000000000000000000000000000000001\",\"symbol\":\"AAA\",\"decimals\":18},"
  "{\"chainId\":10,\"address\":\"0x0000000000000000000000000000000000000000\",\"symbol\":\"ETH\",\"decimals\":18}]";

static void* create_destroy(void* arg) {
  (void)arg;
  uint64_t h = 0;
  assert(tkl_create(TKL_ABI_VERSION, &h) == TKL_OK);
  assert(h != 0);
  assert(tkl_destroy(h) == TKL_OK);
  return NULL;
}

int main(void) {
  /* 1. Runtime init must be safe when the first calls race from two threads. */
  pthread_t a, b;
  pthread_create(&a, NULL, create_destroy, NULL);
  pthread_create(&b, NULL, create_destroy, NULL);
  pthread_join(a, NULL);
  pthread_join(b, NULL);

  assert(tkl_abi_version() == TKL_ABI_VERSION);

  uint64_t bad = 0;
  assert(tkl_create(TKL_ABI_VERSION + 1, &bad) == TKL_ABI_MISMATCH);
  assert(tkl_create(TKL_ABI_VERSION, NULL) == TKL_INVALID_ARGUMENT);

  uint64_t h = 0;
  assert(tkl_create(TKL_ABI_VERSION, &h) == TKL_OK);
  assert(tkl_revision(h) == 0);

  /* 2. Bad content is rejected, nothing staged. */
  uint64_t staged = 0;
  assert(tkl_stage_tokens(h, "nope", 4, &staged) == TKL_INVALID_CONTENT);
  assert(tkl_stage_tokens(h, NULL, 4, &staged) == TKL_INVALID_ARGUMENT);

  /* 3. stage -> abort leaves the catalogue unchanged. */
  assert(tkl_stage_tokens(h, TOKENS, strlen(TOKENS), &staged) == TKL_OK);
  uint64_t second = 0;
  assert(tkl_stage_tokens(h, TOKENS, strlen(TOKENS), &second) == TKL_BUSY);
  assert(tkl_abort(h, staged) == TKL_OK);
  assert(tkl_revision(h) == 0);
  assert(tkl_abort(h, staged) == TKL_NOT_FOUND);

  /* 4. stage -> commit publishes revision 1. */
  uint64_t rev = 0;
  assert(tkl_stage_tokens(h, TOKENS, strlen(TOKENS), &staged) == TKL_OK);
  assert(tkl_commit(h, staged + 99, &rev) == TKL_NOT_FOUND);
  assert(tkl_commit(h, staged, &rev) == TKL_OK);
  assert(rev == 1 && tkl_revision(h) == 1);

  /* 5. Lookup: any-case key, NOT_FOUND, buffers. */
  TklBuf buf = {0};
  const char* key = "1-0xABCDEF0000000000000000000000000000000001";
  assert(tkl_get_by_key(h, key, strlen(key), &buf) == TKL_OK);
  assert(buf.data != NULL && buf.len > 0);
  assert(memmem(buf.data, buf.len, "\"AAA\"", 5) != NULL);
  tkl_buf_free(&buf);
  assert(buf.data == NULL && buf.len == 0);
  tkl_buf_free(&buf); /* double free of an emptied buf is a no-op */

  const char* missing = "1-0x00000000000000000000000000000000000000ff";
  assert(tkl_get_by_key(h, missing, strlen(missing), &buf) == TKL_NOT_FOUND);
  assert(buf.data == NULL);

  assert(tkl_get_all(h, &buf) == TKL_OK);
  assert(buf.len > 2 && buf.data[0] == '[');
  tkl_buf_free(&buf);

  /* 6. Stale handle after destroy. */
  assert(tkl_destroy(h) == TKL_OK);
  assert(tkl_destroy(h) == TKL_INVALID_HANDLE);
  assert(tkl_get_all(h, &buf) == TKL_INVALID_HANDLE);
  assert(tkl_revision(h) == 0);

  puts("SMOKE OK");
  return 0;
}
