{.push raises: [], gcsafe.}

import std/[algorithm, sets]
import ../[types, errors, keys, jsoncodec, store]
export types, errors, jsoncodec, store

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

  ParsedSource* = object
    ## A parsed list: its metadata, and its rows as records of its own store,
    ## or of the caller's store when parsed into one. Row strings are interned
    ## as they are decoded; none outlive the parse.
    list*: TokenList
    store*: TokenStore
    rows*: seq[uint32]
    rowNumbers*: seq[uint32]
      ## Document row of each entry when they differ (Status contracts).

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

template ownStore*(decode: untyped): untyped =
  ## Runs `decode` (which names `target`) into a store the source then owns.
  var target {.inject.} = initTokenStore()
  var source = ?decode
  target.freeze()
  source.store = move(target)
  ok(source)

proc filterSource*(source: ParsedSource, chains: openArray[uint64]): ParsedList =
  ## Materializes the rows visible on `chains`, for callers of the parsers.
  var parsed = ParsedList(list: source.list)
  for entry, index in source.rows:
    let record = source.store.record(index)
    let chainId = source.store.chainId(record)
    let failure = rowFailure(record, chainId in chains, source.list.id)
    if failure.code != Ok:
      let row = if source.rowNumbers.len > 0: int(source.rowNumbers[entry])
        else: entry
      parsed.diagnostics.add RowDiagnostic(error: failure, row: row,
        chainId: chainId)
    else:
      parsed.list.tokens.add source.store.token(index)
  parsed
