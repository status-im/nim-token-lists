{.push raises: [], gcsafe.}

import std/[atomics, locks, options]
import ../tokenlists/core/snapshot
import ./rwlock

const
  TklAbiVersion = 1'u32
  MaxHandles = 64
  TklMaxInputBytes {.intdefine.} = 16 * 1024 * 1024
  TklOk = 0'i32
  TklNotFound = 1'i32
  TklBusy = 5'i32
  TklInvalidContent = 7'i32
  TklInvalidArgument = 13'i32
  TklInvalidHandle = 14'i32
  TklClosed = 15'i32
  TklAbiMismatch = 16'i32
  TklInternal = 17'i32

static:
  doAssert TklMaxInputBytes > 0

type
  TklBuf {.bycopy.} = object
    data: pointer
    len: csize_t
    cap: csize_t

  HandleObj = object
    rw: RwLock
    current: ptr Snapshot
    revision: Atomic[uint64]
    stageLock: Lock
    staged: ptr Snapshot
    stagedId: uint64
    nextStagedId: uint64

  Slot = object
    gen: Atomic[uint32]
    inflight: Atomic[int]
    closing: Atomic[bool]
    obj: Atomic[pointer]

{.pragma: tklExport, exportc, cdecl, dynlib, raises: [].}

proc c_malloc(size: csize_t): pointer {.importc: "malloc", header: "<stdlib.h>".}
proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>".}
proc libtklNimMain() {.importc.}

var
  initState: Atomic[int] # 0 = uninitialised, 1 = initialising, 2 = ready
  registryLock: Lock
  slots: array[MaxHandles, Slot]

proc ensureInit() =
  var expected = 0
  if initState.compareExchange(expected, 1):
    libtklNimMain()
    initLock(registryLock)
    initState.store(2)
  else:
    while initState.load() != 2:
      cpuRelax()

proc newSnapshotPtr(s: sink Snapshot): ptr Snapshot =
  result = createShared(Snapshot)
  result[] = s

proc freeSnapshotPtr(p: ptr Snapshot) =
  if not p.isNil:
    reset(p[])
    deallocShared(p)

proc toNimString(p: cstring, n: csize_t): string =
  result = newString(int(n))
  if n > 0:
    copyMem(addr result[0], p, int(n))

proc fillBuf(outBuf: ptr TklBuf, s: string): int32 =
  let n = s.len
  let mem = c_malloc(csize_t(max(n, 1)))
  if mem.isNil:
    return TklInternal
  if n > 0:
    copyMem(mem, unsafeAddr s[0], n)
  outBuf.data = mem
  outBuf.len = csize_t(n)
  outBuf.cap = csize_t(max(n, 1))
  TklOk

proc leave(idx: int) =
  discard slots[idx].inflight.fetchSub(1)

