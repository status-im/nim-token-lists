{.push raises: [], gcsafe.}

import ./common
export types, errors

proc parseStandard*(
    data: string, chains: openArray[uint64], sourceId = "",
    limits = DefaultParseLimits
): Result[ParsedList, TklError] =
  let wire = ?decodeDocument(data, WireList, limits, sourceId)
  var parsed = initParsed(wire, sourceId)
  for index, raw in wire.tokens:
    let row = ?decodeDocument(string(raw), StandardRow, limits, sourceId)
    parsed.appendRow(row, index, chains)
  ok(parsed)
