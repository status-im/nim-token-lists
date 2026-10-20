{.push raises: [], gcsafe.}

import ./[builder, keys, planner]
from ./validators import validRegistry
export builder, planner

type
  ChangeKind* = enum
    BootstrapChange, CustomChange, ChainsChange, PolicyChange, NoChange,
    RefreshChange

  Change* = object
    revision*: uint64
    kind*: ChangeKind
    chains*: seq[uint64]
    lists*: seq[string]

  CustomMutationKind* = enum
    UpsertCustom, DeleteCustom

  CustomMutation* = object
    id*: uint64
    kind*: CustomMutationKind
    key*: string
    token*: Token

  PendingCustom = object
    mutation: CustomMutation
    revision: uint64
    epoch: uint64
    customs: seq[Token]
    snapshot: SnapshotRef
    change: Change

  Catalogue* = object
    ## Caller-owned state. Serialize calls that mutate the same instance.
    ## Each publication swaps in one new immutable snapshot; none is mutated.
    config: CatalogueConfig
    parsed: ParsedCatalogue
    customs: seq[Token]
    current: SnapshotRef
    configEpoch: uint64
    nextMutation: uint64
    pending: PendingCustom
    history: seq[Change]
    planner: Planner
    limits: ParseLimits
    refreshId: uint64
    refreshSnapshot: SnapshotRef
    refreshSources: SourceRefresh
    refreshChange: Change
    refreshDiagnostics: seq[TklError]
    diagnostics: seq[TklError]

  CatalogueLoad* = object
    ## An open load: bodies are parsed as they are supplied and dropped.
    config: CatalogueConfig
    stored: seq[ListContent]
    customs: seq[Token]
    limits: ParseLimits
    state: RefreshState
    timeoutSec: int64
    sources: LoadedSources
    storedRegistry, bundledRegistry: Opt[Result[Registry, TklError]]

const ChangeHistoryLimit = 64

func revision*(catalogue: Catalogue): uint64 =
  if catalogue.current.isNil: 0'u64 else: catalogue.current[].revision
func epoch*(catalogue: Catalogue): uint64 = catalogue.configEpoch
func snapshot*(catalogue: Catalogue): Snapshot =
  ## Explicit owned copy for retention, sharing nothing with the catalogue.
  ## Hot queries should use the forwarding functions below while the caller
  ## holds its read lock.
  catalogue.current[].detached
func published*(catalogue: Catalogue): SnapshotRef =
  ## The current snapshot itself, shared rather than copied. See `SnapshotRef`.
  catalogue.current

func getByKey*(catalogue: Catalogue, key: string): Result[Token, TklError] =
  catalogue.current[].getByKey(key)

func getByChainAddress*(
    catalogue: Catalogue, chainId: uint64, address: string
): Result[Token, TklError] =
  catalogue.current[].getByChainAddress(chainId, address)

func getNative*(catalogue: Catalogue, chainId: uint64): Result[Token, TklError] =
  catalogue.current[].getNative(chainId)

func getAll*(
    catalogue: Catalogue, offset = 0, limit = 0
): Result[Page[Token], TklError] =
  catalogue.current[].getAll(offset, limit)

func getByChains*(
    catalogue: Catalogue, chains: openArray[uint64], offset = 0, limit = 0
): Result[Page[Token], TklError] =
  catalogue.current[].getByChains(chains, offset, limit)

func getByKeys*(
    catalogue: Catalogue, keys: openArray[string]
): Result[Page[Token], TklError] =
  catalogue.current[].getByKeys(keys)

func getByChainAddresses*(
    catalogue: Catalogue, pairs: openArray[TokenIdentity]
): Result[Page[Token], TklError] =
  catalogue.current[].getByChainAddresses(pairs)

func getList*(catalogue: Catalogue, id: string): Result[TokenList, TklError] =
  catalogue.current[].getList(id)

func getLists*(catalogue: Catalogue): Page[TokenList] =
  catalogue.current[].getLists()

func getDiagnostics*(catalogue: Catalogue): Page[TklError] =
  catalogue.current[].getDiagnostics()

func describeChange(
    before, after: Snapshot, kind: ChangeKind
): Change =
  let delta = diffSnapshots(before, after)
  Change(revision: after.revision, kind: kind,
    chains: delta.chains, lists: delta.lists)

