{.push raises: [], gcsafe.}

import std/locks

type RwLock* = object
  lock: Lock
  cond: Cond
  readers: int
  writer: bool
  waitingWriters: int

proc init*(l: var RwLock) =
  initLock(l.lock)
  initCond(l.cond)

proc deinit*(l: var RwLock) =
  deinitCond(l.cond)
  deinitLock(l.lock)

proc acquireRead*(l: var RwLock) =
  acquire(l.lock)
  # Once a writer queues, new readers wait rather than extending its wait.
  while l.writer or l.waitingWriters > 0:
    wait(l.cond, l.lock)
  inc l.readers
  release(l.lock)

proc releaseRead*(l: var RwLock) =
  acquire(l.lock)
  dec l.readers
  if l.readers == 0:
    broadcast(l.cond)
  release(l.lock)

proc acquireWrite*(l: var RwLock) =
  acquire(l.lock)
  inc l.waitingWriters
  while l.writer or l.readers > 0:
    wait(l.cond, l.lock)
  dec l.waitingWriters
  l.writer = true
  release(l.lock)

proc releaseWrite*(l: var RwLock) =
  acquire(l.lock)
  l.writer = false
  broadcast(l.cond)
  release(l.lock)
