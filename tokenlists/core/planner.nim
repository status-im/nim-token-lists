{.push raises: [], gcsafe.}

import std/[sets, tables]
import ./[types, validators]
import ./parsers/[registry, standard, status]
export types

type
  RefreshOutcome* {.pure.} = enum
    Full, Partial, Unchanged, Failed

  SourceOutcome* {.pure.} = enum
    Updated, Unchanged304, UnchangedSameEtag, FetchFailed, InvalidContent,
    UnsupportedSchema, TooLarge

  RefreshStep* {.pure.} = enum
    NeedMore, Ready, Failed

  FetchRequest* = object
    id*: string
    url*: string
    etag*: string
    format*: ListFormat

  FetchResult* = object
    id*: string
    status*: int
    body*: string
    etag*: string
    failure*: TklError

  SourceReport* = object
    id*: string
    outcome*: SourceOutcome
    error*: TklError

  RefreshPlan* = object
    id*: uint64
    expiresAt*: int64
    requests*: seq[FetchRequest]

  RefreshReport* = object
    step*: RefreshStep
    outcome*: RefreshOutcome
    requests*: seq[FetchRequest]
    writes*: seq[ListContent]
    sources*: seq[SourceReport]
    diagnostics*: seq[TklError]

  RefreshState* = object
    lastSuccess*: int64
    lastAttempt*: int64
    lastOutcome*: RefreshOutcome
    hasSuccess*: bool
    hasAttempt*: bool

  PlanPhase = enum
    Idle, RegistryRound, ListRound, Prepared

  Planner* = object
    config: CatalogueConfig
    limits: ParseLimits
    contents: seq[ListContent]
    registry: ListContent
    candidate: seq[ListContent]
    candidateRegistry: ListContent
    phase: PlanPhase
    plan: RefreshPlan
    baseRevision, baseEpoch, nextId: uint64
    report: RefreshReport
    state: RefreshState
    enabled, networkAllowed: bool
    refreshSec, checkSec, timeoutSec: int64

func state*(planner: Planner): RefreshState = planner.state
func preparedContents*(planner: Planner): seq[ListContent] = planner.candidate
func hasWrites*(planner: Planner): bool = planner.report.writes.len > 0

func findContent(contents: seq[ListContent], id: string): Opt[ListContent] =
  for content in contents:
    if content.id == id:
      return Opt.some(content)
  Opt.none(ListContent)

proc putContent(contents: var seq[ListContent], content: ListContent) =
  for entry in contents.mitems:
    if entry.id == content.id:
      entry = content
      return
  contents.add content

proc initPlanner*(
    config: CatalogueConfig, stored: seq[ListContent], limits: ParseLimits,
    state = RefreshState(), timeoutSec = 300'i64
): Result[Planner, TklError] =
  if timeoutSec <= 0 or state.lastSuccess < 0 or state.lastAttempt < 0:
    return err(tklError(InvalidArgument, "InvalidRefreshState"))
  var planner = Planner(config: config, limits: limits, nextId: 1,
    networkAllowed: true, refreshSec: 1800, checkSec: 180,
    timeoutSec: timeoutSec, state: state)
  for content in config.initialLists:
    planner.contents.putContent(content)
  for content in stored:
    if content.id == config.registryId and config.registryId.len > 0:
      if validateDocument(content.body, RegistryFormat, content.id, limits).isOk:
        planner.registry = content
    elif content.failure.code == Ok:
      var storedContent = content
      for initial in config.initialLists:
        if initial.id == content.id:
          storedContent.format = initial.format
      let valid = case storedContent.format
        of StandardFormat:
          decodeStandardSource(content.body, content.id, limits).isOk
        of StatusFormat:
          decodeStatusSource(content.body, content.id, limits).isOk
        of RegistryFormat: false
      if valid:
        planner.contents.putContent(storedContent)
  if planner.registry.body.len == 0 and config.embeddedRegistry.len > 0:
    ?validateDocument(config.embeddedRegistry, RegistryFormat,
      config.registryId, limits)
    planner.registry = ListContent(id: config.registryId,
      source: config.registryUrl, body: config.embeddedRegistry,
      format: RegistryFormat)
  ok(planner)