proc publish(
    catalogue: var Catalogue, next: sink SnapshotRef, change: Change
): Change =
  catalogue.current = next
  if catalogue.history.len == ChangeHistoryLimit:
    catalogue.history.delete(0)
  catalogue.history.add change
  change

proc beginLoad*(
    config: CatalogueConfig, stored: seq[ListContent] = @[],
    customs: seq[Token] = @[], limits = DefaultParseLimits,
    refreshState = RefreshState(), planTimeoutSec = 300'i64
): Result[CatalogueLoad, TklError] =
  ## `stored` is the metadata of the host's persisted lists and registry.
  ## Supply bodies with `loadList`, stored ones first so that bundled lists
  ## replaced by usable stored copies are never parsed; then `finishLoad`.
  if planTimeoutSec <= 0 or refreshState.lastSuccess < 0 or
      refreshState.lastAttempt < 0:
    return err(tklError(InvalidArgument, "InvalidRefreshState"))
  let sources = ?initLoadedSources(config, stored)
  ok(CatalogueLoad(config: config, stored: stored, customs: customs,
    limits: limits, state: refreshState, timeoutSec: planTimeoutSec,
    sources: sources))

func storedRegistryIndex(load: CatalogueLoad): int =
  for index, content in load.stored:
    if content.id == load.config.registryId:
      return index
  -1

proc loadList*(
    load: var CatalogueLoad, id: string, origin: BodyOrigin, body: openArray[char]
): Result[void, TklError] =
  ## Parses one borrowed body; nothing retains it after the call.
  if id.len > 0 and id == load.config.registryId:
    if origin == StoredBody and load.storedRegistryIndex < 0:
      return err(tklError(InvalidArgument, "UnknownStoredList", id))
    let slot = if origin == StoredBody: addr load.storedRegistry
      else: addr load.bundledRegistry
    if slot[].isSome:
      return err(tklError(InvalidArgument, "DuplicateListBody", id))
    if origin == BundledBody and load.storedRegistry.isSome and
        load.storedRegistry.get.isOk:
      slot[] = Opt.some(Result[Registry, TklError].ok(Registry()))
      return ok()
    slot[] = Opt.some(validRegistry(body, id, load.limits))
    return ok()
  load.sources.loadBody(load.config, load.stored, id, origin, body, load.limits)

proc finishLoad*(load: sink CatalogueLoad): Result[Catalogue, TklError] =
  ## Builds and publishes revision one from the supplied bodies.
  var (parsed, contents) = ?load.sources.finishSources(load.config, load.stored)
  var registry = Opt.none(RegistryContent)
  let storedIndex = load.storedRegistryIndex
  if storedIndex >= 0 and load.storedRegistry.isSome and load.storedRegistry.get.isOk:
    registry = Opt.some(RegistryContent(meta: load.stored[storedIndex],
      registry: load.storedRegistry.get.get))
  elif load.bundledRegistry.isSome:
    registry = Opt.some(RegistryContent(meta: ListContent(
      id: load.config.registryId, source: load.config.registryUrl,
      format: RegistryFormat), registry: ?load.bundledRegistry.get))
  let snapshot = share(?buildFromParsed(parsed, load.config.chains,
    load.config.policy, load.customs, 1))
  var planner = ?initPlanner(load.config, move(contents), move(registry),
    load.limits, load.state, load.timeoutSec)
  var catalogue = Catalogue(config: move(load.config), parsed: move(parsed),
    customs: move(load.customs), nextMutation: 1, limits: load.limits,
    planner: move(planner))
  let change = describeChange(Snapshot(), snapshot[], BootstrapChange)
  discard catalogue.publish(snapshot, change)
  ok(catalogue)

func changesSince*(
    catalogue: Catalogue, revision: uint64
): Result[Page[Change], TklError] =
  if revision > catalogue.revision:
    return err(tklError(InvalidArgument, "FutureRevision"))
  if catalogue.history.len > 0 and revision < catalogue.history[0].revision and
      catalogue.history[0].revision - revision > 1:
    return err(tklError(NotFound, "ChangeHistoryExpired"))
  var changes: seq[Change]
  for change in catalogue.history:
    if change.revision > revision:
      changes.add change
  ok(Page[Change](revision: catalogue.revision, total: changes.len, items: changes))

func nextRevision(catalogue: Catalogue): Result[uint64, TklError] =
  if catalogue.revision == high(uint64):
    return err(tklError(Internal, "RevisionExhausted"))
  ok(catalogue.revision + 1)

