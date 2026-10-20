## The packed by-chains answer carries exactly get_by_chains' tokens, in its
## order, as fixed little-endian records.
import std/[os, unittest]
import ../../tokenlists/api

const Ids = ["status", "uniswap", "coingecko_ethereum", "coingecko_bsc",
  "coingecko_linea", "coingecko_optimism"]

proc fixture(name: string): string =
  readFile(currentSourcePath.parentDir / ".." / ".." / "fixtures" / "embedded" / name)

proc loaded(skipped: seq[string]): Catalogue =
  var config = CatalogueConfig(chains: @[1'u64, 10, 56, 8453, 59144],
    mainListId: "status", policy: CataloguePolicy(
      skippedKeys: skipped,
      nativeAliases: @[TokenIdentity(chainId: 1,
        address: "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee")],
      nativeTokens: @[Token(chainId: 10, address: NativeAddress, symbol: "ETH",
        name: "Ether", decimals: 18)]))
  var bodies: seq[SourceBody]
  for id in Ids:
    config.initialLists.add ListContent(id: id,
      format: if id == "status": StatusFormat else: StandardFormat)
    bodies.add SourceBody(id: id, origin: BundledBody, body: fixture(id & ".json"))
  initCatalogue(config, bodies, customs = @[
    Token(chainId: 1, address: "0x000000000000000000000000000000000000dead",
      symbol: "C", name: "Custom", decimals: 6),
    Token(chainId: 59144, address: "0x000000000000000000000000000000000000beef",
      symbol: "D", name: "Other", decimals: 0)]).get

func le(data: openArray[byte], at, size: int): uint64 =
  for index in countdown(size - 1, 0):
    result = (result shl 8) or uint64(data[at + index])

type Packed = object
  magic: uint32
  count: int
  revision: uint64
  tokens: seq[(uint64, string, uint8)]

func decode(data: openArray[byte]): Packed =
  result.magic = uint32(le(data, 0, 4))
  result.count = int(le(data, 4, 4))
  result.revision = le(data, 8, 8)
  for index in 0 ..< result.count:
    let at = PackedHeaderBytes + index * PackedRecordBytes
    var address = "0x"
    for offset in 0 ..< 20:
      address.add "0123456789abcdef"[int(data[at + 8 + offset]) shr 4]
      address.add "0123456789abcdef"[int(data[at + 8 + offset]) and 15]
    for offset in 29 ..< 32:
      doAssert data[at + offset] == 0
    result.tokens.add (le(data, at, 8), address, data[at + 28])

func expected(snapshot: Snapshot, chains: openArray[uint64]): seq[(uint64, string, uint8)] =
  for token in snapshot.getByChains(chains).get.items:
    result.add (token.chainId, token.address, token.decimals)

proc checkParity(snapshot: Snapshot, chains: openArray[uint64]) =
  let data = snapshot.packedByChains(chains)
  check data.len == snapshot.packedLen(chains)
  let decoded = decode(data)
  check decoded.magic == PackedMagic
  check decoded.revision == snapshot.revision
  check data.len == PackedHeaderBytes + decoded.count * PackedRecordBytes
  check decoded.tokens == snapshot.expected(chains)

suite "packed by-chains query":
  test "layout is little endian with a 32-byte stride":
    check PackedMagic == 0x31504B54'u32
    check PackedHeaderBytes == 16
    check PackedRecordBytes == 32
    let catalogue = loaded(@[])
    let data = catalogue.published[].packedByChains([1'u64])
    check data[0 .. 3] == @[byte 'T', byte 'K', byte 'P', byte '1']
    let custom = decode(data).tokens.find(
      (1'u64, "0x000000000000000000000000000000000000dead", 6'u8))
    check custom >= 0
    let at = PackedHeaderBytes + custom * PackedRecordBytes
    check data[at .. at + 7] == @[1'u8, 0, 0, 0, 0, 0, 0, 0]
    check data[at + 26 .. at + 27] == @[0xde'u8, 0xad]

  test "matches get_by_chains for every chain combination":
    let all = [1'u64, 10, 56, 8453, 59144, 42161, 999]
    let catalogue = loaded(@[])
    let snapshot = catalogue.published
    for mask in 0 ..< (1 shl all.len):
      var chains: seq[uint64]
      for bit, chain in all:
        if (mask and (1 shl bit)) != 0:
          chains.add chain
      snapshot[].checkParity(chains)
    snapshot[].checkParity([10'u64, 1, 10, 1])
    check decode(snapshot[].packedByChains([])).count == 0
    check decode(snapshot[].packedByChains([999'u64])).count == 0

  test "skipped keys, aliases, natives and customs follow get_by_chains":
    let base = loaded(@[])
    let first = base.published[].getByChains([1'u64]).get.items[0]
    let skipped = $first.chainId & "-" & first.address
    let catalogue = loaded(@[skipped, "59144-0x000000000000000000000000000000000000beef"])
    let snapshot = catalogue.published
    let tokens = decode(snapshot[].packedByChains([1'u64, 10, 59144])).tokens
    check (first.chainId, first.address, first.decimals) notin tokens
    check (59144'u64, "0x000000000000000000000000000000000000beef", 0'u8) notin tokens
    check (10'u64, NativeAddress, 18'u8) in tokens
    check (1'u64, "0x000000000000000000000000000000000000dead", 6'u8) in tokens
    check (1'u64, "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", 18'u8) notin tokens
    for chains in [@[1'u64], @[10'u64, 59144], @[1'u64, 10, 56, 8453, 59144]]:
      snapshot[].checkParity(chains)

  test "writing fills exactly the measured size":
    let catalogue = loaded(@[])
    let snapshot = catalogue.published
    let size = snapshot[].packedLen([1'u64, 10])
    var data = newSeq[byte](size + 1)
    data[size] = 0xAB
    snapshot[].writePacked([1'u64, 10],
      cast[ptr UncheckedArray[byte]](addr data[0]), size)
    check data[size] == 0xAB
    check data[0 ..< size] == snapshot[].packedByChains([1'u64, 10])
