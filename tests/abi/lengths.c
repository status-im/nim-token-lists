#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include "tkl.h"

int main(void) {
  uint64_t h = 0, staged = 0;
  TklBuf buf = {0};
  assert(tkl_create(TKL_ABI_VERSION, &h) == TKL_OK);
  assert(tkl_stage_tokens(h, "[]", SIZE_MAX, &staged) == TKL_INVALID_ARGUMENT);
  assert(tkl_get_by_key(h, "x", SIZE_MAX, &buf) == TKL_INVALID_ARGUMENT);
  assert(tkl_stage_tokens(h, "[]", 16u * 1024u * 1024u + 1u, &staged) == TKL_INVALID_ARGUMENT);
  assert(tkl_get_by_key(h, "x", 16u * 1024u * 1024u + 1u, &buf) == TKL_INVALID_ARGUMENT);
  assert(tkl_stage_tokens(h, "[]", 2, &staged) == TKL_OK);
  assert(tkl_abort(h, staged) == TKL_OK);
  assert(tkl_destroy(h) == TKL_OK);
  puts("LENGTHS OK");
}
