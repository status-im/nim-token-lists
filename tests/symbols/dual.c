#include <assert.h>
#include <stdio.h>
#include "tkl.h"
int dummy_ping(int x);

int main(void) {
  uint64_t h = 0;
  assert(dummy_ping(1000) == 1000);
  assert(tkl_create(TKL_ABI_VERSION, &h) == TKL_OK);
  assert(dummy_ping(10) == 10);
  assert(tkl_destroy(h) == TKL_OK);
  puts("DUAL OK");
  return 0;
}
