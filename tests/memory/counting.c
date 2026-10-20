#define TKL_COUNTING_IMPL 1
#undef malloc
#undef calloc
#undef realloc
#undef free
#include <stdint.h>
#include <stdlib.h>
/* Counts requested bytes, not usable sizes: allocators round blocks up to
   platform-specific size classes (32 KiB steps on some macOS versions).
   A pointer table remembers each request; freeing a pointer the shim did
   not allocate counts nothing. Single-threaded tests only. */
static long long live, peak, churn;
typedef struct { void* p; size_t n; } Slot;
static Slot* slots;
static size_t cap, used;

static size_t home(void* p) {
  uint64_t h = (uint64_t)(uintptr_t)p * 0x9E3779B97F4A7C15ull;
  return (size_t)(h >> 32) & (cap - 1);
}
static void put(void* p, size_t n);
static void rehash(void) {
  Slot* old = slots;
  size_t oldCap = cap;
  cap = cap ? cap * 2 : 1 << 16;
  slots = calloc(cap, sizeof(Slot));
  if (!slots) abort();
  used = 0;
  for (size_t i = 0; i < oldCap; i++)
    if (old[i].p) put(old[i].p, old[i].n);
  free(old);
}
static void put(void* p, size_t n) {
  if (2 * (used + 1) > cap) rehash();
  size_t i = home(p);
  while (slots[i].p) i = (i + 1) & (cap - 1);
  slots[i].p = p;
  slots[i].n = n;
  used++;
}
/* Forgets p and returns its requested size; 0 when untracked. */
static size_t take(void* p) {
  if (!cap) return 0;
  size_t i = home(p);
  while (slots[i].p != p) {
    if (!slots[i].p) return 0;
    i = (i + 1) & (cap - 1);
  }
  size_t n = slots[i].n;
  /* Backward-shift deletion keeps linear probe chains unbroken. */
  for (size_t j = (i + 1) & (cap - 1); slots[j].p; j = (j + 1) & (cap - 1)) {
    size_t k = home(slots[j].p);
    if (i <= j ? (k <= i || k > j) : (k <= i && k > j)) {
      slots[i] = slots[j];
      i = j;
    }
  }
  slots[i].p = NULL;
  used--;
  return n;
}
static void grow(long long delta) {
  live += delta;
  if (live > peak) peak = live;
}
static void track(void* p, size_t n) {
  put(p, n);
  churn += (long long)n;
  grow((long long)n);
}
void* tkl_count_malloc(size_t n) {
  void* p = malloc(n);
  if (p) track(p, n);
  return p;
}
void* tkl_count_calloc(size_t a, size_t b) {
  void* p = calloc(a, b);
  if (p) track(p, a * b);
  return p;
}
void* tkl_count_realloc(void* p, size_t n) {
  void* q = realloc(p, n);
  if (q || n == 0) {
    if (p) live -= (long long)take(p);
    if (q) track(q, n);
  }
  return q;
}
void tkl_count_free(void* p) {
  if (p) live -= (long long)take(p);
  free(p);
}
long long tkl_count_live(void) { return live; }
long long tkl_count_churn(void) { return churn; }
long long tkl_count_peak(void) { return peak; }
void tkl_count_reset_peak(void) { peak = live; }
