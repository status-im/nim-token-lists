#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "tkl.h"
/* Load and refresh transactions. Every body is a heap copy overwritten as soon
   as the call that borrowed it returns, so any retained pointer is caught. */
#define REG "{\"timestamp\":\"2026-01-01T00:00:00Z\",\"version\":{\"major\":1,\"minor\":0,\"patch\":0},\"tokenLists\":[{\"id\":\"main\",\"sourceUrl\":\"https://example.org/main\",\"schema\":\"standard\"}]}"
#define LIST(sym) "{\"name\":\"List\",\"timestamp\":\"2026-01-01T00:00:00Z\",\"version\":{\"major\":1,\"minor\":0,\"patch\":0},\"tokens\":[{\"chainId\":1,\"address\":\"0x0000000000000000000000000000000000000001\",\"name\":\"" sym "\",\"symbol\":\"" sym "\",\"decimals\":18}]}"
static const char *cfg="{\"config\":{\"chains\":[1],\"mainListId\":\"main\",\"registryId\":\"registry\","
 "\"registryUrl\":\"https://example.org/registry\",\"initialLists\":[{\"id\":\"main\"}]}}";
static const char *stored="{\"stored\":[{\"id\":\"main\",\"source\":\"https://example.org/main\"}]}";
static int contains(const TklBuf*out,const char*needle){
 size_t n=strlen(needle);
 for(size_t i=0;out->data && i+n<=out->len;i++) if(!memcmp(out->data+i,needle,n)) return 1;
 return 0;
}
static int call_body(int32_t (*fn)(uint64_t,uint64_t,const char*,size_t,uint32_t,const char*,size_t,TklBuf*),
                     uint64_t h,uint64_t txn,const char*id,uint32_t origin,const char*text){
 size_t n=strlen(text); char*copy=malloc(n); memcpy(copy,text,n); TklBuf out={0};
 int rc=fn(h,txn,id,strlen(id),origin,copy,n,&out);
 memset(copy,'x',n); free(copy); tkl_buf_free(&out); return rc;
}
static int put(uint64_t h,uint64_t plan,const char*id,const char*text){
 size_t n=strlen(text); char*copy=malloc(n); memcpy(copy,text,n); TklBuf out={0};
 int rc=tkl_refresh_put_body(h,plan,id,strlen(id),copy,n,&out);
 memset(copy,'x',n); free(copy); tkl_buf_free(&out); return rc;
}
static int has(uint64_t h,const char*needle){
 TklBuf out={0}; assert(tkl_get_list(h,"{\"id\":\"main\"}",13,&out)==TKL_OK);
 int found=contains(&out,needle); tkl_buf_free(&out); return found;
}
static void run(uint64_t h,const char*op,const char*json,int expect,TklBuf*out){
 int rc=0;
 if(!strcmp(op,"plan")) rc=tkl_refresh_plan(h,json,strlen(json),out);
 else if(!strcmp(op,"apply")) rc=tkl_refresh_apply(h,json,strlen(json),out);
 else if(!strcmp(op,"commit")) rc=tkl_refresh_commit(h,json,strlen(json),out);
 else rc=tkl_refresh_abort(h,json,strlen(json),out);
 assert(rc==expect);
}
int main(void){
 uint64_t h=0,txn=0,first=0; TklBuf out={0};
 assert(tkl_create(TKL_ABI_VERSION,cfg,strlen(cfg),&h,&out)==TKL_OK);
 /* Abort halfway: nothing is published and the load id becomes stale. */
 assert(tkl_load_begin(h,stored,strlen(stored),&first,&out)==TKL_OK && out.len==0);
 assert(call_body(tkl_load_list,h,first,"main",TKL_BODY_STORED,LIST("STORED"))==TKL_OK);
 assert(tkl_load_abort(h,first,&out)==TKL_OK);tkl_buf_free(&out);
 assert(tkl_revision(h)==0);
 assert(tkl_get_all(h,"{}",2,&out)==TKL_INVALID_ARGUMENT);tkl_buf_free(&out);
 assert(call_body(tkl_load_list,h,first,"main",TKL_BODY_BUNDLED,LIST("X"))==TKL_INVALID_ARGUMENT);
 assert(tkl_load_finish(h,first,&out)==TKL_INVALID_ARGUMENT);tkl_buf_free(&out);
 /* A new begin replaces an open load. */
 assert(tkl_load_begin(h,stored,strlen(stored),&first,&out)==TKL_OK);
 assert(tkl_load_begin(h,stored,strlen(stored),&txn,&out)==TKL_OK && txn!=first);
 assert(call_body(tkl_load_list,h,first,"main",TKL_BODY_STORED,LIST("X"))==TKL_INVALID_ARGUMENT);
 assert(call_body(tkl_load_list,h,txn,"main",2,LIST("X"))==TKL_INVALID_ARGUMENT);
 assert(call_body(tkl_load_list,h,txn,"other",TKL_BODY_BUNDLED,LIST("X"))==TKL_INVALID_ARGUMENT);
 assert(tkl_load_list(h,txn,"main",4,TKL_BODY_STORED,NULL,0,&out)==TKL_OK);tkl_buf_free(&out);
 assert(call_body(tkl_load_list,h,txn,"main",TKL_BODY_BUNDLED,LIST("BUNDLED"))==TKL_OK);
 assert(tkl_load_finish(h,txn,&out)==TKL_OK && out.len>0);tkl_buf_free(&out);
 assert(tkl_revision(h)==1 && has(h,"\"BUNDLED\""));
 assert(tkl_load_begin(h,"{}",2,&txn,&out)==TKL_BUSY);tkl_buf_free(&out);
 /* Refresh with bodies put per response; abort halfway keeps revision one. */
 for(int attempt=0;attempt<2;attempt++){
  char json[160];
  run(h,"plan","{\"now\":10,\"force\":true}",TKL_OK,&out);
  unsigned long long plan=strtoull(strstr((char*)out.data,"\"id\":")+5,NULL,10);tkl_buf_free(&out);
  snprintf(json,sizeof json,"{\"planId\":%llu,\"now\":11,\"results\":[{\"id\":\"registry\",\"status\":200}]}",plan);
  run(h,"apply",json,TKL_INVALID_ARGUMENT,&out);tkl_buf_free(&out);
  assert(put(h,plan,"registry",REG)==TKL_OK);
  run(h,"apply",json,TKL_OK,&out);tkl_buf_free(&out);
  assert(put(h,plan,"registry",REG)==TKL_INVALID_ARGUMENT);
  assert(put(h,plan,"main",LIST("FETCHED"))==TKL_OK);
  snprintf(json,sizeof json,"{\"planId\":%llu,\"now\":12,\"results\":[{\"id\":\"main\",\"status\":200,\"etag\":\"m\"}]}",plan);
  run(h,"apply",json,TKL_OK,&out);
  const char*writes="\"writes\":[{\"id\":\"registry\"";
  assert(contains(&out,writes) && !contains(&out,"body"));tkl_buf_free(&out);
  snprintf(json,sizeof json,"{\"planId\":%llu,\"now\":13%s}",plan,attempt?"":",\"reason\":\"StorageFailure\"");
  run(h,attempt?"commit":"abort",json,TKL_OK,&out);tkl_buf_free(&out);
  assert(tkl_revision(h)==(uint64_t)(attempt?2:1));
  assert(has(h,attempt?"\"FETCHED\"":"\"BUNDLED\""));
 }
 /* Destroy drops an open refresh; a stale plan cannot take bodies. */
 run(h,"plan","{\"now\":20,\"force\":true}",TKL_OK,&out);tkl_buf_free(&out);
 assert(put(h,1,"registry",REG)==TKL_INVALID_ARGUMENT);
 assert(tkl_destroy(h)==TKL_OK);
 /* Destroy also drops an open load. */
 assert(tkl_create(TKL_ABI_VERSION,cfg,strlen(cfg),&h,&out)==TKL_OK);
 assert(tkl_load_begin(h,stored,strlen(stored),&txn,&out)==TKL_OK);
 assert(call_body(tkl_load_list,h,txn,"main",TKL_BODY_STORED,LIST("OPEN"))==TKL_OK);
 assert(tkl_destroy(h)==TKL_OK);
 assert(tkl_load_finish(h,txn,&out)==TKL_INVALID_HANDLE);
 puts("TRANSACTIONS OK");
}
