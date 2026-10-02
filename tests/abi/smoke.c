#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <stdatomic.h>
#include "tkl.h"
static const char *cfg="{\"config\":{\"chains\":[1]}}";
static uint64_t shared;
static atomic_int stop;
static atomic_ulong reads;
static void *initialize(void *unused) {
 (void)unused; uint64_t h=0; TklBuf out={0};
 assert(tkl_create(TKL_ABI_VERSION,cfg,strlen(cfg),&h,&out)==TKL_OK);
 tkl_buf_free(&out);
 assert(tkl_destroy(h)==TKL_OK);
 /* Also leave the foreign thread immediately after a parser error. */
 const char *bad="{\"config\":";
 assert(tkl_create(TKL_ABI_VERSION,bad,strlen(bad),&h,&out)==TKL_INVALID_ARGUMENT);
 assert(h==0); tkl_buf_free(&out);
 return NULL;
}
static void *reader(void *unused) {
 (void)unused;
 /* Every short-lived thread must parse at least once, even on a slow runner. */
 do {
  TklBuf out={0};
  assert(tkl_get_native(shared,"{\"chainId\":1}",13,&out)==TKL_OK);
  assert(out.len>0); tkl_buf_free(&out); atomic_fetch_add(&reads,1);
 } while(!atomic_load(&stop));
 TklBuf out={0};
 const char *bad="{\"chainId\":";
 assert(tkl_get_native(shared,bad,strlen(bad),&out)==TKL_INVALID_ARGUMENT);
 tkl_buf_free(&out);
 return NULL;
}
int main(void) {
 pthread_t first[2];
 for(int i=0;i<2;i++) assert(pthread_create(&first[i],NULL,initialize,NULL)==0);
 for(int i=0;i<2;i++) assert(pthread_join(first[i],NULL)==0);
 TklBuf out={0}; uint64_t h=99;
 assert(tkl_abi_version()==2);
 assert(tkl_create(1,cfg,strlen(cfg),&h,&out)==TKL_ABI_MISMATCH && h==0);
 assert(tkl_create(2,cfg,strlen(cfg),&h,&out)==TKL_OK);
 assert(tkl_get_all(h,"{}",2,&out)==TKL_INVALID_ARGUMENT); tkl_buf_free(&out);
 assert(tkl_load_stored(h,"{}",2,&out)==TKL_OK);tkl_buf_free(&out);
 assert(tkl_revision(h)==1);
 assert(tkl_get_lists(h,"{}",2,&out)==TKL_OK);
 assert(out.len>0 && out.data[0]=='{');tkl_buf_free(&out);tkl_buf_free(&out);
 assert(out.data==NULL && out.len==0 && out.cap==0);
 shared=h;pthread_t workers[16];
 for(int i=0;i<16;i++) assert(pthread_create(&workers[i],NULL,reader,NULL)==0);
 for(int i=0;i<100;i++) {
  const char *body=i%2 ? "{\"chains\":[1]}" : "{\"chains\":[1,10]}";
  assert(tkl_set_chains(h,body,strlen(body),&out)==TKL_OK);tkl_buf_free(&out);
 }
 atomic_store(&stop,1);
 for(int i=0;i<16;i++) assert(pthread_join(workers[i],NULL)==0);
 assert(atomic_load(&reads)>0);
 assert(tkl_destroy(h)==TKL_OK);
 assert(tkl_get_all(h,"{}",2,&out)==TKL_INVALID_HANDLE);tkl_buf_free(&out);
 assert(tkl_destroy(h)==TKL_INVALID_HANDLE);
 printf("SMOKE OK reads=%lu\n",atomic_load(&reads));
}
