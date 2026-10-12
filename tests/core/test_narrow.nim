## Narrow queries: tokens sharing cross-chain ids (packed) and a symbol or name
## on one chain, each equal to the same filter over the full answers.
import std/[os, sequtils, strutils, unittest]
import ../../tokenlists/api

const Ids = ["status", "uniswap", "coingecko_ethereum", "coingecko_bsc",
  "coingecko_linea", "coingecko_optimism"]

proc fixture(name: string): string =
  readFile(currentSourcePath.parentDir / ".." / ".." / "fixtures" / "embedded" / name)

proc loaded(skipped: seq[string] = @[]): Catalogue =
  var config = CatalogueConfig(chains: @[1'u64, 10, 56, 8453, 59144],
    mainListId: "status", policy: CataloguePolicy(
      skippedKeys: skipped,
      nativeAliases: @[TokenIdentity(chainId: 1,
        address: "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee")],
      nativeTokens: @[Token(chainId: 10, address: NativeAddress, symbol: "ETH",
        name: "Ether", decimals: 18, crossChainId: "ethereum")]))
  var bodies: seq[SourceBody]
  for id in Ids:
    config.initialLists.add ListContent(id: id,
      format: if id == "status": StatusFormat else: StandardFormat)
    bodies.add SourceBody(id: id, origin: BundledBody, body: fixture(id & ".json"))
  initCatalogue(config, bodies, customs = @[
    Token(chainId: 1, address: "0x000000000000000000000000000000000000dead",
      symbol: "usdc", name: "Custom", decimals: 6, crossChainId: "usd-coin"),
    Token(chainId: 59144, address: "0x000000000000000000000000000000000000beef",
      symbol: "D", name: "uSdC", decimals: 0)]).get

func le(data: openArray[byte], at, size: int): uint64 =
  for index in countdown(size - 1, 0):
    result = (result shl 8) or uint64(data[at + index])

func decode(data: openArray[byte]): seq[(uint64, string, uint8)] =
  doAssert uint32(le(data, 0, 4)) == PackedMagic
  let count = int(le(data, 4, 4))
  doAssert data.len == PackedHeaderBytes + count * PackedRecordBytes
  for index in 0 ..< count:
    let at = PackedHeaderBytes + index * PackedRecordBytes
    var address = "0x"
    for offset in 0 ..< 20:
      address.add toHex(data[at + 8 + offset]).toLowerAscii
    result.add (le(data, at, 8), address, data[at + 28])

func sharing(snapshot: Snapshot, ids: openArray[string]): seq[Token] =
  for token in snapshot.getAll.get.items:
    if token.crossChainId.len > 0 and token.crossChainId in ids:
      result.add token

func narrowed(tokens: openArray[Token]): seq[(uint64, string, uint8)] =
  for token in tokens:
    result.add (token.chainId, token.address, token.decimals)

proc checkCross(snapshot: Snapshot, ids: openArray[string]) =
  let expected = snapshot.sharing(ids)
  let data = snapshot.packedByCrossChainIds(ids)
  check le(data, 8, 8) == snapshot.revision
  check decode(data) == narrowed(expected)
  let page = snapshot.getByCrossChainIds(ids)
  check page.total == expected.len
  check page.items == expected

func matching(snapshot: Snapshot, chainId: uint64, symbol: string): seq[Token] =
  ## The client's legacy payment-request rule: symbol or name, ASCII case.
  for token in snapshot.getByChains([chainId]).get.items:
    if cmpIgnoreCase(token.symbol, symbol) == 0 or cmpIgnoreCase(token.name, symbol) == 0:
      result.add token

suite "tokens sharing cross-chain ids":
  test "match get_all filtered by cross-chain id":
    let catalogue = loaded()
    let snapshot = catalogue.published
    var all: seq[string]
    for token in snapshot[].getAll.get.items:
      if token.crossChainId.len > 0 and token.crossChainId notin all:
        all.add token.crossChainId
    check all.len > 100
    snapshot[].checkCross(all)
    snapshot[].checkCross([])
    snapshot[].checkCross(["usd-coin"])
    snapshot[].checkCross(["ethereum", "usd-coin", "tether", "status"])
    snapshot[].checkCross(["tether", "tether", "", "no-such-id", "TETHER"])
    for index in countup(0, all.high, 7):
      snapshot[].checkCross(all[index .. min(all.high, index + 9)])
    check snapshot[].getByCrossChainIds(["usd-coin"]).items.len >= 5

  test "natives, customs, skips and aliases follow get_all":
    let base = loaded()
    let first = base.published[].getByCrossChainIds(["usd-coin"]).items[0]
    let catalogue = loaded(@[$first.chainId & "-" & first.address])
    let snapshot = catalogue.published
    let tokens = snapshot[].getByCrossChainIds(["usd-coin", "ethereum"]).items
    check first notin tokens
    check tokens.anyIt(it.custom and it.address.endsWith("dead"))
    check tokens.anyIt(it.chainId == 10 and it.address == NativeAddress)
    check not tokens.anyIt(it.address == "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee")
    snapshot[].checkCross(["usd-coin", "ethereum"])

  test "writing fills exactly the measured size":
    let catalogue = loaded()
    let output = catalogue.published[].byCrossChainIdsOutput(["usd-coin", "tether"])
    let size = output.packedLen
    var data = newSeq[byte](size + 1)
    data[size] = 0xAB
    output.writePacked(cast[ptr UncheckedArray[byte]](addr data[0]), size)
    check data[size] == 0xAB
    check data[0 ..< size] == catalogue.published[].packedByCrossChainIds(["usd-coin", "tether"])

suite "symbol on chain":
  test "every symbol and name in any case matches the client's filter":
    let catalogue = loaded()
    let snapshot = catalogue.published
    var checked = 0
    for chainId in [1'u64, 10, 56, 8453, 59144]:
      for token in snapshot[].getByChains([chainId]).get.items:
        for probe in [token.symbol, token.symbol.toUpperAscii,
            token.name.toLowerAscii]:
          if probe.len == 0: continue
          let page = snapshot[].getBySymbolOnChain(chainId, probe).get
          let expected = snapshot[].matching(chainId, probe)
          check page.items == expected
          check page.total == expected.len
          check page.revision == snapshot[].revision
          inc checked
    check checked > 10000

  test "customs and natives match; other chains and unknown symbols do not":
    let catalogue = loaded()
    let snapshot = catalogue.published
    let usdc = snapshot[].getBySymbolOnChain(1, "USDC").get.items
    check usdc.len >= 2 and usdc == snapshot[].matching(1, "USDC")
    check usdc.anyIt(it.custom)
    check snapshot[].getBySymbolOnChain(59144, "usdc").get.items.anyIt(it.custom)
    check snapshot[].getBySymbolOnChain(10, "eth").get.items[0].address == NativeAddress
    check snapshot[].getBySymbolOnChain(999, "USDC").get.items.len == 0
    check snapshot[].getBySymbolOnChain(1, "NO-SUCH-SYMBOL").get.total == 0
    check snapshot[].getBySymbolOnChain(1, "").error.code == InvalidArgument

  test "ASCII case only, like cmpIgnoreCase":
    let catalogue = loaded()
    let snapshot = catalogue.published
    check snapshot[].getBySymbolOnChain(1, "USDC\0").get.total == 0
    check snapshot[].getBySymbolOnChain(1, "USD").get.items ==
      snapshot[].matching(1, "USD")
