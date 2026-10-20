#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "tkl.h"
/* tkl_get_by_chains_packed: little-endian records in get_by_chains order. */
#define TOKEN(chain,addr,dec) "{\"chainId\":" #chain ",\"address\":\"0x" addr "\",\"name\":\"T\",\"symbol\":\"T\",\"decimals\":" #dec "}"
static const char *cfg="{\"config\":{\"chains\":[1,10,56],\"mainListId\":\"main\",\"initialLists\":[{\"id\":\"main\"}],"
 "\"policy\":{\"skippedKeys\":[\"56-0x00000000000000000000000000000000000000c3\"],"
 "\"nativeAliases\":[{\"chainId\":1,\"address\":\"0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\"}],"
 "\"nativeTokens\":[{\"chainId\":10,\"address\":\"0x0000000000000000000000000000000000000000\",\"name\":\"Ether\",\"symbol\":\"ETH\",\"decimals\":18}]}}}";
static const char *list="{\"name\":\"List\",\"timestamp\":\"2026-01-01T00:00:00Z\",\"version\":{\"major\":1,\"minor\":0,\"patch\":0},\"tokens\":["
 TOKEN(56,"00000000000000000000000000000000000000a1",8) ","
 TOKEN(1,"0102030405060708090a0b0c0d0e0f1011121314",6) ","
 TOKEN(137,"00000000000000000000000000000000000000b2",18) ","
 TOKEN(56,"00000000000000000000000000000000000000c3",18) ","
 TOKEN(10,"00000000000000000000000000000000000000d4",255) ","
 TOKEN(1,"00000000000000000000000000000000000000e5",0) "]}";
static const char *customs="{\"customs\":[{\"chainId\":56,\"address\":\"0x00000000000000000000000000000000000000f6\",\"name\":\"C\",\"symbol\":\"C\",\"decimals\":9}]}";
static uint64_t le(const uint8_t *p,int n){ uint64_t v=0; for(int i=n-1;i>=0;i--) v=(v<<8)|p[i]; return v; }
static const char *find(const char *hay,size_t n,const char *needle,const char *from){
 size_t k=strlen(needle);
 for(const char *p=from;p+k<=hay+n;p++) if(!memcmp(p,needle,k)) return p;
 return NULL;
}
/* Every record appears in the JSON answer, in order, and the counts agree. */
static void parity(uint64_t h,const uint64_t *chains,size_t count){
 TklBuf packed={0},json={0}; char req[256]; int w=snprintf(req,sizeof req,"{\"chains\":[");
 for(size_t i=0;i<count;i++) w+=snprintf(req+w,sizeof req-w,"%s%llu",i?",":"",(unsigned long long)chains[i]);
 w+=snprintf(req+w,sizeof req-w,"]}");
 assert(tkl_get_by_chains(h,req,(size_t)w,&json)==TKL_OK);
 assert(tkl_get_by_chains_packed(h,chains,count,&packed)==TKL_OK);
 assert(packed.len>=16 && le(packed.data,4)==0x31504B54u);
 uint64_t n=le(packed.data+4,4);
 assert(packed.len==16+32*n && le(packed.data+8,8)==tkl_revision(h));
 char total[64]; snprintf(total,sizeof total,"\"total\":%llu,",(unsigned long long)n);
 assert(find((const char*)json.data,json.len,total,(const char*)json.data));
 const char *at=(const char*)json.data;
 for(uint64_t i=0;i<n;i++){
  const uint8_t *r=packed.data+16+32*i; char needle[160]; int k=snprintf(needle,sizeof needle,"{\"chainId\":%llu,\"address\":\"0x",(unsigned long long)le(r,8));
  for(int b=0;b<20;b++) k+=snprintf(needle+k,sizeof needle-k,"%02x",r[8+b]);
  snprintf(needle+k,sizeof needle-k,"\"");
  at=find((const char*)json.data,json.len,needle,at); assert(at);
  char dec[32]; snprintf(dec,sizeof dec,"\"decimals\":%u,",r[28]);
  const char *d=find((const char*)json.data,json.len,dec,at); const char *next=find((const char*)json.data,json.len,"{\"chainId\":",at+1);
  assert(d && (!next || d<next)); assert(!r[29] && !r[30] && !r[31]);
 }
 tkl_buf_free(&packed); tkl_buf_free(&json);
}
int main(void){
 uint64_t h=0,txn=0; TklBuf out={0};
 assert(tkl_create(TKL_ABI_VERSION,cfg,strlen(cfg),&h,&out)==TKL_OK);
 const uint64_t one=1;
 assert(tkl_get_by_chains_packed(h,&one,1,&out)==TKL_INVALID_ARGUMENT);tkl_buf_free(&out);
 assert(tkl_load_begin(h,customs,strlen(customs),&txn,&out)==TKL_OK);tkl_buf_free(&out);
 assert(tkl_load_list(h,txn,"main",4,TKL_BODY_BUNDLED,list,strlen(list),&out)==TKL_OK);tkl_buf_free(&out);
 assert(tkl_load_finish(h,txn,&out)==TKL_OK);tkl_buf_free(&out);
 /* Default native first, then chain 1 address 01..14, decimals 6. */
 assert(tkl_get_by_chains_packed(h,&one,1,&out)==TKL_OK);
 assert(out.len==16+32*3 && out.cap>=out.len);
 static const uint8_t first[32]={1,0,0,0,0,0,0,0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,6,0,0,0};
 assert(!memcmp(out.data,"TKP1",4) && !memcmp(out.data+16+32,first,32));
 tkl_buf_free(&out);
 const uint64_t all[]={1,10,56,137,999};
 for(unsigned mask=0;mask<32;mask++){
  uint64_t chains[5]; size_t n=0;
  for(int b=0;b<5;b++) if(mask&(1u<<b)) chains[n++]=all[b];
  parity(h,chains,n);
 }
 const uint64_t dup[]={10,1,10};
 parity(h,dup,3);
 assert(tkl_get_by_chains_packed(h,NULL,0,&out)==TKL_OK && out.len==16);tkl_buf_free(&out);
 assert(tkl_get_by_chains_packed(h,NULL,1,&out)==TKL_INVALID_ARGUMENT);tkl_buf_free(&out);
 assert(tkl_get_by_chains_packed(h,&one,SIZE_MAX,&out)==TKL_INVALID_ARGUMENT);tkl_buf_free(&out);
 assert(tkl_get_by_chains_packed(h,&one,1,NULL)==TKL_INVALID_ARGUMENT);
 assert(tkl_get_by_chains_packed(UINT64_MAX,&one,1,&out)==TKL_INVALID_HANDLE);
 assert(tkl_destroy(h)==TKL_OK);
 assert(tkl_get_by_chains_packed(h,&one,1,&out)==TKL_INVALID_HANDLE);
 puts("PACKED OK");
}