proc reconfigure(
    catalogue: var Catalogue, chains: seq[uint64], policy: CataloguePolicy,
    kind: ChangeKind
): Result[Change, TklError] =
  if catalogue.configEpoch == high(uint64):
    return err(tklError(Internal, "EpochExhausted"))
  let next = share(?buildFromParsed(catalogue.parsed, chains, policy,
    catalogue.customs, ?catalogue.nextRevision(), catalogue.diagnostics))
  let change = describeChange(catalogue.current[], next[], kind)
  catalogue.config.chains = chains
  catalogue.config.policy = policy
  inc catalogue.configEpoch
  ok(catalogue.publish(next, change))

proc setChains*(
    catalogue: var Catalogue, chains: seq[uint64]
): Result[Change, TklError] =
  if chains == catalogue.config.chains:
    return ok(Change(revision: catalogue.revision, kind: NoChange))
  catalogue.reconfigure(chains, catalogue.config.policy, ChainsChange)

proc setPolicy*(
    catalogue: var Catalogue, policy: CataloguePolicy
): Result[Change, TklError] =
  if policy == catalogue.config.policy:
    return ok(Change(revision: catalogue.revision, kind: NoChange))
  catalogue.reconfigure(catalogue.config.chains, policy, PolicyChange)

proc prepare(
    catalogue: var Catalogue, mutation: CustomMutation
): Result[CustomMutation, TklError] =
  if catalogue.pending.mutation.id != 0:
    return err(tklError(Busy, "CustomMutationPending"))
  if catalogue.nextMutation == high(uint64):
    return err(tklError(Internal, "MutationIdsExhausted"))
  var customs: seq[Token]
  var found = false
  for token in catalogue.customs:
    let key = tokenKey(token.chainId, token.address)
    if key.isOk and key.get == mutation.key:
      if mutation.kind == UpsertCustom:
        customs.add mutation.token
      found = true
    else:
      customs.add token
  if mutation.kind == DeleteCustom and not found:
    return err(tklError(NotFound, "CustomTokenNotFound"))
  if mutation.kind == UpsertCustom and not found:
    customs.add mutation.token
  let next = share(?buildFromParsed(catalogue.parsed, catalogue.config.chains,
    catalogue.config.policy, customs, ?catalogue.nextRevision(), catalogue.diagnostics))
  let change = describeChange(catalogue.current[], next[], CustomChange)
  var proposal = mutation
  proposal.id = catalogue.nextMutation
  inc catalogue.nextMutation
  catalogue.pending = PendingCustom(mutation: proposal,
    revision: catalogue.revision, epoch: catalogue.configEpoch,
    customs: customs, snapshot: next, change: change)
  ok(proposal)

proc customValidateUpsert*(
    catalogue: var Catalogue, token: Token
): Result[CustomMutation, TklError] =
  ?validateCustom(token, catalogue.config.chains)
  var normalized = token
  normalized.address = ?normalizeAddress(token.address)
  normalized.custom = true
  catalogue.prepare(CustomMutation(kind: UpsertCustom, token: normalized,
    key: ?tokenKey(normalized.chainId, normalized.address)))

proc customValidateDelete*(
    catalogue: var Catalogue, key: string
): Result[CustomMutation, TklError] =
  let identity = ?parseKey(key)
  catalogue.prepare(CustomMutation(kind: DeleteCustom,
    key: $identity.chainId & "-" & identity.address))

proc customCommit*(
    catalogue: var Catalogue, mutationId: uint64
): Result[Change, TklError] =
  if mutationId == 0 or mutationId != catalogue.pending.mutation.id:
    return err(tklError(InvalidArgument, "UnknownCustomMutation"))
  var pending = move(catalogue.pending)
  catalogue.pending = PendingCustom()
  if pending.epoch != catalogue.configEpoch or pending.revision != catalogue.revision:
    return err(tklError(SupersededPlan, "CustomMutationSuperseded"))
  catalogue.customs = move(pending.customs)
  ok(catalogue.publish(move(pending.snapshot), pending.change))

proc customAbort*(
    catalogue: var Catalogue, mutationId: uint64
): Result[void, TklError] =
  if mutationId == 0 or mutationId != catalogue.pending.mutation.id:
    return err(tklError(InvalidArgument, "UnknownCustomMutation"))
  catalogue.pending = PendingCustom()
  ok()

func refreshState*(catalogue: Catalogue): RefreshState = catalogue.planner.state