proc clearPlan(planner: var Planner) =
  planner.phase = Idle
  planner.plan = RefreshPlan()
  planner.candidate = @[]
  planner.candidateRegistry = ListContent()
  planner.report = RefreshReport()

proc setNetworkAllowed*(planner: var Planner, allowed: bool) =
  planner.networkAllowed = allowed
  if not allowed:
    planner.clearPlan()

proc setAutoRefresh*(
    planner: var Planner, enabled: bool, refreshSec, checkSec: int64
): Result[void, TklError] =
  if refreshSec <= 0 or checkSec <= 0:
    return err(tklError(InvalidArgument, "InvalidRefreshInterval"))
  planner.enabled = enabled
  planner.refreshSec = refreshSec
  planner.checkSec = checkSec
  ok()

func saturatingAdd(value, delta: int64): int64 =
  if value > high(int64) - delta: high(int64) else: value + delta

func nextDue*(planner: Planner, now: int64): Result[Opt[int64], TklError] =
  if now < 0:
    return err(tklError(InvalidArgument, "InvalidTime"))
  if not planner.enabled or not planner.networkAllowed:
    return ok(Opt.none(int64))
  var due = now
  if planner.state.hasSuccess or planner.state.lastSuccess > 0:
    due = max(due, saturatingAdd(planner.state.lastSuccess, planner.refreshSec))
  if planner.state.hasAttempt or planner.state.lastAttempt > 0:
    due = max(due, saturatingAdd(planner.state.lastAttempt, planner.checkSec))
  if planner.phase != Idle:
    due = max(due, planner.plan.expiresAt)
  ok(Opt.some(due))

proc startPlan*(
    planner: var Planner, now: int64, revision, epoch: uint64, force = false
): Result[RefreshPlan, TklError] =
  if now < 0 or now > high(int64) - planner.timeoutSec:
    return err(tklError(InvalidArgument, "InvalidTime"))
  if not planner.networkAllowed:
    return err(tklError(Aborted, "NetworkDisabled"))
  if planner.phase != Idle and now < planner.plan.expiresAt and not force:
    return err(tklError(Busy, "RefreshPending"))
  if not force:
    let due = ?planner.nextDue(now)
    if due.isNone or due.get > now:
      return err(tklError(Unchanged, "RefreshNotDue"))
  if planner.config.registryId.len == 0 or planner.config.registryUrl.len == 0:
    return err(tklError(InvalidArgument, "MissingRegistry"))
  if planner.nextId == high(uint64):
    return err(tklError(Internal, "PlanIdsExhausted"))
  planner.clearPlan()
  planner.plan = RefreshPlan(id: planner.nextId,
    expiresAt: now + planner.timeoutSec,
    requests: @[FetchRequest(id: planner.config.registryId,
      url: planner.config.registryUrl,
      etag: (if planner.registry.source == planner.config.registryUrl and
        planner.registry.format == RegistryFormat: planner.registry.etag else: ""),
      format: RegistryFormat)])
  inc planner.nextId
  planner.phase = RegistryRound
  planner.baseRevision = revision
  planner.baseEpoch = epoch
  planner.candidate = planner.contents
  planner.candidateRegistry = planner.registry
  planner.state.lastAttempt = now
  planner.state.hasAttempt = true
  ok(planner.plan)

