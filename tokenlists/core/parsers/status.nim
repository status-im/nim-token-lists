{.push raises: [], gcsafe.}

import ./common
export types, errors

proc parseStatus*(
    data: string, chains: openArray[uint64], sourceId = "",
    limits = DefaultParseLimits
): Result[ParsedList, TklError] =
  let wire = ?decodeDocument(data, WireList, limits, sourceId)
  var parsed = initParsed(wire, sourceId)
  for index, raw in wire.tokens:
    let row = ?decodeDocument(string(raw), StatusRow, limits, sourceId)
    for contract in seq[Contract](row.contracts):
      parsed.appendRow(StandardRow(
        chainId: contract.chainId, address: contract.address,
        name: row.name, symbol: row.symbol, decimals: row.decimals,
        logoURI: row.logoURI,
      ), index, chains, row.crossChainId)
  ok(parsed)
