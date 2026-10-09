{.push raises: [], gcsafe.}

import std/[algorithm, tables, sets]
import ./[types, store]
export types, store

type
  TokenRef = distinct uint32
    ## A record of the shared store, or with `ExtraRef` set, of the
    ## snapshot's own small store of native and custom tokens.

  ListView = object
    meta: TokenList
      ## List metadata; `tokens` stays empty.
    tokens: seq[TokenRef]

  Snapshot* = object
    revisionValue: uint64
    base: StoreRef
    extra: TokenStore
    lists: seq[ListView]
    tokens: seq[TokenRef]
      ## Unique visible tokens: first occurrence of each key, in list order.
    sorted: seq[uint32]
      ## Positions in `tokens` ordered by identity, for binary search.
    diagnostics: seq[TklError]
    aliases: seq[(Identity, Identity)]
    skipped: seq[Identity]

type SnapshotRef* = ref Snapshot
  ## A published snapshot, shared and never mutated. Copying the ref is not
  ## thread-safe: share it across threads only behind a lock.

const ExtraRef = 0x8000_0000'u32

func `==`(a, b: TokenRef): bool {.borrow.}

func revision*(snapshot: Snapshot): uint64 = snapshot.revisionValue

proc share*(snapshot: sink Snapshot): SnapshotRef =
  result = SnapshotRef()
  result[] = snapshot

func detached*(snapshot: Snapshot): Snapshot =
  ## A copy that shares no reference with `snapshot`, so readers holding a
  ## shared lock can take one concurrently: copying the store ref would race
  ## on its reference count.
  result = Snapshot(revisionValue: snapshot.revisionValue,
    extra: snapshot.extra, lists: snapshot.lists, tokens: snapshot.tokens,
    sorted: snapshot.sorted, diagnostics: snapshot.diagnostics,
    aliases: snapshot.aliases, skipped: snapshot.skipped)
  if not snapshot.base.isNil:
    result.base = StoreRef()
    result.base[] = snapshot.base[]

func storeOf(snapshot: Snapshot, reference: TokenRef): ptr TokenStore {.inline.} =
  # A pointer, not a value: the stores are borrowed, never copied.
  if (uint32(reference) and ExtraRef) != 0: unsafeAddr snapshot.extra
  else: unsafeAddr snapshot.base[]

func indexOf(reference: TokenRef): uint32 {.inline.} =
  uint32(reference) and not ExtraRef

func identityOf(snapshot: Snapshot, reference: TokenRef): Identity =
  let store = snapshot.storeOf(reference)
  store[].identity(store[].record(reference.indexOf))

func materialize(snapshot: Snapshot, reference: TokenRef): Token =
  snapshot.storeOf(reference)[].token(reference.indexOf)

func sameToken(a: Snapshot, ar: TokenRef, b: Snapshot, br: TokenRef): bool =
  if (uint32(ar) and ExtraRef) == 0 and ar == br and a.base == b.base:
    return true
  sameToken(a.storeOf(ar)[], ar.indexOf, b.storeOf(br)[], br.indexOf)

func identityOf(chainId: uint64, address: openArray[char]): Result[Identity, TklError] =
  var identity = Identity(chainId: chainId)
  if not parseAddress(address, identity.address):
    return err(tklError(InvalidArgument, "BadAddress"))
  ok(identity)

func parseIdentity(text: openArray[char]): Result[Identity, TklError] =
  ## `parseKey` without allocating: "<chainId>-<address>".
  var separator = -1
  for index, ch in text:
    if ch == '-':
      separator = index
      break
  if separator <= 0 or separator == text.high:
    return err(tklError(InvalidArgument, "BadKey"))
  var chainId = 0'u64
  for ch in text.toOpenArray(0, separator - 1):
    if ch notin {'0'..'9'}:
      return err(tklError(InvalidArgument, "BadChainId"))
    let digit = uint64(ord(ch) - ord('0'))
    if chainId > (high(uint64) - digit) div 10:
      return err(tklError(InvalidArgument, "ChainIdOverflow"))
    chainId = chainId * 10 + digit
  identityOf(chainId, text.toOpenArray(separator + 1, text.high))

func search(snapshot: Snapshot, identity: Identity): int =
  ## Position in `tokens` of the token with `identity`, or -1.
  var
    low = 0
    high = snapshot.sorted.high
  while low <= high:
    let middle = (low + high) shr 1
    let position = int(snapshot.sorted[middle])
    let order = cmp(snapshot.identityOf(snapshot.tokens[position]), identity)
    if order == 0:
      return position
    if order < 0: low = middle + 1
    else: high = middle - 1
  -1

