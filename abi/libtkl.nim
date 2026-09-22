{.push raises: [], gcsafe.}

import std/[atomics, locks]
import ../tokenlists/core/[catalogue, jsoncodec]
import ../tokenlists/core/types as coreTypes
import ./rwlock

const
  TklAbiVersion = 2'u32
  MaxHandles = 64
  TklMaxInputBytes {.intdefine.} = 16 * 1024 * 1024

static:
  doAssert TklMaxInputBytes > 0

type
  TklBuf {.bycopy.} = object
    data: pointer
    len, cap: csize_t
  CreateRequest = object
    config: CatalogueConfig
    limits: Opt[ParseLimits]
  BootstrapRequest = object
    contents: seq[ListContent]
    customs: seq[Token]
    state: RefreshState
  Request = object
    key, address, id: string
    chainId: uint64
    chains: seq[uint64]
    keys: seq[string]
    offset, limit: int
    revision, mutationId, planId: uint64
    now, refreshSec, checkSec: int64
    force, enabled, allowed: bool
    policy: CataloguePolicy
    token: Token
    results: seq[FetchResult]
    reason: TklStatus
  HandleObj = object
    rw: RwLock
    writer: Lock
    current: ptr Snapshot
    core: ptr Catalogue
    config: CatalogueConfig
    limits: ParseLimits
    revision: Atomic[uint64]
  Slot = object
    gen: Atomic[uint32]
    inflight: Atomic[int]
    closing: Atomic[bool]
    obj: Atomic[pointer]

{.pragma: tklExport, exportc, cdecl, dynlib, raises: [].}
proc cMalloc(size: csize_t): pointer {.importc: "malloc", header: "<stdlib.h>".}
proc cFree(p: pointer) {.importc: "free", header: "<stdlib.h>".}
proc libtklNimMain() {.importc.}

var
  initState: Atomic[int]
  registryLock: Lock
  slots: array[MaxHandles, Slot]

proc ensureInit() =
  var expected = 0
  if initState.compareExchange(expected, 1):
    libtklNimMain()
    initLock(registryLock)
    initState.store(2)
  else:
    while initState.load() != 2: cpuRelax()

proc freeValue[T](p: ptr T) =
  if not p.isNil:
    reset(p[])
    deallocShared(p)

proc own[T](value: sink T): ptr T =
  let p = createShared(T)
  p[] = value
  p

proc fillBuf(outBuf: ptr TklBuf, value: string): int32 =
  let mem = cMalloc(csize_t(max(value.len, 1)))
  if mem.isNil: return int32(Internal)
  if value.len > 0: copyMem(mem, unsafeAddr value[0], value.len)
  outBuf[] = TklBuf(data: mem, len: csize_t(value.len),
    cap: csize_t(max(value.len, 1)))
  int32(Ok)

proc errorBuf(outBuf: ptr TklBuf, error: TklError): int32 =
  if not outBuf.isNil: discard fillBuf(outBuf, Json.encode(error))
  int32(error.code)

proc leave(idx: int) =
  discard slots[idx].inflight.fetchSub(1)

proc enter(handle: uint64, idx: var int, obj: var ptr HandleObj): int32 =
  ensureInit()
  let low = handle and 0xFFFF_FFFF'u64
  if handle == 0 or low >= uint64(MaxHandles): return int32(InvalidHandle)
  let i = int(low)
  discard slots[i].inflight.fetchAdd(1)
  if slots[i].closing.load():
    leave(i)
    return int32(Closed)
  let p = cast[ptr HandleObj](slots[i].obj.load())
  if slots[i].gen.load() != uint32(handle shr 32) or p.isNil:
    leave(i)
    return int32(InvalidHandle)
  idx = i
  obj = p
  int32(Ok)

proc readInput(p: cstring, length: csize_t, maxBytes: int): Result[string, TklError] =
  if p.isNil or length == 0 or length > csize_t(maxBytes):
    return err(tklError(InvalidArgument, "InvalidInputBuffer"))
  var value = newString(int(length))
  copyMem(addr value[0], p, value.len)
  ok(value)

func envelopeLimits(limits: ParseLimits): ParseLimits =
  var bounds = limits
  # Embedded documents are JSON strings in the transport, not leaf strings
  # within a token document. The core applies the original bounds on parsing.
  bounds.maxStringBytes = limits.maxBytes
  bounds

proc tkl_abi_version(): uint32 {.tklExport.} = TklAbiVersion

proc tkl_lib_version(outBuf: ptr TklBuf): int32 {.tklExport.} =
  if outBuf.isNil: return int32(InvalidArgument)
  outBuf[] = TklBuf()
  ensureInit()
  fillBuf(outBuf, "\"0.2.0\"")

