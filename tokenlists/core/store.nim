{.push raises: [], gcsafe.}

## Compact token storage: fixed-size records whose strings live in one
## interned byte arena. Build tables are dropped by `freeze`; a frozen store is
## immutable and may be shared between snapshots and reader threads.

import ./types
export types

type
  TextId* = distinct uint32
    ## A string in the store's arena; `EmptyText` is the empty string.

  Address* = array[20, byte]

  RecordFlag* = enum
    CustomToken, BadAddress, BadDecimals

  TokenRecord* = object
    chain*: uint32
      ## Index into the store's chain table, so chain ids keep 64 bits.
    address*: Address
    decimals*: uint8
    flags*: set[RecordFlag]
    logoPrefix*: uint8
      ## 0, or the prefix table entry + 1 that `logo` continues.
    reserved: uint8
    symbol*, name*, logo*, crossChainId*: TextId

  TokenStore* = object
    bytes: seq[char]
    ends: seq[uint32]
    prefixes: seq[TextId]
    chainIds: seq[uint64]
    records: seq[TokenRecord]
    textSlots, recordSlots, chainSlots: seq[uint32]
    frozenValue: bool

  StoreRef* = ref TokenStore
    ## A frozen store shared by a parsed catalogue and its snapshots.

  Identity* = object
    ## A token key without strings: chain id and binary address.
    chainId*: uint64
    address*: Address

const
  EmptyText* = TextId(0)
  MaxPrefixes = 255
  MaxRecords* {.intdefine: "tklMaxRecords".} = 0x7FFF_FFFF
    ## Record indices stay below a snapshot's extra-store bit.
  MaxTextBytes {.intdefine: "tklMaxTextBytes".} = int(high(uint32))
    ## Arena offsets are 32-bit.
  PrefixSlashes = 5
  HexDigits = "0123456789abcdef"

func hexPairs(): array[256, array[2, char]] =
  for value in 0 .. 255:
    result[value] = [HexDigits[value shr 4], HexDigits[value and 15]]

const HexPairs = hexPairs()

func `==`*(a, b: TextId): bool {.borrow.}

