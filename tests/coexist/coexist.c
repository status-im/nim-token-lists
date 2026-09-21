#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "libsds.h"
#include "tkl.h"

static void on_sds(int ret, const char* msg, size_t len, void* user) {
  (void)ret; (void)msg; (void)len; (void)user;
}

int main(void) {
  void* sds = SdsNewReliabilityManager(on_sds, NULL); /* initialises the refc Nim runtime + its thread */
  assert(sds != NULL);

  uint64_t h = 0, staged = 0, rev = 0;
  const char* toks = "[{\"chainId\":1,\"address\":\"0x0000000000000000000000000000000000000000\",\"symbol\":\"ETH\",\"decimals\":18}]";
  assert(tkl_create(TKL_ABI_VERSION, &h) == TKL_OK);
  assert(tkl_stage_tokens(h, toks, strlen(toks), &staged) == TKL_OK);
  assert(tkl_commit(h, staged, &rev) == TKL_OK && rev == 1);

  TklBuf buf = {0};
  assert(tkl_get_all(h, &buf) == TKL_OK);
  tkl_buf_free(&buf);

  assert(SdsCleanupReliabilityManager(sds, on_sds, NULL) == 0);
  assert(tkl_get_all(h, &buf) == TKL_OK); /* libtkl still healthy after libsds teardown */
  tkl_buf_free(&buf);
  assert(tkl_destroy(h) == TKL_OK);
  puts("COEXIST OK");
  return 0;
}