proc tkl_create(
    abiVer: uint32, data: cstring, length: csize_t,
    outHandle: ptr uint64, outBuf: ptr TklBuf
): int32 {.tklExport.} =
  if not outHandle.isNil: outHandle[] = 0
  if not outBuf.isNil: outBuf[] = TklBuf()
  if outHandle.isNil or outBuf.isNil: return int32(InvalidArgument)
  if abiVer != TklAbiVersion: return int32(AbiMismatch)
  ensureInit()
  try:
    let input = readInput(data, length, TklMaxInputBytes)
    if input.isErr: return errorBuf(outBuf, input.error)
    let decoded = decodeDocument(input.get, CreateRequest,
      envelopeLimits(DefaultParseLimits))
    if decoded.isErr: return errorBuf(outBuf, decoded.error)
    let cfg = decoded.get
    let limits = cfg.limits.get(DefaultParseLimits)
    if limits.maxBytes <= 0 or limits.maxDepth <= 0 or
        limits.maxArrayItems <= 0 or limits.maxObjectMembers <= 0 or
        limits.maxStringBytes <= 0:
      return errorBuf(outBuf, tklError(InvalidArgument, "InvalidLimits"))
    acquire(registryLock)
    defer: release(registryLock)
    for i in 0 ..< MaxHandles:
      if slots[i].obj.load().isNil and not slots[i].closing.load() and
          slots[i].gen.load() < high(uint32) - 1:
        let h = createShared(HandleObj)
        h.rw.init()
        initLock(h.writer)
        h.config = cfg.config
        h.limits = limits
        let gen = slots[i].gen.fetchAdd(1) + 1
        slots[i].obj.store(h)
        outHandle[] = (uint64(gen) shl 32) or uint64(i)
        return int32(Ok)
    int32(Busy)
  except CatchableError:
    errorBuf(outBuf, tklError(Internal, "CreateFailed"))

proc tkl_destroy(handle: uint64): int32 {.tklExport.} =
  ensureInit()
  let low = handle and 0xFFFF_FFFF'u64
  if handle == 0 or low >= uint64(MaxHandles): return int32(InvalidHandle)
  let i = int(low)
  acquire(registryLock)
  defer: release(registryLock)
  let h = cast[ptr HandleObj](slots[i].obj.load())
  if h.isNil or slots[i].gen.load() != uint32(handle shr 32):
    return int32(InvalidHandle)
  slots[i].closing.store(true)
  while slots[i].inflight.load() != 0: cpuRelax()
  slots[i].obj.store(nil)
  discard slots[i].gen.fetchAdd(1)
  freeValue(h.current)
  freeValue(h.core)
  reset(h.config)
  deinitLock(h.writer)
  h.rw.deinit()
  deallocShared(h)
  slots[i].closing.store(false)
  int32(Ok)

proc publish(h: ptr HandleObj) =
  if h.core[].revision == h.revision.load(): return
  # Copy before taking the publication lock; readers never share ORC refs.
  let next = own(h.core[].snapshot)
  h.rw.acquireWrite()
  let old = h.current
  h.current = next
  h.revision.store(next[].revision)
  h.rw.releaseWrite()
  freeValue(old)

func normalizedList(list: sink TokenList): TokenList =
  var value = list
  if string(value.tags).len == 0: value.tags = JsonString("{}")
  value

