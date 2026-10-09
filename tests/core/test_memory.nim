## Copy and retention contracts, measured with a counting allocator. Bodies are
## runtime strings: literals are shared and would hide copies.
import std/[os, strutils, unittest]
import ../memory/counting
import ../../abi/published
import ../../tokenlists/core/[catalogue, validators]
import ../../tokenlists/core/parsers/[lists, stream]
import ../../tokenlists/core/parsers/standard

const Padding = 1 shl 20

proc fixture(name: string): string =
  readFile(currentSourcePath.parentDir / ".." / ".." / "fixtures" / "embedded" / name)

proc padded(body: string): string =
  ## Same document with inner whitespace: equal parse results, larger input.
  doAssert body[0] == '{'
  "{" & ' '.repeat(Padding) & body[1 .. ^1]

suite "body copies":
  test "decoding reads the input in place":
    let body = fixture("uniswap.json")
    let large = padded(body)
    let plain = measure:
      discard decodeStandardSource(body, "uniswap").get
    let grown = measure:
      discard decodeStandardSource(large, "uniswap").get
    check grown.churn - plain.churn < Padding div 8

  test "validation copies no more than the decoded metadata":
    let body = fixture("uniswap.json")
    let named = body.replace("\"name\": \"Uniswap Labs Default\"",
      "\"name\":\"" & 'n'.repeat(Padding div 4) & "\"")
    doAssert named.len > body.len
    let plain = measure:
      check validateDocument(body, StandardFormat, "uniswap").isOk
    let grown = measure:
      check validateDocument(named, StandardFormat, "uniswap").isOk
    # Decoding the name itself grows a string (~4.5x); a document copy adds ~8x.
    check grown.churn - plain.churn < 2 * Padding

const RegistryBody = """{"timestamp":"2026-01-01T00:00:00Z","version":{"major":1,"minor":0,"patch":0},"tokenLists":[{"id":"uniswap","sourceUrl":"https://example.org/uniswap"}]}"""

