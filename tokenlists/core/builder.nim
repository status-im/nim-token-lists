{.push raises: [], gcsafe.}

import std/[algorithm, sets, tables]
import ./[types, keys, snapshot]
import ./parsers/[common, standard, status]
export types, snapshot

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

when defined(tklCountParses):
  # Test-only probe: list documents decoded while building catalogues.
  var parsedContents* {.threadvar.}: int

func origin(content: ListContent, format: ListFormat): SourceOrigin =
  SourceOrigin(id: content.id, format: format, source: content.source,
    fetchedTimestamp: content.fetchedTimestamp, etag: content.etag,
    fetchedAt: content.fetchedAt, bodyLen: content.body.len)

proc parseContent(
    content: ListContent, format: ListFormat, limits: ParseLimits
): Result[ParsedSource, TklError] =
  when defined(tklCountParses):
    inc parsedContents
  if content.failure.code != Ok:
    return err(tklError(content.failure.code, content.failure.detail, content.id))
  if content.body.len == 0:
    return err(tklError(InvalidContent, "EmptyListContent", content.id))
  let parsed = case format
    of StandardFormat: decodeStandardSource(content.body, content.id, limits)
    of StatusFormat: decodeStatusSource(content.body, content.id, limits)
    of RegistryFormat:
      err(tklError(UnsupportedSchema, "RegistryIsNotTokenList", content.id))
  var value = ?parsed
  value.list.source = content.source
  value.list.fetchedTimestamp = content.fetchedTimestamp
  ok(value)

proc reparseCatalogueSources*(
    previous: ParsedCatalogue, config: CatalogueConfig, stored: seq[ListContent],
    changed: HashSet[string], limits = DefaultParseLimits
): Result[SourceRefresh, TklError] =
  ## Parses like `parseCatalogueSources`, reusing entries of `previous` whose
  ## content identity is unchanged. `changed` must name every list whose body
  ## may differ from the content `previous` was parsed from. Reused entries stay
  ## in `previous` until `adoptSources`, so no parsed list is copied.
  var initial, cached: Table[string, int]
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
  # Only clean entries are reusable: one with failures fell back or was dropped,
  # so its first-choice content must be parsed again.
  var reusable: Table[string, int]
  for index, entry in previous.sources:
    if entry.usable and entry.failures.len == 0:
      reusable[entry.origin.id] = index
  var output = SourceRefresh(unchanged: order.len == previous.sources.len)
  for id in order:
    var entry: CachedSource
    var reused = -1
    let format = if id in initial:
        config.initialLists[initial.getOrDefault(id)].format
      elif id in cached: stored[cached.getOrDefault(id)].format
      else: StandardFormat
    template storedContent: untyped = stored[cached.getOrDefault(id)]
    template initialContent: untyped = config.initialLists[initial.getOrDefault(id)]
    if id notin changed and id in reusable:
      let index = reusable.getOrDefault(id)
      let first =
        if id in cached: storedContent.origin(format)
        else: initialContent.origin(format)
      if previous.sources[index].origin == first:
        reused = index
    if reused < 0:
      var parsed = Result[ParsedSource, TklError].err(
        tklError(NotFound, "MissingStoredList", id))
      if id in cached:
        parsed = parseContent(storedContent, format, limits)
        if parsed.isErr:
          entry.failures.add parsed.error
        else:
          entry.origin = storedContent.origin(format)
      if parsed.isErr and id in initial:
        parsed = parseContent(initialContent, initialContent.format, limits)
        if parsed.isOk:
          entry.origin = initialContent.origin(initialContent.format)
      if parsed.isErr:
        if id in initial or id == config.mainListId:
          return err(parsed.error)
      else:
        entry.source = parsed.get
        entry.usable = true
    if reused != output.reused.len:
      output.unchanged = false
    output.reused.add reused
    output.parsed.sources.add entry
  ok(output)

proc parseCatalogueSources*(
    config: CatalogueConfig, stored: seq[ListContent] = @[],
    limits = DefaultParseLimits
): Result[ParsedCatalogue, TklError] =
  ok((?reparseCatalogueSources(ParsedCatalogue(), config, stored,
    initHashSet[string](), limits)).parsed)

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

proc buildCatalogue*(
    config: CatalogueConfig, stored: seq[ListContent] = @[],
    customs: seq[Token] = @[], revision = 1'u64,
    limits = DefaultParseLimits
): Result[Snapshot, TklError] =
  let parsed = ?parseCatalogueSources(config, stored, limits)
  buildFromParsed(parsed, config.chains, config.policy, customs, revision)
