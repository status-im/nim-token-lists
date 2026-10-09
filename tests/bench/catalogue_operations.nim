import std/[algorithm, monotimes, sequtils, strformat, times]
import ../../tokenlists/core/catalogue as catalogueCore

const inputs = [
  ListContent(id: "status", format: StatusFormat,
    body: staticRead("../../fixtures/embedded/status.json")),
  ListContent(id: "uniswap", body: staticRead("../../fixtures/embedded/uniswap.json")),
  ListContent(id: "coingecko_ethereum",
    body: staticRead("../../fixtures/embedded/coingecko_ethereum.json")),
  ListContent(id: "coingecko_arbitrum",
    body: staticRead("../../fixtures/embedded/coingecko_arbitrum.json")),
  ListContent(id: "coingecko_base", body: staticRead("../../fixtures/embedded/coingecko_base.json")),
  ListContent(id: "coingecko_bsc", body: staticRead("../../fixtures/embedded/coingecko_bsc.json")),
  ListContent(id: "coingecko_linea", body: staticRead("../../fixtures/embedded/coingecko_linea.json")),
  ListContent(id: "coingecko_optimism",
    body: staticRead("../../fixtures/embedded/coingecko_optimism.json"))]

proc report(label: string, samples: var seq[float64]) =
  samples.sort()
  echo &"{label}: median={samples[samples.len div 2]:.3f} ms ({samples.len} samples)"

var catalogue = initCatalogue(CatalogueConfig(chains: @[1'u64, 10, 8453, 42161],
  mainListId: "status", initialLists: @inputs)).get
doAssert catalogue.snapshot.getAll().get.total == 8404
var total, commits: seq[float64]
var checksum = 0'u64
for index in 0 ..< 20:
  let started = getMonoTime()
  let mutation = catalogue.customValidateUpsert(Token(chainId: 1,
    address: "0x000000000000000000000000000000000000dead",
    symbol: "BENCH" & $index, decimals: 18)).get
  let prepared = getMonoTime()
  checksum += catalogue.customCommit(mutation.id).get.revision
  let finished = getMonoTime()
  total.add float64((finished - started).inNanoseconds) / 1_000_000
  commits.add float64((finished - prepared).inNanoseconds) / 1_000_000
report("upsert prepare+commit", total)
report("commit only", commits)

let key = "1-" & NativeAddress
var ownedReads: seq[float64]
for index in 0 ..< 100:
  let started = getMonoTime()
  let held = catalogue.snapshot
  checksum += uint64(held.getByKey(key).get.symbol.len)
  ownedReads.add float64((getMonoTime() - started).inNanoseconds) / 1_000_000
report("owned snapshot+lookup", ownedReads)
when compiles(catalogue.getByKey(key)):
  let started = getMonoTime()
  for index in 0 ..< 100_000:
    checksum += uint64(catalogue.getByKey(key).get.symbol.len)
  let nanos = float64((getMonoTime() - started).inNanoseconds) / 100_000
  echo &"direct catalogue lookup: {nanos:.1f} ns/op (100000 iterations)"
var registry = """{"timestamp":"2026-01-01T00:00:00Z","version":{"major":1,"minor":0,"patch":0},"tokenLists":["""
for index, input in inputs:
  registry.add (if index > 0: "," else: "") & """{"id":"""" & input.id &
    """","sourceUrl":"https://example.org/""" & input.id & """"}"""
registry.add "]}"
var refreshing = initCatalogue(CatalogueConfig(chains: @[1'u64, 10, 8453, 42161],
  mainListId: "status", registryId: "registry",
  registryUrl: "https://example.org/registry", initialLists: @inputs)).get
var now = 1'i64

proc refresh(changed: openArray[FetchResult]): Change =
  let plan = refreshing.refreshPlan(now, force = true).get
  var report = refreshing.refreshApply(plan.id,
    @[FetchResult(id: "registry", status: 200, body: registry, etag: "r")], now).get
  var responses = @changed
  for request in report.requests:
    if request.etag.len > 0 and not responses.anyIt(it.id == request.id):
      responses.add FetchResult(id: request.id, status: 304)
  report = refreshing.refreshApply(plan.id, responses, now).get
  doAssert report.step == RefreshStep.Ready
  result = refreshing.refreshCommit(plan.id, now).get
  inc now

var everyList: seq[FetchResult]
for input in inputs:
  everyList.add FetchResult(id: input.id, status: 200, body: input.body, etag: "e")
doAssert refresh(everyList).kind == RefreshChange
var unchangedRefreshes, oneListRefreshes: seq[float64]
for index in 0 ..< 20:
  let started = getMonoTime()
  doAssert refresh([]).kind == NoChange
  unchangedRefreshes.add float64((getMonoTime() - started).inNanoseconds) / 1_000_000
report("refresh, all lists unchanged", unchangedRefreshes)
for index in 0 ..< 20:
  # Alternate one list's body so each refresh writes and publishes it.
  let body = inputs[1].body & (if index mod 2 == 0: " " else: "")
  let started = getMonoTime()
  discard refresh([FetchResult(id: inputs[1].id, status: 200, body: body,
    etag: $index)])
  oneListRefreshes.add float64((getMonoTime() - started).inNanoseconds) / 1_000_000
report("refresh, one list changed", oneListRefreshes)
checksum += refreshing.revision
echo &"Consumed checksum: {checksum}"
