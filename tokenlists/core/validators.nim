{.push raises: [], gcsafe.}

import std/[sets, strutils, unicode, uri]
import ./[types, errors, keys, jsoncodec]
import ./parsers/[common, registry]
export types, errors

type
  RequiredList = object
    name: string
    timestamp: string
    version: Version
    tokens: seq[JsonString]
    logoURI: Opt[string]
    keywords: Opt[seq[string]]
    tags: Opt[JsonString]

  RequiredStandardRow = object
    chainId: uint64
    address: string
    name: string
    symbol: string
    decimals: uint64
    logoURI: Opt[string]

  RequiredStatusRow = object
    name: string
    symbol: string
    decimals: uint64
    contracts: Contracts
    crossChainId: Opt[string]
    logoURI: Opt[string]

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

func validUri(value: string, source = false): bool =
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

func validTimestamp(value: string): bool =
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

func wordText(value: string, maximum: int): bool =
  if value.len == 0 or value.len > maximum:
    return false
  for ch in value:
    if ch notin Letters + Digits + {'_', ' '}:
      return false
  true

func validTokenText(name, symbol: string, decimals: uint64): bool =
  if decimals > 255 or name.runeLen > 60 or symbol.runeLen > 20:
    return false
  for rune in symbol.runes:
    if rune.isWhiteSpace:
      return false
  for ch in name:
    if ch < ' ' or ch == '\x7f':
      return false
  true

proc strictDecode[T](
    data: string, kind: typedesc[T], limits: ParseLimits, sourceId: string
): Result[T, TklError] =
  let decoded = decodeDocument(data, T, limits, sourceId, requireFields = true)
  if decoded.isErr:
    return err(tklError(InvalidContent, decoded.error.detail, sourceId))
  decoded

proc validateDocument*(
    data: string, format: ListFormat, sourceId = "",
    limits = DefaultParseLimits
): Result[void, TklError] =
  ## Native core-field contract, not a remote/general JSON Schema interpreter.
  ## Unknown extensions remain allowed and subject to the same resource limits.
  discard ?decodeDocument(data, JsonString, limits, sourceId)
  template invalid(detail: string): untyped =
    return err(tklError(InvalidContent, detail, sourceId))

  if format == RegistryFormat:
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

  let list = ?strictDecode(data, RequiredList, limits, sourceId)
  if not wordText(list.name, 30) or not validTimestamp(list.timestamp):
    invalid("BadListMetadata")
  if list.logoURI.isSome and not validUri(list.logoURI.get):
    invalid("BadLogoUri")
  if list.keywords.isSome:
    if list.keywords.get.len > 20:
      invalid("TooManyKeywords")
    var seen: HashSet[string]
    for keyword in list.keywords.get:
      if not wordText(keyword, 20) or keyword in seen:
        invalid("BadKeyword")
      seen.incl keyword
  if list.tags.isSome:
    let tags = ?decodeDocument(string(list.tags.get), JsonString, limits, sourceId)
    if string(tags).len == 0 or string(tags)[0] != '{':
      invalid("BadTags")
  if format == StandardFormat and (list.tokens.len == 0 or list.tokens.len > 10_000):
    invalid("TokenCountOutOfRange")
  for raw in list.tokens:
    if format == StandardFormat:
      let row = ?strictDecode(string(raw), RequiredStandardRow, limits, sourceId)
      if row.chainId == 0 or normalizeAddress(row.address).isErr or
          row.address.len != 42:
        invalid("BadTokenIdentity")
      if not validTokenText(row.name, row.symbol, row.decimals):
        invalid("BadTokenFields")
      if row.logoURI.isSome and not validUri(row.logoURI.get):
        invalid("BadLogoUri")
    else:
      let row = ?strictDecode(string(raw), RequiredStatusRow, limits, sourceId)
      if not validTokenText(row.name, row.symbol, row.decimals):
        invalid("BadTokenFields")
      if row.logoURI.isSome and not validUri(row.logoURI.get):
        invalid("BadLogoUri")
      if seq[Contract](row.contracts).len == 0:
        invalid("EmptyContracts")
      for contract in seq[Contract](row.contracts):
        if contract.chainId == 0 or normalizeAddress(contract.address).isErr:
          invalid("BadTokenIdentity")
  ok()
