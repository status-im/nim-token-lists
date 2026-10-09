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

func toRegistry*(wire: WireRegistry): Registry =
  result = Registry(timestamp: wire.timestamp, version: wire.version)
  for source in wire.tokenLists:
    result.tokenLists.add ListSource(
      id: source.id, sourceUrl: source.sourceUrl,
      schema: source.schema.get(""),
    )

proc parseRegistry*(
    data: openArray[char], sourceId = "", limits = DefaultParseLimits
): Result[Registry, TklError] =
  ok(toRegistry(?decodeDocument(data, WireRegistry, limits, sourceId)))
