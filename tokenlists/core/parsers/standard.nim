{.push raises: [], gcsafe.}

import ./stream
export types, errors, common

proc decodeStandardSource*(
    store: var TokenStore, data: openArray[char], sourceId: string,
    limits: ParseLimits
): Result[ParsedSource, TklError] =
  ## Adds the rows to `store`; the returned source holds their indices.
  parseList(store, data, StandardFormat, sourceId, limits)

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
