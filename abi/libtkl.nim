{.push raises: [], gcsafe.}

import std/[atomics, locks]
import ../tokenlists/core/[catalogue, jsoncodec]
import ../tokenlists/core/types as coreTypes
import ./published

const
  TklAbiVersion = 3'u32
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
  LoadRequest = object
    stored: seq[ListContent]
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
    published: Published
    writer: Lock
    core: ptr Catalogue
    config: CatalogueConfig
    limits: ParseLimits
    load: ptr CatalogueLoad
    loadTxn: uint64
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

template bytes(p: pointer, length: csize_t): openArray[char] =
  toOpenArray(cast[ptr UncheckedArray[char]](p), 0, int(length) - 1)

func validBytes(p: pointer, length: csize_t, maxBytes: int): bool =
  ## Borrowed inputs are read in place for the call; nothing retains them.
  length <= csize_t(maxBytes) and (length == 0 or not p.isNil)

func validInput(p: pointer, length: csize_t, maxBytes: int): bool =
  length > 0 and validBytes(p, length, maxBytes)

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
  fillBuf(outBuf, "\"0.3.0\"")

proc tkl_create(
    abiVer: uint32, data: cstring, length: csize_t,
    outHandle: ptr uint64, outBuf: ptr TklBuf
): int32 {.tklExport.} =
  if not outHandle.isNil: outHandle[] = 0
  if not outBuf.isNil: outBuf[] = TklBuf()
  if outHandle.isNil or outBuf.isNil: return int32(InvalidArgument)
  if abiVer != TklAbiVersion: return int32(AbiMismatch)
  ensureInit()
  # ORC retains a thread-local cycle buffer even after all temporary refs die.
  # Foreign threads have no Nim exit hook; drain it after the try scope unwinds.
  defer: GC_fullCollect()
  try:
    if not validInput(data, length, TklMaxInputBytes):
      return errorBuf(outBuf, tklError(InvalidArgument, "InvalidInputBuffer"))
    var decoded = decodeDocument(bytes(data, length), CreateRequest,
      envelopeLimits(DefaultParseLimits))
    if decoded.isErr: return errorBuf(outBuf, decoded.error)
    let limits = decoded.get.limits.get(DefaultParseLimits)
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
        h.published.init()
        initLock(h.writer)
        h.config = move(decoded.get.config)
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
  defer: GC_fullCollect()
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
  freeValue(h.load)
  freeValue(h.core)
  reset(h.config)
  deinitLock(h.writer)
  h.published.deinit()
  deallocShared(h)
  slots[i].closing.store(false)
  int32(Ok)

proc publish(h: ptr HandleObj) =
  if h.core[].revision != h.published.revision:
    h.published.publish(h.core[].published)

func normalizedList(list: sink TokenList): TokenList =
  var value = list
  if string(value.tags).len == 0: value.tags = JsonString("{}")
  value

type
  QueryHandler = proc(snapshot: Snapshot, request: Request): Result[string, TklError]
    {.nimcall, raises: [], gcsafe.}
  WriterHandler = proc(h: ptr HandleObj, request: Request): Result[string, TklError]
    {.nimcall, raises: [], gcsafe.}

proc encodeResult[T](value: Result[T, TklError]): Result[string, TklError] =
  let output = ?value
  ok(Json.encode(output))

proc operate(
    h: ptr HandleObj, input: openArray[char], reader: QueryHandler,
    writer: WriterHandler
): Result[string, TklError] =
  let request = ?decodeDocument(input, Request, envelopeLimits(h.limits))
  if not reader.isNil:
    h.published.read(snapshot):
      if snapshot.isNil:
        return err(tklError(InvalidArgument, "NotLoaded"))
      return reader(snapshot[], request)
  doAssert not writer.isNil
  acquire(h.writer)
  defer: release(h.writer)
  if h.core.isNil:
    return err(tklError(InvalidArgument, "NotLoaded"))
  writer(h, request)

