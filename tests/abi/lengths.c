#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "tkl.h"
int main(void) {
 uint64_t h=0;TklBuf out={0};
 uint64_t txn=0;
 assert(tkl_create(3,"{}",2,&h,&out)==TKL_OK);
 assert(tkl_load_begin(h,"{}",SIZE_MAX,&txn,&out)==TKL_INVALID_ARGUMENT);tkl_buf_free(&out);
 assert(tkl_load_begin(h,(const char*)1,16u*1024u*1024u+1u,&txn,&out)==TKL_INVALID_ARGUMENT);tkl_buf_free(&out);
 assert(tkl_load_begin(h,NULL,1,&txn,&out)==TKL_INVALID_ARGUMENT);tkl_buf_free(&out);
 assert(tkl_load_begin(h,"{}",2,&txn,NULL)==TKL_INVALID_ARGUMENT);
 assert(tkl_load_begin(h,"{}",2,NULL,&out)==TKL_INVALID_ARGUMENT);tkl_buf_free(&out);
 assert(tkl_load_begin(h,"null",4,&txn,&out)==TKL_INVALID_ARGUMENT);tkl_buf_free(&out);
 assert(tkl_load_begin(h,"{",1,&txn,&out)==TKL_INVALID_ARGUMENT);tkl_buf_free(&out);
 assert(tkl_load_begin(h,"{}",2,&txn,&out)==TKL_OK);tkl_buf_free(&out);
 assert(tkl_load_list(h,txn,NULL,4,0,"{}",2,&out)==TKL_INVALID_ARGUMENT);tkl_buf_free(&out);
 assert(tkl_load_list(h,txn,"main",4,0,NULL,1,&out)==TKL_INVALID_ARGUMENT);tkl_buf_free(&out);
 assert(tkl_load_list(h,txn,"main",4,0,"{}",SIZE_MAX,&out)==TKL_INVALID_ARGUMENT);tkl_buf_free(&out);
 assert(tkl_refresh_put_body(h,1,"main",4,NULL,1,&out)==TKL_INVALID_ARGUMENT);tkl_buf_free(&out);
 assert(tkl_load_finish(h,txn,&out)==TKL_OK);tkl_buf_free(&out);
 const char nul[]={'{','}',0,'x'};
 assert(tkl_get_all(h,nul,sizeof nul,&out)==TKL_INVALID_ARGUMENT);tkl_buf_free(&out);
 const char utf8[]={'{','"',(char)0xff,'"','}',0};
 assert(tkl_get_all(h,utf8,5,&out)==TKL_INVALID_ARGUMENT);tkl_buf_free(&out);
 assert(tkl_get_all(UINT64_MAX,"{}",2,&out)==TKL_INVALID_HANDLE);
 assert(tkl_destroy(h)==TKL_OK);
 puts("LENGTHS OK");
}
