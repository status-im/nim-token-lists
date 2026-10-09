{.push raises: [], gcsafe.}

import std/atomics
import ./rwlock
import ../tokenlists/core/snapshot

type Published* = object
  ## The snapshot that readers query. Writers, serialized by the caller, are the
  ## only ones that copy or drop the ref; readers borrow it under the read lock,
  ## so its reference count is never updated concurrently.
  rw: RwLock
  current: SnapshotRef
  revisionValue: Atomic[uint64]

proc init*(published: var Published) =
  published.rw.init()

proc deinit*(published: var Published) =
  published.current = nil
  published.rw.deinit()

proc revision*(published: var Published): uint64 =
  published.revisionValue.load()

proc publish*(published: var Published, next: sink SnapshotRef) =
  ## Swaps in `next` without copying it. The replaced snapshot is released
  ## after the write lock, when no reader can still be borrowing it.
  var previous = next
  published.rw.acquireWrite()
  swap(published.current, previous)
  published.revisionValue.store(published.current[].revision)
  published.rw.releaseWrite()

template read*(published: var Published, snapshot, body: untyped) =
  ## Runs `body` with `snapshot` borrowed (possibly nil) under the read lock.
  published.rw.acquireRead()
  try:
    let snapshot {.cursor, inject.} = published.current
    body
  finally:
    published.rw.releaseRead()
