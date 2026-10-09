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

proc strictDecode[T](
    data: openArray[char], kind: typedesc[T], limits: ParseLimits, sourceId: string
): Result[T, TklError] =
  let decoded = decodeDocument(data, T, limits, sourceId, requireFields = true)
  if decoded.isErr:
    return err(tklError(InvalidContent, decoded.error.detail, sourceId))
  decoded

proc validateDocument*(
    data: openArray[char], format: ListFormat, sourceId = "",
    limits = DefaultParseLimits
): Result[void, TklError] =
  ## Required fields and types, not a remote/general JSON Schema interpreter.
  ## Parsers filter individual rows; one unusable token must not reject a list.
  if format == RegistryFormat:
    # Well-formedness only: materializing the document would copy it.
    discard ?decodeDocument(data, JsonVoid, limits, sourceId)
    template invalid(detail: string): untyped =
      return err(tklError(InvalidContent, detail, sourceId))
    let registry = ?strictDecode(data, WireRegistry, limits, sourceId)
    if not validTimestamp(registry.timestamp):
      invalid("BadTimestamp")
    var seen: HashSet[string]
    for source in registry.tokenLists:
      if source.id.len == 0 or source.id in seen:
        invalid("EmptyOrDuplicateSourceId")
      if not validUri(source.sourceUrl, source = true):
        invalid("BadSourceUrl")
      seen.incl source.id
    return ok()

  validateList(data, format, sourceId, limits)
