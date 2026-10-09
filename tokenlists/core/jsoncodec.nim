{.push raises: [], gcsafe.}

import std/[sets, unicode]
import json_serialization
import json_serialization/pkg/results as jsonResults except readValue
import faststreams/inputs
import ./[types, errors, keys]
export json_serialization
export jsonResults except readValue

proc readValue*[T](
    reader: var JsonReader, value: var Opt[T]
) {.raises: [IOError, SerializationError].} =
  mixin readValue
  if reader.tokKind == JsonValueKind.Null:
    reset value
    reader.parseNull()
  else:
    # The pinned optional reader uses the value-returning overload, whose
    # partial result can leak on error. Own it until decoding succeeds.
    var decoded: T
    reader.readValue(decoded)
    value.ok(move(decoded))

proc checkUniqueFields(
    reader: var JsonReader
) {.raises: [IOError, SerializationError].} =
  # The typed dependency reader appends duplicate array fields. Reject all
  # duplicate object keys, including unknown extensions, before materializing.
  case reader.tokKind
  of JsonValueKind.Object:
    var seen: HashSet[string]
    reader.parseObjectWithoutSkip(key):
      if key in seen:
        reader.raiseUnexpectedValue("DuplicateObjectField")
      seen.incl key
      checkUniqueFields(reader)
  of JsonValueKind.Array:
    reader.parseArray:
      checkUniqueFields(reader)
  else:
    discard reader.readValue(JsonVoid)

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

proc readValue*(
    reader: var JsonReader, value: var int64
) {.raises: [IOError, SerializationError].} =
  # Versions are signed SDK metadata, but still require integer JSON syntax.
  let number = reader.parseNumber(string)
  if number.fraction.len > 0 or number.exponent.len > 0:
    reader.raiseUnexpectedValue("SignedIntegerRequired")
  let parsed = parseChainId(number.integer)
  if parsed.isErr:
    reader.raiseUnexpectedValue("IntegerOverflow")
  let
    magnitude = parsed.get
    negative = number.sign == JsonSign.Neg
    maximum = uint64(high(int64)) + uint64(ord(negative))
  if magnitude > maximum:
    reader.raiseUnexpectedValue("IntegerOverflow")
  value =
    if negative and magnitude == uint64(high(int64)) + 1: low(int64)
    elif negative: -int64(magnitude)
    else: int64(magnitude)

proc decodeDocument*[T](
    data: openArray[char], kind: typedesc[T],
    limits: ParseLimits = DefaultParseLimits, sourceId = "", requireFields = false
): Result[T, TklError] =
  ## Reads `data` in place for the duration of the call; nothing retains it.
  ## Exceptions are adapted at this boundary.
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
    # memoryInput would copy the whole document into stream pages.
    let stream = unsafeMemoryInput(data.toOpenArrayByte(0, data.high))
    var flags = {JsonReaderFlag.allowUnknownFields}
    if requireFields:
      flags.incl JsonReaderFlag.requireAllFields
    var reader = JsonReader[DefaultFlavor].init(stream, flags, conf)
    checkUniqueFields(reader)
    while stream.readable:
      if char(stream.read()) notin {' ', '\t', '\r', '\n'}:
        return err(tklError(InvalidArgument, "TrailingData", sourceId))
    var typedReader = JsonReader[DefaultFlavor].init(
      unsafeMemoryInput(data.toOpenArrayByte(0, data.high)), flags, conf)
    # Keep ownership here so partially populated fields are destroyed if reading
    # raises. The value-returning overload can leak its partial result on error.
    var decoded: T
    typedReader.readValue(decoded)
    ok(move(decoded))
  except SerializationError as e:
    err(tklError(InvalidArgument, e.msg, sourceId))
  except IOError as e:
    err(tklError(Internal, e.msg, sourceId))