proc clearRefresh(catalogue: var Catalogue) =
  catalogue.refreshId = 0
  catalogue.refreshSnapshot = nil
  catalogue.refreshSources = SourceRefresh()
  catalogue.refreshChange = Change()
  catalogue.refreshDiagnostics = @[]

proc setNetworkAllowed*(catalogue: var Catalogue, allowed: bool) =
  catalogue.planner.setNetworkAllowed(allowed)
  if not allowed:
    catalogue.clearRefresh()

proc setAutoRefresh*(
    catalogue: var Catalogue, enabled: bool, refreshSec, checkSec: int64
): Result[void, TklError] =
  catalogue.planner.setAutoRefresh(enabled, refreshSec, checkSec)

func nextDue*(catalogue: Catalogue, now: int64): Result[Opt[int64], TklError] =
  catalogue.planner.nextDue(now)

proc refreshPlan*(
    catalogue: var Catalogue, now: int64, force = false
): Result[RefreshPlan, TklError] =
  let plan = ?catalogue.planner.startPlan(now, catalogue.revision,
    catalogue.epoch, force)
  catalogue.clearRefresh()
  ok(plan)

proc refreshPutBody*(
    catalogue: var Catalogue, planId: uint64, requestId: string,
    body: openArray[char]
): Result[void, TklError] =
  ## Validates and parses one fetched body of the current round in this call.
  ## The host keeps its own bytes to persist; the catalogue keeps none.
  catalogue.planner.putBody(planId, requestId, body, catalogue.revision,
    catalogue.epoch)

proc refreshApply*(
    catalogue: var Catalogue, planId: uint64, responses: seq[FetchResult], now: int64
): Result[RefreshReport, TklError] =
  let report = ?catalogue.planner.applyResults(planId, responses, now,
    catalogue.revision, catalogue.epoch)
  if report.step == RefreshStep.Ready:
    var updates = catalogue.planner.takeUpdates()
    var sources = refreshSources(catalogue.parsed, catalogue.config,
      catalogue.planner.preparedContents, updates)
    if sources.isErr:
      discard catalogue.planner.abortPlan(planId, Aborted)
      return err(sources.error)
    let revision = ?catalogue.nextRevision()
    if sources.get.unchanged and report.diagnostics == catalogue.diagnostics:
      # Same parsed lists, chains, policy, customs and diagnostics would
      # rebuild the current snapshot, so commit publishes nothing.
      catalogue.refreshChange = Change(revision: revision, kind: RefreshChange)
    else:
      var next = sources.get.buildFromRefresh(catalogue.parsed,
        catalogue.config.chains, catalogue.config.policy, catalogue.customs,
        revision, report.diagnostics)
      if next.isErr:
        discard catalogue.planner.abortPlan(planId, Aborted)
        return err(next.error)
      let shared = share(next.get)
      catalogue.refreshChange = describeChange(catalogue.current[], shared[],
        RefreshChange)
      catalogue.refreshSnapshot = shared
    catalogue.refreshId = planId
    catalogue.refreshSources = move(sources.get)
    catalogue.refreshDiagnostics = report.diagnostics
  ok(report)

proc refreshCommit*(
    catalogue: var Catalogue, planId: uint64, now: int64
): Result[Change, TklError] =
  ?catalogue.planner.checkPlan(planId, now, catalogue.revision, catalogue.epoch)
  if catalogue.refreshId != planId:
    return err(tklError(InvalidArgument, "RefreshNotPrepared"))
  let changed = catalogue.refreshChange.chains.len > 0 or
    catalogue.refreshChange.lists.len > 0 or
    catalogue.refreshDiagnostics != catalogue.diagnostics
  ?catalogue.planner.commitPlan(planId, now, catalogue.revision, catalogue.epoch)
  catalogue.parsed.adoptSources(move(catalogue.refreshSources))
  catalogue.diagnostics = move(catalogue.refreshDiagnostics)
  let change = if changed:
      catalogue.publish(move(catalogue.refreshSnapshot), catalogue.refreshChange)
    else: Change(revision: catalogue.revision, kind: NoChange)
  catalogue.clearRefresh()
  ok(change)

proc refreshAbort*(
    catalogue: var Catalogue, planId: uint64, reason = Aborted
): Result[void, TklError] =
  ?catalogue.planner.abortPlan(planId, reason)
  catalogue.clearRefresh()
  ok()
