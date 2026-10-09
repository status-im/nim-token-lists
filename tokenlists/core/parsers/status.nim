{.push raises: [], gcsafe.}

import ./common
export types, errors

proc decodeStatusSource*(
    store: var TokenStore, data: openArray[char], sourceId: string,
    limits: ParseLimits
): Result[ParsedSource, TklError] =
  ## Adds the rows to `store`; the returned source holds their indices.
  let wire = ?decodeDocument(data, WireList, limits, sourceId)
  var source = ParsedSource(list: initParsed(wire, sourceId).list)
  for index, raw in wire.tokens:
    let row = ?decodeDocument(string(raw), StatusRow, limits, sourceId)
    for contract in seq[Contract](row.contracts):
      source.rows.add store.addToken(contract.chainId, contract.address,
        row.decimals, row.name, row.symbol, row.logoURI, row.crossChainId)
      source.rowNumbers.add uint32(index)
  ok(source)

proc decodeStatusSource*(
    data: openArray[char], sourceId = "", limits = DefaultParseLimits
): Result[ParsedSource, TklError] =
  ownStore(decodeStatusSource(target, data, sourceId, limits))

proc parseStatus*(
    data: openArray[char], chains: openArray[uint64], sourceId = "",
    limits = DefaultParseLimits
): Result[ParsedList, TklError] =
  let source = ?decodeStatusSource(data, sourceId, limits)
  ok(filterSource(source, chains))
