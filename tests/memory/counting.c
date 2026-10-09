#define TKL_COUNTING_IMPL 1
#undef malloc
#undef calloc
#undef realloc
#undef free
#include <stdlib.h>
#ifdef __APPLE__
#include <malloc/malloc.h>
#define usable(p) malloc_size(p)
#else
#include <malloc.h>
#define usable(p) malloc_usable_size(p)
#endif
/* Single-threaded tests only. */
static long long live, peak, churn;
static void grow(long long delta) {
  live += delta;
  if (live > peak) peak = live;
}
void* tkl_count_malloc(size_t n) {
  void* p = malloc(n);
  if (p) { size_t s = usable(p); churn += s; grow((long long)s); }
  return p;
}
void* tkl_count_calloc(size_t a, size_t b) {
  void* p = calloc(a, b);
  if (p) { size_t s = usable(p); churn += s; grow((long long)s); }
  return p;
}
void* tkl_count_realloc(void* p, size_t n) {
  long long old = p ? (long long)usable(p) : 0;
  void* q = realloc(p, n);
  if (q) { size_t s = usable(q); churn += s; grow((long long)s - old); }
  return q;
}
void tkl_count_free(void* p) {
  if (p) live -= (long long)usable(p);
  free(p);
}
long long tkl_count_live(void) { return live; }
long long tkl_count_churn(void) { return churn; }
long long tkl_count_peak(void) { return peak; }
void tkl_count_reset_peak(void) { peak = live; }