proc checkPlan*(
    planner: var Planner, id: uint64, now: int64, revision, epoch: uint64
): Result[void, TklError] =
  if now < 0:
    return err(tklError(InvalidArgument, "InvalidTime"))
  if id == 0 or planner.phase == Idle or id != planner.plan.id:
    return err(tklError(InvalidArgument, "UnknownRefreshPlan"))
  if now < planner.state.lastAttempt:
    return err(tklError(InvalidArgument, "TimeBeforePlan"))
  if now >= planner.plan.expiresAt:
    planner.clearPlan()
    return err(tklError(Aborted, "PlanExpired"))
  if revision != planner.baseRevision or epoch != planner.baseEpoch:
    planner.clearPlan()
    return err(tklError(SupersededPlan, "RefreshSuperseded"))
  ok()

func fallbackFormat(planner: Planner, id: string): ListFormat =
  for content in planner.config.initialLists:
    if content.id == id:
      return content.format
  StandardFormat

proc acceptResponse(
    planner: var Planner, request: FetchRequest, response: FetchResult, now: int64
): SourceReport =
  let previous = if request.format == RegistryFormat:
      (if planner.registry.body.len > 0: Opt.some(planner.registry)
       else: Opt.none(ListContent))
    else: findContent(planner.contents, request.id)
  template rejected(kind: SourceOutcome, code: TklStatus, detail: string): untyped =
    return SourceReport(id: request.id, outcome: kind,
      error: tklError(code, detail, request.id))
  if response.body.len > planner.limits.maxBytes or
      response.failure.detail == "tooLarge":
    rejected(SourceOutcome.TooLarge, InvalidContent, "TooLarge")
  if response.failure.code != Ok:
    return SourceReport(id: request.id, outcome: SourceOutcome.FetchFailed,
      error: tklError(response.failure.code, response.failure.detail, request.id))
  let sameSource = previous.isSome and previous.get.source == request.url and
    previous.get.format == request.format
  if response.status == 304:
    if previous.isNone or not sameSource or request.etag.len == 0:
      rejected(SourceOutcome.FetchFailed, NetworkFailure, "Unexpected304")
    return SourceReport(id: request.id, outcome: SourceOutcome.Unchanged304)
  if response.status != 200:
    rejected(SourceOutcome.FetchFailed, NetworkFailure, "HttpStatus")
  if sameSource and response.etag.len > 0 and response.etag == request.etag:
    return SourceReport(id: request.id, outcome: SourceOutcome.UnchangedSameEtag)
  let valid = validateDocument(response.body, request.format, request.id, planner.limits)
  if valid.isErr:
    return SourceReport(id: request.id, outcome: SourceOutcome.InvalidContent,
      error: valid.error)
  let content = ListContent(id: request.id, source: request.url,
    body: response.body, etag: response.etag, format: request.format,
    fetchedAt: now, fetchedTimestamp: $now)
  planner.report.writes.add content
  if request.format == RegistryFormat:
    planner.candidateRegistry = content
  else:
    planner.candidate.putContent(content)
  SourceReport(id: request.id, outcome: SourceOutcome.Updated)

proc finishReport(planner: var Planner): RefreshReport =
  var failures, successes: int
  for source in planner.report.sources:
    if source.outcome in {SourceOutcome.Updated, SourceOutcome.Unchanged304,
        SourceOutcome.UnchangedSameEtag}:
      inc successes
    else:
      inc failures
  planner.report.outcome =
    if successes == 0 and failures > 0: RefreshOutcome.Failed
    elif failures > 0: RefreshOutcome.Partial
    elif planner.report.writes.len == 0: RefreshOutcome.Unchanged
    else: RefreshOutcome.Full
  if planner.report.outcome == RefreshOutcome.Failed:
    var report = planner.report
    report.step = RefreshStep.Failed
    planner.state.lastOutcome = RefreshOutcome.Failed
    planner.clearPlan()
    return report
  planner.phase = Prepared
  planner.report.step = RefreshStep.Ready
  planner.report.requests = @[]
  planner.report

