{.push raises: [], gcsafe.}

import std/[tables, sets]
import ./[types, keys]
export types

type Snapshot* = object
  revisionValue: uint64
  tokens: seq[Token]
  lists: seq[TokenList]
  diagnostics: seq[TklError]
  byKey: Table[string, int]
  aliases: Table[string, string]
  skipped: HashSet[string]

func revision*(snapshot: Snapshot): uint64 = snapshot.revisionValue

func initSnapshot*(
    lists: sink seq[TokenList], policy: CataloguePolicy,
    diagnostics: sink seq[TklError], revision: uint64
): Result[Snapshot, TklError] =
  var snapshot = Snapshot(revisionValue: revision,
    lists: lists, diagnostics: diagnostics)
  for key in policy.skippedKeys:
    let identity = ?parseKey(key)
    snapshot.skipped.incl ($identity.chainId & "-" & identity.address)
  for alias in policy.nativeAliases:
    let key = ?tokenKey(alias.chainId, alias.address)
    snapshot.aliases[key] = $alias.chainId & "-" & NativeAddress
  for list in snapshot.lists:
    for token in list.tokens:
      let key = ?tokenKey(token.chainId, token.address)
      if key notin snapshot.skipped and key notin snapshot.byKey:
        snapshot.byKey[key] = snapshot.tokens.len
        snapshot.tokens.add token
  ok(snapshot)

func getByKey*(snapshot: Snapshot, key: string): Result[Token, TklError] =
  let identity = ?parseKey(key)
  let canonical = $identity.chainId & "-" & identity.address
  if canonical in snapshot.skipped:
    return err(tklError(NotFound, "SkippedToken"))
  let resolved = snapshot.aliases.getOrDefault(canonical, canonical)
  let index = snapshot.byKey.getOrDefault(resolved, -1)
  if index < 0:
    return err(tklError(NotFound, "TokenNotFound"))
  ok(snapshot.tokens[index])

func getByChainAddress*(
    snapshot: Snapshot, chainId: uint64, address: string
): Result[Token, TklError] =
  snapshot.getByKey(?tokenKey(chainId, address))

func getNative*(snapshot: Snapshot, chainId: uint64): Result[Token, TklError] =
  snapshot.getByChainAddress(chainId, NativeAddress)

func page[T](
    items: seq[T], revision: uint64, offset, limit: int
): Result[Page[T], TklError] =
  if offset < 0 or limit < 0:
    return err(tklError(InvalidArgument, "NegativePagination"))
  var output = Page[T](revision: revision, total: items.len)
  if offset < items.len:
    let count = if limit == 0: items.len - offset
                else: min(limit, items.len - offset)
    output.items = items[offset ..< offset + count]
  ok(output)

func getAll*(
    snapshot: Snapshot, offset = 0, limit = 0
): Result[Page[Token], TklError] =
  page(snapshot.tokens, snapshot.revisionValue, offset, limit)

func getByChains*(
    snapshot: Snapshot, chains: openArray[uint64], offset = 0, limit = 0
): Result[Page[Token], TklError] =
  var tokens: seq[Token]
  for token in snapshot.tokens:
    if token.chainId in chains:
      tokens.add token
  page(tokens, snapshot.revisionValue, offset, limit)

func getByKeys*(
    snapshot: Snapshot, keys: openArray[string]
): Result[Page[Token], TklError] =
  var tokens: seq[Token]
  for key in keys:
    let token = snapshot.getByKey(key)
    if token.isOk:
      tokens.add token.get
    elif token.error.code != NotFound:
      return err(token.error)
  ok(Page[Token](revision: snapshot.revisionValue,
    total: tokens.len, items: tokens))

func getList*(snapshot: Snapshot, id: string): Result[TokenList, TklError] =
  for list in snapshot.lists:
    if list.id == id:
      return ok(list)
  err(tklError(NotFound, "ListNotFound", id))

func getLists*(snapshot: Snapshot): Page[TokenList] =
  Page[TokenList](revision: snapshot.revisionValue,
    total: snapshot.lists.len, items: snapshot.lists)

func getDiagnostics*(snapshot: Snapshot): Page[TklError] =
  Page[TklError](revision: snapshot.revisionValue,
    total: snapshot.diagnostics.len, items: snapshot.diagnostics)
