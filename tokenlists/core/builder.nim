{.push raises: [], gcsafe.}

import std/[algorithm, sets, tables]
import ./[types, keys, snapshot]
import ./parsers/lists
export types, snapshot, ParsedContent

const DefaultNativeLogo =
  "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/" &
  "ethereum/assets/0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2/logo.png"

type
  SourceOrigin = object
    ## Identity of the content an entry was parsed from, without its body.
    id: string
    format: ListFormat
    source, fetchedTimestamp, etag: string
    fetchedAt: int64
    bodyLen: int

  CachedSource = object
    list: TokenList
      ## Metadata of the parsed list; its tokens are `rows`.
    rows: seq[uint32]
      ## Records of the catalogue store, in document order.
    failures: seq[TklError]
    usable: bool
    origin: SourceOrigin

  ParsedCatalogue* = object
    ## Every parsed list, sharing one frozen store. Chain, policy and custom
    ## changes build new index views over it; only refreshes replace it.
    store: StoreRef
    sources: seq[CachedSource]

  SourceRefresh* = object
    ## The parsed catalogue a refresh would publish. Building it leaves the
    ## previous one untouched; it is empty when nothing changed.
    parsed: ParsedCatalogue
    unchanged: bool

  SourceBody* = object
    ## Convenience load input for Nim callers. The C ABI borrows host bytes.
    id*: string
    origin*: BodyOrigin
    body*: string

  ParsedBody = object
    received: bool
    bodyLen: int
    parsed: Result[ParsedSource, TklError]

  LoadedList = object
    bundled, stored: ParsedBody

  LoadedSources* = object
    ## Lists parsed during a load, by id and origin, into one store. Bodies
    ## are not kept.
    order: seq[string]
    initial, cached, slots: Table[string, int]
    lists: seq[LoadedList]
    store: TokenStore
    unreferenced: bool
      ## A discarded or failed parse left rows in `store`.

func origin(content: ListContent, format: ListFormat, bodyLen: int): SourceOrigin =
  SourceOrigin(id: content.id, format: format, source: content.source,
    fetchedTimestamp: content.fetchedTimestamp, etag: content.etag,
    fetchedAt: content.fetchedAt, bodyLen: bodyLen)

proc parseContent(
    store: var TokenStore, content: ListContent, body: openArray[char],
    format: ListFormat, limits: ParseLimits
): Result[ParsedSource, TklError] =
  if content.failure.code != Ok:
    return err(tklError(content.failure.code, content.failure.detail, content.id))
  var value = ?parseListBody(store, body, format, content.id, limits)
  value.list.source = content.source
  value.list.fetchedTimestamp = content.fetchedTimestamp
  ok(value)

proc sourceOrder(
    config: CatalogueConfig, stored: openArray[ListContent],
    initial, cached: var Table[string, int]
): Result[seq[string], TklError] =
  ## Native and custom are synthetic; the registry is not a token list.
  for index, source in config.initialLists:
    if source.id.len == 0 or source.id in ["native", "custom", config.registryId] or
        source.id in initial:
      return err(tklError(InvalidArgument, "InvalidInitialListId", source.id))
    initial[source.id] = index
  for index, source in stored:
    if source.id == config.registryId and config.registryId.len > 0:
      continue
    if source.id.len == 0 or source.id in ["native", "custom"] or source.id in cached:
      return err(tklError(InvalidArgument, "InvalidStoredListId", source.id))
    cached[source.id] = index
  if config.mainListId.len > 0 and
      config.mainListId notin initial and config.mainListId notin cached:
    return err(tklError(InvalidArgument, "MissingMainList", config.mainListId))
  var order: seq[string]
  if config.mainListId.len > 0:
    order.add config.mainListId
  var ids: seq[string]
  for id in initial.keys:
    if id != config.mainListId:
      ids.add id
  ids.sort()
  order.add ids
  ids.setLen(0)
  for id in cached.keys:
    if id != config.mainListId and id notin initial:
      ids.add id
  ids.sort()
  order.add ids
  ok(order)

proc initLoadedSources*(
    config: CatalogueConfig, stored: openArray[ListContent]
): Result[LoadedSources, TklError] =
  var sources: LoadedSources
  sources.order = ?sourceOrder(config, stored, sources.initial, sources.cached)
  sources.store = initTokenStore()
  sources.lists.setLen(sources.order.len)
  for slot, id in sources.order:
    sources.slots[id] = slot
  ok(sources)

