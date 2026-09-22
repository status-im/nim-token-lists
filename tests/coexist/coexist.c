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

  uint64_t h = 0;
  TklBuf buf = {0};
  const char* config = "{\"config\":{\"chains\":[1]}}";
  assert(tkl_create(TKL_ABI_VERSION, config, strlen(config), &h, &buf) == TKL_OK);
  tkl_buf_free(&buf);
  assert(tkl_load_stored(h, "{}", 2, &buf) == TKL_OK);
  tkl_buf_free(&buf);
  assert(tkl_get_all(h, "{}", 2, &buf) == TKL_OK);
  tkl_buf_free(&buf);

  assert(SdsCleanupReliabilityManager(sds, on_sds, NULL) == 0);
  assert(tkl_get_all(h, "{}", 2, &buf) == TKL_OK); /* healthy after libsds teardown */
  tkl_buf_free(&buf);
  assert(tkl_destroy(h) == TKL_OK);
  puts("COEXIST OK");
  return 0;
}
