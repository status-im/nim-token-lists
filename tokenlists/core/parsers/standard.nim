{.push raises: [], gcsafe.}

import ./common
export types, errors

proc decodeStandardSource*(
    data: openArray[char], sourceId = "",
    limits = DefaultParseLimits
): Result[ParsedSource, TklError] =
  let wire = ?decodeDocument(data, WireList, limits, sourceId)
  var source = ParsedSource(list: initParsed(wire, sourceId).list)
  for index, raw in wire.tokens:
    let row = ?decodeDocument(string(raw), StandardRow, limits, sourceId)
    source.rows.add SourceRow(token: row, row: index)
  ok(source)

proc parseStandard*(
    data: openArray[char], chains: openArray[uint64], sourceId = "",
    limits = DefaultParseLimits
): Result[ParsedList, TklError] =
  let source = ?decodeStandardSource(data, sourceId, limits)
  ok(filterSource(source, chains))
