{.push raises: [], gcsafe.}

import std/[algorithm, sets]
import ./[builder, keys]
export builder

type
  ChangeKind* = enum
    BootstrapChange, CustomChange, ChainsChange, PolicyChange, NoChange

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

  Catalogue* = object
    ## Caller-owned state. Serialize calls that mutate the same instance.
    ## Queries use independent immutable value snapshots, never shared refs.
    config: CatalogueConfig
    stored: seq[ListContent]
    customs: seq[Token]
    limits: ParseLimits
    current: Snapshot
    configEpoch: uint64
    nextMutation: uint64
    pending: PendingCustom
    history: seq[Change]

const ChangeHistoryLimit = 64

func revision*(catalogue: Catalogue): uint64 = catalogue.current.revision
func epoch*(catalogue: Catalogue): uint64 = catalogue.configEpoch
func snapshot*(catalogue: Catalogue): Snapshot = catalogue.current

func describeChange(before, after: Snapshot, kind: ChangeKind): Change =
  var
    chains: HashSet[uint64]
    lists: HashSet[string]
    change = Change(revision: after.revision, kind: kind)
  for snapshot in [before, after]:
    for list in snapshot.getLists().items:
      lists.incl list.id
      for token in list.tokens:
        chains.incl token.chainId
  for chain in chains:
    if before.getByChains([chain]).get.items != after.getByChains([chain]).get.items:
      change.chains.add chain
  for id in lists:
    if before.getList(id) != after.getList(id):
      change.lists.add id
  change.chains.sort()
  change.lists.sort()
  change

proc publish(catalogue: var Catalogue, next: sink Snapshot, kind: ChangeKind): Change =
  let change = describeChange(catalogue.current, next, kind)
  catalogue.current = next
  if catalogue.history.len == ChangeHistoryLimit:
    catalogue.history.delete(0)
  catalogue.history.add change
  change

proc initCatalogue*(
    config: CatalogueConfig, stored: seq[ListContent] = @[],
    customs: seq[Token] = @[], limits = DefaultParseLimits
): Result[Catalogue, TklError] =
  let snapshot = ?buildCatalogue(config, stored, customs, 1, limits)
  var catalogue = Catalogue(config: config, stored: stored,
    customs: customs, limits: limits, nextMutation: 1)
  discard catalogue.publish(snapshot, BootstrapChange)
  ok(catalogue)

func changesSince*(
    catalogue: Catalogue, revision: uint64
): Result[Page[Change], TklError] =
  if revision > catalogue.revision:
    return err(tklError(InvalidArgument, "FutureRevision"))
  if catalogue.history.len > 0 and revision < catalogue.history[0].revision - 1:
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
  let next = ?buildCatalogue(config, catalogue.stored, catalogue.customs,
    ?catalogue.nextRevision(), catalogue.limits)
  catalogue.config = config
  inc catalogue.configEpoch
  ok(catalogue.publish(next, kind))

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
      if not found and mutation.kind == UpsertCustom:
        customs.add mutation.token
      found = true
    else:
      customs.add token
  if mutation.kind == DeleteCustom and not found:
    return err(tklError(NotFound, "CustomTokenNotFound"))
  if mutation.kind == UpsertCustom and not found:
    customs.add mutation.token
  let next = ?buildCatalogue(catalogue.config, catalogue.stored, customs,
    ?catalogue.nextRevision(), catalogue.limits)
  var proposal = mutation
  proposal.id = catalogue.nextMutation
  inc catalogue.nextMutation
  catalogue.pending = PendingCustom(mutation: proposal,
    revision: catalogue.revision, epoch: catalogue.configEpoch,
    customs: customs, snapshot: next)
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
  ok(catalogue.publish(pending.snapshot, CustomChange))

proc customAbort*(
    catalogue: var Catalogue, mutationId: uint64
): Result[void, TklError] =
  if mutationId == 0 or mutationId != catalogue.pending.mutation.id:
    return err(tklError(InvalidArgument, "UnknownCustomMutation"))
  catalogue.pending = PendingCustom()
  ok()
