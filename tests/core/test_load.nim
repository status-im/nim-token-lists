import std/[unittest, sequtils]
import tokenlists/api
import tokenlists/core/parsers/lists

func listBody(symbol: string): string =
  """{"name":"List","timestamp":"2026-01-01T00:00:00Z","version":{"major":1,"minor":0,"patch":0},"tokens":[{"chainId":1,"address":"0x0000000000000000000000000000000000000001","name":"""" &
    symbol & """","symbol":"""" & symbol & """","decimals":18}]}"""

const RegistryBody = """{"timestamp":"2026-01-01T00:00:00Z","version":{"major":1,"minor":0,"patch":0},"tokenLists":[{"id":"main","sourceUrl":"https://example.org/main","schema":"standard"}]}"""

let config = CatalogueConfig(chains: @[1'u64], mainListId: "main",
  registryId: "registry", registryUrl: "https://example.org/registry",
  initialLists: @[ListContent(id: "main", source: "bundled")])
let stored = @[ListContent(id: "main", source: "https://example.org/main", etag: "m1"),
  ListContent(id: "remote", source: "https://example.org/remote"),
  ListContent(id: "registry", source: "https://example.org/registry",
    etag: "r1", format: RegistryFormat)]

proc symbol(catalogue: Catalogue, id = "main"): string =
  catalogue.getList(id).get.tokens[0].symbol

suite "load transactions":
  test "a usable stored list is parsed and its bundled body is not":
    parsedContents = 0
    var load = beginLoad(config, stored).get
    load.loadList("main", StoredBody, listBody("STORED")).get
    load.loadList("main", BundledBody, listBody("BUNDLED")).get
    load.loadList("remote", StoredBody, listBody("REMOTE")).get
    load.loadList("registry", StoredBody, RegistryBody).get
    let catalogue = finishLoad(move(load)).get
    check parsedContents == 2
    check catalogue.symbol == "STORED"
    check catalogue.symbol("remote") == "REMOTE"
    check catalogue.getList("main").get.source == "https://example.org/main"
    check catalogue.getDiagnostics().items.len == 0

  test "a stored list loaded after its bundled body still wins":
    var load = beginLoad(config, stored).get
    load.loadList("main", BundledBody, listBody("BUNDLED")).get
    load.loadList("main", StoredBody, listBody("STORED")).get
    check finishLoad(move(load)).get.symbol == "STORED"

  test "unusable stored copies fall back to bundled bodies with diagnostics":
    var failed = stored
    failed[0].failure = tklError(StorageFailure, "unreadable")
    for (metadata, body, detail) in [(stored, "broken", ""),
        (stored, "", "EmptyListContent"), (failed, listBody("UNREAD"), "unreadable")]:
      checkpoint detail
      parsedContents = 0
      var load = beginLoad(config, metadata).get
      load.loadList("main", StoredBody, body).get
      load.loadList("main", BundledBody, listBody("BUNDLED")).get
      let catalogue = finishLoad(move(load)).get
      check catalogue.symbol == "BUNDLED"
      check catalogue.getList("main").get.source == "bundled"
      let diagnostics = catalogue.getDiagnostics().items
      check diagnostics.anyIt(it.sourceId == "main")
      check diagnostics.anyIt(it.sourceId == "remote" and it.detail == "MissingListBody")
      if detail.len > 0:
        check diagnostics.anyIt(it.detail == detail)
      if metadata == failed:
        check parsedContents == 1

  test "an initial list needs a usable stored or bundled body":
    var load = beginLoad(config, stored).get
    load.loadList("main", StoredBody, "broken").get
    check finishLoad(move(load)).error.detail == "MissingListBody"
    var invalid = beginLoad(config).get
    invalid.loadList("main", BundledBody, "{").get
    check finishLoad(move(invalid)).isErr

  test "bodies are checked against the declared lists and loaded once":
    var load = beginLoad(config, stored).get
    check load.loadList("other", BundledBody, listBody("X")).error.detail ==
      "UnknownInitialList"
    check load.loadList("remote", BundledBody, listBody("X")).error.detail ==
      "UnknownInitialList"
    check load.loadList("other", StoredBody, listBody("X")).error.detail ==
      "UnknownStoredList"
    load.loadList("main", BundledBody, listBody("BUNDLED")).get
    check load.loadList("main", BundledBody, listBody("AGAIN")).error.detail ==
      "DuplicateListBody"
    # Rejected calls leave the load usable.
    check finishLoad(move(load)).get.symbol == "BUNDLED"
    var bare = beginLoad(config).get
    check bare.loadList("registry", StoredBody, RegistryBody).error.detail ==
      "UnknownStoredList"
    check beginLoad(config, @[ListContent(id: "native")]).error.detail ==
      "InvalidStoredListId"

  test "the registry prefers a valid stored copy over the bundled one":
    for (storedRegistry, etag) in [(RegistryBody, "r1"), ("broken", "")]:
      var load = beginLoad(config, stored).get
      load.loadList("registry", StoredBody, storedRegistry).get
      load.loadList("registry", BundledBody, RegistryBody).get
      load.loadList("main", BundledBody, listBody("BUNDLED")).get
      var catalogue = finishLoad(move(load)).get
      check catalogue.refreshPlan(10, force = true).get.requests[0].etag == etag
    var load = beginLoad(config, stored).get
    load.loadList("registry", StoredBody, "broken").get
    load.loadList("registry", BundledBody, "broken").get
    load.loadList("main", BundledBody, listBody("BUNDLED")).get
    check finishLoad(move(load)).isErr

  test "a load without a registry body cannot refresh":
    var catalogue = initCatalogue(config,
      [SourceBody(id: "main", origin: BundledBody, body: listBody("BUNDLED"))]).get
    let plan = catalogue.refreshPlan(10, force = true).get
    let report = catalogue.refreshApply(plan.id,
      @[FetchedBody(id: "registry", status: 503)], 11).get
    check report.diagnostics[0].detail == "RegistryUnavailable"

  test "invalid refresh state is rejected before any body is parsed":
    check beginLoad(config, refreshState = RefreshState(lastSuccess: -1)).isErr
    check beginLoad(config, planTimeoutSec = 0).isErr