let config = CatalogueConfig(chains: @[1'u64, 10], registryId: "registry",
  registryUrl: "https://example.org/registry",
  initialLists: @[ListContent(id: "uniswap", source: "bundled")])

proc loaded(body: string, origin: BodyOrigin): (Catalogue, Usage) =
  ## A stored copy, when loaded, shadows a bundled body of the same list.
  let stored = if origin == StoredBody:
      @[ListContent(id: "uniswap", source: "https://example.org/uniswap")]
    else: @[]
  var catalogue: Catalogue
  let usage = measure:
    var load = beginLoad(config, stored).get
    load.loadList("uniswap", origin, body).get
    if origin == StoredBody:
      load.loadList("uniswap", BundledBody, body).get
    catalogue = finishLoad(move(load)).get
  (catalogue, usage)

proc refreshed(body: string): (Catalogue, Usage) =
  var (catalogue, _) = loaded(fixture("uniswap.json"), BundledBody)
  let registry = RegistryBody & ""
  let usage = measure:
    let plan = catalogue.refreshPlan(10, force = true).get
    catalogue.refreshPutBody(plan.id, "registry", registry).get
    discard catalogue.refreshApply(plan.id,
      @[FetchResult(id: "registry", status: 200, etag: "r")], 10).get
    catalogue.refreshPutBody(plan.id, "uniswap", body).get
    let report = catalogue.refreshApply(plan.id,
      @[FetchResult(id: "uniswap", status: 200, etag: "u")], 10).get
    check report.writes.len == 2
    discard catalogue.refreshCommit(plan.id, 10).get
  (catalogue, usage)

suite "body retention":
  test "a load keeps no bundled or stored body":
    let body = fixture("uniswap.json")
    let large = padded(body)
    for origin in [BundledBody, StoredBody]:
      checkpoint $origin
      let (plain, plainUsage) = loaded(body, origin)
      let (grown, grownUsage) = loaded(large, origin)
      check plain.getAll().get == grown.getAll().get
      check grownUsage.retained - plainUsage.retained < Padding div 8

  test "a refresh keeps no fetched body":
    let body = fixture("uniswap.json")
    let (plain, plainUsage) = refreshed(body)
    let (grown, grownUsage) = refreshed(padded(body))
    check plain.getAll().get == grown.getAll().get
    check grownUsage.retained - plainUsage.retained < Padding div 8

suite "publication":
  test "publishing shares the snapshot instead of copying it":
    var (catalogue, _) = loaded(fixture("uniswap.json"), BundledBody)
    var shared: Published
    shared.init()
    let first = measure:
      shared.publish(catalogue.published)
    check first.churn == 0
    let owned = measure:
      discard catalogue.snapshot
    check owned.churn > 0
    discard catalogue.setChains(@[1'u64]).get
    let previous = catalogue.published
    discard catalogue.setChains(@[1'u64, 10]).get
    let swap = measure:
      shared.publish(catalogue.published)
    check swap.churn == 0
    shared.read(snapshot):
      check snapshot == catalogue.published
      check snapshot[].getAll().get == catalogue.getAll().get
    check previous[].revision + 1 == catalogue.revision
    shared.deinit()

const
  Mib = 1 shl 20
  Ids = ["coingecko_arbitrum", "coingecko_base", "coingecko_bsc",
    "coingecko_ethereum", "coingecko_linea", "coingecko_optimism", "status",
    "uniswap"]
  Chains = @[1'u64, 10, 42161, 8453, 56, 59144]

proc embedded(): (CatalogueConfig, seq[string]) =
  var config = CatalogueConfig(chains: Chains, mainListId: "status",
    policy: CataloguePolicy(nativeTokens: @[Token(chainId: 56,
      address: NativeAddress, symbol: "BNB", name: "BNB", decimals: 18)]))
  var bodies: seq[string]
  for id in Ids:
    config.initialLists.add ListContent(id: id, source: "local",
      format: if id == "status": StatusFormat else: StandardFormat)
    bodies.add fixture(id & ".json")
  (config, bodies)

proc loadAll(config: CatalogueConfig, bodies: seq[string]): Catalogue =
  var load = beginLoad(config).get
  for index, id in Ids:
    load.loadList(id, BundledBody, bodies[index]).get
  finishLoad(move(load)).get

suite "compact catalogue":
  test "a loaded catalogue retains a compact store":
    let (config, bodies) = embedded()
    var catalogue: Catalogue
    let usage = measure:
      catalogue = loadAll(config, bodies)
    check catalogue.getAll().get.total > 11_000
    checkpoint "retained " & $usage.retained & " peak " & $usage.peak
    check usage.retained < 2 * Mib + Mib div 2
    check usage.peak < 8 * Mib

  test "chain and policy changes rebuild only indices":
    let (config, bodies) = embedded()
    var catalogue = loadAll(config, bodies)
    let narrowed = measure:
      discard catalogue.setChains(@[1'u64, 10]).get
    let restored = measure:
      discard catalogue.setChains(Chains).get
    var policy = config.policy
    policy.priority = CustomFirstPriority
    let reordered = measure:
      discard catalogue.setPolicy(policy).get
    for usage in [narrowed, restored, reordered]:
      checkpoint "churn " & $usage.churn & " peak " & $usage.peak
      check usage.churn < 2 * Mib
      check usage.peak < Mib
    check restored.retained < Mib div 2

  test "lookups and batches allocate only their results":
    let (config, bodies) = embedded()
    let catalogue = loadAll(config, bodies)
    let key = "1-0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2"
    check catalogue.getByKey(key).isOk
    let single = measure:
      for _ in 0 ..< 100:
        discard catalogue.getByKey(key).get
    check single.churn div 100 < 512
    let pairs = @[TokenIdentity(chainId: 1, address: NativeAddress),
      TokenIdentity(chainId: 1, address: "0xC02aaa39b223FE8D0A0e5C4F27eAD9083C756Cc2")]
    let batch = measure:
      check catalogue.getByChainAddresses(pairs).get.items.len == 2
    check batch.churn < 2048

  test "rows of discarded parses are not retained":
    let config = CatalogueConfig(chains: Chains,
      initialLists: @[ListContent(id: "uniswap", source: "bundled")])
    let stored = @[ListContent(id: "uniswap", source: "https://example.org/u")]
    let bundled = fixture("uniswap.json")
    let replacement = fixture("coingecko_linea.json")
    var first, second: Catalogue
    let storedFirst = measure:
      var load = beginLoad(config, stored).get
      load.loadList("uniswap", StoredBody, replacement).get
      load.loadList("uniswap", BundledBody, bundled).get
      first = finishLoad(move(load)).get
    let bundledFirst = measure:
      var reordered = beginLoad(config, stored).get
      reordered.loadList("uniswap", BundledBody, bundled).get
      reordered.loadList("uniswap", StoredBody, replacement).get
      second = finishLoad(move(reordered)).get
    check first.getAll().get == second.getAll().get
    checkpoint $storedFirst.retained & " " & $bundledFirst.retained
    check abs(bundledFirst.retained - storedFirst.retained) < 16 * 1024

suite "single-pass parsing":
  test "a list parse allocates about its own store":
    for id in Ids:
      let body = fixture(id & ".json")
      let format = if id == "status": StatusFormat else: StandardFormat
      var parsed: ParsedSource
      let usage = measure:
        var store = initTokenStore()
        parsed = parseList(store, body, format, id, DefaultParseLimits).get
        store.freeze()
        parsed.store = move(store)
      checkpoint id & " body " & $body.len & " churn " & $usage.churn &
        " peak " & $usage.peak & " retained " & $usage.retained
      # Stores grow by doubling and are trimmed once: about 3x the body.
      check usage.churn < 4 * body.len
      check usage.peak < 2 * body.len

  test "a refresh validates and parses a fetched body in one pass":
    let body = fixture("uniswap.json")
    let format = StandardFormat
    let usage = measure:
      discard fetchedListBody(body, format, "uniswap", DefaultParseLimits).get
    checkpoint "body " & $body.len & " churn " & $usage.churn
    check usage.churn < 4 * body.len

  test "a full load allocates a few times its bodies":
    let (config, bodies) = embedded()
    var total = 0
    for body in bodies:
      total += body.len
    let usage = measure:
      discard loadAll(config, bodies)
    checkpoint "bodies " & $total & " churn " & $usage.churn
    check usage.churn < 4 * total