proc loadBody*(
    sources: var LoadedSources, config: CatalogueConfig,
    stored: openArray[ListContent], id: string, origin: BodyOrigin,
    body: openArray[char], limits: ParseLimits
): Result[void, TklError] =
  ## Parses a body at most once while it is borrowed. A bundled body is parsed
  ## only while no usable stored copy of that list has been loaded.
  let known = if origin == BundledBody: id in sources.initial else: id in sources.cached
  if not known:
    return err(tklError(InvalidArgument,
      if origin == BundledBody: "UnknownInitialList" else: "UnknownStoredList", id))
  let list = addr sources.lists[sources.slots.getOrDefault(id)]
  let target = if origin == BundledBody: addr list.bundled else: addr list.stored
  if target.received:
    return err(tklError(InvalidArgument, "DuplicateListBody", id))
  target[] = ParsedBody(received: true, bodyLen: body.len,
    parsed: Result[ParsedSource, TklError].err(tklError(Ok, "", id)))
  if origin == StoredBody:
    let content = stored[sources.cached.getOrDefault(id)]
    let format = if id in sources.initial:
        config.initialLists[sources.initial.getOrDefault(id)].format
      else: content.format
    target.parsed = sources.store.parseContent(content, body, format, limits)
    if target.parsed.isOk and list.bundled.parsed.isOk:
      # A usable stored copy wins; drop a bundled one parsed before it.
      list.bundled.parsed = Result[ParsedSource, TklError].err(tklError(Ok, "", id))
      sources.unreferenced = true
    sources.unreferenced = sources.unreferenced or target.parsed.isErr
  elif not (list.stored.received and list.stored.parsed.isOk):
    let content = config.initialLists[sources.initial.getOrDefault(id)]
    target.parsed = sources.store.parseContent(content, body, content.format, limits)
    sources.unreferenced = sources.unreferenced or target.parsed.isErr
  ok()

proc absorb(
    store: var TokenStore, source: TokenStore, rows: openArray[uint32]
): seq[uint32] =
  result = newSeqOfCap[uint32](rows.len)
  for row in rows:
    result.add store.copyRecord(source, row)

proc shared(store: sink TokenStore): StoreRef =
  var value = store
  value.freeze()
  result = StoreRef()
  result[] = move(value)

proc finishSources*(
    sources: var LoadedSources, config: CatalogueConfig,
    stored: openArray[ListContent]
): Result[(ParsedCatalogue, seq[ListContent]), TklError] =
  ## Picks each stored list if it parsed, else its bundled list, and merges
  ## them into one store. Also returns the committed metadata of every usable
  ## list, for refresh planning.
  var parsed: ParsedCatalogue
  # Rows left by discarded parses are dropped by copying the used ones.
  var compacted = initTokenStore()
  var contents = config.initialLists
  var usableStored: HashSet[string]
  for slot, id in sources.order:
    var entry = CachedSource(origin: SourceOrigin(id: id))
    let list = addr sources.lists[slot]
    var chosen: ptr ParsedSource
    if id in sources.cached:
      let content = stored[sources.cached.getOrDefault(id)]
      if content.failure.code != Ok:
        entry.failures.add tklError(content.failure.code, content.failure.detail, id)
      elif not list.stored.received:
        entry.failures.add tklError(InvalidContent, "MissingListBody", id)
      elif list.stored.parsed.isErr:
        entry.failures.add list.stored.parsed.error
      else:
        var meta = content
        if id in sources.initial:
          meta.format = config.initialLists[sources.initial.getOrDefault(id)].format
          contents[sources.initial.getOrDefault(id)] = meta
        else:
          usableStored.incl id
        entry.origin = origin(meta, meta.format, list.stored.bodyLen)
        chosen = addr list.stored.parsed.value
    if chosen.isNil and id in sources.initial:
      let content = config.initialLists[sources.initial.getOrDefault(id)]
      if not list.bundled.received:
        return err(tklError(InvalidContent, "MissingListBody", id))
      if list.bundled.parsed.isErr:
        return err(list.bundled.parsed.error)
      entry.origin = origin(content, content.format, list.bundled.bodyLen)
      chosen = addr list.bundled.parsed.value
    if chosen.isNil and id == config.mainListId:
      return err(entry.failures[^1])
    if not chosen.isNil:
      entry.list = move(chosen.list)
      entry.rows = if sources.unreferenced:
          compacted.absorb(sources.store, chosen.rows)
        else: move(chosen.rows)
      entry.usable = true
      list[] = LoadedList()
    parsed.sources.add entry
  sources.lists.setLen(0)
  parsed.store = shared(if sources.unreferenced: move(compacted)
    else: move(sources.store))
  sources.store = TokenStore()
  for content in stored:
    if content.id in usableStored:
      contents.add content
  ok((parsed, contents))

proc refreshSources*(
    previous: ParsedCatalogue, config: CatalogueConfig,
    contents: openArray[ListContent], updates: var seq[ParsedContent]
): Result[SourceRefresh, TklError] =
  ## Lists in `updates` replace their entries; every other list in `contents`
  ## keeps its parsed entry from `previous`, so no body is needed. The result
  ## is a new store; `previous` stays published until `adoptSources`.
  var initial, cached: Table[string, int]
  let order = ?sourceOrder(config, contents, initial, cached)
  var previousIndex, updateIndex: Table[string, int]
  for index, entry in previous.sources:
    previousIndex[entry.origin.id] = index
  for index, update in updates:
    updateIndex[update.meta.id] = index
  var unchanged = updates.len == 0 and order.len == previous.sources.len
  for slot, id in order:
    if id notin updateIndex and id notin previousIndex:
      return err(tklError(Internal, "MissingParsedList", id))
    unchanged = unchanged and previous.sources[slot].origin.id == id
  if unchanged:
    return ok(SourceRefresh(unchanged: true))
  var output: SourceRefresh
  var store = initTokenStore()
  for id in order:
    var entry: CachedSource
    if id in updateIndex:
      let update = addr updates[updateIndex.getOrDefault(id)]
      entry.origin = origin(update.meta, update.meta.format, update.bodyLen)
      entry.list = move(update.source.list)
      entry.rows = store.absorb(update.source.store, update.source.rows)
      entry.usable = true
      update.source = ParsedSource()
    else:
      let reused = addr previous.sources[previousIndex.getOrDefault(id)]
      entry = CachedSource(list: reused.list, failures: reused.failures,
        usable: reused.usable, origin: reused.origin)
      entry.rows = store.absorb(previous.store[], reused.rows)
    output.parsed.sources.add entry
  output.parsed.store = shared(store)
  ok(output)

