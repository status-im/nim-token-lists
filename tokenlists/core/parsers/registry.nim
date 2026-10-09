{.push raises: [], gcsafe.}

import ../[types, errors, jsoncodec]
export types, errors

type
  WireSource* = object
    id*: string
    sourceUrl*: string
    schema*: Opt[string]

  WireRegistry* = object
    timestamp*: string
    version*: Version
    tokenLists*: seq[WireSource]

proc parseRegistry*(
    data: openArray[char], sourceId = "", limits = DefaultParseLimits
): Result[Registry, TklError] =
  let wire = ?decodeDocument(data, WireRegistry, limits, sourceId)
  var registry = Registry(timestamp: wire.timestamp, version: wire.version)
  for source in wire.tokenLists:
    registry.tokenLists.add ListSource(
      id: source.id, sourceUrl: source.sourceUrl,
      schema: source.schema.get(""),
    )
  ok(registry)