func lookup(snapshot: Snapshot, identity: Identity): int =
  ## Applies skips, then native aliases, like the key lookups.
  if identity in snapshot.skipped:
    return -1
  for (alias, native) in snapshot.aliases:
    if alias == identity:
      return snapshot.search(native)
  snapshot.search(identity)

func find(snapshot: Snapshot, identity: Identity): Result[TokenRef, TklError] =
  if identity in snapshot.skipped:
    return err(tklError(NotFound, "SkippedToken"))
  let position = snapshot.lookup(identity)
  if position < 0:
    return err(tklError(NotFound, "TokenNotFound"))
  ok(snapshot.tokens[position])

proc indexTokens(snapshot: var Snapshot) =
  ## Keeps the first occurrence of each key across lists, then sorts.
  var
    references: seq[TokenRef]
    identities: seq[Identity]
  for list in snapshot.lists:
    for reference in list.tokens:
      let identity = snapshot.identityOf(reference)
      if identity notin snapshot.skipped:
        references.add reference
        identities.add identity
  var order = newSeq[uint32](references.len)
  for index in 0 ..< order.len:
    order[index] = uint32(index)
  # Stable on equal keys, so the first occurrence leads each group.
  order.sort(proc(a, b: uint32): int = cmp(identities[a], identities[b]))
  var position = newSeq[uint32](references.len)
  for rank, index in order:
    position[index] =
      if rank > 0 and cmp(identities[order[rank - 1]], identities[index]) == 0:
        high(uint32)
      else: 0
  identities = @[]
  snapshot.tokens = newSeqOfCap[TokenRef](references.len)
  for index, reference in references:
    if position[index] == 0:
      position[index] = uint32(snapshot.tokens.len)
      snapshot.tokens.add reference
  snapshot.sorted = newSeqOfCap[uint32](snapshot.tokens.len)
  for index in order:
    if position[index] != high(uint32):
      snapshot.sorted.add position[index]

type
  ViewBuilder* = object
    ## Builds a snapshot's lists as index views over a shared store.
    snapshot: Snapshot
    enabled: seq[bool]

proc initViewBuilder*(
    base: StoreRef, chains: openArray[uint64], revision: uint64
): ViewBuilder =
  result.snapshot = Snapshot(revisionValue: revision, base: base,
    extra: initTokenStore())
  if not base.isNil:
    result.enabled = newSeq[bool](base[].chainIds.len)
    for index, chainId in base[].chainIds:
      result.enabled[index] = chainId in chains

proc addList*(builder: var ViewBuilder, meta: sink TokenList) =
  builder.snapshot.lists.add ListView(meta: meta)

proc addExtra*(builder: var ViewBuilder, token: Token) =
  ## Appends a native or custom token to the last list.
  let index = builder.snapshot.extra.addToken(token.chainId, token.address,
    token.decimals, token.name, token.symbol, token.logoUri, token.crossChainId,
    token.custom)
  builder.snapshot.lists[^1].tokens.add TokenRef(index or ExtraRef)

proc addRows*(
    builder: var ViewBuilder, rows: openArray[uint32],
    diagnostics: var seq[TklError]
) =
  ## Appends the rows of a parsed list that are visible on the enabled chains
  ## to the last list; the others are reported in row order.
  let store = addr builder.snapshot.base[]
  let list = addr builder.snapshot.lists[^1]
  var visible = 0
  for row in rows:
    let record = store[].record(row)
    if record.flags == {} and builder.enabled[record.chain]:
      inc visible
  list.tokens = newSeqOfCap[TokenRef](visible)
  for row in rows:
    let record = store[].record(row)
    let failure = rowFailure(record, builder.enabled[record.chain], list.meta.id)
    if failure.code != Ok:
      diagnostics.add failure
    else:
      list.tokens.add TokenRef(row)

proc finish*(
    builder: sink ViewBuilder, policy: CataloguePolicy,
    diagnostics: sink seq[TklError]
): Result[Snapshot, TklError] =
  var snapshot = move(builder.snapshot)
  snapshot.diagnostics = diagnostics
  snapshot.extra.freeze()
  for key in policy.skippedKeys:
    snapshot.skipped.add ?parseIdentity(key)
  for alias in policy.nativeAliases:
    let identity = ?identityOf(alias.chainId, alias.address)
    if snapshot.aliases.find((identity, Identity(chainId: alias.chainId))) < 0:
      snapshot.aliases.add (identity, Identity(chainId: alias.chainId))
  snapshot.indexTokens()
  ok(snapshot)

