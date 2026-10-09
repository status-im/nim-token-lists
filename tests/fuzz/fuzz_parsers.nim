{.push raises: [], gcsafe.}

import tokenlists/core/[keys, validators]
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
    maxArrayItems: 512, maxObjectMembers: 256, maxStringBytes: 8192)
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
  0
