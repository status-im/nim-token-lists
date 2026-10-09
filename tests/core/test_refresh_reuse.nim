import std/[unittest, strutils, sequtils, sets]
import tokenlists/core/catalogue

func listBody(symbol: string, digit: char): string =
  """{"name":"List","timestamp":"2026-01-01T00:00:00Z","version":{"major":1,"minor":0,"patch":0},"tokens":[{"chainId":1,"address":"0x""" &
    '0'.repeat(39) & digit & """","name":"""" & symbol & """","symbol":"""" &
    symbol & """","decimals":18}]}"""

func registryBody(ids: openArray[string]): string =
  var sources: seq[string]
  for id in ids:
    sources.add """{"id":"""" & id & """","sourceUrl":"https://example.org/""" &
      id & """","schema":"standard"}"""
  """{"timestamp":"2026-01-01T00:00:00Z","version":{"major":1,"minor":0,"patch":0},"tokenLists":[""" &
    sources.join(",") & "]}"

let config = CatalogueConfig(chains: @[1'u64], mainListId: "main",
  registryId: "registry", registryUrl: "https://example.org/registry",
  initialLists: @[ListContent(id: "main", body: listBody("MAIN", '1')),
    ListContent(id: "a", body: listBody("A", '2'))])

type Host = object
  catalogue: Catalogue
  persisted: seq[ListContent]
  diagnostics: seq[TklError]

proc persist(host: var Host, writes: seq[ListContent]) =
  for write in writes:
    host.persisted.keepItIf(it.id != write.id)
    host.persisted.add write

proc refresh(
    host: var Host, now: int64, registry: FetchResult,
    lists: seq[FetchResult] = @[]
): Change =
  let plan = host.catalogue.refreshPlan(now, force = true).get
  var report = host.catalogue.refreshApply(plan.id, @[registry], now).get
  if report.step == RefreshStep.NeedMore:
    var responses = lists
    for request in report.requests:
      if not responses.anyIt(it.id == request.id):
        responses.add FetchResult(id: request.id, status: 304)
    report = host.catalogue.refreshApply(plan.id, responses, now).get
  check report.step == RefreshStep.Ready
  host.persist(report.writes)
  host.diagnostics = report.diagnostics
  host.catalogue.refreshCommit(plan.id, now).get

proc registry(ids: openArray[string], etag: string): FetchResult =
  FetchResult(id: "registry", status: 200, body: registryBody(ids), etag: etag)

proc list(id, symbol: string, digit: char, etag: string): FetchResult =
  FetchResult(id: id, status: 200, body: listBody(symbol, digit), etag: etag)

proc seeded(stored: seq[ListContent] = @[]): Host =
  ## Every list has been fetched once, so the next refresh can be conditional.
  result = Host(catalogue: initCatalogue(config, stored).get, persisted: stored)
  discard result.refresh(10, registry(["main", "a", "b"], "r1"),
    @[list("main", "MAIN", '1', "m1"), list("a", "A", '2', "a1"),
      list("b", "B", '3', "b1")])
  parsedContents = 0

proc checkMatchesFullRebuild(host: Host) =
  ## The published catalogue equals one rebuilt from everything the host persisted.
  let parsed = parseCatalogueSources(config, host.persisted).get
  let rebuilt = buildFromParsed(parsed, config.chains, config.policy, @[],
    host.catalogue.revision, host.diagnostics).get
  check host.catalogue.getAll().get == rebuilt.getAll().get
  check host.catalogue.getLists() == rebuilt.getLists()
  check host.catalogue.getDiagnostics() == rebuilt.getDiagnostics()

suite "refresh parses only changed lists":
  test "an unchanged refresh parses nothing and keeps the revision":
    var host = seeded()
    let revision = host.catalogue.revision
    check host.refresh(20, FetchResult(id: "registry", status: 304)).kind == NoChange
    check parsedContents == 0
    check host.refresh(30, registry(["main", "a", "b"], "r1"),
      @[list("main", "ignored", '9', "m1")]).kind == NoChange
    check parsedContents == 0
    check host.refresh(40, registry(["main", "a", "b"], "r2")).kind == NoChange
    check parsedContents == 0
    check host.catalogue.revision == revision
    host.checkMatchesFullRebuild()

  test "one updated list is the only list parsed":
    var host = seeded()
    let change = host.refresh(20, FetchResult(id: "registry", status: 304),
      @[list("b", "BETA", '3', "b2")])
    check parsedContents == 1
    check change.kind == RefreshChange
    check change.lists == @["b"]
    check host.catalogue.getList("b").get.tokens[0].symbol == "BETA"
    check host.catalogue.getList("a").get.tokens[0].symbol == "A"
    host.checkMatchesFullRebuild()

  test "a refetched body is parsed even when its metadata is unchanged":
    var host = seeded()
    discard host.refresh(20, FetchResult(id: "registry", status: 304),
      @[FetchResult(id: "b", status: 200, body: listBody("B", '3'))])
    parsedContents = 0
    discard host.refresh(20, FetchResult(id: "registry", status: 304),
      @[FetchResult(id: "b", status: 200, body: listBody("C", '3'))])
    check parsedContents == 1
    check host.catalogue.getList("b").get.tokens[0].symbol == "C"
    host.checkMatchesFullRebuild()

  test "added and removed registry sources parse only the new list":
    var host = seeded()
    let added = host.refresh(20, registry(["main", "a", "b", "c"], "r2"),
      @[list("c", "C", '4', "c1")])
    check parsedContents == 1
    check added.lists == @["c"]
    host.checkMatchesFullRebuild()
    parsedContents = 0
    let removed = host.refresh(30, registry(["main", "a", "c"], "r3"))
    check parsedContents == 0
    check removed.kind == RefreshChange
    check host.catalogue.getList("b").isOk
    check host.catalogue.getDiagnostics().items.anyIt(
      it.detail == "OrphanedSource" and it.sourceId == "b")
    host.checkMatchesFullRebuild()

  test "lists that fell back at bootstrap are parsed again":
    let stored = @[ListContent(id: "main", body: listBody("MAIN", '1'),
      source: "https://example.org/main", etag: "m1"),
      ListContent(id: "a", body: "broken")]
    var host = Host(catalogue: initCatalogue(config, stored).get, persisted: stored)
    let revision = host.catalogue.revision
    parsedContents = 0
    check host.refresh(10, registry(["main", "a"], "r1"),
      @[FetchResult(id: "a", status: 503)]).kind == NoChange
    check parsedContents == 1
    check host.catalogue.revision == revision
    check host.catalogue.getList("a").get.tokens[0].symbol == "A"

  test "chain changes between refreshes reuse parsed lists":
    var host = seeded()
    discard host.catalogue.setChains(@[1'u64, 10]).get
    check parsedContents == 0
    check host.refresh(20, FetchResult(id: "registry", status: 304)).kind == NoChange
    check parsedContents == 0

  test "reparse reuses an entry only while its content identity matches":
    let first = @[ListContent(id: "main", body: listBody("MAIN", '1'),
      source: "https://example.org/main", etag: "m1")]
    var parsed = parseCatalogueSources(config, first).get
    for (moved, reparsed) in [(false, 0), (true, 1)]:
      var stored = first
      if moved:
        stored[0].source = "https://mirror.example.org/main"
      parsedContents = 0
      var refresh = reparseCatalogueSources(parsed, config, stored,
        initHashSet[string]()).get
      check parsedContents == reparsed
      check refresh.unchanged == not moved
      parsed.adoptSources(move(refresh))
      let snapshot = buildFromParsed(parsed, config.chains).get
      check snapshot.getList("main").get.source == stored[0].source
