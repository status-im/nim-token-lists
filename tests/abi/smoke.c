#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <stdatomic.h>
#include <time.h>
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

static atomic_int stop_readers;
static atomic_ulong read_count;
static uint64_t stress_handle;
static struct timespec stress_start;

static void* read_snapshot(void* unused) {
  (void)unused;
  const char* key = "1-0xabcdef0000000000000000000000000000000001";
  while (!atomic_load(&stop_readers)) {
    TklBuf buf = {0};
    assert(tkl_get_by_key(stress_handle, key, strlen(key), &buf) == TKL_OK);
    tkl_buf_free(&buf);
    assert(tkl_get_all(stress_handle, &buf) == TKL_OK);
    tkl_buf_free(&buf);
    atomic_fetch_add(&read_count, 1);
    struct timespec now;
    assert(clock_gettime(CLOCK_MONOTONIC, &now) == 0);
    if ((now.tv_sec - stress_start.tv_sec) +
        (now.tv_nsec - stress_start.tv_nsec) / 1e9 >= 2.0)
      atomic_store(&stop_readers, 1);
  }
  return NULL;
}

static void stress(void) {
  uint64_t id, revision;
  assert(tkl_create(TKL_ABI_VERSION, &stress_handle) == TKL_OK);
  assert(tkl_stage_tokens(stress_handle, TOKENS, strlen(TOKENS), &id) == TKL_OK);
  assert(tkl_commit(stress_handle, id, &revision) == TKL_OK);
  pthread_t readers[16];
  assert(clock_gettime(CLOCK_MONOTONIC, &stress_start) == 0);
  for (int i = 0; i < 16; ++i)
    assert(pthread_create(&readers[i], NULL, read_snapshot, NULL) == 0);
  struct timespec start, now;
  assert(clock_gettime(CLOCK_MONOTONIC, &start) == 0);
  unsigned commits = 0;
  do {
    assert(tkl_stage_tokens(stress_handle, TOKENS, strlen(TOKENS), &id) == TKL_OK);
    assert(tkl_commit(stress_handle, id, &revision) == TKL_OK);
    ++commits;
    assert(clock_gettime(CLOCK_MONOTONIC, &now) == 0);
  } while ((now.tv_sec - start.tv_sec) + (now.tv_nsec - start.tv_nsec) / 1e9 < 2.0);
  atomic_store(&stop_readers, 1);
  for (int i = 0; i < 16; ++i) assert(pthread_join(readers[i], NULL) == 0);
  assert(atomic_load(&read_count) > 0);
  assert(tkl_destroy(stress_handle) == TKL_OK);
  printf("STRESS OK commits=%u reads=%lu\n", commits, atomic_load(&read_count));
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

  stress();
  puts("SMOKE OK");
  return 0;
}
