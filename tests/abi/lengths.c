#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "tkl.h"
int main(void) {
 uint64_t h=0;TklBuf out={0};
 assert(tkl_create(2,"{}",2,&h,&out)==TKL_OK);
 assert(tkl_load_stored(h,"{}",SIZE_MAX,&out)==TKL_INVALID_ARGUMENT);tkl_buf_free(&out);
 assert(tkl_load_stored(h,(const char*)1,16u*1024u*1024u+1u,&out)==TKL_INVALID_ARGUMENT);tkl_buf_free(&out);
 assert(tkl_load_stored(h,NULL,1,&out)==TKL_INVALID_ARGUMENT);tkl_buf_free(&out);
 assert(tkl_load_stored(h,"{}",2,NULL)==TKL_INVALID_ARGUMENT);
 assert(tkl_load_stored(h,"null",4,&out)==TKL_INVALID_ARGUMENT);tkl_buf_free(&out);
 assert(tkl_load_stored(h,"{",1,&out)==TKL_INVALID_ARGUMENT);tkl_buf_free(&out);
 assert(tkl_load_stored(h,"{}",2,&out)==TKL_OK);tkl_buf_free(&out);
 const char nul[]={'{','}',0,'x'};
 assert(tkl_get_all(h,nul,sizeof nul,&out)==TKL_INVALID_ARGUMENT);tkl_buf_free(&out);
 const char utf8[]={'{','"',(char)0xff,'"','}',0};
 assert(tkl_get_all(h,utf8,5,&out)==TKL_INVALID_ARGUMENT);tkl_buf_free(&out);
 assert(tkl_get_all(UINT64_MAX,"{}",2,&out)==TKL_INVALID_HANDLE);
 assert(tkl_destroy(h)==TKL_OK);
 puts("LENGTHS OK");
}