type
  OutputKind = enum
    TokenOutput, ListOutput, DiagnosticOutput

  QueryOutput* = object
    ## A query answer, written as JSON straight from the records. It borrows
    ## the snapshot, which must outlive it.
    snapshot: ptr Snapshot
    kind: OutputKind
    selected: seq[TokenRef]
    windowed: bool
      ## Items are `first .. last` of the snapshot's tokens, lists or
      ## diagnostics rather than `selected`.
    first, last: int
    total: int

func output(snapshot: Snapshot, kind: OutputKind, total: int): QueryOutput =
  QueryOutput(snapshot: unsafeAddr snapshot, kind: kind, total: total, last: -1)

func window(count, offset, limit: int): Result[(int, int), TklError] =
  if offset < 0 or limit < 0:
    return err(tklError(InvalidArgument, "NegativePagination"))
  if offset >= count:
    return ok((0, -1))
  let length = if limit == 0: count - offset else: min(limit, count - offset)
  ok((offset, offset + length - 1))

func byKeyOutput*(snapshot: Snapshot, key: openArray[char]): Result[QueryOutput, TklError] =
  var output = snapshot.output(TokenOutput, 1)
  output.selected = @[?snapshot.find(?parseIdentity(key))]
  ok(output)

func byChainAddressOutput*(
    snapshot: Snapshot, chainId: uint64, address: openArray[char]
): Result[QueryOutput, TklError] =
  var output = snapshot.output(TokenOutput, 1)
  output.selected = @[?snapshot.find(?identityOf(chainId, address))]
  ok(output)

func nativeOutput*(snapshot: Snapshot, chainId: uint64): Result[QueryOutput, TklError] =
  snapshot.byChainAddressOutput(chainId, NativeAddress)

func allOutput*(snapshot: Snapshot, offset = 0, limit = 0): Result[QueryOutput, TklError] =
  var output = snapshot.output(TokenOutput, snapshot.tokens.len)
  (output.first, output.last) = ?window(snapshot.tokens.len, offset, limit)
  output.windowed = true
  ok(output)

func byChainsOutput*(
    snapshot: Snapshot, chains: openArray[uint64], offset = 0, limit = 0
): Result[QueryOutput, TklError] =
  var references: seq[TokenRef]
  for reference in snapshot.tokens:
    if snapshot.identityOf(reference).chainId in chains:
      references.add reference
  let (first, last) = ?window(references.len, offset, limit)
  var output = snapshot.output(TokenOutput, references.len)
  if last >= first:
    output.selected = references[first .. last]
  ok(output)

func byKeysOutput*(
    snapshot: Snapshot, keys: openArray[string]
): Result[QueryOutput, TklError] =
  var output = snapshot.output(TokenOutput, 0)
  output.selected = newSeqOfCap[TokenRef](keys.len)
  for key in keys:
    let found = snapshot.find(?parseIdentity(key))
    if found.isOk:
      output.selected.add found.get
  output.total = output.selected.len
  ok(output)

func byChainAddressesOutput*(
    snapshot: Snapshot, chainIds: openArray[uint64], addresses: openArray[string]
): Result[QueryOutput, TklError] =
  ## Batch `byChainAddressOutput` over parallel arrays: the tokens found, in
  ## request order.
  if chainIds.len != addresses.len:
    return err(tklError(InvalidArgument, "MismatchedPairs"))
  var output = snapshot.output(TokenOutput, 0)
  output.selected = newSeqOfCap[TokenRef](chainIds.len)
  for index, chainId in chainIds:
    let found = snapshot.find(?identityOf(chainId, addresses[index]))
    if found.isOk:
      output.selected.add found.get
  output.total = output.selected.len
  ok(output)

func listOutput*(snapshot: Snapshot, id: string): Result[QueryOutput, TklError] =
  for index, list in snapshot.lists:
    if list.meta.id == id:
      var output = snapshot.output(ListOutput, 1)
      (output.first, output.last, output.windowed) = (index, index, true)
      return ok(output)
  err(tklError(NotFound, "ListNotFound", id))

func listsOutput*(snapshot: Snapshot): QueryOutput =
  result = snapshot.output(ListOutput, snapshot.lists.len)
  (result.first, result.last, result.windowed) = (0, snapshot.lists.high, true)

func diagnosticsOutput*(snapshot: Snapshot): QueryOutput =
  result = snapshot.output(DiagnosticOutput, snapshot.diagnostics.len)
  (result.first, result.last, result.windowed) =
    (0, snapshot.diagnostics.high, true)

template references(output: QueryOutput): openArray[TokenRef] =
  if output.windowed:
    output.snapshot.tokens.toOpenArray(output.first, output.last)
  else:
    output.selected.toOpenArray(0, output.selected.high)

