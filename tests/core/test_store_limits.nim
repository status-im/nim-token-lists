## Store size guards, reached with small limits (test_store_limits.nims).
import std/[strutils, unittest]
import tokenlists/api
import ../../tokenlists/core/store
import ../../tokenlists/core/parsers/stream

func listBody(symbol: string, rows: int): string =
  result = """{"name":"List","timestamp":"2026-01-01T00:00:00Z","version":{"major":1,"minor":0,"patch":0},"tokens":["""
  for row in 0 ..< rows:
    if row > 0: result.add ','
    result.add """{"chainId":1,"address":"0x""" & toHex(row + 1, 40) &
      """","name":"N","symbol":"""" & symbol & """","decimals":18}"""
  result.add "]}"

suite "store size guards":
  test "record indices stay below the snapshot's extra-store bit":
    var store = initTokenStore()
    for index in 0 ..< MaxRecords:
      check store.addToken(1, "", uint64(index), "", "", "", "").isSome
    check store.addToken(1, "", 999, "", "", "", "").isNone
    check store.len == MaxRecords

  test "text offsets stay within 32 bits":
    let half = MaxTextBytes div 2
    var store = initTokenStore()
    check store.addToken(1, "", 1, 'a'.repeat(half), "", "", "").isSome
    check store.addToken(1, "", 2, "b", 'c'.repeat(half), "", "").isNone
    check store.textBytes == half and store.len == 1
    var target = initTokenStore()
    check target.addToken(1, "", 3, 'd'.repeat(half + 1), "", "", "").isSome
    check target.copyRecord(store, 0).isNone

  test "a list beyond the store's room fails with TooLarge":
    var store = initTokenStore()
    let parsed = parseList(store, listBody("S", MaxRecords + 1), StandardFormat,
      "src", DefaultParseLimits)
    check parsed.isErr and parsed.error.detail == "TooLarge"

  test "a refresh whose lists outgrow the store fails with TooLarge":
    let config = CatalogueConfig(chains: @[1'u64], mainListId: "main",
      registryId: "registry", registryUrl: "https://example.org/registry",
      initialLists: @[ListContent(id: "main"), ListContent(id: "a")])
    var catalogue = initCatalogue(config, [
      SourceBody(id: "main", origin: BundledBody, body: listBody("M", 5)),
      SourceBody(id: "a", origin: BundledBody, body: listBody("A", 1))]).get
    let before = catalogue.published[].getAll().get
    let plan = catalogue.refreshPlan(10, force = true).get
    const registry = """{"timestamp":"2026-01-01T00:00:00Z","version":{"major":1,"minor":0,"patch":0},"tokenLists":[{"id":"main","sourceUrl":"https://example.org/main","schema":"standard"},{"id":"a","sourceUrl":"https://example.org/a","schema":"standard"}]}"""
    catalogue.refreshPutBody(plan.id, "registry", registry).get
    discard catalogue.refreshApply(plan.id, @[FetchResult(id: "registry", status: 200)], 11).get
    catalogue.refreshPutBody(plan.id, "a", listBody("B", 5)).get
    let applied = catalogue.refreshApply(plan.id, @[FetchResult(id: "main", status: 304),
      FetchResult(id: "a", status: 200, etag: "a2")], 12)
    check applied.isErr and applied.error.detail == "TooLarge"
    check catalogue.published[].getAll().get == before
