{.push raises: [], gcsafe.}

import ./[builder, keys, planner]
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
    snapshot: Snapshot
    change: Change

  Catalogue* = object
    ## Caller-owned state. Serialize calls that mutate the same instance.
    ## Queries use independent immutable value snapshots, never shared refs.
    config: CatalogueConfig
    parsed: ParsedCatalogue
    customs: seq[Token]
    current: Snapshot
    configEpoch: uint64
    nextMutation: uint64
    pending: PendingCustom
    history: seq[Change]
    planner: Planner
    limits: ParseLimits
    refreshId: uint64
    refreshSnapshot: Snapshot
    refreshParsed: ParsedCatalogue
    refreshChange: Change
    refreshDiagnostics: seq[TklError]
    diagnostics: seq[TklError]

const ChangeHistoryLimit = 64

func revision*(catalogue: Catalogue): uint64 = catalogue.current.revision
func epoch*(catalogue: Catalogue): uint64 = catalogue.configEpoch
func snapshot*(catalogue: Catalogue): Snapshot =
  ## Explicit owned copy for retention. Hot queries should use the forwarding
  ## functions below while the caller holds its read lock.
  catalogue.current

func getByKey*(catalogue: Catalogue, key: string): Result[Token, TklError] =
  catalogue.current.getByKey(key)

func getByChainAddress*(
    catalogue: Catalogue, chainId: uint64, address: string
): Result[Token, TklError] =
  catalogue.current.getByChainAddress(chainId, address)

func getNative*(catalogue: Catalogue, chainId: uint64): Result[Token, TklError] =
  catalogue.current.getNative(chainId)

func getAll*(
    catalogue: Catalogue, offset = 0, limit = 0
): Result[Page[Token], TklError] =
  catalogue.current.getAll(offset, limit)

func getByChains*(
    catalogue: Catalogue, chains: openArray[uint64], offset = 0, limit = 0
): Result[Page[Token], TklError] =
  catalogue.current.getByChains(chains, offset, limit)

func getByKeys*(
    catalogue: Catalogue, keys: openArray[string]
): Result[Page[Token], TklError] =
  catalogue.current.getByKeys(keys)

func getList*(catalogue: Catalogue, id: string): Result[TokenList, TklError] =
  catalogue.current.getList(id)

func getLists*(catalogue: Catalogue): Page[TokenList] =
  catalogue.current.getLists()

func getDiagnostics*(catalogue: Catalogue): Page[TklError] =
  catalogue.current.getDiagnostics()

func describeChange(
    before, after: Snapshot, kind: ChangeKind
): Change =
  let delta = diffSnapshots(before, after)
  Change(revision: after.revision, kind: kind,
    chains: delta.chains, lists: delta.lists)

proc publish(
    catalogue: var Catalogue, next: sink Snapshot, change: Change
): Change =
  catalogue.current = next
  if catalogue.history.len == ChangeHistoryLimit:
    catalogue.history.delete(0)
  catalogue.history.add change
  change

proc initCatalogue*(
    config: CatalogueConfig, stored: seq[ListContent] = @[],
    customs: seq[Token] = @[], limits = DefaultParseLimits,
    refreshState = RefreshState(), planTimeoutSec = 300'i64
): Result[Catalogue, TklError] =
  let parsed = ?parseCatalogueSources(config, stored, limits)
  let snapshot = ?buildFromParsed(parsed, config.chains, config.policy, customs, 1)
  var catalogue = Catalogue(config: config, parsed: parsed,
    customs: customs, nextMutation: 1, limits: limits,
    planner: ?initPlanner(config, stored, limits, refreshState, planTimeoutSec))
  let change = describeChange(catalogue.current, snapshot, BootstrapChange)
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
    catalogue: var Catalogue, config: CatalogueConfig, kind: ChangeKind
): Result[Change, TklError] =
  if catalogue.configEpoch == high(uint64):
    return err(tklError(Internal, "EpochExhausted"))
  let next = ?buildFromParsed(catalogue.parsed, config.chains, config.policy,
    catalogue.customs, ?catalogue.nextRevision(), catalogue.diagnostics)
  let change = describeChange(catalogue.current, next, kind)
  catalogue.config = config
  inc catalogue.configEpoch
  ok(catalogue.publish(next, change))

proc setChains*(
    catalogue: var Catalogue, chains: seq[uint64]
): Result[Change, TklError] =
  if chains == catalogue.config.chains:
    return ok(Change(revision: catalogue.revision, kind: NoChange))
  var config = catalogue.config
  config.chains = chains
  catalogue.reconfigure(config, ChainsChange)

proc setPolicy*(
    catalogue: var Catalogue, policy: CataloguePolicy
): Result[Change, TklError] =
  if policy == catalogue.config.policy:
    return ok(Change(revision: catalogue.revision, kind: NoChange))
  var config = catalogue.config
  config.policy = policy
  catalogue.reconfigure(config, PolicyChange)

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
  let next = ?buildFromParsed(catalogue.parsed, catalogue.config.chains,
    catalogue.config.policy, customs, ?catalogue.nextRevision(), catalogue.diagnostics)
  let change = describeChange(catalogue.current, next, CustomChange)
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
  let pending = move(catalogue.pending)
  catalogue.pending = PendingCustom()
  if pending.epoch != catalogue.configEpoch or pending.revision != catalogue.revision:
    return err(tklError(SupersededPlan, "CustomMutationSuperseded"))
  catalogue.customs = pending.customs
  ok(catalogue.publish(pending.snapshot, pending.change))

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
  catalogue.refreshSnapshot = Snapshot()
  catalogue.refreshParsed = ParsedCatalogue()
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

proc refreshApply*(
    catalogue: var Catalogue, planId: uint64, responses: seq[FetchResult], now: int64
): Result[RefreshReport, TklError] =
  let report = ?catalogue.planner.applyResults(planId, responses, now,
    catalogue.revision, catalogue.epoch)
  if report.step == RefreshStep.Ready:
    let parsed = parseCatalogueSources(catalogue.config,
      catalogue.planner.preparedContents, catalogue.limits)
    if parsed.isErr:
      discard catalogue.planner.abortPlan(planId, Aborted)
      return err(parsed.error)
    let next = buildFromParsed(parsed.get, catalogue.config.chains,
      catalogue.config.policy, catalogue.customs, ?catalogue.nextRevision(),
      report.diagnostics)
    if next.isErr:
      discard catalogue.planner.abortPlan(planId, Aborted)
      return err(next.error)
    catalogue.refreshId = planId
    catalogue.refreshParsed = parsed.get
    catalogue.refreshSnapshot = next.get
    catalogue.refreshChange = describeChange(catalogue.current, next.get, RefreshChange)
    catalogue.refreshDiagnostics = report.diagnostics
  ok(report)

proc refreshCommit*(
    catalogue: var Catalogue, planId: uint64, now: int64
): Result[Change, TklError] =
  ?catalogue.planner.checkPlan(planId, now, catalogue.revision, catalogue.epoch)
  if catalogue.refreshId != planId:
    return err(tklError(InvalidArgument, "RefreshNotPrepared"))
  let changed = catalogue.planner.hasWrites or
    catalogue.refreshChange.chains.len > 0 or catalogue.refreshChange.lists.len > 0 or
    catalogue.refreshDiagnostics != catalogue.diagnostics
  ?catalogue.planner.commitPlan(planId, now, catalogue.revision, catalogue.epoch)
  catalogue.parsed = move(catalogue.refreshParsed)
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
