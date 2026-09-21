{.push raises: [], gcsafe.}

import std/unicode
import json_serialization
import json_serialization/pkg/results as jsonResults
import faststreams/inputs
import ./[types, errors, keys]
export json_serialization, jsonResults

proc readValue*(
    reader: var JsonReader, value: var uint64
) {.raises: [IOError, SerializationError].} =
  # The pinned library's parseInt ignores exponent-only notation (1e1 -> 1).
  # Token integer fields follow Go's integer JSON contract, without exponents.
  let number = reader.parseNumber(string)
  if number.sign == JsonSign.Neg or number.fraction.len > 0 or
      number.exponent.len > 0:
    reader.raiseUnexpectedValue("UnsignedIntegerRequired")
  let parsed = parseChainId(number.integer)
  if parsed.isErr:
    reader.raiseUnexpectedValue("IntegerOverflow")
  value = parsed.get

proc decodeDocument*[T](
    data: string, kind: typedesc[T],
    limits: ParseLimits = DefaultParseLimits, sourceId = "", requireFields = false
): Result[T, TklError] =
  ## Only memory input is used. Exceptions are adapted at this boundary.
  mixin readValue
  if limits.maxBytes <= 0 or limits.maxDepth <= 0 or
      limits.maxArrayItems <= 0 or limits.maxObjectMembers <= 0 or
      limits.maxStringBytes <= 0:
    return err(tklError(InvalidArgument, "InvalidLimits", sourceId))
  if data.len > limits.maxBytes:
    return err(tklError(InvalidArgument, "TooLarge", sourceId))
  if validateUtf8(data) != -1:
    return err(tklError(InvalidArgument, "InvalidUtf8", sourceId))
  let conf = JsonReaderConf(
    nestedDepthLimit: limits.maxDepth,
    arrayElementsLimit: limits.maxArrayItems,
    objectMembersLimit: limits.maxObjectMembers,
    integerDigitsLimit: 20,
    fractionDigitsLimit: 128,
    exponentDigitsLimit: 32,
    stringLengthLimit: limits.maxStringBytes,
  )
  try:
    let stream = memoryInput(data)
    var flags = {JsonReaderFlag.allowUnknownFields}
    if requireFields:
      flags.incl JsonReaderFlag.requireAllFields
    var reader = JsonReader[DefaultFlavor].init(stream, flags, conf)
    let decoded = reader.readValue(T)
    while stream.readable:
      if char(stream.read()) notin {' ', '\t', '\r', '\n'}:
        return err(tklError(InvalidArgument, "TrailingData", sourceId))
    ok(decoded)
  except SerializationError as e:
    err(tklError(InvalidArgument, e.msg, sourceId))
  except IOError as e:
    err(tklError(Internal, e.msg, sourceId))
