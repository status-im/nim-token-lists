{.push raises: [], gcsafe.}

import tokenlists/core/catalogue

const
  ListBody = """{"name":"List","timestamp":"2026-01-01T00:00:00Z","version":{"major":1,"minor":0,"patch":0},"tokens":[]}"""
  RegistryBody = """{"timestamp":"2026-01-01T00:00:00Z","version":{"major":1,"minor":0,"patch":0},"tokenLists":[{"id":"main","sourceUrl":"https://example.org/main","schema":"standard"}]}"""

proc nimMain() {.importc: "NimMain", cdecl.}

proc initialize(argc: ptr cint, argv: ptr ptr cstring): cint
    {.exportc: "LLVMFuzzerInitialize", cdecl.} =
  nimMain()
  0

proc fuzz(data: ptr UncheckedArray[byte], size: csize_t): cint
    {.exportc: "LLVMFuzzerTestOneInput", cdecl.} =
  if size > 4096:
    return 0
  var input = newString(int(size))
  if size > 0:
    copyMem(addr input[0], data, int(size))
  var catalogue = initCatalogue(CatalogueConfig(chains: @[1'u64],
    registryId: "registry", registryUrl: "https://example.org/registry",
    initialLists: @[ListContent(id: "main", body: ListBody)])).get
  var planId: uint64
  var now = 1'i64
  for i in 0 ..< min(int(size), 256):
    let
      op = int(data[i]) mod 13
      before = catalogue.revision
    case op
    of 0:
      let plan = catalogue.refreshPlan(now, force = data[i] > 127)
      if plan.isOk:
        planId = plan.get.id
    of 1, 2:
      discard catalogue.refreshApply(planId,
        @[FetchResult(id: "registry", status: 200,
          body: (if op == 1: RegistryBody else: input))], now)
    of 3, 4:
      discard catalogue.refreshApply(planId,
        @[FetchResult(id: "main", status: (if data[i] > 127: 304 else: 200),
          body: (if op == 3: ListBody else: input))], now)
    of 5:
      discard catalogue.refreshCommit(planId, now)
    of 6:
      discard catalogue.refreshAbort(planId, StorageFailure)
    of 7:
      discard catalogue.setChains(@[uint64(data[i]) + 1])
    of 8:
      let mutation = catalogue.customValidateUpsert(Token(chainId: 1,
        address: "0x0000000000000000000000000000000000000001",
        symbol: "ONE", decimals: 18))
      if mutation.isOk:
        discard catalogue.customCommit(mutation.get.id)
    of 9:
      catalogue.setNetworkAllowed(data[i] > 127)
    of 10:
      discard catalogue.setAutoRefresh(true, int64(data[i]), 3)
    of 11:
      now += int64(data[i])
    else:
      discard catalogue.refreshApply(planId + 1, @[], now)
    doAssert catalogue.revision >= before
    doAssert catalogue.revision <= before + 1
    if op notin [5, 7, 8]:
      doAssert catalogue.revision == before
    doAssert catalogue.getAll.get.revision == catalogue.revision
    doAssert catalogue.refreshState.lastSuccess <= now
  0
