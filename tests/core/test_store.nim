import std/[unittest, strutils, typetraits]
import ../../tokenlists/core/store

const
  a = "0x000000000000000000000000000000000000000A"
  logo = "https://assets.coingecko.com/coins/images/279/thumb/ethereum.png?1696501628"

proc add(store: var TokenStore, chain: uint64, address: string, symbol = "A",
    name = "", logoUri = "", crossChainId = "", decimals = 18'u64): uint32 =
  store.addToken(chain, address, decimals, name, symbol, logoUri, crossChainId)

suite "token store":
  test "records are plain fixed-size values":
    check sizeof(TokenRecord) == 44
    check supportsCopyMem(TokenRecord)

  test "strings are interned once and the empty string is free":
    var store = initTokenStore()
    let first = store.intern("Ether")
    check store.intern("Ether") == first
    check store.intern("Other") != first
    check store.intern("") == EmptyText
    check store.text(first) == "Ether"
    check store.text(EmptyText) == ""
    check store.textBytes == "EtherOther".len

  test "logos share prefixes and round-trip exactly":
    var store = initTokenStore()
    for url in [logo, logo.replace("279", "280"), "", "no-slashes",
        "ipfs://Qm/x", "https://a/b/c/d/", "https://a/b/c/d/e/f/g.png"]:
      let index = store.add(1, a, logoUri = url)
      check store.logo(store.record(index)) == url
    check store.prefixCount <= 3

  test "the prefix table is bounded and falls back to whole strings":
    var store = initTokenStore()
    for i in 0 ..< 600:
      let url = "https://host" & $i & ".org/a/b/logo.png"
      let index = store.add(1, a, symbol = $i, logoUri = url)
      check store.logo(store.record(index)) == url
    check store.prefixCount == 255

  test "identical tokens are stored once":
    var store = initTokenStore()
    let first = store.add(1, a, name = "Alpha", logoUri = logo)
    check store.add(1, a.toLowerAscii, name = "Alpha", logoUri = logo) == first
    check store.add(10, a, name = "Alpha", logoUri = logo) != first
    check store.add(1, a, name = "Beta", logoUri = logo) != first
    check store.len == 3

  test "materialized tokens use normalized addresses and wide chain ids":
    var store = initTokenStore()
    let index = store.add(high(uint64), a, symbol = "S", name = "N",
      logoUri = logo, crossChainId = "x", decimals = 6)
    let token = store.token(index)
    check token.chainId == high(uint64)
    check token.address == a.toLowerAscii
    check token.symbol == "S"
    check token.name == "N"
    check token.logoUri == logo
    check token.crossChainId == "x"
    check token.decimals == 6
    check not token.custom

  test "invalid rows keep their position and failure":
    var store = initTokenStore()
    let bad = store.add(1, "0x12")
    check BadAddress in store.record(bad).flags
    let wide = store.add(1, a, decimals = 256)
    check BadDecimals in store.record(wide).flags
    check store.chainId(store.record(wide)) == 1

  test "records copy between stores by content":
    var source = initTokenStore()
    let index = source.add(5, a, symbol = "SYM", name = "Name", logoUri = logo)
    var target = initTokenStore()
    discard target.add(1, a, symbol = "OTHER")
    let copied = target.copyRecord(source, index)
    check target.token(copied) == source.token(index)
    check target.copyRecord(source, index) == copied

  test "freezing drops build tables and keeps content":
    var store = initTokenStore()
    var indexes: seq[uint32]
    for i in 0 ..< 1000:
      indexes.add store.add(1, "0x" & toHex(i, 40), symbol = "S" & $i, logoUri = logo)
    let before = store.token(indexes[500])
    store.freeze()
    check store.frozen
    check store.token(indexes[500]) == before
    check store.retainedBytes < 1000 * (44 + 16)