template guarded(handle: uint64, outBuf: ptr TklBuf, body: untyped): int32 =
  ## Enters a live handle, runs `body` (a Result[string, TklError]) and fills
  ## `outBuf` with its JSON output or error. An empty output means no body.
  if outBuf.isNil: return int32(InvalidArgument)
  outBuf[] = TklBuf()
  var idx: int
  var h {.inject.}: ptr HandleObj
  let rc = enter(handle, idx, h)
  if rc != int32(Ok): return rc
  defer: leave(idx)
  # Run after request/result destructors, before returning to the host thread.
  defer: GC_fullCollect()
  try:
    let output: Result[string, TklError] = body
    if output.isErr: errorBuf(outBuf, output.error)
    elif output.get.len == 0: int32(Ok)
    else: fillBuf(outBuf, output.get)
  except CatchableError:
    errorBuf(outBuf, tklError(Internal, "OperationFailed"))

proc run(
    handle: uint64, data: cstring, length: csize_t, outBuf: ptr TklBuf,
    reader: QueryHandler = nil, writer: WriterHandler = nil
): int32 =
  guarded(handle, outBuf):
    if not validInput(data, length, h.limits.maxBytes):
      Result[string, TklError].err(tklError(InvalidArgument, "InvalidInputBuffer"))
    else:
      operate(h, bytes(data, length), reader, writer)

proc idOf(p: cstring, length: csize_t, limits: ParseLimits): Result[string, TklError] =
  if length == 0 or not validBytes(p, length, limits.maxStringBytes):
    return err(tklError(InvalidArgument, "InvalidListId"))
  var id = newString(int(length))
  copyMem(addr id[0], p, int(length))
  ok(id)

proc loadOf(h: ptr HandleObj, txn: uint64): Result[ptr CatalogueLoad, TklError] =
  if h.load.isNil or txn == 0 or txn != h.loadTxn:
    return err(tklError(InvalidArgument, "UnknownLoad"))
  ok(h.load)

proc beginLoad(h: ptr HandleObj, input: openArray[char],
    outTxn: ptr uint64): Result[string, TklError] =
  let request = ?decodeDocument(input, LoadRequest, envelopeLimits(h.limits))
  acquire(h.writer)
  defer: release(h.writer)
  if not h.core.isNil:
    return err(tklError(Busy, "AlreadyLoaded"))
  if h.loadTxn == high(uint64):
    return err(tklError(Internal, "LoadIdsExhausted"))
  let load = ?beginLoad(h.config, request.stored, request.customs, h.limits,
    request.state)
  # A new load replaces an open one, whose id becomes stale.
  freeValue(h.load)
  h.load = own(load)
  inc h.loadTxn
  outTxn[] = h.loadTxn
  ok("")

proc loadBody(h: ptr HandleObj, txn: uint64, id: string, origin: BodyOrigin,
    body: openArray[char]): Result[string, TklError] =
  acquire(h.writer)
  defer: release(h.writer)
  let load = ?h.loadOf(txn)
  ?load[].loadList(id, origin, body)
  ok("")

proc finishLoad(h: ptr HandleObj, txn: uint64): Result[string, TklError] =
  acquire(h.writer)
  defer: release(h.writer)
  let load = ?h.loadOf(txn)
  var open = move(load[])
  freeValue(h.load)
  h.load = nil
  let core = ?finishLoad(move(open))
  h.core = own(core)
  publish(h)
  encodeResult(h.core[].changesSince(0))

proc abortLoad(h: ptr HandleObj, txn: uint64): Result[string, TklError] =
  acquire(h.writer)
  defer: release(h.writer)
  discard ?h.loadOf(txn)
  freeValue(h.load)
  h.load = nil
  ok("")

proc putBody(h: ptr HandleObj, planId: uint64, id: string,
    body: openArray[char]): Result[string, TklError] =
  acquire(h.writer)
  defer: release(h.writer)
  if h.core.isNil:
    return err(tklError(InvalidArgument, "NotLoaded"))
  ?h.core[].refreshPutBody(planId, id, body)
  ok("")

proc queryByKey(snapshot: Snapshot, request: Request): Result[string, TklError] =
  let item = ?snapshot.getByKey(request.key)
  ok(Json.encode(coreTypes.Page[Token](revision: snapshot.revision, total: 1, items: @[item])))

proc queryByChainAddress(snapshot: Snapshot, request: Request): Result[string, TklError] =
  let item = ?snapshot.getByChainAddress(request.chainId, request.address)
  ok(Json.encode(coreTypes.Page[Token](revision: snapshot.revision, total: 1, items: @[item])))

proc queryNative(snapshot: Snapshot, request: Request): Result[string, TklError] =
  let item = ?snapshot.getNative(request.chainId)
  ok(Json.encode(coreTypes.Page[Token](revision: snapshot.revision, total: 1, items: @[item])))