proc applyResults*(
    planner: var Planner, id: uint64, responses: seq[FetchResult],
    now: int64, revision, epoch: uint64
): Result[RefreshReport, TklError] =
  ?planner.checkPlan(id, now, revision, epoch)
  if planner.phase notin {RegistryRound, ListRound}:
    return err(tklError(InvalidArgument, "RefreshAlreadyApplied"))
  # Validate the entire batch before changing candidate state. Order is irrelevant.
  var byId: Table[string, FetchResult]
  for response in responses:
    if response.id in byId:
      return err(tklError(InvalidArgument, "DuplicateFetchResult", response.id))
    byId[response.id] = response
  if byId.len != planner.plan.requests.len:
    return err(tklError(InvalidArgument, "IncompleteFetchResults"))
  for request in planner.plan.requests:
    if request.id notin byId:
      return err(tklError(InvalidArgument, "UnexpectedFetchResult"))
  for request in planner.plan.requests:
    planner.report.sources.add planner.acceptResponse(request,
      byId.getOrDefault(request.id), now)
  if planner.phase == ListRound:
    return ok(planner.finishReport())
  if planner.candidateRegistry.body.len == 0:
    let report = RefreshReport(step: RefreshStep.Failed,
      outcome: RefreshOutcome.Failed, sources: planner.report.sources,
      diagnostics: @[tklError(InvalidContent, "RegistryUnavailable")])
    planner.state.lastOutcome = RefreshOutcome.Failed
    planner.clearPlan()
    return ok(report)
  let registry = ?parseRegistry(planner.candidateRegistry.body,
    planner.config.registryId, planner.limits)
  var requests: seq[FetchRequest]
  var present: HashSet[string]
  for source in registry.tokenLists:
    present.incl source.id
    let format = resolveFormat(source.schema, planner.fallbackFormat(source.id))
    let initial = findContent(planner.config.initialLists, source.id)
    if source.id in ["native", "custom", planner.config.registryId] or
        format.isErr or (format.isOk and (format.get == RegistryFormat or
          (initial.isSome and initial.get.format != format.get))):
      planner.report.sources.add SourceReport(id: source.id,
        outcome: SourceOutcome.UnsupportedSchema,
        error: tklError(UnsupportedSchema, "UnsupportedSource", source.id))
      continue
    let previous = findContent(planner.contents, source.id)
    let etag = if previous.isSome and previous.get.source == source.sourceUrl and
        previous.get.format == format.get: previous.get.etag else: ""
    requests.add FetchRequest(id: source.id, url: source.sourceUrl,
      etag: etag, format: format.get)
  for content in planner.contents:
    if content.id notin present:
      planner.report.diagnostics.add tklError(NotFound, "OrphanedSource", content.id)
  if requests.len == 0:
    return ok(planner.finishReport())
  planner.phase = ListRound
  planner.plan.requests = requests
  ok(RefreshReport(step: RefreshStep.NeedMore, requests: requests,
    sources: planner.report.sources, diagnostics: planner.report.diagnostics))

proc commitPlan*(
    planner: var Planner, id: uint64, now: int64, revision, epoch: uint64
): Result[void, TklError] =
  ?planner.checkPlan(id, now, revision, epoch)
  if planner.phase != Prepared:
    return err(tklError(InvalidArgument, "RefreshNotPrepared"))
  planner.contents = move(planner.candidate)
  planner.registry = move(planner.candidateRegistry)
  planner.state.lastSuccess = now
  planner.state.hasSuccess = true
  planner.state.lastOutcome = planner.report.outcome
  planner.clearPlan()
  ok()

proc abortPlan*(
    planner: var Planner, id: uint64, reason: TklStatus
): Result[void, TklError] =
  if id == 0 or id != planner.plan.id or planner.phase == Idle:
    return err(tklError(InvalidArgument, "UnknownRefreshPlan"))
  if reason notin {Aborted, StorageFailure, NetworkFailure}:
    return err(tklError(InvalidArgument, "InvalidAbortReason"))
  planner.state.lastOutcome = RefreshOutcome.Failed
  planner.clearPlan()
  ok()