func initTokenStore*(): TokenStore =
  TokenStore(ends: @[0'u32])

func len*(store: TokenStore): int = store.records.len
func frozen*(store: TokenStore): bool = store.frozenValue
func prefixCount*(store: TokenStore): int = store.prefixes.len
func textBytes*(store: TokenStore): int = store.bytes.len

func record*(store: TokenStore, index: uint32): lent TokenRecord =
  store.records[index]

func chainId*(store: TokenStore, record: TokenRecord): uint64 =
  store.chainIds[record.chain]

func chainIds*(store: TokenStore): lent seq[uint64] = store.chainIds

func identity*(store: TokenStore, record: TokenRecord): Identity =
  Identity(chainId: store.chainIds[record.chain], address: record.address)

func retainedBytes*(store: TokenStore): int =
  ## Payload bytes of the store's buffers, for memory tests.
  store.bytes.capacity + 4 * (store.ends.capacity + store.prefixes.capacity +
    store.textSlots.capacity + store.recordSlots.capacity +
    store.chainSlots.capacity) +
    8 * store.chainIds.capacity + sizeof(TokenRecord) * store.records.capacity

func mix(hash: uint64, value: uint64): uint64 {.inline.} =
  (hash xor value) * 0x100000001B3'u64

func hashText(text: openArray[char]): uint64 =
  result = 0xCBF29CE484222325'u64
  for ch in text:
    result = mix(result, uint64(ord(ch)))

func hashRecord(record: TokenRecord): uint64 =
  result = 0xCBF29CE484222325'u64
  let bytes = cast[ptr array[sizeof(TokenRecord), byte]](unsafeAddr record)
  for value in bytes[]:
    result = mix(result, uint64(value))

func span(store: TokenStore, id: TextId): (int, int) {.inline.} =
  let index = int(uint32(id))
  if index == 0: (0, 0)
  else: (int(store.ends[index - 1]), int(store.ends[index]))

func textLen(store: TokenStore, id: TextId): int =
  let (first, last) = store.span(id)
  last - first

func textEquals(store: TokenStore, id: TextId, text: openArray[char]): bool =
  let (first, last) = store.span(id)
  if last - first != text.len:
    return false
  for offset in 0 ..< text.len:
    if store.bytes[first + offset] != text[offset]:
      return false
  true

func text*(store: TokenStore, id: TextId): string =
  let (first, last) = store.span(id)
  if last > first:
    result = newStringUninit(last - first)
    copyMem(addr result[0], unsafeAddr store.bytes[first], last - first)

func sameText(a: TokenStore, aid: TextId, b: TokenStore, bid: TextId): bool =
  let (first, last) = a.span(aid)
  b.textEquals(bid, a.bytes.toOpenArray(first, last - 1))

# Open-addressing tables of ids or indices + 1 (0 is empty), at most half full.
proc rehashTexts(store: var TokenStore) =
  store.textSlots = newSeq[uint32](max(1024, store.textSlots.len * 2))
  let mask = uint64(store.textSlots.len - 1)
  for id in 1 ..< store.ends.len:
    let (first, last) = store.span(TextId(uint32(id)))
    var slot = hashText(store.bytes.toOpenArray(first, last - 1)) and mask
    while store.textSlots[slot] != 0:
      slot = (slot + 1) and mask
    store.textSlots[slot] = uint32(id)

proc findText(store: TokenStore, text: openArray[char], slot: var uint64): int =
  ## The id of `text`, or -1 with `slot` the free slot it would take.
  let mask = uint64(store.textSlots.len - 1)
  slot = hashText(text) and mask
  while store.textSlots[slot] != 0:
    let id = TextId(store.textSlots[slot])
    if store.textEquals(id, text):
      return int(uint32(id))
    slot = (slot + 1) and mask
  -1

proc intern*(store: var TokenStore, text: openArray[char]): TextId =
  doAssert not store.frozenValue
  if text.len == 0:
    return EmptyText
  if store.ends.len == 0:
    store.ends.add 0
  if store.textSlots.len < 2 * (store.ends.len + 1):
    store.rehashTexts()
  var slot: uint64
  let found = store.findText(text, slot)
  if found >= 0:
    return TextId(uint32(found))
  doAssert store.bytes.len + text.len <= MaxTextBytes, "token store arena full"
  let start = store.bytes.len
  store.bytes.setLen(start + text.len)
  copyMem(addr store.bytes[start], unsafeAddr text[0], text.len)
  store.ends.add uint32(store.bytes.len)
  result = TextId(uint32(store.ends.len - 1))
  store.textSlots[slot] = uint32(result)

func prefixEnd(text: openArray[char]): int =
  ## Logo URLs share scheme, host and leading path segments.
  var slashes = 0
  for index, ch in text:
    if ch == '/':
      inc slashes
      if slashes == PrefixSlashes:
        return index + 1
  0

proc prefixEntry(store: var TokenStore, prefix: openArray[char]): int =
  ## The prefix table entry of `prefix`, added if there is room, or -1. A
  ## prefix the full table cannot take is not interned.
  var slot: uint64
  let found = if store.textSlots.len == 0: -1 else: store.findText(prefix, slot)
  if found >= 0:
    result = store.prefixes.find(TextId(uint32(found)))
    if result >= 0:
      return
  if store.prefixes.len >= MaxPrefixes:
    return -1
  store.prefixes.add store.intern(prefix)
  result = store.prefixes.high

proc internLogo(store: var TokenStore, text: openArray[char]): (uint8, TextId) =
  let split = prefixEnd(text)
  if split > 0 and split < text.len:
    let entry = store.prefixEntry(text.toOpenArray(0, split - 1))
    if entry >= 0:
      return (uint8(entry + 1), store.intern(text.toOpenArray(split, text.high)))
  (0'u8, store.intern(text))

func logoLen(store: TokenStore, record: TokenRecord): int =
  result = store.textLen(record.logo)
  if record.logoPrefix > 0:
    result += store.textLen(store.prefixes[record.logoPrefix - 1])

func logo*(store: TokenStore, record: TokenRecord): string =
  if record.logoPrefix == 0:
    return store.text(record.logo)
  let
    (prefixFirst, prefixLast) = store.span(store.prefixes[record.logoPrefix - 1])
    (first, last) = store.span(record.logo)
  result = newStringUninit(prefixLast - prefixFirst + last - first)
  copyMem(addr result[0], unsafeAddr store.bytes[prefixFirst],
    prefixLast - prefixFirst)
  if last > first:
    copyMem(addr result[prefixLast - prefixFirst], unsafeAddr store.bytes[first],
      last - first)

func logoAt(store: TokenStore, record: TokenRecord, offset: int): char =
  var index = offset
  if record.logoPrefix > 0:
    let (first, last) = store.span(store.prefixes[record.logoPrefix - 1])
    if index < last - first:
      return store.bytes[first + index]
    index -= last - first
  store.bytes[store.span(record.logo)[0] + index]

func sameLogo(a: TokenStore, ar: TokenRecord, b: TokenStore, br: TokenRecord): bool =
  let length = a.logoLen(ar)
  if length != b.logoLen(br):
    return false
  if ar.logoPrefix > 0 and br.logoPrefix > 0 and
      a.sameText(a.prefixes[ar.logoPrefix - 1], b, b.prefixes[br.logoPrefix - 1]):
    return a.sameText(ar.logo, b, br.logo)
  for offset in 0 ..< length:
    if a.logoAt(ar, offset) != b.logoAt(br, offset):
      return false
  true

func hashChain(chainId: uint64): uint64 {.inline.} =
  ## splitmix64: ids differing only in high bits still spread over slots.
  result = (chainId xor (chainId shr 30)) * 0xBF58476D1CE4E5B9'u64
  result = (result xor (result shr 27)) * 0x94D049BB133111EB'u64
  result = result xor (result shr 31)

proc rehashChains(store: var TokenStore) =
  store.chainSlots = newSeq[uint32](max(16, store.chainSlots.len * 2))
  let mask = uint64(store.chainSlots.len - 1)
  for index, chainId in store.chainIds:
    var slot = hashChain(chainId) and mask
    while store.chainSlots[slot] != 0:
      slot = (slot + 1) and mask
    store.chainSlots[slot] = uint32(index + 1)

proc chainIndex(store: var TokenStore, chainId: uint64): uint32 =
  doAssert not store.frozenValue
  if store.chainSlots.len < 2 * (store.chainIds.len + 1):
    store.rehashChains()
  let mask = uint64(store.chainSlots.len - 1)
  var slot = hashChain(chainId) and mask
  while store.chainSlots[slot] != 0:
    let index = store.chainSlots[slot] - 1
    if store.chainIds[index] == chainId:
      return index
    slot = (slot + 1) and mask
  store.chainIds.add chainId
  store.chainSlots[slot] = uint32(store.chainIds.len)
  uint32(store.chainIds.high)

func hexValue(ch: char): int =
  case ch
  of '0'..'9': ord(ch) - ord('0')
  of 'a'..'f': ord(ch) - ord('a') + 10
  of 'A'..'F': ord(ch) - ord('A') + 10
  else: -1

func parseAddress*(text: openArray[char], address: var Address): bool =
  ## Match SDK IsHexAddress: optional any-case 0x prefix; exactly 20 bytes.
  let start =
    if text.len == 42 and text[0] == '0' and text[1] in {'x', 'X'}: 2
    else: 0
  if text.len - start != 40:
    return false
  for index in 0 ..< 20:
    let
      high = hexValue(text[start + 2 * index])
      low = hexValue(text[start + 2 * index + 1])
    if high < 0 or low < 0:
      return false
    address[index] = byte(high * 16 + low)
  true

func addressText*(address: Address): string =
  ## Lowercase 0x-prefixed hex, the normalized form of list addresses.
  result = newStringUninit(42)
  result[0] = '0'
  result[1] = 'x'
  let output = cast[ptr UncheckedArray[array[2, char]]](addr result[2])
  for index, value in address:
    output[index] = HexPairs[value]

proc rehashRecords(store: var TokenStore) =
  store.recordSlots = newSeq[uint32](max(1024, store.recordSlots.len * 2))
  let mask = uint64(store.recordSlots.len - 1)
  for index, record in store.records:
    var slot = hashRecord(record) and mask
    while store.recordSlots[slot] != 0:
      slot = (slot + 1) and mask
    store.recordSlots[slot] = uint32(index + 1)

proc addRecord(store: var TokenStore, record: TokenRecord): uint32 =
  ## Returns the index of an identical record, adding it if new.
  doAssert not store.frozenValue
  if store.recordSlots.len < 2 * (store.records.len + 1):
    store.rehashRecords()
  let mask = uint64(store.recordSlots.len - 1)
  var slot = hashRecord(record) and mask
  while store.recordSlots[slot] != 0:
    let index = store.recordSlots[slot] - 1
    if store.records[index] == record:
      return index
    slot = (slot + 1) and mask
  doAssert store.records.len < MaxRecords, "token store full"
  store.records.add record
  store.recordSlots[slot] = uint32(store.records.len)
  uint32(store.records.high)

proc addToken*(
    store: var TokenStore, chainId: uint64, address: openArray[char],
    decimals: uint64, name, symbol, logoUri, crossChainId: openArray[char],
    custom = false
): uint32 =
  ## Adds one row; an invalid address or decimals is kept as a flag so that
  ## filtering can still report it in row order.
  var record = TokenRecord(chain: store.chainIndex(chainId))
  if not parseAddress(address, record.address):
    record.flags.incl BadAddress
  if decimals > 255:
    record.flags.incl BadDecimals
  else:
    record.decimals = uint8(decimals)
  if custom:
    record.flags.incl CustomToken
  record.symbol = store.intern(symbol)
  record.name = store.intern(name)
  (record.logoPrefix, record.logo) = store.internLogo(logoUri)
  record.crossChainId = store.intern(crossChainId)
  store.addRecord(record)

proc copyText(store: var TokenStore, source: TokenStore, id: TextId): TextId =
  let (first, last) = source.span(id)
  store.intern(source.bytes.toOpenArray(first, last - 1))

proc copyLogo(
    store: var TokenStore, source: TokenStore, record: TokenRecord
): (uint8, TextId) =
  if record.logoPrefix == 0:
    let (first, last) = source.span(record.logo)
    return store.internLogo(source.bytes.toOpenArray(first, last - 1))
  let (first, last) = source.span(source.prefixes[record.logoPrefix - 1])
  let entry = store.prefixEntry(source.bytes.toOpenArray(first, last - 1))
  if entry < 0:
    return (0'u8, store.intern(source.logo(record)))
  (uint8(entry + 1), store.copyText(source, record.logo))

proc copyRecord*(store: var TokenStore, source: TokenStore, index: uint32): uint32 =
  ## Re-interns one record of another store into this one.
  let original = source.records[index]
  var record = original
  record.chain = store.chainIndex(source.chainIds[original.chain])
  record.symbol = store.copyText(source, original.symbol)
  record.name = store.copyText(source, original.name)
  record.crossChainId = store.copyText(source, original.crossChainId)
  (record.logoPrefix, record.logo) = store.copyLogo(source, original)
  store.addRecord(record)

proc trim[T](values: var seq[T]) =
  if values.capacity > values.len:
    var exact = newSeq[T](values.len)
    if values.len > 0:
      copyMem(addr exact[0], addr values[0], values.len * sizeof(T))
    values = move(exact)

proc freeze*(store: var TokenStore) =
  ## Drops the build tables and spare capacity; the store becomes read-only.
  store.textSlots = @[]
  store.recordSlots = @[]
  store.chainSlots = @[]
  store.bytes.trim()
  store.ends.trim()
  store.records.trim()
  store.chainIds.trim()
  store.prefixes.trim()
  store.frozenValue = true

func sameToken*(a: TokenStore, ai: uint32, b: TokenStore, bi: uint32): bool =
  ## Content equality of records from possibly different stores.
  let
    ar = a.records[ai]
    br = b.records[bi]
  a.chainIds[ar.chain] == b.chainIds[br.chain] and ar.address == br.address and
    ar.decimals == br.decimals and ar.flags == br.flags and
    a.sameText(ar.symbol, b, br.symbol) and a.sameText(ar.name, b, br.name) and
    a.sameText(ar.crossChainId, b, br.crossChainId) and a.sameLogo(ar, b, br)

func rowFailure*(
    record: TokenRecord, chainEnabled: bool, sourceId: string
): TklError =
  ## Why a parsed row cannot be published, in SDK check order.
  if BadAddress in record.flags:
    tklError(ValidationFailed, "BadAddress", sourceId)
  elif not chainEnabled:
    tklError(UnsupportedChain, "UnsupportedChain", sourceId)
  elif BadDecimals in record.flags:
    tklError(ValidationFailed, "DecimalsTooLarge", sourceId)
  else: tklError(Ok, "", sourceId)

func token*(store: TokenStore, index: uint32): Token =
  ## Materializes one record for callers that need a `Token` value.
  let record = store.records[index]
  Token(chainId: store.chainIds[record.chain],
    address: addressText(record.address),
    crossChainId: store.text(record.crossChainId), decimals: record.decimals,
    name: store.text(record.name), symbol: store.text(record.symbol),
    logoUri: store.logo(record), custom: CustomToken in record.flags)

func cmp*(a, b: Identity): int =
  if a.chainId != b.chainId:
    return (if a.chainId < b.chainId: -1 else: 1)
  for index in 0 ..< 20:
    if a.address[index] != b.address[index]:
      return (if a.address[index] < b.address[index]: -1 else: 1)
  0