proc enter(handle: uint64, idx: var int, obj: var ptr HandleObj): int32 =
  ## On TklOk the caller MUST call leave(idx).
  ensureInit()
  let i = int(handle and 0xFFFF_FFFF'u64)
  let gen = uint32(handle shr 32)
  if handle == 0 or i >= MaxHandles:
    return TklInvalidHandle
  discard slots[i].inflight.fetchAdd(1)
  if slots[i].closing.load():
    leave(i)
    return TklClosed
  let p = cast[ptr HandleObj](slots[i].obj.load())
  if slots[i].gen.load() != gen or p.isNil:
    leave(i)
    return TklInvalidHandle
  idx = i
  obj = p
  TklOk

proc tkl_abi_version(): uint32 {.tklExport.} =
  TklAbiVersion

proc tkl_create(abiVer: uint32, outHandle: ptr uint64): int32 {.tklExport.} =
  ensureInit()
  if outHandle.isNil:
    return TklInvalidArgument
  if abiVer != TklAbiVersion:
    return TklAbiMismatch
  acquire(registryLock)
  defer: release(registryLock)
  for i in 0 ..< MaxHandles:
    if slots[i].obj.load().isNil and not slots[i].closing.load():
      let h = createShared(HandleObj)
      h.rw.init()
      initLock(h.stageLock)
      h.current = newSnapshotPtr(buildSnapshot(@[]))
      h.nextStagedId = 1
      let gen = slots[i].gen.fetchAdd(1) + 1
      slots[i].obj.store(h)
      outHandle[] = (uint64(gen) shl 32) or uint64(i)
      return TklOk
  TklBusy

proc tkl_destroy(handle: uint64): int32 {.tklExport.} =
  ensureInit()
  let i = int(handle and 0xFFFF_FFFF'u64)
  let gen = uint32(handle shr 32)
  if handle == 0 or i >= MaxHandles:
    return TklInvalidHandle
  acquire(registryLock)
  defer: release(registryLock)
  let h = cast[ptr HandleObj](slots[i].obj.load())
  if h.isNil or slots[i].gen.load() != gen:
    return TklInvalidHandle
  slots[i].closing.store(true)
  while slots[i].inflight.load() != 0:
    cpuRelax()
  slots[i].obj.store(nil)
  discard slots[i].gen.fetchAdd(1)
  freeSnapshotPtr(h.staged)
  freeSnapshotPtr(h.current)
  deinitLock(h.stageLock)
  h.rw.deinit()
  deallocShared(h)
  slots[i].closing.store(false)
  TklOk

proc tkl_stage_tokens(
    handle: uint64, json: cstring, len: csize_t, outStagedId: ptr uint64
): int32 {.tklExport.} =
  if json.isNil or outStagedId.isNil or len > csize_t(TklMaxInputBytes):
    return TklInvalidArgument
  var idx: int
  var h: ptr HandleObj
  let rc = enter(handle, idx, h)
  if rc != TklOk:
    return rc
  defer: leave(idx)
  try:
    let parsed = parseTokens(toNimString(json, len))
    if parsed.isNone:
      return TklInvalidContent
    acquire(h.stageLock)
    defer: release(h.stageLock)
    if not h.staged.isNil:
      return TklBusy
    h.staged = newSnapshotPtr(buildSnapshot(parsed.get))
    h.stagedId = h.nextStagedId
    inc h.nextStagedId
    outStagedId[] = h.stagedId
    TklOk
  except CatchableError:
    TklInternal

proc tkl_commit(
    handle: uint64, stagedId: uint64, outRevision: ptr uint64
): int32 {.tklExport.} =
  if outRevision.isNil:
    return TklInvalidArgument
  var idx: int
  var h: ptr HandleObj
  let rc = enter(handle, idx, h)
  if rc != TklOk:
    return rc
  defer: leave(idx)
  acquire(h.stageLock)
  defer: release(h.stageLock)
  if h.staged.isNil or h.stagedId != stagedId:
    return TklNotFound
  h.rw.acquireWrite()
  let old = h.current
  h.current = h.staged
  h.staged = nil
  let rev = h.revision.fetchAdd(1) + 1
  h.rw.releaseWrite()
  # The swap excludes every old reader. In-flight tracking keeps h alive.
  freeSnapshotPtr(old)
  outRevision[] = rev
  TklOk

proc tkl_abort(handle: uint64, stagedId: uint64): int32 {.tklExport.} =
  var idx: int
  var h: ptr HandleObj
  let rc = enter(handle, idx, h)
  if rc != TklOk:
    return rc
  defer: leave(idx)
  acquire(h.stageLock)
  defer: release(h.stageLock)
  if h.staged.isNil or h.stagedId != stagedId:
    return TklNotFound
  freeSnapshotPtr(h.staged)
  h.staged = nil
  TklOk

proc tkl_get_by_key(
    handle: uint64, key: cstring, keyLen: csize_t, outBuf: ptr TklBuf
): int32 {.tklExport.} =
  if key.isNil or outBuf.isNil or keyLen > csize_t(TklMaxInputBytes):
    return TklInvalidArgument
  var idx: int
  var h: ptr HandleObj
  let rc = enter(handle, idx, h)
  if rc != TklOk:
    return rc
  defer: leave(idx)
  try:
    let k = toNimString(key, keyLen)
    h.rw.acquireRead()
    defer: h.rw.releaseRead()
    let hit = h.current[].lookup(k)
    if hit.isNone:
      return TklNotFound
    fillBuf(outBuf, toJson(hit.get))
  except CatchableError:
    TklInternal

proc tkl_get_all(handle: uint64, outBuf: ptr TklBuf): int32 {.tklExport.} =
  if outBuf.isNil:
    return TklInvalidArgument
  var idx: int
  var h: ptr HandleObj
  let rc = enter(handle, idx, h)
  if rc != TklOk:
    return rc
  defer: leave(idx)
  try:
    h.rw.acquireRead()
    defer: h.rw.releaseRead()
    fillBuf(outBuf, allToJson(h.current[]))
  except CatchableError:
    TklInternal

proc tkl_revision(handle: uint64): uint64 {.tklExport.} =
  var idx: int
  var h: ptr HandleObj
  if enter(handle, idx, h) != TklOk:
    return 0
  defer: leave(idx)
  h.revision.load()

proc tkl_buf_free(buf: ptr TklBuf) {.tklExport.} =
  if buf.isNil or buf.data.isNil:
    return
  c_free(buf.data)
  buf.data = nil
  buf.len = 0
  buf.cap = 0