proc writeReference(sink: var JsonSink, snapshot: Snapshot, reference: TokenRef) =
  sink.writeToken(snapshot.storeOf(reference)[], reference.indexOf)

proc writeList(sink: var JsonSink, snapshot: Snapshot, list: ListView) =
  ## A list as the C API returns it: missing tags become `{}`.
  let meta = unsafeAddr list.meta
  sink.add "{\"id\":"
  sink.addString(meta.id)
  sink.add ",\"name\":"
  sink.addString(meta.name)
  sink.add ",\"timestamp\":"
  sink.addString(meta.timestamp)
  sink.add ",\"fetchedTimestamp\":"
  sink.addString(meta.fetchedTimestamp)
  sink.add ",\"source\":"
  sink.addString(meta.source)
  sink.add ",\"version\":{\"major\":"
  sink.addInt(meta.version.major)
  sink.add ",\"minor\":"
  sink.addInt(meta.version.minor)
  sink.add ",\"patch\":"
  sink.addInt(meta.version.patch)
  sink.add "},\"tags\":"
  sink.add(if string(meta.tags).len == 0: "{}" else: string(meta.tags))
  sink.add ",\"logoUri\":"
  sink.addString(meta.logoUri)
  sink.add ",\"keywords\":["
  for index, keyword in meta.keywords:
    if index > 0:
      sink.add ','
    sink.addString(keyword)
  sink.add "],\"tokens\":["
  for index, reference in list.tokens:
    if index > 0:
      sink.add ','
    sink.writeReference(snapshot, reference)
  sink.add "]}"

proc writeError(sink: var JsonSink, error: TklError) =
  sink.add "{\"code\":"
  sink.addString($error.code)
  sink.add ",\"detail\":"
  sink.addString(error.detail)
  sink.add ",\"sourceId\":"
  sink.addString(error.sourceId)
  sink.add '}'

proc emit(output: QueryOutput, sink: var JsonSink) =
  let snapshot = output.snapshot
  sink.add "{\"revision\":"
  sink.addUint(snapshot.revisionValue)
  sink.add ",\"total\":"
  sink.addInt(output.total)
  sink.add ",\"items\":["
  case output.kind
  of TokenOutput:
    for index, reference in output.references:
      if index > 0:
        sink.add ','
      sink.writeReference(snapshot[], reference)
  of ListOutput:
    for index in output.first .. output.last:
      if index > output.first:
        sink.add ','
      sink.writeList(snapshot[], snapshot.lists[index])
  of DiagnosticOutput:
    for index in output.first .. output.last:
      if index > output.first:
        sink.add ','
      sink.writeError(snapshot.diagnostics[index])
  sink.add "]}"

proc jsonLen*(output: QueryOutput): int =
  var sink = measuring()
  output.emit(sink)
  sink.len

proc writeJson*(output: QueryOutput, data: ptr UncheckedArray[char]) =
  ## Writes exactly `jsonLen` bytes to `data`.
  var sink = writing(data)
  output.emit(sink)

proc json*(output: QueryOutput): string =
  result = newString(output.jsonLen)
  if result.len > 0:
    output.writeJson(cast[ptr UncheckedArray[char]](addr result[0]))

func tokenPage(output: QueryOutput): Page[Token] =
  ## Materializes a token output for Nim callers.
  result = Page[Token](revision: output.snapshot.revisionValue,
    total: output.total, items: newSeqOfCap[Token](output.references.len))
  for reference in output.references:
    result.items.add output.snapshot[].materialize(reference)

func getByKey*(snapshot: Snapshot, key: string): Result[Token, TklError] =
  let reference = ?snapshot.find(?parseIdentity(key))
  ok(snapshot.materialize(reference))

func getByChainAddress*(
    snapshot: Snapshot, chainId: uint64, address: string
): Result[Token, TklError] =
  let reference = ?snapshot.find(?identityOf(chainId, address))
  ok(snapshot.materialize(reference))

func getNative*(snapshot: Snapshot, chainId: uint64): Result[Token, TklError] =
  snapshot.getByChainAddress(chainId, NativeAddress)

func getAll*(
    snapshot: Snapshot, offset = 0, limit = 0
): Result[Page[Token], TklError] =
  ok((?snapshot.allOutput(offset, limit)).tokenPage)

func getByChains*(
    snapshot: Snapshot, chains: openArray[uint64], offset = 0, limit = 0
): Result[Page[Token], TklError] =
  ok((?snapshot.byChainsOutput(chains, offset, limit)).tokenPage)

