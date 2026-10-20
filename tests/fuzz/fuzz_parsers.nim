{.push raises: [], gcsafe.}

import std/strutils
import tokenlists/core/[keys, validators, jsoncodec, snapshot]
import tokenlists/core/parsers/[standard, status, registry]
import tokenlists/api

proc nimMain() {.importc: "NimMain", cdecl.}

proc initialize(argc: ptr cint, argv: ptr ptr cstring): cint
    {.exportc: "LLVMFuzzerInitialize", cdecl.} =
  nimMain()
  0

proc fuzz(data: ptr UncheckedArray[byte], size: csize_t): cint
    {.exportc: "LLVMFuzzerTestOneInput", cdecl.} =
  if size > 65536:
    return 0
  var input = newString(int(size))
  if size > 0:
    copyMem(addr input[0], data, int(size))
  let limits = ParseLimits(maxBytes: 65536, maxDepth: 32,
    maxArrayItems: 512, maxObjectMembers: 256, maxStringBytes: 8192, maxRows: 1 shl 30)
  discard parseKey(input)
  discard normalizeAddress(input)
  discard parseRegistry(input, limits = limits)
  let standard = parseStandard(input, @[1'u64, 10], limits = limits)
  let status = parseStatus(input, @[1'u64, 10], limits = limits)
  for format in ListFormat:
    discard validateDocument(input, format, limits = limits)
  for parsed in [standard, status]:
    if parsed.isOk:
      for token in parsed.get.list.tokens:
        doAssert token.chainId in [1'u64, 10]
        doAssert normalizeAddress(token.address).get == token.address
  # The compact catalogue answers every query with what the parser produced.
  let config = CatalogueConfig(chains: @[1'u64, 10], initialLists: @[
    ListContent(id: "list", format: StatusFormat)])
  let catalogue = initCatalogue(config,
    [SourceBody(id: "list", origin: BundledBody, body: input)], limits = limits)
  if catalogue.isOk:
    discard catalogue.get.getByKey(input)
    let all = catalogue.get.getAll().get.items
    var pairs: seq[TokenIdentity]
    for token in all:
      pairs.add TokenIdentity(chainId: token.chainId, address: token.address)
      doAssert catalogue.get.getByKey($token.chainId & "-" & token.address).get == token
    doAssert catalogue.get.getByChainAddresses(pairs).get.items == all
    var listed = 0
    for list in catalogue.get.getLists().items:
      listed += list.tokens.len
    doAssert listed >= all.len
    if status.isOk:
      doAssert catalogue.get.getList("list").get.tokens == status.get.list.tokens
    # Packed by-chains records against the materialized page.
    let held = catalogue.get.published
    for chains in [@[1'u64, 10], @[10'u64], @[]]:
      let packed = held[].packedByChains(chains)
      let tokens = held[].getByChains(chains).get.items
      doAssert packed.len == PackedHeaderBytes + tokens.len * PackedRecordBytes
      for index, token in tokens:
        let at = PackedHeaderBytes + index * PackedRecordBytes
        var address = "0x"
        for offset in 0 ..< 20:
          address.add toHex(packed[at + 8 + offset]).toLowerAscii
        doAssert (uint64(packed[at]) or (uint64(packed[at + 1]) shl 8)) == token.chainId
        doAssert address == token.address and packed[at + 28] == token.decimals
    # Narrow queries against the same filters over the full answers.
    var crossIds = @["", input]
    for token in all:
      if token.crossChainId.len > 0 and crossIds.len < 8:
        crossIds.add token.crossChainId
    var sharing: seq[Token]
    for token in all:
      if token.crossChainId.len > 0 and token.crossChainId in crossIds:
        sharing.add token
    doAssert held[].getByCrossChainIds(crossIds).items == sharing
    doAssert held[].packedByCrossChainIds(crossIds).len ==
      PackedHeaderBytes + sharing.len * PackedRecordBytes
    for probe in [input, if all.len > 0: all[0].symbol.toUpperAscii else: "x"]:
      for chainId in [1'u64, 10]:
        let found = held[].getBySymbolOnChain(chainId, probe)
        if probe.len == 0:
          doAssert found.isErr
          continue
        var expected: seq[Token]
        for token in held[].getByChains([chainId]).get.items:
          if cmpIgnoreCase(token.symbol, probe) == 0 or cmpIgnoreCase(token.name, probe) == 0:
            expected.add token
        doAssert found.get.items == expected
    # Direct encoding against json_serialization.
    var lists = held[].getLists()
    for list in lists.items.mitems:
      if string(list.tags).len == 0:
        list.tags = JsonString("{}")
    let actual = held[].listsOutput.json
    doAssert actual == Json.encode(lists)
    doAssert held[].allOutput().get.json == Json.encode(held[].getAll().get)
    doAssert held[].diagnosticsOutput.json == Json.encode(held[].getDiagnostics())
  0
