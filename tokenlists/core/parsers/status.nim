{.push raises: [], gcsafe.}

import ./common
export types, errors

proc decodeStatusSource*(
    data: openArray[char], sourceId = "",
    limits = DefaultParseLimits
): Result[ParsedSource, TklError] =
  let wire = ?decodeDocument(data, WireList, limits, sourceId)
  var source = ParsedSource(list: initParsed(wire, sourceId).list)
  for index, raw in wire.tokens:
    let row = ?decodeDocument(string(raw), StatusRow, limits, sourceId)
    for contract in seq[Contract](row.contracts):
      source.rows.add SourceRow(token: StandardRow(
        chainId: contract.chainId, address: contract.address,
        name: row.name, symbol: row.symbol, decimals: row.decimals,
        logoURI: row.logoURI,
      ), row: index, crossChainId: row.crossChainId)
  ok(source)

proc parseStatus*(
    data: openArray[char], chains: openArray[uint64], sourceId = "",
    limits = DefaultParseLimits
): Result[ParsedList, TklError] =
  let source = ?decodeStatusSource(data, sourceId, limits)
  ok(filterSource(source, chains))