proc queryByKeys(snapshot: Snapshot, request: Request): Result[string, TklError] =
  encodeResult(snapshot.getByKeys(request.keys))

proc queryByChains(snapshot: Snapshot, request: Request): Result[string, TklError] =
  encodeResult(snapshot.getByChains(request.chains, request.offset, request.limit))

proc queryAll(snapshot: Snapshot, request: Request): Result[string, TklError] =
  encodeResult(snapshot.getAll(request.offset, request.limit))

proc queryList(snapshot: Snapshot, request: Request): Result[string, TklError] =
  let item = normalizedList(?snapshot.getList(request.id))
  ok(Json.encode(coreTypes.Page[TokenList](revision: snapshot.revision, total: 1, items: @[item])))

proc queryLists(snapshot: Snapshot, request: Request): Result[string, TklError] =
  var page = snapshot.getLists()
  for item in page.items.mitems: item = normalizedList(move(item))
  ok(Json.encode(page))

proc queryDiagnostics(snapshot: Snapshot, request: Request): Result[string, TklError] =
  ok(Json.encode(snapshot.getDiagnostics()))

proc updateChains(h: ptr HandleObj, request: Request): Result[string, TklError] =
  let change = ?h.core[].setChains(request.chains)
  publish(h)
  ok(Json.encode(change))

proc updatePolicy(h: ptr HandleObj, request: Request): Result[string, TklError] =
  let change = ?h.core[].setPolicy(request.policy)
  publish(h)
  ok(Json.encode(change))

proc prepareUpsert(h: ptr HandleObj, request: Request): Result[string, TklError] =
  encodeResult(h.core[].customValidateUpsert(request.token))

proc prepareDelete(h: ptr HandleObj, request: Request): Result[string, TklError] =
  encodeResult(h.core[].customValidateDelete(request.key))

proc commitCustom(h: ptr HandleObj, request: Request): Result[string, TklError] =
  let change = ?h.core[].customCommit(request.mutationId)
  publish(h)
  ok(Json.encode(change))

proc abortCustom(h: ptr HandleObj, request: Request): Result[string, TklError] =
  ?h.core[].customAbort(request.mutationId)
  ok(Json.encode(true))

proc planRefresh(h: ptr HandleObj, request: Request): Result[string, TklError] =
  encodeResult(h.core[].refreshPlan(request.now, request.force))

proc applyRefresh(h: ptr HandleObj, request: Request): Result[string, TklError] =
  encodeResult(h.core[].refreshApply(request.planId, request.results, request.now))

proc commitRefresh(h: ptr HandleObj, request: Request): Result[string, TklError] =
  let change = ?h.core[].refreshCommit(request.planId, request.now)
  publish(h)
  ok(Json.encode(change))

proc abortRefresh(h: ptr HandleObj, request: Request): Result[string, TklError] =
  ?h.core[].refreshAbort(request.planId, request.reason)
  ok(Json.encode(true))

proc updateSchedule(h: ptr HandleObj, request: Request): Result[string, TklError] =
  ?h.core[].setAutoRefresh(request.enabled, request.refreshSec, request.checkSec)
  ok(Json.encode(true))

proc updateNetwork(h: ptr HandleObj, request: Request): Result[string, TklError] =
  h.core[].setNetworkAllowed(request.allowed)
  ok(Json.encode(true))

proc queryNextDue(h: ptr HandleObj, request: Request): Result[string, TklError] =
  encodeResult(h.core[].nextDue(request.now))

proc queryChanges(h: ptr HandleObj, request: Request): Result[string, TklError] =
  encodeResult(h.core[].changesSince(request.revision))

proc queryRefreshState(h: ptr HandleObj, request: Request): Result[string, TklError] =
  ok(Json.encode(h.core[].refreshState))

proc tkl_revision(handle: uint64): uint64 {.tklExport.} =
  var idx: int
  var h: ptr HandleObj
  if enter(handle, idx, h) != int32(Ok): return 0
  defer: leave(idx)
  h.published.revision

proc tkl_buf_free(buf: ptr TklBuf) {.tklExport.} =
  if buf.isNil: return
  if not buf.data.isNil: cFree(buf.data)
  buf[] = TklBuf()

