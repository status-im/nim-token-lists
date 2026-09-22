{.push raises: [], gcsafe.}

import std/[algorithm, sets, tables]
import ./[types, keys, snapshot]
import ./parsers/[standard, status]
export types, snapshot

proc parseContent(
    content: ListContent, chains: seq[uint64], limits: ParseLimits
): Result[ParsedList, TklError] =
  if content.failure.code != Ok:
    return err(tklError(content.failure.code, content.failure.detail, content.id))
  if content.body.len == 0:
    return err(tklError(InvalidContent, "EmptyListContent", content.id))
  let parsed = case content.format
    of StandardFormat: parseStandard(content.body, chains, content.id, limits)
    of StatusFormat: parseStatus(content.body, chains, content.id, limits)
    of RegistryFormat: err(tklError(UnsupportedSchema, "RegistryIsNotTokenList", content.id))
  var value = ?parsed
  value.list.source = content.source
  value.list.fetchedTimestamp = content.fetchedTimestamp
  ok(value)

proc buildCatalogue*(
    config: CatalogueConfig, stored: seq[ListContent] = @[],
    customs: seq[Token] = @[], revision = 1'u64,
    limits = DefaultParseLimits
): Result[Snapshot, TklError] =
  var chains: HashSet[uint64]
  for chain in config.chains:
    if chain in chains:
      return err(tklError(InvalidArgument, "DuplicateChain"))
    chains.incl chain
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

  var descriptors: Table[uint64, Token]
  for descriptor in config.policy.nativeTokens:
    if descriptor.chainId in descriptors or
        normalizeAddress(descriptor.address).isErr or
        normalizeAddress(descriptor.address).get != NativeAddress:
      return err(tklError(InvalidArgument, "InvalidNativeDescriptor"))
    descriptors[descriptor.chainId] = descriptor
  var nativeList = TokenList(id: "native", name: "Native tokens")
  for chain in config.chains:
    var token = descriptors.getOrDefault(chain, Token(chainId: chain,
      address: NativeAddress, symbol: "ETH", name: "Ethereum",
      crossChainId: "eth-native", decimals: 18))
    token.address = NativeAddress
    token.custom = false
    nativeList.tokens.add token

  var lists = @[nativeList]
  var diagnostics: seq[TklError]
  var customList = TokenList(id: "custom", name: "Custom tokens")
  for token in customs:
    let valid = validateCustom(token, config.chains)
    if valid.isErr:
      diagnostics.add tklError(valid.error.code, valid.error.detail, "custom")
      continue
    var normalized = token
    normalized.address = normalizeAddress(token.address).get
    normalized.custom = true
    customList.tokens.add normalized
  if config.policy.priority == CustomFirstPriority:
    lists.add customList

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
  for id in order:
    var parsed = Result[ParsedList, TklError].err(
      tklError(NotFound, "MissingStoredList", id))
    if id in cached:
      var content = cached.getOrDefault(id)
      if id in initial:
        content.format = initial.getOrDefault(id).format
      parsed = parseContent(content, config.chains, limits)
      if parsed.isErr:
        diagnostics.add parsed.error
    if parsed.isErr and id in initial:
      parsed = parseContent(initial.getOrDefault(id), config.chains, limits)
    if parsed.isErr:
      if id in initial or id == config.mainListId:
        return err(parsed.error)
      continue
    let value = parsed.get
    lists.add value.list
    for diagnostic in value.diagnostics:
      diagnostics.add diagnostic.error
  if config.policy.priority == StatusPriority:
    lists.add customList
  initSnapshot(lists, config.policy, diagnostics, revision)
