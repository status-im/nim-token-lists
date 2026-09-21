{.push raises: [], gcsafe.}
import std/atomics

proc libdummyNimMain() {.importc.}
var ready: Atomic[bool]

proc dummy_ping(x: cint): cint {.exportc, cdecl, dynlib.} =
  if not ready.exchange(true):
    libdummyNimMain()
  var s = newSeq[int](int(x)) # force allocator + runtime use
  for i in 0 ..< s.len: s[i] = i
  cint(s.len)
