import std/[unittest, strutils, sequtils]
import tokenlists/api
import tokenlists/core/parsers/[lists, standard]

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
  initialLists: @[ListContent(id: "main"), ListContent(id: "a")])
let bundled = @[SourceBody(id: "main", origin: BundledBody, body: listBody("MAIN", '1')),
  SourceBody(id: "a", origin: BundledBody, body: listBody("A", '2'))]

type Host = object
  ## Persists the bytes it fetched under the metadata the catalogue writes.
  catalogue: Catalogue
  persisted: seq[ListContent]
  bodies: seq[SourceBody]
  diagnostics: seq[TklError]

proc persist(host: var Host, writes: seq[ListContent], fetched: seq[FetchedBody]) =
  for write in writes:
    host.persisted.keepItIf(it.id != write.id)
    host.bodies.keepItIf(it.id != write.id)
    host.persisted.add write
    for response in fetched:
      if response.id == write.id:
        host.bodies.add SourceBody(id: write.id, origin: StoredBody, body: response.body)

proc apply(
    host: var Host, planId: uint64, requests: seq[FetchRequest],
    responses: seq[FetchedBody], now: int64
): RefreshReport =
  ## Puts only the bodies the catalogue can use: not those of a same-ETag 200.
  var results: seq[FetchResult]
  for response in responses:
    let sent = requests.filterIt(it.id == response.id)
    if response.status == 200 and
        not (sent.len > 0 and sent[0].etag.len > 0 and sent[0].etag == response.etag):
      host.catalogue.refreshPutBody(planId, response.id, response.body).get
    results.add FetchResult(id: response.id, status: response.status, etag: response.etag)
  host.catalogue.refreshApply(planId, results, now).get

proc refresh(
    host: var Host, now: int64, registry: FetchedBody,
    lists: seq[FetchedBody] = @[]
): Change =
  let plan = host.catalogue.refreshPlan(now, force = true).get
  var report = host.apply(plan.id, plan.requests, @[registry], now)
  var fetched = @[registry]
  if report.step == RefreshStep.NeedMore:
    var responses = lists
    for request in report.requests:
      if not responses.anyIt(it.id == request.id):
        responses.add FetchedBody(id: request.id, status: 304)
    fetched.add responses
    report = host.apply(plan.id, report.requests, responses, now)
  check report.step == RefreshStep.Ready
  host.persist(report.writes, fetched)
  host.diagnostics = report.diagnostics
  host.catalogue.refreshCommit(plan.id, now).get

proc registry(ids: openArray[string], etag: string): FetchedBody =
  FetchedBody(id: "registry", status: 200, body: registryBody(ids), etag: etag)

proc list(id, symbol: string, digit: char, etag: string): FetchedBody =
  FetchedBody(id: id, status: 200, body: listBody(symbol, digit), etag: etag)

proc seeded(): Host =
  ## Every list has been fetched once, so the next refresh can be conditional.
  result = Host(catalogue: initCatalogue(config, bundled).get)
  discard result.refresh(10, registry(["main", "a", "b"], "r1"),
    @[list("main", "MAIN", '1', "m1"), list("a", "A", '2', "a1"),
      list("b", "B", '3', "b1")])
  parsedContents = 0

proc checkMatchesFullRebuild(host: Host) =
  ## The published catalogue equals one loaded from everything the host persisted.
  let lists = host.persisted.filterIt(it.id != "registry")
  let (parsed, _) = loadSources(config, host.bodies.filterIt(it.id != "registry") &
    bundled, lists, DefaultParseLimits).get
  let rebuilt = buildFromParsed(parsed, config.chains, config.policy, @[],
    host.catalogue.revision, host.diagnostics).get
  check host.catalogue.getAll().get == rebuilt.getAll().get
  check host.catalogue.getLists() == rebuilt.getLists()
  check host.catalogue.getDiagnostics() == rebuilt.getDiagnostics()

suite "refresh parses only changed lists":
  test "an unchanged refresh parses nothing and keeps the revision":
    var host = seeded()
    let revision = host.catalogue.revision
    check host.refresh(20, FetchedBody(id: "registry", status: 304)).kind == NoChange
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
    let change = host.refresh(20, FetchedBody(id: "registry", status: 304),
      @[list("b", "BETA", '3', "b2")])
    check parsedContents == 1
    check change.kind == RefreshChange
    check change.lists == @["b"]
    check host.catalogue.getList("b").get.tokens[0].symbol == "BETA"
    check host.catalogue.getList("a").get.tokens[0].symbol == "A"
    host.checkMatchesFullRebuild()

  test "a refetched body is parsed even when its metadata is unchanged":
    var host = seeded()
    discard host.refresh(20, FetchedBody(id: "registry", status: 304),
      @[FetchedBody(id: "b", status: 200, body: listBody("B", '3'))])
    parsedContents = 0
    discard host.refresh(20, FetchedBody(id: "registry", status: 304),
      @[FetchedBody(id: "b", status: 200, body: listBody("C", '3'))])
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

  test "lists that fell back at bootstrap are reused with their diagnostics":
    let stored = @[ListContent(id: "main", source: "https://example.org/main", etag: "m1"),
      ListContent(id: "a")]
    let bodies = @[SourceBody(id: "main", origin: StoredBody, body: listBody("MAIN", '1')),
      SourceBody(id: "a", origin: StoredBody, body: "broken")] & bundled
    var host = Host(catalogue: initCatalogue(config, bodies, stored).get,
      persisted: stored)
    let revision = host.catalogue.revision
    check host.catalogue.getDiagnostics().items.anyIt(it.sourceId == "a")
    parsedContents = 0
    check host.refresh(10, registry(["main", "a"], "r1"),
      @[FetchedBody(id: "a", status: 503)]).kind == NoChange
    check parsedContents == 0
    check host.catalogue.revision == revision
    check host.catalogue.getList("a").get.tokens[0].symbol == "A"

  test "chain changes between refreshes reuse parsed lists":
    var host = seeded()
    discard host.catalogue.setChains(@[1'u64, 10]).get
    check parsedContents == 0
    check host.refresh(20, FetchedBody(id: "registry", status: 304)).kind == NoChange
    check parsedContents == 0

  test "refresh sources reuse every list they are not given":
    let (parsed, contents) = loadSources(config, bundled, @[], DefaultParseLimits).get
    var none: seq[ParsedContent]
    let same = refreshSources(parsed, config, contents, none).get
    check same.unchanged
    var updates = @[ParsedContent(meta: ListContent(id: "a", source: "remote"),
      source: decodeStandardSource(listBody("B", '2'), "a").get)]
    var refresh = refreshSources(parsed, config, contents, updates).get
    check not refresh.unchanged
    var adopted = parsed
    adopted.adoptSources(move(refresh))
    let snapshot = buildFromParsed(adopted, config.chains).get
    check snapshot.getList("a").get.tokens[0].symbol == "B"
    check snapshot.getList("main").get.tokens[0].symbol == "MAIN"
