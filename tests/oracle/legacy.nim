{.push raises: [], gcsafe.}

## The typed json_serialization list decoder and strict validator that the
## streaming parser replaced, kept as the oracle of differential tests and
## fuzzing. Production code must not import it.

import std/[algorithm, sets]
import ../../tokenlists/core/[types, errors, keys, jsoncodec, store]
import ../../tokenlists/core/parsers/[common, stream]
export types, errors, common

type
  WireTags = distinct JsonString

  WireList = object
    name: string
    timestamp: string
    version: Version
    tags: WireTags
    logoURI: string
    keywords: seq[string]
    tokens: seq[JsonString]

  StandardRow = object
    chainId: uint64
    address: string
    name: string
    symbol: string
    decimals: uint64
    logoURI: string

  Contract = object
    chainId: uint64
    address: string

  Contracts = distinct seq[Contract]

  StatusRow = object
    crossChainId: string
    name: string
    symbol: string
    decimals: uint64
    logoURI: string
    contracts: Contracts

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

proc readValue(
    reader: var JsonReader, value: var WireTags
) {.raises: [IOError, SerializationError].} =
  if reader.tokKind notin {JsonValueKind.Object, JsonValueKind.Null}:
    reader.raiseUnexpectedValue("TagsObjectRequired")
  value = WireTags(reader.parseAsString())

proc readValue(
    reader: var JsonReader, value: var Contracts
) {.raises: [IOError, SerializationError].} =
  var contracts: seq[Contract]
  var chains: HashSet[uint64]
  reader.parseObject(key):
    let parsed = parseChainId(key)
    if parsed.isErr:
      reader.raiseUnexpectedValue("BadContractChainId")
    let chainId = parsed.get
    if chainId in chains:
      reader.raiseUnexpectedValue("DuplicateContractChainId")
    chains.incl chainId
    contracts.add Contract(chainId: chainId, address: reader.readValue(string))
  contracts.sort(proc(a, b: Contract): int = cmp(a.chainId, b.chainId))
  value = Contracts(contracts)

func initList(wire: WireList, sourceId: string): TokenList =
  TokenList(id: sourceId, name: wire.name, timestamp: wire.timestamp,
    version: wire.version, tags: JsonString(wire.tags), logoUri: wire.logoURI,
    keywords: wire.keywords)

proc legacyParse*(
    store: var TokenStore, data: openArray[char], format: ListFormat,
    sourceId: string, limits: ParseLimits
): Result[ParsedSource, TklError] =
  ## The former `parseListBody`: permissive typed decode, then rows one by one.
  if data.len == 0:
    return err(tklError(InvalidContent, "EmptyListContent", sourceId))
  let wire = ?decodeDocument(data, WireList, limits, sourceId)
  var source = ParsedSource(list: initList(wire, sourceId))
  for index, raw in wire.tokens:
    if format == StandardFormat:
      let row = ?decodeDocument(string(raw), StandardRow, limits, sourceId)
      source.rows.add store.addToken(row.chainId, row.address, row.decimals,
        row.name, row.symbol, row.logoURI, "").get
    else:
      let row = ?decodeDocument(string(raw), StatusRow, limits, sourceId)
      for contract in seq[Contract](row.contracts):
        source.rows.add store.addToken(contract.chainId, contract.address,
          row.decimals, row.name, row.symbol, row.logoURI, row.crossChainId).get
        source.rowNumbers.add uint32(index)
  ok(source)

proc strictDecode[T](
    data: openArray[char], kind: typedesc[T], limits: ParseLimits, sourceId: string
): Result[T, TklError] =
  let decoded = decodeDocument(data, T, limits, sourceId, requireFields = true)
  if decoded.isErr:
    return err(tklError(InvalidContent, decoded.error.detail, sourceId))
  decoded

proc legacyValidate*(
    data: openArray[char], format: ListFormat, sourceId = "",
    limits = DefaultParseLimits
): Result[void, TklError] =
  ## The former `validateDocument` for list formats.
  doAssert format != RegistryFormat
  discard ?decodeDocument(data, JsonVoid, limits, sourceId)
  template invalid(detail: string): untyped =
    return err(tklError(InvalidContent, detail, sourceId))
  let list = ?strictDecode(data, RequiredList, limits, sourceId)
  if not validTimestamp(list.timestamp):
    invalid("BadListMetadata")
  if list.logoURI.isSome and list.logoURI.get.len > 0 and
      not validUri(list.logoURI.get):
    invalid("BadLogoUri")
  if list.tags.isSome:
    let tags = ?decodeDocument(string(list.tags.get), JsonString, limits, sourceId)
    if string(tags).len == 0 or string(tags)[0] != '{':
      invalid("BadTags")
  for raw in list.tokens:
    if format == StandardFormat:
      discard ?strictDecode(string(raw), RequiredStandardRow, limits, sourceId)
    else:
      discard ?strictDecode(string(raw), RequiredStatusRow, limits, sourceId)
  ok()

proc legacyRefreshParse*(
    store: var TokenStore, data: openArray[char], format: ListFormat,
    sourceId: string, limits: ParseLimits
): Result[ParsedSource, TklError] =
  ## What a refresh did with a fetched body: validate, then parse.
  ?legacyValidate(data, format, sourceId, limits)
  legacyParse(store, data, format, sourceId, limits)
