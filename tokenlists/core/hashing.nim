{.push raises: [], gcsafe.}

## Hashes and probe accounting for the open-addressing tables that index list
## content. `-d:tklCountProbes` counts table probes and sort comparisons so
## tests can bound work without timing it.

import std/monotimes
when defined(posix):
  import std/posix
elif defined(windows):
  import std/sysrand

when defined(tklCountProbes):
  var probes*: int

template countProbe*() =
  when defined(tklCountProbes):
    {.cast(noSideEffect).}:
      inc probes

func mix64*(value: uint64): uint64 {.inline.} =
  ## splitmix64 finalizer: every input bit reaches the low (slot) bits.
  result = (value xor (value shr 30)) * 0xBF58476D1CE4E5B9'u64
  result = (result xor (result shr 27)) * 0x94D049BB133111EB'u64
  result = result xor (result shr 31)

func hashBytes*(data: openArray[char], seed: uint64): uint64 =
  ## FNV-1a from a seeded basis, finalized so slots depend on every seed bit.
  var hash = 0xCBF29CE484222325'u64 xor seed
  for ch in data:
    hash = (hash xor uint64(ord(ch))) * 0x100000001B3'u64
  mix64(hash)

func hashValue*(value, seed: uint64): uint64 {.inline.} =
  mix64(value xor seed)

proc processSeed(): uint64 =
  # /dev/urandom rather than std/sysrand, which needs Security.framework on
  # Apple platforms.
  when defined(posix):
    let fd = posix.open("/dev/urandom", O_RDONLY or O_CLOEXEC)
    if fd >= 0:
      let read = posix.read(fd, addr result, sizeof(result))
      discard posix.close(fd)
      if read == sizeof(result):
        return
  elif defined(windows):
    var bytes: array[8, byte]
    if urandom(bytes):
      copyMem(addr result, addr bytes[0], sizeof(result))
      return
  mix64(uint64(getMonoTime().ticks) xor cast[uint64](addr result))

let hashSeed* = processSeed()
  ## Per process, so lists cannot be crafted to collide in the tables.