proc tkl_load_begin(handle: uint64, data: cstring, length: csize_t,
    outTxn: ptr uint64, outBuf: ptr TklBuf): int32 {.tklExport.} =
  if not outTxn.isNil: outTxn[] = 0
  if outTxn.isNil: return int32(InvalidArgument)
  guarded(handle, outBuf):
    if not validInput(data, length, h.limits.maxBytes):
      Result[string, TklError].err(tklError(InvalidArgument, "InvalidInputBuffer"))
    else:
      beginLoad(h, bytes(data, length), outTxn)

proc tkl_load_list(handle, txn: uint64, id: cstring, idLength: csize_t,
    origin: uint32, body: cstring, bodyLength: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  guarded(handle, outBuf):
    let listId = idOf(id, idLength, h.limits)
    if listId.isErr:
      Result[string, TklError].err(listId.error)
    elif origin > uint32(high(BodyOrigin)) or
        not validBytes(body, bodyLength, high(int)):
      Result[string, TklError].err(tklError(InvalidArgument, "InvalidListBody"))
    else:
      loadBody(h, txn, listId.get, BodyOrigin(origin), bytes(body, bodyLength))

proc tkl_load_finish(handle, txn: uint64, outBuf: ptr TklBuf): int32 {.tklExport.} =
  guarded(handle, outBuf):
    finishLoad(h, txn)

proc tkl_load_abort(handle, txn: uint64, outBuf: ptr TklBuf): int32 {.tklExport.} =
  guarded(handle, outBuf):
    abortLoad(h, txn)

proc tkl_refresh_put_body(handle, planId: uint64, id: cstring, idLength: csize_t,
    body: cstring, bodyLength: csize_t, outBuf: ptr TklBuf): int32 {.tklExport.} =
  guarded(handle, outBuf):
    let requestId = idOf(id, idLength, h.limits)
    if requestId.isErr:
      Result[string, TklError].err(requestId.error)
    elif not validBytes(body, bodyLength, high(int)):
      Result[string, TklError].err(tklError(InvalidArgument, "InvalidListBody"))
    else:
      putBody(h, planId, requestId.get, bytes(body, bodyLength))

proc tkl_set_chains(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, data, length, outBuf, writer = updateChains)

proc tkl_set_policy(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, data, length, outBuf, writer = updatePolicy)

proc tkl_get_by_key(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, data, length, outBuf, reader = queryByKey)

proc tkl_get_by_chain_address(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, data, length, outBuf, reader = queryByChainAddress)

proc tkl_get_by_keys(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, data, length, outBuf, reader = queryByKeys)

proc tkl_get_by_chains(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, data, length, outBuf, reader = queryByChains)

proc tkl_get_all(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, data, length, outBuf, reader = queryAll)

proc tkl_get_native(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, data, length, outBuf, reader = queryNative)

proc tkl_get_list(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, data, length, outBuf, reader = queryList)

proc tkl_get_lists(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, data, length, outBuf, reader = queryLists)

proc tkl_get_diagnostics(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, data, length, outBuf, reader = queryDiagnostics)

proc tkl_custom_validate_upsert(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, data, length, outBuf, writer = prepareUpsert)

proc tkl_custom_validate_delete(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, data, length, outBuf, writer = prepareDelete)

proc tkl_custom_commit(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, data, length, outBuf, writer = commitCustom)

proc tkl_custom_abort(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, data, length, outBuf, writer = abortCustom)

proc tkl_refresh_plan(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, data, length, outBuf, writer = planRefresh)

proc tkl_refresh_apply(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, data, length, outBuf, writer = applyRefresh)

proc tkl_refresh_commit(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, data, length, outBuf, writer = commitRefresh)

proc tkl_refresh_abort(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, data, length, outBuf, writer = abortRefresh)

proc tkl_set_auto_refresh(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, data, length, outBuf, writer = updateSchedule)

proc tkl_set_network_allowed(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, data, length, outBuf, writer = updateNetwork)

proc tkl_next_due(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, data, length, outBuf, writer = queryNextDue)

proc tkl_changes_since(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, data, length, outBuf, writer = queryChanges)

proc tkl_refresh_state(handle: uint64, data: cstring, length: csize_t,
    outBuf: ptr TklBuf): int32 {.tklExport.} =
  run(handle, data, length, outBuf, writer = queryRefreshState)
