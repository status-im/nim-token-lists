{.push raises: [], gcsafe.}

import ../[types, errors, store]
export types, errors, store

type
  ParsedSource* = object
    ## A parsed list: its metadata, and its rows as records of its own store,
    ## or of the caller's store when parsed into one. Row strings are interned
    ## as they are decoded; none outlive the parse.
    list*: TokenList
    store*: TokenStore
    rows*: seq[uint32]
    rowNumbers*: seq[uint32]
      ## Document row of each entry when they differ (Status contracts).

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