func unchanged*(refresh: SourceRefresh): bool =
  ## Every entry of the previous catalogue is reused in its existing order.
  refresh.unchanged

proc adoptSources*(previous: var ParsedCatalogue, refresh: sink SourceRefresh) =
  if not refresh.unchanged:
    previous = move(refresh.parsed)

func validateCustomKeys(customs: seq[Token]): Result[void, TklError] =
  var seen: HashSet[string]
  for token in customs:
    let key = tokenKey(token.chainId, token.address)
    if key.isOk:
      if key.get in seen:
        return err(tklError(InvalidArgument, "DuplicateCustomKey", "custom"))
      seen.incl key.get
  ok()

proc buildFromParsed*(
    parsed: ParsedCatalogue, chains: seq[uint64],
    policy = CataloguePolicy(), customs: seq[Token] = @[], revision = 1'u64,
    extraDiagnostics: seq[TklError] = @[]
): Result[Snapshot, TklError] =
  ## Builds index views over the parsed store; nothing parsed is copied.
  ?validateCustomKeys(customs)
  var seen: HashSet[uint64]
  for chain in chains:
    if chain in seen:
      return err(tklError(InvalidArgument, "DuplicateChain"))
    seen.incl chain
  var descriptors: Table[uint64, Token]
  for descriptor in policy.nativeTokens:
    if descriptor.chainId in descriptors or
        normalizeAddress(descriptor.address).isErr or
        normalizeAddress(descriptor.address).get != NativeAddress:
      return err(tklError(InvalidArgument, "InvalidNativeDescriptor"))
    descriptors[descriptor.chainId] = descriptor
  var builder = initViewBuilder(parsed.store, chains, revision)
  builder.addList(TokenList(id: "native", name: "Native tokens"))
  for chain in chains:
    var token = descriptors.getOrDefault(chain, Token(chainId: chain,
      address: NativeAddress, symbol: "ETH", name: "Ethereum",
      crossChainId: "eth-native", decimals: 18, logoUri: DefaultNativeLogo))
    token.address = NativeAddress
    token.custom = false
    builder.addExtra(token)
  var diagnostics = extraDiagnostics
  var visibleCustoms: seq[Token]
  for token in customs:
    let valid = validateCustom(token, chains)
    if valid.isErr:
      diagnostics.add tklError(valid.error.code, valid.error.detail, "custom")
      continue
    var normalized = token
    normalized.address = normalizeAddress(token.address).get
    normalized.custom = true
    visibleCustoms.add normalized
  template addCustoms() =
    builder.addList(TokenList(id: "custom", name: "Custom tokens"))
    for token in visibleCustoms:
      builder.addExtra(token)
  if policy.priority == CustomFirstPriority:
    addCustoms()
  for entry in parsed.sources:
    diagnostics.add entry.failures
    if entry.usable:
      builder.addList(entry.list)
      builder.addRows(entry.rows, diagnostics)
  if policy.priority == StatusPriority:
    addCustoms()
  builder.finish(policy, diagnostics)

proc buildFromRefresh*(
    refresh: SourceRefresh, previous: ParsedCatalogue, chains: seq[uint64],
    policy: CataloguePolicy, customs: seq[Token], revision: uint64,
    extraDiagnostics: seq[TklError]
): Result[Snapshot, TklError] =
  let parsed = if refresh.unchanged: unsafeAddr previous
    else: unsafeAddr refresh.parsed
  buildFromParsed(parsed[], chains, policy, customs, revision, extraDiagnostics)

proc loadSources*(
    config: CatalogueConfig, bodies: openArray[SourceBody],
    stored: openArray[ListContent], limits: ParseLimits
): Result[(ParsedCatalogue, seq[ListContent]), TklError] =
  var sources = ?initLoadedSources(config, stored)
  for body in bodies:
    ?sources.loadBody(config, stored, body.id, body.origin, body.body, limits)
  sources.finishSources(config, stored)

proc buildCatalogue*(
    config: CatalogueConfig, bodies: openArray[SourceBody] = [],
    stored: seq[ListContent] = @[], customs: seq[Token] = @[], revision = 1'u64,
    limits = DefaultParseLimits
): Result[Snapshot, TklError] =
  let (parsed, _) = ?loadSources(config, bodies, stored, limits)
  buildFromParsed(parsed, config.chains, config.policy, customs, revision)
