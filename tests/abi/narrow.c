#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "tkl.h"
/* tkl_get_by_cross_chain_ids_packed and tkl_get_by_symbol_on_chain. */
#define TOKEN(cross,sym,name,dec,contracts) "{\"crossChainId\":\"" cross "\",\"symbol\":\"" sym "\",\"name\":\"" name "\",\"decimals\":" #dec ",\"contracts\":{" contracts "}}"
#define ADDR(n) "\"0x00000000000000000000000000000000000000" n "\""
static const char *cfg="{\"config\":{\"chains\":[1,10,56],\"mainListId\":\"main\",\"initialLists\":[{\"id\":\"main\",\"format\":\"StatusFormat\"}],"
 "\"policy\":{\"skippedKeys\":[\"56-0x00000000000000000000000000000000000000c3\"],"
 "\"nativeTokens\":[{\"chainId\":10,\"address\":\"0x0000000000000000000000000000000000000000\",\"crossChainId\":\"ethereum\",\"name\":\"Ether\",\"symbol\":\"ETH\",\"decimals\":18}]}}}";
static const char *list="{\"name\":\"List\",\"timestamp\":\"2026-01-01T00:00:00Z\",\"version\":{\"major\":1,\"minor\":0,\"patch\":0},\"tokens\":["
 TOKEN("usd-coin","USDC","USD Coin",6,"\"1\":" ADDR("a1") ",\"10\":" ADDR("a2") ",\"56\":" ADDR("a3") ",\"137\":" ADDR("a4")) ","
 TOKEN("tether","USDT","Tether",6,"\"1\":" ADDR("b1") ",\"56\":" ADDR("c3")) ","
 TOKEN("","eth","uSdc",18,"\"1\":" ADDR("d1")) "]}";
static const char *customs="{\"customs\":[{\"chainId\":56,\"address\":\"0x00000000000000000000000000000000000000f6\",\"crossChainId\":\"usd-coin\",\"name\":\"C\",\"symbol\":\"usdc\",\"decimals\":9}]}";
static uint64_t le(const uint8_t *p,int n){ uint64_t v=0; for(int i=n-1;i>=0;i--) v=(v<<8)|p[i]; return v; }
static int contains(const TklBuf *out,const char *text){
 size_t n=strlen(text);
 for(size_t i=0;i+n<=out->len;i++) if(!memcmp(out->data+i,text,n)) return 1;
 return 0;
}
/* Records as (chain, last address byte, decimals), in order. */
static void expect(uint64_t h,const char *ids,size_t count,const unsigned (*want)[3]){
 TklBuf out={0};
 assert(tkl_get_by_cross_chain_ids_packed(h,ids,strlen(ids),&out)==TKL_OK);
 assert(out.len==16+32*count && le(out.data,4)==TKL_PACKED_MAGIC && le(out.data+4,4)==count);
 assert(le(out.data+8,8)==tkl_revision(h));
 for(size_t i=0;i<count;i++){
  const uint8_t *r=out.data+16+32*i;
  assert(le(r,8)==want[i][0] && r[27]==want[i][1] && r[28]==want[i][2]);
  assert(!r[29] && !r[30] && !r[31]);
 }
 tkl_buf_free(&out);
}
int main(void){
 uint64_t h=0,txn=0; TklBuf out={0};
 assert(tkl_create(TKL_ABI_VERSION,cfg,strlen(cfg),&h,&out)==TKL_OK);
 const char *usd="{\"crossChainIds\":[\"usd-coin\"]}";
 assert(tkl_get_by_cross_chain_ids_packed(h,usd,strlen(usd),&out)==TKL_INVALID_ARGUMENT);tkl_buf_free(&out);
 assert(tkl_load_begin(h,customs,strlen(customs),&txn,&out)==TKL_OK);tkl_buf_free(&out);
 assert(tkl_load_list(h,txn,"main",4,TKL_BODY_BUNDLED,list,strlen(list),&out)==TKL_OK);tkl_buf_free(&out);
 assert(tkl_load_finish(h,txn,&out)==TKL_OK);tkl_buf_free(&out);
 /* Chain 137 is disabled, 56-c3 skipped; natives and customs take part. */
 static const unsigned usdc[][3]={{1,0xa1,6},{10,0xa2,6},{56,0xa3,6},{56,0xf6,9}};
 expect(h,usd,4,usdc);
 static const unsigned both[][3]={{10,0,18},{1,0xa1,6},{10,0xa2,6},{56,0xa3,6},{1,0xb1,6},{56,0xf6,9}};
 expect(h,"{\"crossChainIds\":[\"tether\",\"usd-coin\",\"\",\"tether\",\"ethereum\",\"USD-COIN\"]}",6,both);
 expect(h,"{\"crossChainIds\":[]}",0,NULL);
 expect(h,"{\"crossChainIds\":[\"\"]}",0,NULL);
 expect(h,"{}",0,NULL);
 const char *bad="{\"crossChainIds\":\"usd-coin\"}";
 assert(tkl_get_by_cross_chain_ids_packed(h,bad,strlen(bad),&out)==TKL_INVALID_ARGUMENT);tkl_buf_free(&out);
 assert(tkl_get_by_cross_chain_ids_packed(h,NULL,0,&out)==TKL_INVALID_ARGUMENT);tkl_buf_free(&out);
 assert(tkl_get_by_cross_chain_ids_packed(h,usd,strlen(usd),NULL)==TKL_INVALID_ARGUMENT);
 /* Symbol or name, ASCII case-insensitive, in get_by_chains order. */
 const char *sym="{\"chainId\":1,\"symbol\":\"usdc\"}";
 assert(tkl_get_by_symbol_on_chain(h,sym,strlen(sym),&out)==TKL_OK);
 assert(contains(&out,"\"total\":2,"));
 const char *first=strstr((const char*)out.data,"0x00000000000000000000000000000000000000a1");
 const char *second=strstr((const char*)out.data,"0x00000000000000000000000000000000000000d1");
 assert(first && second && first<second);
 tkl_buf_free(&out);
 sym="{\"chainId\":56,\"symbol\":\"USDC\"}";
 assert(tkl_get_by_symbol_on_chain(h,sym,strlen(sym),&out)==TKL_OK);
 assert(contains(&out,"\"total\":2,") && contains(&out,"\"custom\":true"));
 tkl_buf_free(&out);
 sym="{\"chainId\":10,\"symbol\":\"ETHER\"}";
 assert(tkl_get_by_symbol_on_chain(h,sym,strlen(sym),&out)==TKL_OK);
 assert(contains(&out,"\"total\":1,") && contains(&out,"0x0000000000000000000000000000000000000000"));
 tkl_buf_free(&out);
 sym="{\"chainId\":137,\"symbol\":\"USDC\"}";
 assert(tkl_get_by_symbol_on_chain(h,sym,strlen(sym),&out)==TKL_OK && contains(&out,"\"total\":0,"));
 tkl_buf_free(&out);
 sym="{\"chainId\":1,\"symbol\":\"\"}";
 assert(tkl_get_by_symbol_on_chain(h,sym,strlen(sym),&out)==TKL_INVALID_ARGUMENT);tkl_buf_free(&out);
 assert(tkl_destroy(h)==TKL_OK);
 assert(tkl_get_by_cross_chain_ids_packed(h,usd,strlen(usd),&out)==TKL_INVALID_HANDLE);
 assert(tkl_get_by_symbol_on_chain(h,sym,strlen(sym),&out)==TKL_INVALID_HANDLE);
 puts("NARROW OK");
}
