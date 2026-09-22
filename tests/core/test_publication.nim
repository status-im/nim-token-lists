import std/[atomics, os, unittest]
import ../../abi/rwlock
import ../../tokenlists/core/catalogue

type Shared = object
  lock: RwLock
  attempted: Atomic[bool]
  earlyReader: Atomic[bool]
  writerDone: Atomic[bool]
  errors: Atomic[int]
  catalogue: Catalogue

proc waitingWriter(shared: ptr Shared) {.thread.} =
  shared.attempted.store(true)
  shared.lock.acquireWrite()
  shared.writerDone.store(true)
  shared.lock.releaseWrite()

proc lateReader(shared: ptr Shared) {.thread.} =
  shared.lock.acquireRead()
  if not shared.writerDone.load():
    shared.earlyReader.store(true)
  shared.lock.releaseRead()

proc publisher(shared: ptr Shared) {.thread.} =
  for index in 0 ..< 200:
    shared.lock.acquireWrite()
    let chain = if index mod 2 == 0: 10'u64 else: 1'u64
    if shared.catalogue.setChains(@[chain]).isErr:
      discard shared.errors.fetchAdd(1)
    shared.lock.releaseWrite()

proc queryReader(shared: ptr Shared) {.thread.} =
  for index in 0 ..< 1000:
    shared.lock.acquireRead()
    let held = shared.catalogue.snapshot
    shared.lock.releaseRead()
    let page = held.getAll().get
    let expected = if page.revision mod 2 == 0: 10'u64 else: 1'u64
    if page.items.len != 1 or page.items[0].chainId != expected:
      discard shared.errors.fetchAdd(1)

suite "snapshot publication under readers":
  test "a queued writer is not bypassed by new readers":
    var shared: Shared
    shared.lock.init()
    shared.lock.acquireRead()
    var writer, reader: Thread[ptr Shared]
    createThread(writer, waitingWriter, addr shared)
    while not shared.attempted.load():
      sleep(1)
    # Keep the first read held so the writer must queue before the late reader.
    sleep(50)
    createThread(reader, lateReader, addr shared)
    sleep(50)
    let bypassed = shared.earlyReader.load()
    shared.lock.releaseRead()
    joinThread(writer)
    joinThread(reader)
    shared.lock.deinit()
    check not bypassed
    check not shared.earlyReader.load()
    check shared.writerDone.load()

  test "concurrent publication never mixes snapshot revisions":
    var shared: Shared
    shared.catalogue = initCatalogue(CatalogueConfig(chains: @[1'u64])).get
    shared.lock.init()
    var writer: Thread[ptr Shared]
    var readers: array[4, Thread[ptr Shared]]
    for reader in readers.mitems:
      createThread(reader, queryReader, addr shared)
    createThread(writer, publisher, addr shared)
    joinThread(writer)
    for reader in readers.mitems:
      joinThread(reader)
    shared.lock.deinit()
    check shared.errors.load() == 0
    check shared.catalogue.revision == 201
