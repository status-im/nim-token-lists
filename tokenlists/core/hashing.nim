{.push raises: [], gcsafe.}

## Hashes and probe accounting for the open-addressing tables that index list
## content. `-d:tklCountProbes` counts table probes and sort comparisons so
## tests can bound work without timing it.

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
