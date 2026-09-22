import std/[unittest, sequtils, strutils]
import ../../tokenlists/core/[builder, keys]

const
  a = "0x000000000000000000000000000000000000000a"
  b = "0x000000000000000000000000000000000000000b"
  c = "0x000000000000000000000000000000000000000c"

func body(symbol: string, address = a): string =
  "{\"tokens\":[{\"chainId\":1,\"address\":\"" & address &
    "\",\"symbol\":\"" & symbol & "\",\"decimals\":18}]}"

suite "catalogue builder and immutable queries":
  test "source priority is deterministic and raw lists retain duplicates":
    let config = CatalogueConfig(chains: @[1'u64], mainListId: "main",
      initialLists: @[
        ListContent(id: "z", body: body("Z", b)),
        ListContent(id: "main", body: body("MAIN")),
        ListContent(id: "a", body: body("A", b))])
    let snapshot = buildCatalogue(config, @[
      ListContent(id: "remote-z", body: body("RZ", c)),
      ListContent(id: "remote-a", body: body("RA", c))],
      @[Token(chainId: 1, address: a, symbol: "CUSTOM", decimals: 18)], 7).get
    check snapshot.getAll().get.items.mapIt(it.symbol) == @["ETH", "MAIN", "A", "RA"]
    check snapshot.getLists().items.mapIt(it.id) ==
      @["native", "main", "a", "z", "remote-a", "remote-z", "custom"]
    check snapshot.getList("z").get.tokens[0].symbol == "Z"
    check snapshot.getAll().get.revision == 7
    check snapshot.getByKey("1-" & a.toUpperAscii()).get.symbol == "MAIN"

  test "stored data wins and corrupt stored data falls back with diagnostics":
    let config = CatalogueConfig(chains: @[1'u64], mainListId: "main",
      initialLists: @[ListContent(id: "main", body: body("EMBEDDED"))])
    let stored = buildCatalogue(config,
      @[ListContent(id: "main", body: body("STORED"), source: "remote")]).get
    check stored.getByKey("1-" & a).get.symbol == "STORED"
    check stored.getList("main").get.source == "remote"
    let fallback = buildCatalogue(config, @[
      ListContent(id: "main", body: "{"),
      ListContent(id: "broken-remote", body: "null")]).get
    check fallback.getByKey("1-" & a).get.symbol == "EMBEDDED"
    check fallback.getDiagnostics().items.len == 2
    check fallback.getDiagnostics().items[0].sourceId == "main"

  test "skips affect only unique tokens and disable native alias mapping":
    var config = CatalogueConfig(chains: @[1'u64], initialLists: @[
      ListContent(id: "list", body: body("ALIAS"))],
      policy: CataloguePolicy(nativeAliases: @[TokenIdentity(chainId: 1, address: a)]))
    let aliased = buildCatalogue(config).get
    check aliased.getByChainAddress(1, a).get.address == NativeAddress
    config.policy.skippedKeys = @["1-" & a.toUpperAscii()]
    let skipped = buildCatalogue(config).get
    check skipped.getByKey("1-" & a).error.code == NotFound
    check skipped.getList("list").get.tokens.len == 1
    check skipped.getNative(1).get.symbol == "ETH"

  test "pagination and key queries are bounded and retain request order":
    let snapshot = buildCatalogue(CatalogueConfig(chains: @[1'u64, 10],
      initialLists: @[ListContent(id: "list", body: body("A"))])).get
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
      initialLists: @[ListContent(id: "list", body: body("A"))])).get
    var items = snapshot.getAll().get.items
    items[1].symbol[0] = 'B'
    var list = snapshot.getList("list").get
    list.tokens[0].symbol = "CHANGED"
    check snapshot.getByKey("1-" & a).get.symbol == "A"
    check snapshot.getList("list").get.tokens[0].symbol == "A"

  test "native descriptors and custom-first policy are explicit":
    let config = CatalogueConfig(chains: @[56'u64], initialLists: @[
      ListContent(id: "list", body: body("CURATED").replace("\"chainId\":1", "\"chainId\":56"))],
      policy: CataloguePolicy(priority: CustomFirstPriority,
        nativeTokens: @[Token(chainId: 56, address: NativeAddress,
          symbol: "BNB", name: "BNB", crossChainId: "bsc-native", decimals: 18)]))
    let snapshot = buildCatalogue(config, customs = @[
      Token(chainId: 56, address: a, symbol: "CUSTOM", decimals: 18)]).get
    check snapshot.getNative(56).get.crossChainId == "bsc-native"
    check snapshot.getByKey("56-" & a).get.custom
    check snapshot.getByKey("56-" & a).get.symbol == "CUSTOM"

  test "invalid configuration cannot silently change priority":
    check buildCatalogue(CatalogueConfig(chains: @[1'u64, 1])).isErr
    check buildCatalogue(CatalogueConfig(initialLists: @[
      ListContent(id: "native", body: "{}")])).isErr
    check buildCatalogue(CatalogueConfig(mainListId: "missing")).isErr
    check buildCatalogue(CatalogueConfig(policy:
      CataloguePolicy(skippedKeys: @["bad"])) ).isErr
