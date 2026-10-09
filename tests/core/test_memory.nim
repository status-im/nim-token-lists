## Copy and retention contracts, measured with a counting allocator. Bodies are
## runtime strings: literals are shared and would hide copies.
import std/[os, strutils, unittest]
import ../memory/counting
import ../../abi/published
import ../../tokenlists/core/[catalogue, validators]
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
    check owned.churn > 100_000
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
