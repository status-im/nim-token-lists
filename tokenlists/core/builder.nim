{.push raises: [], gcsafe.}

import std/[algorithm, sets, tables]
import ./[types, keys, snapshot]
import ./parsers/[common, standard, status]
export types, snapshot

const DefaultNativeLogo =
  "https://raw.githubusercontent.com/trustwallet/assets/master/blockchains/" &
  "ethereum/assets/0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2/logo.png"

type
  CachedSource = object
    source: ParsedSource
    failures: seq[TklError]
    usable: bool

  ParsedCatalogue* = object
    sources: seq[CachedSource]

proc parseContent(
    content: ListContent, limits: ParseLimits
): Result[ParsedSource, TklError] =
  if content.failure.code != Ok:
    return err(tklError(content.failure.code, content.failure.detail, content.id))
  if content.body.len == 0:
    return err(tklError(InvalidContent, "EmptyListContent", content.id))
  let parsed = case content.format
    of StandardFormat: decodeStandardSource(content.body, content.id, limits)
    of StatusFormat: decodeStatusSource(content.body, content.id, limits)
    of RegistryFormat:
      err(tklError(UnsupportedSchema, "RegistryIsNotTokenList", content.id))
  var value = ?parsed
  value.list.source = content.source
  value.list.fetchedTimestamp = content.fetchedTimestamp
  ok(value)

proc parseCatalogueSources*(
    config: CatalogueConfig, stored: seq[ListContent] = @[],
    limits = DefaultParseLimits
): Result[ParsedCatalogue, TklError] =
  var initial, cached: Table[string, ListContent]
  for source in config.initialLists:
    if source.id.len == 0 or source.id in ["native", "custom", config.registryId] or
        source.id in initial:
      return err(tklError(InvalidArgument, "InvalidInitialListId", source.id))
    initial[source.id] = source
  for source in stored:
    if source.id == config.registryId and config.registryId.len > 0:
      continue
    if source.id.len == 0 or source.id in ["native", "custom"] or source.id in cached:
      return err(tklError(InvalidArgument, "InvalidStoredListId", source.id))
    cached[source.id] = source
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
  var output: ParsedCatalogue
  for id in order:
    var entry: CachedSource
    var parsed = Result[ParsedSource, TklError].err(
      tklError(NotFound, "MissingStoredList", id))
    if id in cached:
      var content = cached.getOrDefault(id)
      if id in initial:
        content.format = initial.getOrDefault(id).format
      parsed = parseContent(content, limits)
      if parsed.isErr:
        entry.failures.add parsed.error
    if parsed.isErr and id in initial:
      parsed = parseContent(initial.getOrDefault(id), limits)
    if parsed.isErr:
      if id in initial or id == config.mainListId:
        return err(parsed.error)
    else:
      entry.source = parsed.get
      entry.usable = true
    output.sources.add entry
  ok(output)

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

proc buildCatalogue*(
    config: CatalogueConfig, stored: seq[ListContent] = @[],
    customs: seq[Token] = @[], revision = 1'u64,
    limits = DefaultParseLimits
): Result[Snapshot, TklError] =
  let parsed = ?parseCatalogueSources(config, stored, limits)
  buildFromParsed(parsed, config.chains, config.policy, customs, revision)
