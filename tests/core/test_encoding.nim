## Query JSON written straight from records matches json_serialization's
## encoding of the materialized pages byte for byte.
import std/[os, strutils, unittest]
import ../../tokenlists/api
import ../../tokenlists/core/[jsoncodec, types]

const Ids = ["status", "uniswap", "coingecko_ethereum", "coingecko_bsc",
  "coingecko_linea"]

proc fixture(name: string): string =
  readFile(currentSourcePath.parentDir / ".." / ".." / "fixtures" / "embedded" / name)

proc loaded(): Catalogue =
  var config = CatalogueConfig(chains: @[1'u64, 10, 42161, 8453, 59144],
    mainListId: "status", policy: CataloguePolicy(nativeTokens: @[Token(
      chainId: 10, address: NativeAddress, symbol: "OP\"E", name: "a\\b\tc\x01\x7f",
      decimals: 18)]))
  var bodies: seq[SourceBody]
  for id in Ids:
    config.initialLists.add ListContent(id: id, source: "local\n",
      fetchedTimestamp: "2026-01-01T00:00:00Z",
      format: if id == "status": StatusFormat else: StandardFormat)
    bodies.add SourceBody(id: id, origin: BundledBody, body: fixture(id & ".json"))
  bodies.add SourceBody(id: "odd", origin: BundledBody, body: """{"name":"O\u00e9\"",
    "keywords":["a","b\u0007"],"tags":{"x" : [1, "\u000b"]},"tokens":[{"chainId":1,
    "address":"0x00000000000000000000000000000000000000Aa","name":"\u0000\b\f\n\r\t\"\\/",
    "symbol":"\u0019\u001e\u00ff","decimals":0,"logoURI":"https://a.example/b/c/d/e\""}]}""")
  config.initialLists.add ListContent(id: "odd", format: StandardFormat)
  initCatalogue(config, bodies, customs = @[Token(chainId: 1,
    address: "0x000000000000000000000000000000000000dEaD", symbol: "C",
    name: "\x1d", decimals: 6)]).get

func normalized(list: TokenList): TokenList =
  result = list
  if string(result.tags).len == 0:
    result.tags = JsonString("{}")

suite "direct query encoding":
  test "every query kind matches the materialized encoding":
    let catalogue = loaded()
    let snapshot = catalogue.published
    let held = snapshot[].detached
    check held.allOutput().get.json == Json.encode(held.getAll().get)
    for (offset, limit) in [(0, 1), (5, 100), (8000, 0), (100_000, 3)]:
      check held.allOutput(offset, limit).get.json ==
        Json.encode(held.getAll(offset, limit).get)
    for chains in [@[1'u64], @[10'u64, 59144], @[999'u64]]:
      check held.byChainsOutput(chains, 2, 50).get.json ==
        Json.encode(held.getByChains(chains, 2, 50).get)
    let all = held.getAll().get.items
    var keys: seq[string]
    var chainIds: seq[uint64]
    var addresses: seq[string]
    for index in countup(0, all.high, 7):
      keys.add $all[index].chainId & "-" & all[index].address
      chainIds.add all[index].chainId
      addresses.add all[index].address
    keys.add "1-0x0000000000000000000000000000000000000bad"
    check held.byKeysOutput(keys).get.json == Json.encode(held.getByKeys(keys).get)
    check held.byChainAddressesOutput(chainIds, addresses).get.json ==
      Json.encode(held.getByChainAddresses(chainIds, addresses).get)
    for key in keys[0 .. 3]:
      check held.byKeyOutput(key).get.json == Json.encode(types.Page[Token](
        revision: held.revision, total: 1, items: @[held.getByKey(key).get]))
    check held.nativeOutput(10).get.json == Json.encode(types.Page[Token](
      revision: held.revision, total: 1, items: @[held.getNative(10).get]))
    for id in @Ids & @["odd", "native", "custom"]:
      check held.listOutput(id).get.json == Json.encode(types.Page[TokenList](
        revision: held.revision, total: 1, items: @[normalized(held.getList(id).get)]))
    var lists = held.getLists()
    for item in lists.items.mitems:
      item = normalized(item)
    check held.listsOutput.json == Json.encode(lists)
    check held.diagnosticsOutput.json == Json.encode(held.getDiagnostics())
    check held.getDiagnostics().total > 0
    check held.listOutput("missing").error.code == NotFound
    check held.allOutput(-1).isErr

  test "control bytes the pinned writer cannot encode are escaped":
    var config = CatalogueConfig(chains: @[1'u64])
    let catalogue = initCatalogue(config, customs = @[Token(chainId: 1,
      address: "0x000000000000000000000000000000000000dEaD", symbol: "\x0f",
      name: "\x1f", decimals: 6)]).get
    let text = catalogue.published[].byKeyOutput(
      "1-0x000000000000000000000000000000000000dead").get.json
    check "\"name\":\"\\u001f\"" in text
    check "\"symbol\":\"\\u000f\"" in text
