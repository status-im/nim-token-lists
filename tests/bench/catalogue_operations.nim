import std/[algorithm, monotimes, os, sequtils, strformat, times]
import ../../tokenlists/api as catalogueApi

# Bodies are read at run time: string literals are shared, so copies of
# staticRead bodies would be invisible to the measurements.
const ids = ["status", "uniswap", "coingecko_ethereum", "coingecko_arbitrum",
  "coingecko_base", "coingecko_bsc", "coingecko_linea", "coingecko_optimism"]
var lists: seq[ListContent]
var bodies: seq[SourceBody]
for id in ids:
  lists.add ListContent(id: id,
    format: (if id == "status": StatusFormat else: StandardFormat))
  bodies.add SourceBody(id: id, origin: BundledBody, body: readFile(
    currentSourcePath.parentDir / ".." / ".." / "fixtures" / "embedded" / id & ".json"))

proc report(label: string, samples: var seq[float64]) =
  samples.sort()
  echo &"{label}: median={samples[samples.len div 2]:.3f} ms ({samples.len} samples)"

proc millis(started: MonoTime): float64 =
  float64((getMonoTime() - started).inNanoseconds) / 1_000_000

var loads, storedLoads: seq[float64]
var stored: seq[SourceBody]
for body in bodies:
  stored.add SourceBody(id: body.id, origin: StoredBody, body: body.body)
for index in 0 ..< 10:
  let started = getMonoTime()
  doAssert initCatalogue(CatalogueConfig(chains: @[1'u64, 10, 8453, 42161],
    mainListId: "status", initialLists: lists), bodies).isOk
  loads.add millis(started)
  let restarted = getMonoTime()
  doAssert initCatalogue(CatalogueConfig(chains: @[1'u64, 10, 8453, 42161],
    mainListId: "status", initialLists: lists), stored & bodies, lists).isOk
  storedLoads.add millis(restarted)
report("load, bundled lists", loads)
report("load, eight stored lists", storedLoads)

var catalogue = initCatalogue(CatalogueConfig(chains: @[1'u64, 10, 8453, 42161],
  mainListId: "status", initialLists: lists), bodies).get
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
for index, id in ids:
  registry.add (if index > 0: "," else: "") & """{"id":"""" & id &
    """","sourceUrl":"https://example.org/""" & id & """"}"""
registry.add "]}"
var refreshing = initCatalogue(CatalogueConfig(chains: @[1'u64, 10, 8453, 42161],
  mainListId: "status", registryId: "registry",
  registryUrl: "https://example.org/registry", initialLists: lists), bodies).get
var now = 1'i64

proc refresh(changed: openArray[FetchedBody]): Change =
  let plan = refreshing.refreshPlan(now, force = true).get
  var report = refreshing.refreshApply(plan.id,
    @[FetchedBody(id: "registry", status: 200, body: registry, etag: "r")], now).get
  var responses = @changed
  for request in report.requests:
    if request.etag.len > 0 and not responses.anyIt(it.id == request.id):
      responses.add FetchedBody(id: request.id, status: 304)
  report = refreshing.refreshApply(plan.id, responses, now).get
  doAssert report.step == RefreshStep.Ready
  result = refreshing.refreshCommit(plan.id, now).get
  inc now

var everyList: seq[FetchedBody]
for body in bodies:
  everyList.add FetchedBody(id: body.id, status: 200, body: body.body, etag: "e")
let first = getMonoTime()
doAssert refresh(everyList).kind == RefreshChange
echo &"refresh, every list fetched: {millis(first):.3f} ms (1 sample)"
var unchangedRefreshes, oneListRefreshes: seq[float64]
for index in 0 ..< 20:
  let started = getMonoTime()
  doAssert refresh([]).kind == NoChange
  unchangedRefreshes.add float64((getMonoTime() - started).inNanoseconds) / 1_000_000
report("refresh, all lists unchanged", unchangedRefreshes)
for index in 0 ..< 20:
  # Alternate one list's body so each refresh writes and publishes it.
  let body = bodies[1].body & (if index mod 2 == 0: " " else: "")
  let started = getMonoTime()
  discard refresh([FetchedBody(id: bodies[1].id, status: 200, body: body,
    etag: $index)])
  oneListRefreshes.add float64((getMonoTime() - started).inNanoseconds) / 1_000_000
report("refresh, one list changed", oneListRefreshes)
checksum += refreshing.revision
echo &"Consumed checksum: {checksum}"
