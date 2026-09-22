{.push raises: [], gcsafe.}

import std/[algorithm, tables, sets]
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

type SnapshotDiff* = object
  chains*: seq[uint64]
  lists*: seq[string]

func lookupIndex(snapshot: Snapshot, key: string): int =
  if key in snapshot.skipped:
    return -1
  snapshot.byKey.getOrDefault(snapshot.aliases.getOrDefault(key, key), -1)

func lookupDiffers(before, after: Snapshot, key: string): bool =
  let
    oldIndex = before.lookupIndex(key)
    newIndex = after.lookupIndex(key)
  if oldIndex < 0 or newIndex < 0:
    return oldIndex != newIndex
  before.tokens[oldIndex] != after.tokens[newIndex]

func diffSnapshots*(before, after: Snapshot): SnapshotDiff =
  ## Borrow both immutable values. Compare indexes and raw lists in place;
  ## no query pages, TokenLists or per-chain token arrays are materialized.
  var chains: HashSet[uint64]
  for key, index in before.byKey:
    let other = after.byKey.getOrDefault(key, -1)
    if other < 0 or before.tokens[index] != after.tokens[other]:
      chains.incl before.tokens[index].chainId
  var priorPositions = newSeq[int](after.tokens.len)
  for key, index in after.byKey:
    let other = before.byKey.getOrDefault(key, -1)
    if other < 0:
      chains.incl after.tokens[index].chainId
    else:
      priorPositions[index] = other + 1
  # A key/value-only comparison would miss changes to paginated chain order.
  var lastPosition: Table[uint64, int]
  for index, token in after.tokens:
    let previous = priorPositions[index]
    if previous > 0:
      if previous < lastPosition.getOrDefault(token.chainId):
        chains.incl token.chainId
      lastPosition[token.chainId] = previous
  for key in before.aliases.keys:
    if lookupDiffers(before, after, key):
      chains.incl parseKey(key).get.chainId
  for key in after.aliases.keys:
    if key notin before.aliases and lookupDiffers(before, after, key):
      chains.incl parseKey(key).get.chainId
  var oldLists, newLists: Table[string, int]
  for index, list in before.lists:
    oldLists[list.id] = index
  for index, list in after.lists:
    newLists[list.id] = index
  var changedLists: seq[string]
  for id, index in oldLists:
    let other = newLists.getOrDefault(id, -1)
    if other < 0 or before.lists[index] != after.lists[other]:
      changedLists.add id
  for id in newLists.keys:
    if id notin oldLists:
      changedLists.add id
  var changedChains: seq[uint64]
  for chain in chains:
    changedChains.add chain
  changedChains.sort()
  changedLists.sort()
  SnapshotDiff(chains: changedChains, lists: changedLists)
