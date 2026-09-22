import std/[unittest, strutils, sequtils]
import tokenlists/core/catalogue

const
  ListBody = """{"name":"List","timestamp":"2026-01-01T00:00:00Z","version":{"major":1,"minor":0,"patch":0},"tokens":[{"chainId":1,"address":"0x0000000000000000000000000000000000000001","name":"One","symbol":"ONE","decimals":18}]}"""
  RegistryBody = """{"timestamp":"2026-01-01T00:00:00Z","version":{"major":1,"minor":0,"patch":0},"tokenLists":[{"id":"main","sourceUrl":"https://example.org/main","schema":"standard"}]}"""

proc fresh(): Catalogue =
  initCatalogue(CatalogueConfig(chains: @[1'u64], mainListId: "main",
    registryId: "registry", registryUrl: "https://example.org/registry",
    initialLists: @[ListContent(id: "main", body: ListBody)])).get

proc registryResult(body = RegistryBody): FetchResult =
  FetchResult(id: "registry", status: 200, body: body, etag: "r1")

proc complete(catalogue: var Catalogue, now = 10'i64) =
  let plan = catalogue.refreshPlan(now, force = true).get
  discard catalogue.refreshApply(plan.id, @[registryResult()], now + 1).get
  discard catalogue.refreshApply(plan.id,
    @[FetchResult(id: "main", status: 200, body: ListBody, etag: "m1")], now + 2).get
  discard catalogue.refreshCommit(plan.id, now + 3).get

suite "refresh transactions":
  test "two rounds prepare writes without publishing and commit once":
    var catalogue = fresh()
    let plan = catalogue.refreshPlan(10, force = true).get
    check plan.requests.len == 1
    check plan.requests[0].id == "registry"
    let more = catalogue.refreshApply(plan.id, @[registryResult()], 11).get
    check more.step == RefreshStep.NeedMore
    check more.requests[0].id == "main"
    let ready = catalogue.refreshApply(plan.id,
      @[FetchResult(id: "main", status: 200, body: ListBody, etag: "m1")], 12).get
    check ready.step == RefreshStep.Ready
    check ready.outcome == RefreshOutcome.Full
    check ready.writes.len == 2
    check catalogue.revision == 1
    let change = catalogue.refreshCommit(plan.id, 13).get
    check change.kind == RefreshChange
    check catalogue.revision == 2
    check catalogue.refreshState.lastSuccess == 13
    check catalogue.refreshCommit(plan.id, 14).isErr

  test "storage failure abort leaves catalogue and conditional state untouched":
    var catalogue = fresh()
    let plan = catalogue.refreshPlan(10, force = true).get
    discard catalogue.refreshApply(plan.id, @[registryResult()], 11).get
    discard catalogue.refreshApply(plan.id,
      @[FetchResult(id: "main", status: 200, body: ListBody, etag: "m1")], 12).get
    check catalogue.refreshAbort(plan.id, StorageFailure).isOk
    check catalogue.revision == 1
    check catalogue.refreshState.lastSuccess == 0
    let retry = catalogue.refreshPlan(20, force = true).get
    check retry.requests[0].etag == ""

  test "busy force supersession expiry and changed chains reject stale work":
    var catalogue = fresh()
    let first = catalogue.refreshPlan(10, force = true).get
    check catalogue.refreshPlan(11).error.code == Busy
    let second = catalogue.refreshPlan(11, force = true).get
    check second.id != first.id
    check catalogue.refreshApply(first.id, @[registryResult()], 12).isErr
    discard catalogue.setChains(@[10'u64]).get
    check catalogue.refreshApply(second.id, @[registryResult()], 12).error.code == SupersededPlan
    let third = catalogue.refreshPlan(20, force = true).get
    check catalogue.refreshApply(third.id, @[registryResult()], 320).error.detail == "PlanExpired"

  test "network permission cannot be bypassed by force":
    var catalogue = fresh()
    catalogue.setNetworkAllowed(false)
    check catalogue.refreshPlan(10, force = true).error.detail == "NetworkDisabled"
    check catalogue.setAutoRefresh(true, 0, 3).isErr
    check catalogue.setAutoRefresh(true, 30, 3).isOk
    check catalogue.nextDue(10).get.isNone
    catalogue.setNetworkAllowed(true)
    check catalogue.nextDue(10).get.get == 10

  test "304 and same etag reuse committed content without an extra revision":
    var catalogue = fresh()
    catalogue.complete()
    let plan = catalogue.refreshPlan(20, force = true).get
    check plan.requests[0].etag == "r1"
    let more = catalogue.refreshApply(plan.id,
      @[FetchResult(id: "registry", status: 304)], 21).get
    check more.requests[0].etag == "m1"
    let ready = catalogue.refreshApply(plan.id,
      @[FetchResult(id: "main", status: 200, etag: "m1", body: "ignored")], 22).get
    check ready.writes.len == 0
    check ready.outcome == RefreshOutcome.Unchanged
    check ready.sources[1].outcome == SourceOutcome.UnchangedSameEtag
    check catalogue.refreshCommit(plan.id, 23).get.kind == NoChange
    check catalogue.revision == 2
    check catalogue.refreshState.lastSuccess == 23

  test "registry failure falls back to durable registry and list failures retain data":
    var catalogue = fresh()
    catalogue.complete()
    let plan = catalogue.refreshPlan(20, force = true).get
    let more = catalogue.refreshApply(plan.id,
      @[FetchResult(id: "registry", failure: tklError(NetworkFailure, "timeout"))], 21).get
    check more.step == RefreshStep.NeedMore
    let failed = catalogue.refreshApply(plan.id,
      @[FetchResult(id: "main", status: 503)], 22).get
    check failed.step == RefreshStep.Failed
    check failed.outcome == RefreshOutcome.Failed
    check catalogue.revision == 2
    check catalogue.refreshState.lastSuccess == 13
    check catalogue.getList("main").get.tokens[0].symbol == "ONE"

  test "missing registry fails and corrupt persisted registry uses embedded fallback":
    var catalogue = fresh()
    let plan = catalogue.refreshPlan(10, force = true).get
    let failed = catalogue.refreshApply(plan.id,
      @[FetchResult(id: "registry", status: 304)], 11).get
    check failed.step == RefreshStep.Failed
    check failed.diagnostics[0].detail == "RegistryUnavailable"
    var embedded = initCatalogue(CatalogueConfig(chains: @[1'u64],
      registryId: "registry", registryUrl: "https://example.org/registry",
      embeddedRegistry: RegistryBody),
      @[ListContent(id: "registry", body: "broken", format: RegistryFormat)]).get
    let fallback = embedded.refreshPlan(20, force = true).get
    check embedded.refreshApply(fallback.id,
      @[FetchResult(id: "registry", status: 503)], 21).get.requests[0].id == "main"

  test "invalid batches are retryable and apply and commit enforce round order":
    var catalogue = fresh()
    let plan = catalogue.refreshPlan(10, force = true).get
    check catalogue.refreshCommit(plan.id, 11).error.detail == "RefreshNotPrepared"
    check catalogue.refreshApply(plan.id, @[], 11).isErr
    check catalogue.refreshApply(plan.id, @[registryResult(), registryResult()], 11).isErr
    check catalogue.refreshApply(plan.id, @[FetchResult(id: "unknown")], 11).isErr
    discard catalogue.refreshApply(plan.id, @[registryResult()], 11).get
    check catalogue.refreshCommit(plan.id, 12).isErr
    discard catalogue.refreshApply(plan.id,
      @[FetchResult(id: "main", status: 200, body: ListBody)], 12).get
    check catalogue.refreshApply(plan.id, @[], 13).error.detail == "RefreshAlreadyApplied"
    check catalogue.refreshCommit(plan.id, 13).isOk

  test "partial success retains bad and orphaned sources while publishing good data":
    var catalogue = fresh()
    catalogue.complete()
    let registry = RegistryBody.replace("\"id\":\"main\"", "\"id\":\"new\"")
      .replace("\"tokenLists\":[", "\"tokenLists\":[{\"id\":\"bad\",\"sourceUrl\":\"https://example.org/bad\",\"schema\":\"unknown\"},")
    let plan = catalogue.refreshPlan(20, force = true).get
    let more = catalogue.refreshApply(plan.id,
      @[FetchResult(id: "registry", status: 200, body: registry, etag: "r2")], 21).get
    check more.requests.len == 1
    check more.requests[0].id == "new"
    let ready = catalogue.refreshApply(plan.id,
      @[FetchResult(id: "new", status: 200, body: ListBody, etag: "n1")], 22).get
    check ready.outcome == RefreshOutcome.Partial
    check ready.writes.len == 2
    discard catalogue.refreshCommit(plan.id, 23).get
    check catalogue.getList("main").isOk
    check catalogue.getList("new").isOk
    check catalogue.getDiagnostics.items.anyIt(it.detail == "OrphanedSource")

  test "malformed and oversized list bodies do not replace previous tokens":
    for response in [FetchResult(id: "main", status: 200, body: "{}"),
        FetchResult(id: "main", failure: tklError(NetworkFailure, "tooLarge"))]:
      var catalogue = fresh()
      let plan = catalogue.refreshPlan(10, force = true).get
      discard catalogue.refreshApply(plan.id, @[registryResult()], 11).get
      let ready = catalogue.refreshApply(plan.id, @[response], 12).get
      check ready.outcome == RefreshOutcome.Partial
      check ready.writes.len == 1
      check ready.sources[1].outcome in {SourceOutcome.InvalidContent, SourceOutcome.TooLarge}
      discard catalogue.refreshCommit(plan.id, 13).get
      check catalogue.getList("main").get.tokens[0].symbol == "ONE"

  test "custom commit and policy changes invalidate prepared refreshes":
    for policyChange in [false, true]:
      var catalogue = fresh()
      let plan = catalogue.refreshPlan(10, force = true).get
      discard catalogue.refreshApply(plan.id, @[registryResult()], 11).get
      discard catalogue.refreshApply(plan.id,
        @[FetchResult(id: "main", status: 200, body: ListBody)], 12).get
      if policyChange:
        discard catalogue.setPolicy(CataloguePolicy(priority: CustomFirstPriority)).get
      else:
        let mutation = catalogue.customValidateUpsert(Token(chainId: 1,
          address: "0x0000000000000000000000000000000000000002",
          symbol: "TWO", name: "Two", decimals: 18)).get
        discard catalogue.customCommit(mutation.id).get
      check catalogue.refreshCommit(plan.id, 13).error.code == SupersededPlan
      check catalogue.revision == 2
      check catalogue.refreshState.lastSuccess == 0

  test "scheduler throttles failures and never overflows host timestamps":
    var catalogue = fresh()
    check catalogue.refreshPlan(10).error.detail == "RefreshNotDue"
    catalogue.setAutoRefresh(true, 30, 3).get
    let plan = catalogue.refreshPlan(10).get
    catalogue.refreshAbort(plan.id).get
    check catalogue.nextDue(11).get.get == 13
    check catalogue.refreshPlan(12).error.detail == "RefreshNotDue"
    catalogue.complete(13)
    check catalogue.nextDue(17).get.get == 46
    check catalogue.nextDue(-1).isErr
    check catalogue.refreshPlan(high(int64), force = true).isErr
    catalogue.setAutoRefresh(true, high(int64), high(int64)).get
    check catalogue.nextDue(17).get.get == high(int64)

  test "time zero still throttles retries":
    var catalogue = fresh()
    catalogue.setAutoRefresh(true, 30, 3).get
    let plan = catalogue.refreshPlan(0).get
    catalogue.refreshAbort(plan.id).get
    check catalogue.nextDue(0).get.get == 3

  test "bootstrap retains permissively parsed stored content after failed refresh":
    let minimal = """{"tokens":[{"chainId":1,"address":"0x0000000000000000000000000000000000000003","symbol":"STORED","decimals":18}]}"""
    var catalogue = initCatalogue(CatalogueConfig(chains: @[1'u64],
      mainListId: "main", registryId: "registry",
      registryUrl: "https://example.org/registry",
      initialLists: @[ListContent(id: "main", body: ListBody)]),
      @[ListContent(id: "main", body: minimal)]).get
    check catalogue.getList("main").get.tokens[0].symbol == "STORED"
    let plan = catalogue.refreshPlan(10, force = true).get
    discard catalogue.refreshApply(plan.id, @[registryResult()], 11).get
    discard catalogue.refreshApply(plan.id,
      @[FetchResult(id: "main", status: 503)], 12).get
    discard catalogue.refreshCommit(plan.id, 13).get
    check catalogue.getList("main").get.tokens[0].symbol == "STORED"

  test "a registry cannot change the configured format of an initial list":
    var catalogue = fresh()
    let plan = catalogue.refreshPlan(10, force = true).get
    let ready = catalogue.refreshApply(plan.id,
      @[registryResult(RegistryBody.replace("standard", "status"))], 11).get
    check ready.step == RefreshStep.Ready
    check ready.outcome == RefreshOutcome.Partial
    check ready.sources[1].outcome == SourceOutcome.UnsupportedSchema
    check catalogue.refreshCommit(plan.id, 12).isOk
    check catalogue.getList("main").get.tokens[0].symbol == "ONE"

  test "registry validators are scoped to the configured URL and format":
    for sameUrl in [false, true]:
      var catalogue = initCatalogue(CatalogueConfig(chains: @[1'u64],
        registryId: "registry", registryUrl: "https://example.org/registry"),
        @[ListContent(id: "registry", body: RegistryBody, etag: "r1",
          source: (if sameUrl: "https://example.org/registry"
                   else: "https://old.example.org/registry"),
          format: RegistryFormat)]).get
      check catalogue.refreshPlan(10, force = true).get.requests[0].etag ==
        (if sameUrl: "r1" else: "")
