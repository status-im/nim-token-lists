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
    source: ParsedSource
    failures: seq[TklError]
    usable: bool
    origin: SourceOrigin

  ParsedCatalogue* = object
    sources: seq[CachedSource]

  SourceRefresh* = object
    ## Parsed catalogue whose unchanged entries still live in the previous one.
    parsed: ParsedCatalogue
    reused: seq[int]
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
    ## Lists parsed during a load, by id and origin. Bodies are not kept.
    order: seq[string]
    initial, cached, slots: Table[string, int]
    lists: seq[LoadedList]

func origin(content: ListContent, format: ListFormat, bodyLen: int): SourceOrigin =
  SourceOrigin(id: content.id, format: format, source: content.source,
    fetchedTimestamp: content.fetchedTimestamp, etag: content.etag,
    fetchedAt: content.fetchedAt, bodyLen: bodyLen)

proc parseContent(
    content: ListContent, body: openArray[char], format: ListFormat,
    limits: ParseLimits
): Result[ParsedSource, TklError] =
  if content.failure.code != Ok:
    return err(tklError(content.failure.code, content.failure.detail, content.id))
  var value = ?parseListBody(body, format, content.id, limits)
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
    target.parsed = parseContent(content, body, format, limits)
    if target.parsed.isOk:
      # A usable stored copy wins; drop a bundled one parsed before it.
      list.bundled.parsed = Result[ParsedSource, TklError].err(tklError(Ok, "", id))
  elif not (list.stored.received and list.stored.parsed.isOk):
    let content = config.initialLists[sources.initial.getOrDefault(id)]
    target.parsed = parseContent(content, body, content.format, limits)
  ok()

proc finishSources*(
    sources: var LoadedSources, config: CatalogueConfig,
    stored: openArray[ListContent]
): Result[(ParsedCatalogue, seq[ListContent]), TklError] =
  ## Picks each stored list if it parsed, else its bundled list. Also returns
  ## the committed metadata of every usable list, for refresh planning.
  var parsed: ParsedCatalogue
  var contents = config.initialLists
  var usableStored: HashSet[string]
  for slot, id in sources.order:
    var entry = CachedSource(origin: SourceOrigin(id: id))
    let list = addr sources.lists[slot]
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
        entry.source = move(list.stored.parsed.value)
        entry.usable = true
    if not entry.usable and id in sources.initial:
      let content = config.initialLists[sources.initial.getOrDefault(id)]
      if not list.bundled.received:
        return err(tklError(InvalidContent, "MissingListBody", id))
      if list.bundled.parsed.isErr:
        return err(list.bundled.parsed.error)
      entry.origin = origin(content, content.format, list.bundled.bodyLen)
      entry.source = move(list.bundled.parsed.value)
      entry.usable = true
    if not entry.usable and id == config.mainListId:
      return err(entry.failures[^1])
    parsed.sources.add entry
  sources.lists.setLen(0)
  for content in stored:
    if content.id in usableStored:
      contents.add content
  ok((parsed, contents))

proc refreshSources*(
    previous: ParsedCatalogue, config: CatalogueConfig,
    contents: openArray[ListContent], updates: var seq[ParsedContent]
): Result[SourceRefresh, TklError] =
  ## Lists in `updates` replace their entries; every other list in `contents`
  ## reuses its parsed entry from `previous`, which stays there until
  ## `adoptSources`, so no parsed list is copied and no body is needed.
  var initial, cached: Table[string, int]
  let order = ?sourceOrder(config, contents, initial, cached)
  var previousIndex, updateIndex: Table[string, int]
  for index, entry in previous.sources:
    previousIndex[entry.origin.id] = index
  for index, update in updates:
    updateIndex[update.meta.id] = index
  var output = SourceRefresh(unchanged: order.len == previous.sources.len)
  for id in order:
    var entry: CachedSource
    var reused = -1
    if id in updateIndex:
      let update = addr updates[updateIndex.getOrDefault(id)]
      entry.origin = origin(update.meta, update.meta.format, update.bodyLen)
      entry.source = move(update.source)
      entry.usable = true
    elif id in previousIndex:
      reused = previousIndex.getOrDefault(id)
    else:
      return err(tklError(Internal, "MissingParsedList", id))
    if reused != output.reused.len:
      output.unchanged = false
    output.reused.add reused
    output.parsed.sources.add entry
  ok(output)

func unchanged*(refresh: SourceRefresh): bool =
  ## Every entry of the previous catalogue is reused in its existing order.
  refresh.unchanged

proc adoptSources*(previous: var ParsedCatalogue, refresh: sink SourceRefresh) =
  for slot, index in refresh.reused:
    if index >= 0:
      refresh.parsed.sources[slot] = move(previous.sources[index])
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
  var nativeList = TokenList(id: "native", name: "Native tokens")
  for chain in chains:
    var token = descriptors.getOrDefault(chain, Token(chainId: chain,
      address: NativeAddress, symbol: "ETH", name: "Ethereum",
      crossChainId: "eth-native", decimals: 18, logoUri: DefaultNativeLogo))
    token.address = NativeAddress
    token.custom = false
    nativeList.tokens.add token
  var lists = @[nativeList]
  var diagnostics = extraDiagnostics
  var customList = TokenList(id: "custom", name: "Custom tokens")
  for token in customs:
    let valid = validateCustom(token, chains)
    if valid.isErr:
      diagnostics.add tklError(valid.error.code, valid.error.detail, "custom")
      continue
    var normalized = token
    normalized.address = normalizeAddress(token.address).get
    normalized.custom = true
    customList.tokens.add normalized
  if policy.priority == CustomFirstPriority:
    lists.add customList
  for entry in parsed.sources:
    diagnostics.add entry.failures
    if entry.usable:
      let filtered = filterSource(entry.source, chains)
      lists.add filtered.list
      for diagnostic in filtered.diagnostics:
        diagnostics.add diagnostic.error
  if policy.priority == StatusPriority:
    lists.add customList
  initSnapshot(lists, policy, diagnostics, revision)

proc buildFromRefresh*(
    refresh: var SourceRefresh, previous: var ParsedCatalogue, chains: seq[uint64],
    policy: CataloguePolicy, customs: seq[Token], revision: uint64,
    extraDiagnostics: seq[TklError]
): Result[Snapshot, TklError] =
  ## Borrows reused entries from `previous` for the build and returns them.
  for slot, index in refresh.reused:
    if index >= 0:
      swap(refresh.parsed.sources[slot], previous.sources[index])
  result = buildFromParsed(refresh.parsed, chains, policy, customs, revision,
    extraDiagnostics)
  for slot, index in refresh.reused:
    if index >= 0:
      swap(refresh.parsed.sources[slot], previous.sources[index])

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
