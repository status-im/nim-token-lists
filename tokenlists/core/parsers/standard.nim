{.push raises: [], gcsafe.}

import ./common
export types, errors

proc decodeStandardSource*(
    store: var TokenStore, data: openArray[char], sourceId: string,
    limits: ParseLimits
): Result[ParsedSource, TklError] =
  ## Adds the rows to `store`; the returned source holds their indices.
  let wire = ?decodeDocument(data, WireList, limits, sourceId)
  var source = ParsedSource(list: initParsed(wire, sourceId).list)
  source.rows = newSeqOfCap[uint32](wire.tokens.len)
  for raw in wire.tokens:
    let row = ?decodeDocument(string(raw), StandardRow, limits, sourceId)
    source.rows.add store.addToken(row.chainId, row.address, row.decimals,
      row.name, row.symbol, row.logoURI, "")
  ok(source)

proc decodeStandardSource*(
    data: openArray[char], sourceId = "", limits = DefaultParseLimits
): Result[ParsedSource, TklError] =
  ownStore(decodeStandardSource(target, data, sourceId, limits))

proc parseStandard*(
    data: openArray[char], chains: openArray[uint64], sourceId = "",
    limits = DefaultParseLimits
): Result[ParsedList, TklError] =
  let source = ?decodeStandardSource(data, sourceId, limits)
  ok(filterSource(source, chains))
