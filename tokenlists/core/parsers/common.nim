{.push raises: [], gcsafe.}

import std/[algorithm, sets]
import ../[types, errors, keys, jsoncodec]
export types, errors, jsoncodec

type
  WireTags = distinct JsonString

  WireList* = object
    name*: string
    timestamp*: string
    version*: Version
    tags*: WireTags
    logoURI*: string
    keywords*: seq[string]
    tokens*: seq[JsonString]

  StandardRow* = object
    chainId*: uint64
    address*: string
    name*: string
    symbol*: string
    decimals*: uint64
    logoURI*: string

  Contract* = object
    chainId*: uint64
    address*: string

  Contracts* = distinct seq[Contract]

  StatusRow* = object
    crossChainId*: string
    name*: string
    symbol*: string
    decimals*: uint64
    logoURI*: string
    contracts*: Contracts

  SourceRow* = object
    token*: StandardRow
    row*: int
    crossChainId*: string

  ParsedSource* = object
    list*: TokenList
    rows*: seq[SourceRow]

proc readValue*(
    reader: var JsonReader, value: var WireTags
) {.raises: [IOError, SerializationError].} =
  if reader.tokKind notin {JsonValueKind.Object, JsonValueKind.Null}:
    reader.raiseUnexpectedValue("TagsObjectRequired")
  value = WireTags(reader.parseAsString())

proc readValue*(
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

func initParsed*(wire: WireList, sourceId: string): ParsedList =
  ParsedList(list: TokenList(
    id: sourceId, name: wire.name, timestamp: wire.timestamp,
    version: wire.version, tags: JsonString(wire.tags), logoUri: wire.logoURI,
    keywords: wire.keywords,
  ))

proc appendRow*(
    parsed: var ParsedList, row: StandardRow, index: int,
    chains: openArray[uint64], crossChainId = ""
) =
  let address = normalizeAddress(row.address)
  let failure =
    if address.isErr: tklError(ValidationFailed, "BadAddress", parsed.list.id)
    elif row.chainId notin chains:
      tklError(UnsupportedChain, "UnsupportedChain", parsed.list.id)
    elif row.decimals > 255:
      tklError(ValidationFailed, "DecimalsTooLarge", parsed.list.id)
    else: tklError(Ok, "", parsed.list.id)
  if failure.code != Ok:
    parsed.diagnostics.add RowDiagnostic(
      error: failure, row: index, chainId: row.chainId)
    return
  parsed.list.tokens.add Token(
    chainId: row.chainId, address: address.get, name: row.name,
    symbol: row.symbol, decimals: uint8(row.decimals), logoUri: row.logoURI,
    crossChainId: crossChainId,
  )

proc filterSource*(source: ParsedSource, chains: openArray[uint64]): ParsedList =
  var parsed = ParsedList(list: source.list)
  for row in source.rows:
    parsed.appendRow(row.token, row.row, chains, row.crossChainId)
  parsed
