{.push raises: [], gcsafe.}

## Single-pass parser for Standard and Status token lists. It reads a borrowed
## body once, applies the JSON, limit and schema rules of the typed decoder and
## validator it replaced (same results and error details), and writes rows
## straight into a token store. tests/oracle keeps that decoder for
## differential tests and fuzzing.

import std/[algorithm, math, strutils, unicode, uri]
from json_serialization/lexer import JsonErrorKind
import ../[types, errors, keys, store, hashing]
import ./common
export common

type
  Mode = enum
    ## Lenient is the permissive list decoder; Strict the refresh validator.
    Lenient, Strict

  Fault = object
    ## The first typed-decoder error of one mode; its message may be empty.
    found: bool
    message: string

  Faults = array[Mode, Fault]

  Kind = enum
    StringValue, NumberValue, ObjectValue, ArrayValue, BoolValue, NullValue

  Text = object
    ## Raw content of a string in the body, or its decoded copy in `text`.
    start, len: int
    decoded: bool

  Number = object
    negative, decimal: bool
      ## `decimal`: a fraction or an exponent is present.
    first, last: int
      ## Integer digits in the body.

  KeySlot = object
    start, len: int
    hash: uint32
    decoded: bool

  Contract = object
    chainId: uint64
    address: Text

  Scanner = object
    data: ptr UncheckedArray[char]
    len, pos, depth: int
    limits: ParseLimits
    failed, badUtf8: bool
    failure: string
    ws, adjust: int
      ## Whitespace skipped and the growth of escaped strings when re-encoded:
      ## the size of a value as the old decoder re-serialized it.
    keys: seq[KeySlot]
      ## Keys of the open objects, for duplicate detection.
    keyBytes: seq[char]
    tables: seq[seq[uint32]]
      ## Per depth: key index of objects with many members.
    text: seq[char]
      ## Decoded escaped strings of the current row.
    contracts: seq[Contract]
    contractSlots: seq[uint32]
      ## Contract index + 1 by chain id once a row has many contracts.

  Field = enum
    OtherField, NameField, TimestampField, VersionField, TagsField, LogoField,
    KeywordsField, TokensField, ChainIdField, AddressField, SymbolField,
    DecimalsField, CrossChainIdField, ContractsField, MajorField, MinorField,
    PatchField

  Row = object
    faults: Faults
    seen: set[Field]
    chainId, decimals: uint64
    address, name, symbol, logo, crossChainId: Text

  Document = object
    faults, rowFaults: Faults
    seen: set[Field]
    list: TokenList
    logoNull, tagsSet: bool
    rowIndex, rowCount: int
      ## `rowCount`: rows the tokens expand to, contracts included.

const
  ManyKeys = 16
  Whitespace = {' ', '\t', '\r', '\n'}
  FieldNames: array[Field, string] = ["", "name", "timestamp", "version", "tags",
    "logoURI", "keywords", "tokens", "chainId", "address", "symbol", "decimals",
    "crossChainId", "contracts", "major", "minor", "patch"]
  ListFields = {NameField, TimestampField, VersionField, TagsField, LogoField,
    KeywordsField, TokensField}
  StandardFields = {ChainIdField, AddressField, NameField, SymbolField,
    DecimalsField, LogoField}
  StatusFields = {CrossChainIdField, NameField, SymbolField, DecimalsField,
    LogoField, ContractsField}
  VersionFields = {MajorField, MinorField, PatchField}
  RequiredList = {NameField, TimestampField, VersionField, TokensField}
  RequiredStandard = {ChainIdField, AddressField, NameField, SymbolField,
    DecimalsField}
  RequiredStatus = {NameField, SymbolField, DecimalsField, ContractsField}

template message(kind: JsonErrorKind): string = $kind

func validUri*(value: string, source = false): bool =
  if value.len == 0:
    return false
  for i, ch in value:
    if ch <= ' ' or ch == '\x7f':
      return false
    if ch == '%' and (i + 2 >= value.len or
        value[i + 1] notin HexDigits or value[i + 2] notin HexDigits):
      return false
  try:
    let parsed = parseUri(value)
    if parsed.scheme.len == 0 or parsed.scheme[0] notin Letters:
      return false
    for ch in parsed.scheme:
      if ch notin Letters + Digits + {'+', '-', '.'}:
        return false
    if source:
      if parsed.scheme notin ["http", "https"] or parsed.hostname.len == 0:
        return false
    if parsed.scheme in ["http", "https"] and parsed.hostname.len == 0:
      return false
    true
  except ValueError:
    false

