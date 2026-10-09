import std/[unittest, sequtils, strutils]
import ../../tokenlists/core/[builder, keys]

const
  a = "0x000000000000000000000000000000000000000a"
  b = "0x000000000000000000000000000000000000000b"
  c = "0x000000000000000000000000000000000000000c"

func body(symbol: string, address = a): string =
  "{\"tokens\":[{\"chainId\":1,\"address\":\"" & address &
    "\",\"symbol\":\"" & symbol & "\",\"decimals\":18}]}"

func bundled(id, body: string): SourceBody =
  SourceBody(id: id, origin: BundledBody, body: body)

func stored(id, body: string): SourceBody =
  SourceBody(id: id, origin: StoredBody, body: body)

let list = @[ListContent(id: "list")]

suite "catalogue builder and immutable queries":
  test "index diff detects order and raw-only changes":
    let rows = body("A")[0 ..< body("A").len - 2] & "," &
      body("B", b)[11 ..< body("B", b).len]
    let reversed = body("B", b)[0 ..< body("B", b).len - 2] & "," &
      body("A")[11 ..< body("A").len]
    let config = CatalogueConfig(chains: @[1'u64], initialLists: list)
    let before = buildCatalogue(config, [bundled("list", rows)]).get
    let after = buildCatalogue(config, [bundled("list", reversed)]).get
    check diffSnapshots(before, after).chains == @[1'u64]
    check diffSnapshots(before, after).lists == @["list"]
    check diffSnapshots(before, before).chains.len == 0
    let skippedConfig = CatalogueConfig(chains: @[1'u64],
      policy: CataloguePolicy(skippedKeys: @["1-" & a]), initialLists: list)
    let delta = diffSnapshots(buildCatalogue(skippedConfig, [bundled("list", body("A"))]).get,
      buildCatalogue(skippedConfig, [bundled("list", body("EDITED"))]).get)
    check delta.chains.len == 0
    check delta.lists == @["list"]

  test "parsed source cache supports chain changes without reading JSON again":
    let config = CatalogueConfig(chains: @[1'u64], initialLists: list)
    let (cache, _) = loadSources(config, [bundled("list",
      body("TEN").replace("\"chainId\":1", "\"chainId\":10"))], [], DefaultParseLimits).get
    let hidden = buildFromParsed(cache, @[1'u64]).get
    check hidden.getList("list").get.tokens.len == 0
    check hidden.getDiagnostics().items[0].code == UnsupportedChain
    let visible = buildFromParsed(cache, @[10'u64]).get
    check visible.getByKey("10-" & a).get.symbol == "TEN"
    check visible.getDiagnostics().items.len == 0

  test "source priority is deterministic and raw lists retain duplicates":
    let config = CatalogueConfig(chains: @[1'u64], mainListId: "main",
      initialLists: @[ListContent(id: "z"), ListContent(id: "main"), ListContent(id: "a")])
    let snapshot = buildCatalogue(config, [bundled("z", body("Z", b)),
      bundled("main", body("MAIN")), bundled("a", body("A", b)),
      stored("remote-z", body("RZ", c)), stored("remote-a", body("RA", c))],
      @[ListContent(id: "remote-z"), ListContent(id: "remote-a")],
      @[Token(chainId: 1, address: a, symbol: "CUSTOM", decimals: 18)], 7).get
    check snapshot.getAll().get.items.mapIt(it.symbol) == @["ETH", "MAIN", "A", "RA"]
    check snapshot.getLists().items.mapIt(it.id) ==
      @["native", "main", "a", "z", "remote-a", "remote-z", "custom"]
    check snapshot.getList("z").get.tokens[0].symbol == "Z"
    check snapshot.getAll().get.revision == 7
    check snapshot.getByKey("1-" & a.toUpperAscii()).get.symbol == "MAIN"

  test "stored data wins and corrupt stored data falls back with diagnostics":
    let config = CatalogueConfig(chains: @[1'u64], mainListId: "main",
      initialLists: @[ListContent(id: "main")])
    let fresh = buildCatalogue(config, [stored("main", body("STORED")),
      bundled("main", body("EMBEDDED"))], @[ListContent(id: "main", source: "remote")]).get
    check fresh.getByKey("1-" & a).get.symbol == "STORED"
    check fresh.getList("main").get.source == "remote"
    let fallback = buildCatalogue(config, [stored("main", "{"),
      stored("broken-remote", "null"), bundled("main", body("EMBEDDED"))],
      @[ListContent(id: "main"), ListContent(id: "broken-remote")]).get
    check fallback.getByKey("1-" & a).get.symbol == "EMBEDDED"
    check fallback.getDiagnostics().items.len == 2
    check fallback.getDiagnostics().items[0].sourceId == "main"

  test "skips affect only unique tokens and disable native alias mapping":
    var config = CatalogueConfig(chains: @[1'u64], initialLists: list,
      policy: CataloguePolicy(nativeAliases: @[TokenIdentity(chainId: 1, address: a)]))
    let aliased = buildCatalogue(config, [bundled("list", body("ALIAS"))]).get
    check aliased.getByChainAddress(1, a).get.address == NativeAddress
    config.policy.skippedKeys = @["1-" & a.toUpperAscii()]
    let skipped = buildCatalogue(config, [bundled("list", body("ALIAS"))]).get
    check skipped.getByKey("1-" & a).error.code == NotFound
    check skipped.getList("list").get.tokens.len == 1
    check skipped.getNative(1).get.symbol == "ETH"
    check skipped.getNative(1).get.logoUri ==
      "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/ethereum/assets/0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2/logo.png"

  test "pagination and key queries are bounded and retain request order":
    let snapshot = buildCatalogue(CatalogueConfig(chains: @[1'u64, 10],
      initialLists: list), [bundled("list", body("A"))]).get
    check snapshot.getAll(1, 1).get.items[0].chainId == 10
    check snapshot.getAll(1, 1).get.total == 3
    check snapshot.getAll(high(int), 0).get.items.len == 0
    check snapshot.getAll(-1, 0).error.code == InvalidArgument
    check snapshot.getAll(0, -1).error.code == InvalidArgument
    check snapshot.getByChains([1'u64], 1, high(int)).get.items[0].symbol == "A"
    check snapshot.getByKeys(["1-" & a, "1-" & b, "1-" & a]).get.items.len == 2
    check snapshot.getByKeys(["bad"]).error.code == InvalidArgument
    check snapshot.getNative(999).error.code == NotFound

  test "returned values cannot mutate an existing snapshot":
    let snapshot = buildCatalogue(CatalogueConfig(chains: @[1'u64],
      initialLists: list), [bundled("list", body("A"))]).get
    var items = snapshot.getAll().get.items
    items[1].symbol[0] = 'B'
    var list = snapshot.getList("list").get
    list.tokens[0].symbol = "CHANGED"
    check snapshot.getByKey("1-" & a).get.symbol == "A"
    check snapshot.getList("list").get.tokens[0].symbol == "A"

  test "native descriptors and custom-first policy are explicit":
    let config = CatalogueConfig(chains: @[56'u64], initialLists: list,
      policy: CataloguePolicy(priority: CustomFirstPriority,
        nativeTokens: @[Token(chainId: 56, address: NativeAddress,
          symbol: "BNB", name: "BNB", crossChainId: "bsc-native", decimals: 18)]))
    let snapshot = buildCatalogue(config, [bundled("list",
      body("CURATED").replace("\"chainId\":1", "\"chainId\":56"))], customs = @[
      Token(chainId: 56, address: a, symbol: "CUSTOM", decimals: 18)]).get
    check snapshot.getNative(56).get.crossChainId == "bsc-native"
    check snapshot.getByKey("56-" & a).get.custom
    check snapshot.getByKey("56-" & a).get.symbol == "CUSTOM"

  test "invalid configuration cannot silently change priority":
    check buildCatalogue(CatalogueConfig(chains: @[1'u64, 1])).isErr
    check buildCatalogue(CatalogueConfig(initialLists: @[
      ListContent(id: "native")]), [bundled("native", "{}")]).isErr
    check buildCatalogue(CatalogueConfig(mainListId: "missing")).isErr
    check buildCatalogue(CatalogueConfig(policy:
      CataloguePolicy(skippedKeys: @["bad"])) ).isErr
