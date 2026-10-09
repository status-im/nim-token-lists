/* Test-only allocation counter; force-included into generated C. */
#ifndef TKL_COUNTING_H
#define TKL_COUNTING_H
#include <stdlib.h>
#include <string.h>
void* tkl_count_malloc(size_t n);
void* tkl_count_calloc(size_t a, size_t b);
void* tkl_count_realloc(void* p, size_t n);
void tkl_count_free(void* p);
#ifndef TKL_COUNTING_IMPL
#define malloc(n) tkl_count_malloc(n)
#define calloc(a, b) tkl_count_calloc(a, b)
#define realloc(p, n) tkl_count_realloc(p, n)
#define free(p) tkl_count_free(p)
#endif
#endif