proc run(
    handle: uint64, operation: string, data: cstring, length: csize_t,
    outBuf: ptr TklBuf
): int32 =
  if outBuf.isNil: return int32(InvalidArgument)
  outBuf[] = TklBuf()
  var idx: int
  var h: ptr HandleObj
  let rc = enter(handle, idx, h)
  if rc != int32(Ok): return rc
  defer: leave(idx)
  try:
    let input = readInput(data, length, h.limits.maxBytes)
    if input.isErr: return errorBuf(outBuf, input.error)
    template checked(expression: untyped): untyped =
      block:
        let answer = expression
        if answer.isErr: return errorBuf(outBuf, answer.error)
        answer.get
    template respond(payload: untyped): untyped =
      block:
        let output = payload
        return fillBuf(outBuf, Json.encode(output))
    if operation == "load_stored":
      let request = checked(decodeDocument(input.get, BootstrapRequest,
        envelopeLimits(h.limits)))
      acquire(h.writer)
      defer: release(h.writer)
      if not h.core.isNil:
        return errorBuf(outBuf, tklError(Busy, "AlreadyLoaded"))
      let core = checked(initCatalogue(h.config, request.contents, request.customs,
        h.limits, request.state))
      h.core = own(core)
      publish(h)
      respond(h.core[].changesSince(0).get)
    let request = checked(decodeDocument(input.get, Request, envelopeLimits(h.limits)))
    if operation in ["get_by_key", "get_by_chain_address", "get_by_keys",
        "get_by_chains", "get_all", "get_native", "get_list", "get_lists",
        "get_diagnostics"]:
      h.rw.acquireRead()
      defer: h.rw.releaseRead()
      if h.current.isNil:
        return errorBuf(outBuf, tklError(InvalidArgument, "NotLoaded"))
      case operation
      of "get_by_key":
        let item = checked(h.current[].getByKey(request.key))
        let page = coreTypes.Page[Token](revision: h.current[].revision, total: 1, items: @[item])
        respond(page)
      of "get_by_chain_address":
        let item = checked(h.current[].getByChainAddress(request.chainId, request.address))
        let page = coreTypes.Page[Token](revision: h.current[].revision, total: 1, items: @[item])
        respond(page)
      of "get_native":
        let item = checked(h.current[].getNative(request.chainId))
        let page = coreTypes.Page[Token](revision: h.current[].revision, total: 1, items: @[item])
        respond(page)
      of "get_by_keys": respond(checked(h.current[].getByKeys(request.keys)))
      of "get_by_chains":
        respond(checked(h.current[].getByChains(request.chains, request.offset, request.limit)))
      of "get_all": respond(checked(h.current[].getAll(request.offset, request.limit)))
      of "get_list":
        let item = normalizedList(checked(h.current[].getList(request.id)))
        let page = coreTypes.Page[TokenList](revision: h.current[].revision, total: 1, items: @[item])
        respond(page)
      of "get_lists":
        var page = h.current[].getLists()
        for item in page.items.mitems: item = normalizedList(move(item))
        respond(page)
      else: respond(h.current[].getDiagnostics())
    acquire(h.writer)
    defer: release(h.writer)
    if h.core.isNil:
      return errorBuf(outBuf, tklError(InvalidArgument, "NotLoaded"))
    template change(expression: untyped): untyped =
      block:
        let answer = checked(expression)
        publish(h)
        respond(answer)
    case operation
    of "set_chains": change(h.core[].setChains(request.chains))
    of "set_policy": change(h.core[].setPolicy(request.policy))
    of "custom_validate_upsert": respond(checked(h.core[].customValidateUpsert(request.token)))
    of "custom_validate_delete": respond(checked(h.core[].customValidateDelete(request.key)))
    of "custom_commit": change(h.core[].customCommit(request.mutationId))
    of "custom_abort":
      checked(h.core[].customAbort(request.mutationId))
      respond(true)
    of "refresh_plan": respond(checked(h.core[].refreshPlan(request.now, request.force)))
    of "refresh_apply":
      respond(checked(h.core[].refreshApply(request.planId, request.results, request.now)))
    of "refresh_commit": change(h.core[].refreshCommit(request.planId, request.now))
    of "refresh_abort":
      checked(h.core[].refreshAbort(request.planId, request.reason))
      respond(true)
    of "set_auto_refresh":
      checked(h.core[].setAutoRefresh(request.enabled, request.refreshSec, request.checkSec))
      respond(true)
    of "set_network_allowed":
      h.core[].setNetworkAllowed(request.allowed)
      respond(true)
    of "next_due": respond(checked(h.core[].nextDue(request.now)))
    of "changes_since": respond(checked(h.core[].changesSince(request.revision)))
    of "refresh_state": respond(h.core[].refreshState)
    else: return errorBuf(outBuf, tklError(InvalidArgument, "UnknownOperation"))
  except CatchableError:
    return errorBuf(outBuf, tklError(Internal, "OperationFailed"))

proc tkl_revision(handle: uint64): uint64 {.tklExport.} =
  var idx: int
  var h: ptr HandleObj
  if enter(handle, idx, h) != int32(Ok): return 0
  defer: leave(idx)
  h.revision.load()

proc tkl_buf_free(buf: ptr TklBuf) {.tklExport.} =
  if buf.isNil: return
  if not buf.data.isNil: cFree(buf.data)
  buf[] = TklBuf()

proc tkl_load_stored(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, "load_stored", data, length, outBuf)

proc tkl_set_chains(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, "set_chains", data, length, outBuf)

proc tkl_set_policy(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, "set_policy", data, length, outBuf)

proc tkl_get_by_key(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, "get_by_key", data, length, outBuf)

proc tkl_get_by_chain_address(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, "get_by_chain_address", data, length, outBuf)

proc tkl_get_by_keys(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, "get_by_keys", data, length, outBuf)

proc tkl_get_by_chains(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, "get_by_chains", data, length, outBuf)

proc tkl_get_all(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, "get_all", data, length, outBuf)

proc tkl_get_native(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, "get_native", data, length, outBuf)

proc tkl_get_list(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, "get_list", data, length, outBuf)

proc tkl_get_lists(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, "get_lists", data, length, outBuf)

proc tkl_get_diagnostics(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, "get_diagnostics", data, length, outBuf)

proc tkl_custom_validate_upsert(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, "custom_validate_upsert", data, length, outBuf)

proc tkl_custom_validate_delete(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, "custom_validate_delete", data, length, outBuf)

proc tkl_custom_commit(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, "custom_commit", data, length, outBuf)

proc tkl_custom_abort(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, "custom_abort", data, length, outBuf)

proc tkl_refresh_plan(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, "refresh_plan", data, length, outBuf)

proc tkl_refresh_apply(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, "refresh_apply", data, length, outBuf)

proc tkl_refresh_commit(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, "refresh_commit", data, length, outBuf)

proc tkl_refresh_abort(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, "refresh_abort", data, length, outBuf)

proc tkl_set_auto_refresh(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, "set_auto_refresh", data, length, outBuf)

proc tkl_set_network_allowed(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, "set_network_allowed", data, length, outBuf)

proc tkl_next_due(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, "next_due", data, length, outBuf)

proc tkl_changes_since(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, "changes_since", data, length, outBuf)

proc tkl_refresh_state(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, "refresh_state", data, length, outBuf)
