{.push raises: [], gcsafe.}

import std/sets
import ./[types, errors, jsoncodec]
import ./parsers/[registry, stream]
export types, errors

func resolveFormat*(
    identifier: string, fallback: ListFormat
): Result[ListFormat, TklError] =
  case identifier
  of "": ok(fallback)
  of "standard", "https://uniswap.org/tokenlist.schema.json":
    ok(StandardFormat)
  of "status": ok(StatusFormat)
  of "registry": ok(RegistryFormat)
  else: err(tklError(UnsupportedSchema, identifier))

proc validRegistry*(
    data: openArray[char], sourceId = "", limits = DefaultParseLimits
): Result[Registry, TklError] =
  ## A registry that passes the refresh checks, decoded once.
  template invalid(detail: string): untyped =
    return err(tklError(InvalidContent, detail, sourceId))
  let wire = decodeDocument(data, WireRegistry, limits, sourceId,
    requireFields = true)
  if wire.isErr:
    # Malformed JSON keeps its own error; only then is the body re-read.
    discard ?decodeDocument(data, JsonVoid, limits, sourceId)
    invalid(wire.error.detail)
  if not validTimestamp(wire.get.timestamp):
    invalid("BadTimestamp")
  var seen: HashSet[string]
  for source in wire.get.tokenLists:
    if source.id.len == 0 or source.id in seen:
      invalid("EmptyOrDuplicateSourceId")
    if not validUri(source.sourceUrl, source = true):
      invalid("BadSourceUrl")
    seen.incl source.id
  ok(toRegistry(wire.get))

proc validateDocument*(
    data: openArray[char], format: ListFormat, sourceId = "",
    limits = DefaultParseLimits
): Result[void, TklError] =
  ## Required fields and types, not a remote/general JSON Schema interpreter.
  ## Parsers filter individual rows; one unusable token must not reject a list.
  if format == RegistryFormat:
    discard ?validRegistry(data, sourceId, limits)
    return ok()
  validateList(data, format, sourceId, limits)
