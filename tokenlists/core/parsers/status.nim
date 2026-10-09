{.push raises: [], gcsafe.}

import ./stream
export types, errors, common

proc decodeStatusSource*(
    store: var TokenStore, data: openArray[char], sourceId: string,
    limits: ParseLimits
): Result[ParsedSource, TklError] =
  ## Adds one row per contract to `store`; the returned source holds their
  ## indices.
  parseList(store, data, StatusFormat, sourceId, limits)

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