func validTimestamp*(value: string): bool =
  # RFC3339 calendar/time checks without consulting a clock or time zone.
  if value.len < 20 or value[4] != '-' or value[7] != '-' or
      value[10] notin {'T', 't'} or value[13] != ':' or value[16] != ':':
    return false
  for i in [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18]:
    if value[i] notin Digits:
      return false
  let
    year = parseChainId(value[0..3]).get
    month = int(parseChainId(value[5..6]).get)
    day = int(parseChainId(value[8..9]).get)
    hour = parseChainId(value[11..12]).get
    minute = parseChainId(value[14..15]).get
    second = parseChainId(value[17..18]).get
    leap = year mod 4 == 0 and (year mod 100 != 0 or year mod 400 == 0)
    days = [31, (if leap: 29 else: 28), 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
  if month < 1 or month > 12 or day < 1 or day > days[month - 1] or
      hour > 23 or minute > 59 or second > 59:
    return false
  var index = 19
  if value[index] == '.':
    inc index
    let start = index
    while index < value.len and value[index] in Digits:
      inc index
    if index == start:
      return false
  if index == value.high and value[index] in {'Z', 'z'}:
    return true
  if value.len - index != 6 or value[index] notin {'+', '-'} or value[index + 3] != ':':
    return false
  for i in [index + 1, index + 2, index + 4, index + 5]:
    if value[i] notin Digits:
      return false
  parseChainId(value[index + 1 .. index + 2]).get <= 23 and
    parseChainId(value[index + 4 .. index + 5]).get <= 59

func fault(faults: var Faults, modes: set[Mode], message: string) =
  for mode in modes:
    if not faults[mode].found:
      faults[mode] = Fault(found: true, message: message)

proc fail(s: var Scanner, kind: JsonErrorKind): bool =
  s.failed = true
  s.failure = message(kind)
  false

proc fail(s: var Scanner, detail: string): bool =
  s.failed = true
  s.failure = detail
  false

proc skipWs(s: var Scanner): bool =
  while s.pos < s.len:
    case s.data[s.pos]
    of ' ', '\t', '\r', '\n':
      inc s.pos
      inc s.ws
    of '/':
      return s.fail(errCommentNotAllowed)
    else:
      break
  true

proc kindAt(s: var Scanner, kind: var Kind): bool =
  ## Skips whitespace and classifies the value that starts there.
  if not s.skipWs():
    return false
  if s.pos >= s.len:
    return s.fail(errUnknownChar)
  case s.data[s.pos]
  of '"': kind = StringValue
  of '+', '-', '.', '0'..'9': kind = NumberValue
  of '{': kind = ObjectValue
  of '[': kind = ArrayValue
  of 't', 'f': kind = BoolValue
  of 'n': kind = NullValue
  else: return s.fail(errUnknownChar)
  true

func hexValue(ch: char): int =
  case ch
  of '0'..'9': ord(ch) - ord('0')
  of 'a'..'f': ord(ch) - ord('a') + 10
  of 'A'..'F': ord(ch) - ord('A') + 10
  else: -1

proc hexRune(s: var Scanner, rune: var int): bool =
  rune = 0
  for _ in 0 .. 3:
    if s.pos >= s.len:
      return s.fail(errUnexpectedEof)
    let digit = hexValue(s.data[s.pos])
    inc s.pos
    if digit < 0:
      return s.fail(errHexCharExpected)
    rune = (rune shl 4) or digit
  true

func runeLen(rune: int): int =
  if rune < 0x80: 1
  elif rune < 0x800: 2
  elif rune < 0x10000: 3
  else: 4

func utf8Len(data: ptr UncheckedArray[char], pos, len: int): int =
  ## Length of the sequence at `pos` as std/unicode.validateUtf8 checks it,
  ## or -1.
  let lead = uint(data[pos])
  template continued(offset: int): bool =
    pos + offset < len and uint(data[pos + offset]) shr 6 == 0b10
  if lead shr 5 == 0b110:
    if lead < 0xc2 or not continued(1): -1 else: 2
  elif lead shr 4 == 0b1110:
    if continued(1) and continued(2): 3 else: -1
  elif lead shr 3 == 0b11110:
    if continued(1) and continued(2) and continued(3): 4 else: -1
  else: -1

func escapedLen(ch: char): int =
  ## Bytes std/json.escapeJson writes for one decoded byte.
  case ch
  of '\L', '\b', '\f', '\t', '\r', '"', '\\': 2
  of '\v', '\0'..'\7', '\14'..'\31': 6
  else: 1

iterator decodedBytes(
    data: ptr UncheckedArray[char], first, last: int
): char =
  ## Decoded bytes of validated string content `first ..< last`.
  var pos = first
  var rune = 0
  template hex4(): int =
    var value = 0
    for _ in 0 .. 3:
      value = (value shl 4) or hexValue(data[pos])
      inc pos
    value
  while pos < last:
    let ch = data[pos]
    inc pos
    if ch != '\\':
      yield ch
      continue
    let escape = data[pos]
    inc pos
    case escape
    of 'b': yield '\b'
    of 'f': yield '\f'
    of 'n': yield '\n'
    of 'r': yield '\r'
    of 't': yield '\t'
    of 'v': yield '\v'
    of '0': yield '\0'
    of 'u':
      rune = hex4()
      if (rune and 0xfc00) == 0xd800:
        pos += 2
        let low = hex4()
        if (low and 0xfc00) == 0xdc00:
          rune = 0x10000 + (((rune - 0xd800) shl 10) or (low - 0xdc00))
      let n = runeLen(rune)
      if n == 1:
        yield char(rune)
      elif n == 2:
        yield char(0xc0 or (rune shr 6))
        yield char(0x80 or (rune and 0x3f))
      elif n == 3:
        yield char(0xe0 or (rune shr 12))
        yield char(0x80 or ((rune shr 6) and 0x3f))
        yield char(0x80 or (rune and 0x3f))
      else:
        yield char(0xf0 or (rune shr 18))
        yield char(0x80 or ((rune shr 12) and 0x3f))
        yield char(0x80 or ((rune shr 6) and 0x3f))
        yield char(0x80 or (rune and 0x3f))
    else: yield escape

proc decodeInto(
    data: ptr UncheckedArray[char], first, last: int, output: var seq[char]
) =
  for ch in decodedBytes(data, first, last):
    output.add ch

proc decoded(s: var Scanner, raw: Text, output: var seq[char]): Text =
  ## Appends the decoded content of an escaped string to `output`.
  let start = output.len
  decodeInto(s.data, raw.start, raw.start + raw.len, output)
  Text(start: start, len: output.len - start, decoded: true)

proc scanString(s: var Scanner, text: var Text, escaped: var bool): bool =
  ## At the opening quote. `text` spans the raw content.
  inc s.pos
  let start = s.pos
  let limit = s.limits.maxStringBytes
  var length = 0
  escaped = false
  while true:
    if s.pos >= s.len:
      return s.fail(errUnexpectedEof)
    let ch = s.data[s.pos]
    inc s.pos
    case ch
    of '"':
      break
    of '\\':
      escaped = true
      if s.pos >= s.len:
        return s.fail(errUnexpectedEof)
      let escape = s.data[s.pos]
      inc s.pos
      case escape
      of '\\', '"', '\'', '/', 'b', 'f', 'n', 'r', 't', 'v', '0':
        if length + 1 > limit:
          return s.fail(errStringLengthLimit)
        inc length
      of 'x':
        return s.fail(errEscapeHex)
      of 'u':
        var rune: int
        if not s.hexRune(rune):
          return false
        if (rune and 0xfc00) == 0xd800:
          for expected in ['\\', 'u']:
            if s.pos >= s.len:
              return s.fail(errUnexpectedEof)
            let next = s.data[s.pos]
            inc s.pos
            if next != expected:
              return s.fail(errOrphanSurrogate)
          var low: int
          if not s.hexRune(low):
            return false
          if (low and 0xfc00) == 0xdc00:
            rune = 0x10000 + (((rune - 0xd800) shl 10) or (low - 0xdc00))
        if length + runeLen(rune) > limit:
          return s.fail(errStringLengthLimit)
        length += runeLen(rune)
      else:
        return s.fail(errRelaxedEscape)
    of '\x00'..'\x09', '\x0B', '\x0C', '\x0E'..'\x1F':
      return s.fail(errEscapeControlChar)
    of '\r', '\n':
      return s.fail(errQuoteExpected)
    of '\x80'..'\xFF':
      let n = utf8Len(s.data, s.pos - 1, s.len)
      if n < 0:
        s.badUtf8 = true
        return s.fail("InvalidUtf8")
      if length + n > limit:
        return s.fail(errStringLengthLimit)
      length += n
      s.pos += n - 1
    else:
      if length + 1 > limit:
        return s.fail(errStringLengthLimit)
      inc length
  text = Text(start: start, len: s.pos - 1 - start)
  if escaped:
    # Re-encoding expands or shrinks only escaped strings.
    var encoded = 0
    for ch in decodedBytes(s.data, text.start, text.start + text.len):
      encoded += escapedLen(ch)
    s.adjust += encoded - text.len
  true

proc scanString(s: var Scanner, text: var Text): bool =
  var escaped: bool
  s.scanString(text, escaped)

proc digits(s: var Scanner, limit: int, integer: bool,
    error: JsonErrorKind, count: var int): bool =
  ## At a digit; mirrors the lexer's digit-limit and leading-zero rules.
  let first = s.data[s.pos]
  inc s.pos
  count = 1
  if s.pos >= s.len:
    return true
  var ch = s.data[s.pos]
  if first == '0' and ch in Digits and integer:
    return s.fail(errLeadingZero)
  var seen = 2
  while ch in Digits:
    if seen > limit:
      return s.fail(error)
    inc s.pos
    count = seen
    if s.pos >= s.len:
      return true
    ch = s.data[s.pos]
    inc seen
  true

proc scanNumber(s: var Scanner, number: var Number): bool =
  number = Number()
  case s.data[s.pos]
  of '-':
    number.negative = true
    inc s.pos
  of '+':
    inc s.pos
    return s.fail(errIntPosSign)
  else: discard
  if s.pos >= s.len:
    return s.fail(errNumberExpected)
  var ch = s.data[s.pos]
  var fraction = false
  if ch == '.':
    return s.fail(errLeadingFraction)
  elif ch in Digits:
    number.first = s.pos
    var count: int
    if not s.digits(20, true, errIntDigitLimit, count):
      return false
    number.last = s.pos
    if s.pos >= s.len:
      return true
    ch = s.data[s.pos]
    if ch == '.':
      fraction = true
      inc s.pos
      if s.pos >= s.len:
        return s.fail(errEmptyFraction)
      ch = s.data[s.pos]
  else:
    return s.fail(errNumberExpected)
  var fractionDigits = 0
  if ch in Digits:
    if not s.digits(128, false, errFracDigitLimit, fractionDigits):
      return false
  if fraction and fractionDigits == 0:
    return s.fail(errEmptyFraction)
  number.decimal = fraction
  if s.pos >= s.len:
    return true
  ch = s.data[s.pos]
  if ch in {'e', 'E'}:
    number.decimal = true
    inc s.pos
    if s.pos >= s.len:
      return s.fail(errNumberExpected)
    if s.data[s.pos] in {'+', '-'}:
      inc s.pos
    if s.pos >= s.len or s.data[s.pos] notin Digits:
      return s.fail(errNumberExpected)
    var count: int
    if not s.digits(32, false, errExpDigitLimit, count):
      return false
  true

proc scanLiteral(s: var Scanner, word: string, error: JsonErrorKind): bool =
  inc s.pos
  for index in 1 ..< word.len:
    # The lexer reads NUL past the end, which never matches.
    let ch = if s.pos < s.len: s.data[s.pos] else: '\0'
    if s.pos < s.len:
      inc s.pos
    if ch != word[index]:
      return s.fail(error)
  true

proc skipValue(s: var Scanner, kind: Kind): bool

func keyHash*(text: openArray[char], seed = hashSeed): uint32 {.inline.} =
  uint32(hashBytes(text, seed))

template keyText(s: Scanner, slot: KeySlot): openArray[char] =
  if slot.decoded: s.keyBytes.toOpenArray(slot.start, slot.start + slot.len - 1)
  else: toOpenArray(s.data, slot.start, slot.start + slot.len - 1)

func sameKey(s: Scanner, a, b: KeySlot): bool =
  if a.hash != b.hash or a.len != b.len:
    return false
  for offset in 0 ..< a.len:
    let x = if a.decoded: s.keyBytes[a.start + offset] else: s.data[a.start + offset]
    let y = if b.decoded: s.keyBytes[b.start + offset] else: s.data[b.start + offset]
    if x != y:
      return false
  true

proc indexKeys(s: var Scanner, frame: int) =
  let level = s.depth
  if s.tables.len <= level:
    s.tables.setLen(level + 1)
  var size = 64
  while size < 4 * (s.keys.len - frame):
    size *= 2
  s.tables[level].setLen(0)
  s.tables[level].setLen(size)
  let mask = uint32(size - 1)
  for index in frame ..< s.keys.len:
    var slot = s.keys[index].hash and mask
    while s.tables[level][slot] != 0:
      countProbe()
      slot = (slot + 1) and mask
    s.tables[level][slot] = uint32(index + 1)

proc addKey(s: var Scanner, raw: Text, escaped: bool, frame: int): bool =
  ## Records a key of the object at `frame`; rejects duplicates.
  var slot = KeySlot(start: raw.start, len: raw.len)
  if escaped:
    let start = s.keyBytes.len
    decodeInto(s.data, raw.start, raw.start + raw.len, s.keyBytes)
    slot = KeySlot(start: start, len: s.keyBytes.len - start, decoded: true)
  slot.hash = keyHash(s.keyText(slot))
  let count = s.keys.len - frame
  if count < ManyKeys:
    for index in frame ..< s.keys.len:
      if s.sameKey(s.keys[index], slot):
        return s.fail("DuplicateObjectField")
    s.keys.add slot
    if s.keys.len - frame == ManyKeys:
      s.indexKeys(frame)
    return true
  let level = s.depth
  let mask = uint32(s.tables[level].len - 1)
  var position = slot.hash and mask
  while s.tables[level][position] != 0:
    countProbe()
    if s.sameKey(s.keys[s.tables[level][position] - 1], slot):
      return s.fail("DuplicateObjectField")
    position = (position + 1) and mask
  s.keys.add slot
  if 2 * (s.keys.len - frame) > s.tables[level].len:
    s.indexKeys(frame)
  else:
    s.tables[level][position] = uint32(s.keys.len)
  true

template members(s: var Scanner, slot, body: untyped) {.dirty.} =
  ## Iterates an object's members at '{' (the lexer's object loop). `slot` is
  ## the member's key; `body` reads its value and may `return false`.
  if s.depth + 1 > s.limits.maxDepth:
    return s.fail(errNestedDepthLimit)
  inc s.depth
  inc s.pos
  let frame = s.keys.len
  let frameBytes = s.keyBytes.len
  var
    count = 0
    afterComma = false
  while true:
    if not s.skipWs():
      return false
    if s.pos >= s.len:
      return s.fail(errCurlyRiExpected)
    case s.data[s.pos]
    of '}':
      inc s.pos
      break
    of ',':
      if afterComma:
        return s.fail(errValueExpected)
      if count == 0:
        return s.fail(errMissingFirstElement)
      afterComma = true
      inc s.pos
      if not s.skipWs():
        return false
      if s.pos < s.len and s.data[s.pos] == '}':
        return s.fail(errTrailingComma)
    of '"':
      if count >= 1 and not afterComma:
        return s.fail(errCommaExpected)
      afterComma = false
      inc count
      if count > s.limits.maxObjectMembers:
        return s.fail(errObjectMembersLimit)
      var
        raw: Text
        escaped: bool
      if not s.scanString(raw, escaped):
        return false
      if not s.skipWs():
        return false
      if s.pos >= s.len or s.data[s.pos] != ':':
        return s.fail(errColonExpected)
      inc s.pos
      if not s.addKey(raw, escaped, frame):
        return false
      let slot {.used.} = s.keys[^1]
      body
    else:
      return s.fail(errStringExpected)
  s.keys.setLen(frame)
  s.keyBytes.setLen(frameBytes)
  dec s.depth

template elements(s: var Scanner, body: untyped) {.dirty.} =
  ## Iterates an array's elements at '[' (the lexer's array loop).
  if s.depth + 1 > s.limits.maxDepth:
    return s.fail(errNestedDepthLimit)
  inc s.depth
  inc s.pos
  var
    count = 0
    afterComma = false
  while true:
    if not s.skipWs():
      return false
    if s.pos >= s.len:
      return s.fail(errBracketRiExpected)
    case s.data[s.pos]
    of ']':
      inc s.pos
      break
    of ',':
      if afterComma:
        return s.fail(errValueExpected)
      if count == 0:
        return s.fail(errMissingFirstElement)
      afterComma = true
      inc s.pos
      if not s.skipWs():
        return false
      if s.pos < s.len and s.data[s.pos] == ']':
        return s.fail(errTrailingComma)
    else:
      if count >= 1 and not afterComma:
        return s.fail(errCommaExpected)
      if count + 1 > s.limits.maxArrayItems:
        return s.fail(errArrayElementsLimit)
      afterComma = false
      body
      inc count
  dec s.depth

proc skipObject(s: var Scanner): bool =
  s.members(slot):
    var kind: Kind
    if not s.kindAt(kind) or not s.skipValue(kind):
      return false
  true

proc skipArray(s: var Scanner): bool =
  s.elements:
    var kind: Kind
    if not s.kindAt(kind) or not s.skipValue(kind):
      return false
  true

proc skipValue(s: var Scanner, kind: Kind): bool =
  ## Validates one value at its first byte.
  case kind
  of StringValue:
    var text: Text
    s.scanString(text)
  of NumberValue:
    var number: Number
    s.scanNumber(number)
  of ObjectValue: s.skipObject()
  of ArrayValue: s.skipArray()
  of BoolValue:
    if s.data[s.pos] == 't': s.scanLiteral("true", errInvalidBool)
    else: s.scanLiteral("false", errInvalidBool)
  of NullValue: s.scanLiteral("null", errInvalidNull)

func fieldOf(s: Scanner, slot: KeySlot, fields: set[Field]): Field =
  for field in fields:
    let name = FieldNames[field]
    if name.len == slot.len:
      block compare:
        for offset in 0 ..< name.len:
          let ch = if slot.decoded: s.keyBytes[slot.start + offset]
            else: s.data[slot.start + offset]
          if ch != name[offset]:
            break compare
        return field
  OtherField

func unsignedValue(s: Scanner, number: Number, value: var uint64): string =
  ## The SDK integer contract of chain ids and decimals; "" when valid.
  if number.negative or number.decimal:
    return "UnsignedIntegerRequired"
  value = 0
  for pos in number.first ..< number.last:
    let digit = uint64(ord(s.data[pos]) - ord('0'))
    if value > (high(uint64) - digit) div 10:
      return "IntegerOverflow"
    value = value * 10 + digit
  ""

func signedValue(s: Scanner, number: Number, value: var int64): string =
  if number.decimal:
    return "SignedIntegerRequired"
  var magnitude: uint64
  var negative = number
  negative.negative = false
  let failure = s.unsignedValue(negative, magnitude)
  if failure.len > 0:
    return failure
  let maximum = uint64(high(int64)) + uint64(ord(number.negative))
  if magnitude > maximum:
    return "IntegerOverflow"
  value =
    if number.negative and magnitude == uint64(high(int64)) + 1: low(int64)
    elif number.negative: -int64(magnitude)
    else: int64(magnitude)
  ""

proc str(s: Scanner, text: Text): string =
  if text.len > 0:
    result = newString(text.len)
    if text.decoded:
      copyMem(addr result[0], unsafeAddr s.text[text.start], text.len)
    else:
      copyMem(addr result[0], unsafeAddr s.data[text.start], text.len)

func base(s: Scanner, text: Text): ptr UncheckedArray[char] {.inline.} =
  if text.decoded and text.len > 0:
    cast[ptr UncheckedArray[char]](unsafeAddr s.text[0])
  else: s.data

template view(s: Scanner, text: Text): openArray[char] =
  toOpenArray(s.base(text), text.start, text.start + text.len - 1)

proc stringValue(
    s: var Scanner, kind: Kind, faults: var Faults, modes, nullable: set[Mode],
    text: var Text
): bool =
  ## A string field; `nullable` modes accept null as absent.
  if kind == StringValue:
    var
      raw: Text
      escaped: bool
    if not s.scanString(raw, escaped):
      return false
    text = if escaped: s.decoded(raw, s.text) else: raw
    return true
  if kind != NullValue or modes - nullable != {}:
    faults.fault(if kind == NullValue: modes - nullable else: modes,
      message(errStringExpected))
  s.skipValue(kind)

proc numberValue(
    s: var Scanner, kind: Kind, faults: var Faults, modes: set[Mode],
    value: var uint64
): bool =
  if kind != NumberValue:
    faults.fault(modes, message(errNumberExpected))
    return s.skipValue(kind)
  var number: Number
  if not s.scanNumber(number):
    return false
  let failure = s.unsignedValue(number, value)
  if failure.len > 0:
    faults.fault(modes, failure)
  true

proc versionValue(
    s: var Scanner, kind: Kind, faults: var Faults, modes: set[Mode],
    version: var Version
): bool =
  if kind != ObjectValue:
    faults.fault(modes, message(errCurlyLeExpected))
    return s.skipValue(kind)
  var seen: set[Field]
  s.members(slot):
    let field = s.fieldOf(slot, VersionFields)
    var valueKind: Kind
    if not s.kindAt(valueKind):
      return false
    if field == OtherField:
      if not s.skipValue(valueKind):
        return false
    elif valueKind != NumberValue:
      faults.fault(modes, message(errNumberExpected))
      if not s.skipValue(valueKind):
        return false
    else:
      var number: Number
      if not s.scanNumber(number):
        return false
      var value: int64
      let failure = s.signedValue(number, value)
      if failure.len > 0:
        faults.fault(modes, failure)
      case field
      of MajorField: version.major = value
      of MinorField: version.minor = value
      else: version.patch = value
    seen.incl field
  if VersionFields - seen != {}:
    faults.fault(modes * {Strict}, "")
  true

proc normalized(s: Scanner, first, last: int): string =
  ## A validated value as the old decoder re-serialized it: compact, with
  ## strings re-escaped by std/json.
  var pos = first
  while pos < last:
    let ch = s.data[pos]
    if ch in Whitespace:
      inc pos
    elif ch != '"':
      result.add ch
      inc pos
    else:
      inc pos
      let start = pos
      while s.data[pos] != '"':
        pos += (if s.data[pos] == '\\': 2 else: 1)
      let last = pos
      inc pos
      result.add '"'
      for byte in decodedBytes(s.data, start, last):
        case byte
        of '\L': result.add "\\n"
        of '\b': result.add "\\b"
        of '\f': result.add "\\f"
        of '\t': result.add "\\t"
        of '\v': result.add "\\u000b"
        of '\r': result.add "\\r"
        of '"': result.add "\\\""
        of '\0'..'\7': result.add "\\u000" & $ord(byte)
        of '\14'..'\31': result.add "\\u00" & toHex(ord(byte), 2)
        of '\\': result.add "\\\\"
        else: result.add byte
      result.add '"'

proc seenContract(s: Scanner, chainId: uint64): bool =
  ## Whether an earlier contract of the row has `chainId`.
  if s.contracts.len < ManyKeys:
    for contract in s.contracts:
      countProbe()
      if contract.chainId == chainId:
        return true
    return false
  let mask = uint64(s.contractSlots.len - 1)
  var slot = hashValue(chainId, hashSeed) and mask
  while s.contractSlots[slot] != 0:
    countProbe()
    if s.contracts[s.contractSlots[slot] - 1].chainId == chainId:
      return true
    slot = (slot + 1) and mask
  false

proc addContract(s: var Scanner, contract: Contract) =
  s.contracts.add contract
  if s.contracts.len < ManyKeys:
    return
  var first = s.contracts.high
  if s.contracts.len == ManyKeys or 2 * s.contracts.len > s.contractSlots.len:
    s.contractSlots.setLen(0)
    s.contractSlots.setLen(nextPowerOfTwo(4 * s.contracts.len))
    first = 0
  let mask = uint64(s.contractSlots.len - 1)
  for index in first ..< s.contracts.len:
    var slot = hashValue(s.contracts[index].chainId, hashSeed) and mask
    while s.contractSlots[slot] != 0:
      countProbe()
      slot = (slot + 1) and mask
    s.contractSlots[slot] = uint32(index + 1)

func byChainId(a, b: Contract): int =
  countProbe()
  cmp(a.chainId, b.chainId)

proc contractsValue(
    s: var Scanner, kind: Kind, faults: var Faults, modes: set[Mode]
): bool =
  s.contracts.setLen(0)
  if kind != ObjectValue:
    faults.fault(modes, message(errCurlyLeExpected))
    return s.skipValue(kind)
  s.members(slot):
    var chainId = 0'u64
    var valid = slot.len > 0
    for offset in 0 ..< slot.len:
      let ch = if slot.decoded: s.keyBytes[slot.start + offset]
        else: s.data[slot.start + offset]
      if ch notin Digits:
        valid = false
        break
      let digit = uint64(ord(ch) - ord('0'))
      if chainId > (high(uint64) - digit) div 10:
        valid = false
        break
      chainId = chainId * 10 + digit
    if not valid:
      faults.fault(modes, "BadContractChainId")
    elif s.seenContract(chainId):
      faults.fault(modes, "DuplicateContractChainId")
    var valueKind: Kind
    if not s.kindAt(valueKind):
      return false
    var address: Text
    if not s.stringValue(valueKind, faults, modes, {}, address):
      return false
    if valid:
      s.addContract Contract(chainId: chainId, address: address)
  # Stable order by chain id, like the decoder's sort.
  if s.contracts.len >= ManyKeys:
    s.contracts.sort(byChainId)
  else:
    for index in 1 ..< s.contracts.len:
      var position = index
      let contract = s.contracts[index]
      while position > 0 and s.contracts[position - 1].chainId > contract.chainId:
        countProbe()
        s.contracts[position] = s.contracts[position - 1]
        dec position
      s.contracts[position] = contract
  true

proc rowValue(
    s: var Scanner, format: ListFormat, modes: set[Mode], row: var Row
): bool =
  ## One element of `tokens`, as the decoder re-read it from its
  ## re-serialized text.
  var kind: Kind
  if not s.kindAt(kind):
    return false
  let
    start = s.pos
    ws = s.ws
    adjust = s.adjust
  s.contracts.setLen(0)
  if kind != ObjectValue:
    row.faults.fault(modes, message(errCurlyLeExpected))
    if not s.skipValue(kind):
      return false
  else:
    let known = if format == StandardFormat: StandardFields else: StatusFields
    s.members(slot):
      let field = s.fieldOf(slot, known)
      var valueKind: Kind
      if not s.kindAt(valueKind):
        return false
      let ok = case field
        of ChainIdField:
          s.numberValue(valueKind, row.faults, modes, row.chainId)
        of DecimalsField:
          s.numberValue(valueKind, row.faults, modes, row.decimals)
        of AddressField:
          s.stringValue(valueKind, row.faults, modes, {}, row.address)
        of NameField:
          s.stringValue(valueKind, row.faults, modes, {}, row.name)
        of SymbolField:
          s.stringValue(valueKind, row.faults, modes, {}, row.symbol)
        of LogoField:
          s.stringValue(valueKind, row.faults, modes, {Strict}, row.logo)
        of CrossChainIdField:
          s.stringValue(valueKind, row.faults, modes, {Strict}, row.crossChainId)
        of ContractsField:
          s.contractsValue(valueKind, row.faults, modes)
        else:
          s.skipValue(valueKind)
      if not ok:
        return false
      row.seen.incl field
    let required = if format == StandardFormat: RequiredStandard else: RequiredStatus
    if required - row.seen != {}:
      row.faults.fault(modes * {Strict}, "")
  # The decoder re-read each row from its re-serialized text, which can
  # outgrow the document when escapes expand.
  if s.pos - start - (s.ws - ws) + (s.adjust - adjust) > s.limits.maxBytes:
    for mode in modes:
      row.faults[mode] = Fault(found: true, message: "TooLarge")
  true

proc tokensValue(
    s: var Scanner, kind: Kind, format: ListFormat, modes: set[Mode],
    document: var Document, store: ptr TokenStore, source: var ParsedSource
): bool =
  if kind != ArrayValue:
    document.faults.fault(modes, message(errBracketLeExpected))
    return s.skipValue(kind)
  s.elements:
    s.text.setLen(0)
    var row = Row()
    if not s.rowValue(format, modes, row):
      return false
    document.rowCount += (if format == StandardFormat: 1 else: s.contracts.len)
    if document.rowCount > s.limits.maxRows:
      return s.fail("TooLarge")
    for mode in modes:
      if row.faults[mode].found and not document.rowFaults[mode].found:
        document.rowFaults[mode] = row.faults[mode]
    if not store.isNil and not document.faults[Lenient].found and
        not document.rowFaults[Lenient].found:
      if format == StandardFormat:
        let added = store[].addToken(row.chainId, s.view(row.address),
          row.decimals, s.view(row.name), s.view(row.symbol), s.view(row.logo), "")
        if added.isNone:
          return s.fail("TooLarge")
        source.rows.add added.get
      else:
        for contract in s.contracts:
          let added = store[].addToken(contract.chainId,
            s.view(contract.address), row.decimals, s.view(row.name),
            s.view(row.symbol), s.view(row.logo), s.view(row.crossChainId))
          if added.isNone:
            return s.fail("TooLarge")
          source.rows.add added.get
          source.rowNumbers.add uint32(document.rowIndex)
    inc document.rowIndex
  true

proc keywordsValue(
    s: var Scanner, kind: Kind, faults: var Faults, modes: set[Mode],
    keywords: var seq[string]
): bool =
  if kind == NullValue and Strict in modes:
    faults.fault(modes - {Strict}, message(errBracketLeExpected))
    return s.skipValue(kind)
  if kind != ArrayValue:
    faults.fault(modes, message(errBracketLeExpected))
    return s.skipValue(kind)
  s.elements:
    var valueKind: Kind
    if not s.kindAt(valueKind):
      return false
    s.text.setLen(0)
    var text: Text
    if not s.stringValue(valueKind, faults, modes, {}, text):
      return false
    if valueKind == StringValue:
      keywords.add s.str(text)
  true

proc documentValue(
    s: var Scanner, format: ListFormat, modes: set[Mode], document: var Document,
    store: ptr TokenStore, source: var ParsedSource
): bool =
  var kind: Kind
  if not s.kindAt(kind):
    return false
  if kind != ObjectValue:
    document.faults.fault(modes, message(errCurlyLeExpected))
    return s.skipValue(kind)
  s.members(slot):
    let field = s.fieldOf(slot, ListFields)
    var valueKind: Kind
    if not s.kindAt(valueKind):
      return false
    s.text.setLen(0)
    var text: Text
    let start = s.pos
    let ok = case field
      of NameField:
        s.stringValue(valueKind, document.faults, modes, {}, text)
      of TimestampField:
        s.stringValue(valueKind, document.faults, modes, {}, text)
      of LogoField:
        s.stringValue(valueKind, document.faults, modes, {Strict}, text)
      of VersionField:
        s.versionValue(valueKind, document.faults, modes, document.list.version)
      of TagsField:
        if valueKind notin {ObjectValue, NullValue}:
          document.faults.fault(modes * {Lenient}, "TagsObjectRequired")
        s.skipValue(valueKind)
      of KeywordsField:
        s.keywordsValue(valueKind, document.faults, modes, document.list.keywords)
      of TokensField:
        s.tokensValue(valueKind, format, modes, document, store, source)
      else:
        s.skipValue(valueKind)
    if not ok:
      return false
    case field
    of NameField: document.list.name = s.str(text)
    of TimestampField: document.list.timestamp = s.str(text)
    of LogoField:
      document.list.logoUri = s.str(text)
      document.logoNull = valueKind == NullValue
    of TagsField:
      document.list.tags = JsonString(s.normalized(start, s.pos))
      document.tagsSet = valueKind != NullValue
    else: discard
    document.seen.incl field
  if RequiredList - document.seen != {}:
    document.faults.fault(modes * {Strict}, "")
  true

proc strictFailure(
    s: Scanner, document: Document, sourceId: string
): Result[void, TklError] =
  ## The refresh validator's verdict on a well-formed document.
  template invalid(detail: string): untyped =
    return err(tklError(InvalidContent, detail, sourceId))
  if document.faults[Strict].found:
    invalid(document.faults[Strict].message)
  if not validTimestamp(document.list.timestamp):
    invalid("BadListMetadata")
  if document.list.logoUri.len > 0 and not validUri(document.list.logoUri):
    invalid("BadLogoUri")
  if document.tagsSet:
    let tags = string(document.list.tags)
    if tags.len > s.limits.maxBytes:
      return err(tklError(InvalidArgument, "TooLarge", sourceId))
    if tags[0] != '{':
      invalid("BadTags")
  if document.rowFaults[Strict].found:
    invalid(document.rowFaults[Strict].message)
  ok()

proc scanList(
    body: openArray[char], format: ListFormat, sourceId: string,
    limits: ParseLimits, modes: set[Mode], store: ptr TokenStore
): Result[ParsedSource, TklError] =
  doAssert format in {StandardFormat, StatusFormat}
  if limits.maxBytes <= 0 or limits.maxDepth <= 0 or
      limits.maxArrayItems <= 0 or limits.maxObjectMembers <= 0 or
      limits.maxStringBytes <= 0 or limits.maxRows <= 0:
    return err(tklError(InvalidArgument, "InvalidLimits", sourceId))
  if body.len > limits.maxBytes:
    return err(tklError(InvalidArgument, "TooLarge", sourceId))
  var s = Scanner(len: body.len, limits: limits)
  if body.len > 0:
    s.data = cast[ptr UncheckedArray[char]](unsafeAddr body[0])
  var document = Document()
  var source = ParsedSource()
  var ok = s.documentValue(format, modes, document, store, source)
  if ok:
    while s.pos < s.len:
      if s.data[s.pos] notin Whitespace:
        ok = s.fail("TrailingData")
        break
      inc s.pos
  if not ok:
    # Bytes after the failure are unread; invalid UTF-8 anywhere wins.
    if not s.badUtf8 and validateUtf8(body) != -1:
      s.failure = "InvalidUtf8"
    return err(tklError(InvalidArgument, s.failure, sourceId))
  if Strict in modes:
    ?s.strictFailure(document, sourceId)
  if Lenient in modes:
    if document.faults[Lenient].found:
      return err(tklError(InvalidArgument, document.faults[Lenient].message, sourceId))
    if document.rowFaults[Lenient].found:
      return err(tklError(InvalidArgument, document.rowFaults[Lenient].message,
        sourceId))
  document.list.id = sourceId
  source.list = move(document.list)
  if source.rows.len < source.rows.capacity:
    source.rows = source.rows[0 .. ^1]
  if source.rowNumbers.len < source.rowNumbers.capacity:
    source.rowNumbers = source.rowNumbers[0 .. ^1]
  ok(source)

proc parseList*(
    store: var TokenStore, body: openArray[char], format: ListFormat,
    sourceId: string, limits: ParseLimits, validate = false
): Result[ParsedSource, TklError] =
  ## Parses a borrowed body into `store`. With `validate`, the body must also
  ## pass the strict checks a refresh applies. A failed parse may leave
  ## unreferenced rows in `store`.
  let modes = if validate: {Lenient, Strict} else: {Lenient}
  scanList(body, format, sourceId, limits, modes, addr store)

proc validateList*(
    body: openArray[char], format: ListFormat, sourceId: string,
    limits: ParseLimits
): Result[void, TklError] =
  ## The strict checks alone: required fields and types, metadata formats.
  discard ?scanList(body, format, sourceId, limits, {Strict}, nil)
  ok()