func getByKeys*(
    snapshot: Snapshot, keys: openArray[string]
): Result[Page[Token], TklError] =
  ok((?snapshot.byKeysOutput(keys)).tokenPage)

func getByChainAddresses*(
    snapshot: Snapshot, pairs: openArray[TokenIdentity]
): Result[Page[Token], TklError] =
  ## Batch `getByChainAddress`: the tokens found, in request order.
  var output = snapshot.output(TokenOutput, 0)
  output.selected = newSeqOfCap[TokenRef](pairs.len)
  for pair in pairs:
    let found = snapshot.find(?identityOf(pair.chainId, pair.address))
    if found.isOk:
      output.selected.add found.get
  output.total = output.selected.len
  ok(output.tokenPage)

func getByChainAddresses*(
    snapshot: Snapshot, chainIds: openArray[uint64], addresses: openArray[string]
): Result[Page[Token], TklError] =
  ## The same batch as parallel arrays, which the C ABI decodes cheaply.
  ok((?snapshot.byChainAddressesOutput(chainIds, addresses)).tokenPage)

func materialize(snapshot: Snapshot, list: ListView): TokenList =
  result = list.meta
  result.tokens = newSeqOfCap[Token](list.tokens.len)
  for reference in list.tokens:
    result.tokens.add snapshot.materialize(reference)

func getList*(snapshot: Snapshot, id: string): Result[TokenList, TklError] =
  for list in snapshot.lists:
    if list.meta.id == id:
      return ok(snapshot.materialize(list))
  err(tklError(NotFound, "ListNotFound", id))

func getLists*(snapshot: Snapshot): Page[TokenList] =
  result = Page[TokenList](revision: snapshot.revisionValue,
    total: snapshot.lists.len, items: newSeqOfCap[TokenList](snapshot.lists.len))
  for list in snapshot.lists:
    result.items.add snapshot.materialize(list)

func getDiagnostics*(snapshot: Snapshot): Page[TklError] =
  Page[TklError](revision: snapshot.revisionValue,
    total: snapshot.diagnostics.len, items: snapshot.diagnostics)

type SnapshotDiff* = object
  chains*: seq[uint64]
  lists*: seq[string]

func lookupDiffers(before, after: Snapshot, identity: Identity): bool =
  let
    oldIndex = before.lookup(identity)
    newIndex = after.lookup(identity)
  if oldIndex < 0 or newIndex < 0:
    return oldIndex != newIndex
  not sameToken(before, before.tokens[oldIndex], after, after.tokens[newIndex])

func sameList(before: Snapshot, a: ListView, after: Snapshot, b: ListView): bool =
  if a.meta != b.meta or a.tokens.len != b.tokens.len:
    return false
  for index in 0 ..< a.tokens.len:
    if not sameToken(before, a.tokens[index], after, b.tokens[index]):
      return false
  true

func diffSnapshots*(before, after: Snapshot): SnapshotDiff =
  ## Borrow both immutable values and compare their indexes and list views;
  ## nothing is materialized.
  var chains: HashSet[uint64]
  for reference in before.tokens:
    let identity = before.identityOf(reference)
    let other = after.search(identity)
    if other < 0 or not sameToken(before, reference, after, after.tokens[other]):
      chains.incl identity.chainId
  var priorPositions = newSeq[int](after.tokens.len)
  for index, reference in after.tokens:
    let identity = after.identityOf(reference)
    let other = before.search(identity)
    if other < 0:
      chains.incl identity.chainId
    else:
      priorPositions[index] = other + 1
  # A key/value-only comparison would miss changes to paginated chain order.
  var lastPosition: Table[uint64, int]
  for index, reference in after.tokens:
    let previous = priorPositions[index]
    if previous > 0:
      let chainId = after.identityOf(reference).chainId
      if previous < lastPosition.getOrDefault(chainId):
        chains.incl chainId
      lastPosition[chainId] = previous
  for (alias, _) in before.aliases:
    if lookupDiffers(before, after, alias):
      chains.incl alias.chainId
  for (alias, native) in after.aliases:
    if before.aliases.find((alias, native)) < 0 and
        lookupDiffers(before, after, alias):
      chains.incl alias.chainId
  var oldLists, newLists: Table[string, int]
  for index, list in before.lists:
    oldLists[list.meta.id] = index
  for index, list in after.lists:
    newLists[list.meta.id] = index
  var changedLists: seq[string]
  for id, index in oldLists:
    let other = newLists.getOrDefault(id, -1)
    if other < 0 or not sameList(before, before.lists[index], after, after.lists[other]):
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
