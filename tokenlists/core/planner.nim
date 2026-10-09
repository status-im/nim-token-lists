{.push raises: [], gcsafe.}

import std/[sets, tables, times]
import ./[types, validators]
import ./parsers/[lists, registry]
export types

const
  LastRfc3339Second = 253402300799'i64 # 9999-12-31T23:59:59Z
  FetchedTimeFormat = initTimeFormat("yyyy-MM-dd'T'HH:mm:ss'Z'")

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
    ## Bodies of 200 responses are passed separately with `putBody`.
    id*: string
    status*: int
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

  RegistryContent* = object
    ## A registry parsed from a borrowed body, with its fetch metadata.
    meta*: ListContent
    registry*: Registry

  PlanPhase = enum
    Idle, RegistryRound, ListRound, Prepared

  ReceivedBody = object
    ## A fetched body validated and parsed in the call that borrowed it.
    id: string
    bodyLen: int
    tooLarge: bool
    error: TklError
    source: ParsedSource
    registry: Registry

  Planner* = object
    config: CatalogueConfig
    limits: ParseLimits
    contents: seq[ListContent]
    registry: Opt[RegistryContent]
    candidate: seq[ListContent]
    candidateRegistry: Opt[RegistryContent]
    received: seq[ReceivedBody]
    updates: seq[ParsedContent]
    phase: PlanPhase
    plan: RefreshPlan
    baseRevision, baseEpoch, nextId: uint64
    report: RefreshReport
    state: RefreshState
    enabled, networkAllowed: bool
    refreshSec, checkSec, timeoutSec: int64
    lastSeen: int64

func state*(planner: Planner): RefreshState = planner.state
func preparedContents*(planner: Planner): lent seq[ListContent] = planner.candidate

proc takeUpdates*(planner: var Planner): seq[ParsedContent] =
  ## Lists parsed by the prepared run, moved out for the candidate build.
  move(planner.updates)

func findContent(contents: seq[ListContent], id: string): int =
  for index, content in contents:
    if content.id == id:
      return index
  -1

proc putContent(contents: var seq[ListContent], content: sink ListContent) =
  let index = contents.findContent(content.id)
  if index >= 0:
    contents[index] = content
  else:
    contents.add content

proc initPlanner*(
    config: CatalogueConfig, contents: sink seq[ListContent],
    registry: sink Opt[RegistryContent], limits: ParseLimits,
    state = RefreshState(), timeoutSec = 300'i64
): Result[Planner, TklError] =
  ## `contents` is the metadata of every usable list the catalogue was built
  ## from; `registry` the usable stored or bundled registry, if any.
  if timeoutSec <= 0 or state.lastSuccess < 0 or state.lastAttempt < 0:
    return err(tklError(InvalidArgument, "InvalidRefreshState"))
  ok(Planner(config: config, limits: limits, nextId: 1,
    networkAllowed: true, refreshSec: 1800, checkSec: 180,
    timeoutSec: timeoutSec, state: state, contents: contents, registry: registry))

proc clearPlan(planner: var Planner) =
  planner.phase = Idle
  planner.plan = RefreshPlan()
  planner.candidate = @[]
  planner.candidateRegistry = Opt.none(RegistryContent)
  planner.received = @[]
  planner.updates = @[]
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
  if now < 0 or now > LastRfc3339Second or
      now > high(int64) - planner.timeoutSec:
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
      etag: (if planner.registry.isSome and
        planner.registry.get.meta.source == planner.config.registryUrl and
        planner.registry.get.meta.format == RegistryFormat:
          planner.registry.get.meta.etag else: ""),
      format: RegistryFormat)])
  inc planner.nextId
  planner.phase = RegistryRound
  planner.baseRevision = revision
  planner.baseEpoch = epoch
  planner.candidate = planner.contents
  planner.candidateRegistry = planner.registry
  planner.state.lastAttempt = now
  planner.state.hasAttempt = true
  planner.lastSeen = now
  ok(planner.plan)

proc checkPlan*(
    planner: var Planner, id: uint64, now: int64, revision, epoch: uint64
): Result[void, TklError] =
  if now < 0 or now > LastRfc3339Second:
    return err(tklError(InvalidArgument, "InvalidTime"))
  if id == 0 or planner.phase == Idle or id != planner.plan.id:
    return err(tklError(InvalidArgument, "UnknownRefreshPlan"))
  if now < planner.lastSeen:
    return err(tklError(InvalidArgument, "TimeBeforePlan"))
  if now >= planner.plan.expiresAt:
    planner.clearPlan()
    return err(tklError(Aborted, "PlanExpired"))
  if revision != planner.baseRevision or epoch != planner.baseEpoch:
    planner.clearPlan()
    return err(tklError(SupersededPlan, "RefreshSuperseded"))
  planner.lastSeen = now
  ok()

func fallbackFormat(planner: Planner, id: string): ListFormat =
  for content in planner.config.initialLists:
    if content.id == id:
      return content.format
  StandardFormat

func utcTime(time: Time): ZonedTime =
  ZonedTime(time: time, utcOffset: 0, isDst: false)

proc formatFetchedTime(now: int64): string =
  # Own the timezone locally: times.utc() caches a ref in thread-local state,
  # which is unsuitable for future callers on foreign threads.
  let zone = newTimezone("UTC", utcTime, utcTime)
  fromUnix(now).inZone(zone).format(FetchedTimeFormat)

proc putBody*(
    planner: var Planner, id: uint64, requestId: string, body: openArray[char],
    revision, epoch: uint64
): Result[void, TklError] =
  ## Validates and parses one fetched body of the current round while it is
  ## borrowed. Only the parsed result is kept until `applyResults`.
  if id == 0 or planner.phase == Idle or id != planner.plan.id:
    return err(tklError(InvalidArgument, "UnknownRefreshPlan"))
  if planner.phase == Prepared:
    return err(tklError(InvalidArgument, "RefreshAlreadyApplied"))
  if revision != planner.baseRevision or epoch != planner.baseEpoch:
    planner.clearPlan()
    return err(tklError(SupersededPlan, "RefreshSuperseded"))
  var format = Opt.none(ListFormat)
  for request in planner.plan.requests:
    if request.id == requestId:
      format = Opt.some(request.format)
  if format.isNone:
    return err(tklError(InvalidArgument, "UnexpectedFetchResult", requestId))
  var received = ReceivedBody(id: requestId, bodyLen: body.len)
  if body.len > planner.limits.maxBytes:
    received.tooLarge = true
  elif format.get == RegistryFormat:
    let valid = validateDocument(body, RegistryFormat, requestId, planner.limits)
    if valid.isErr:
      received.error = valid.error
    else:
      let parsed = parseRegistry(body, requestId, planner.limits)
      if parsed.isErr: received.error = parsed.error
      else: received.registry = parsed.get
  else:
    var parsed = fetchedListBody(body, format.get, requestId, planner.limits)
    if parsed.isErr: received.error = parsed.error
    else: received.source = move(parsed.value)
  for entry in planner.received.mitems:
    if entry.id == requestId:
      entry = move(received)
      return ok()
  planner.received.add move(received)
  ok()

func findReceived(planner: Planner, id: string): int =
  for index, entry in planner.received:
    if entry.id == id:
      return index
  -1

func needsBody(request: FetchRequest, response: FetchResult): bool =
  response.failure.code == Ok and response.status == 200 and
    not (response.etag.len > 0 and response.etag == request.etag)

proc acceptResponse(
    planner: var Planner, request: FetchRequest, response: FetchResult, now: int64
): SourceReport =
  var previousSource = Opt.none(ListContent)
  if request.format == RegistryFormat:
    if planner.registry.isSome:
      previousSource = Opt.some(planner.registry.get.meta)
  else:
    let index = planner.contents.findContent(request.id)
    if index >= 0:
      previousSource = Opt.some(planner.contents[index])
  let received = planner.findReceived(request.id)
  template rejected(kind: SourceOutcome, code: TklStatus, detail: string): untyped =
    return SourceReport(id: request.id, outcome: kind,
      error: tklError(code, detail, request.id))
  if (received >= 0 and planner.received[received].tooLarge and
      response.failure.code == Ok and response.status == 200) or
      response.failure.detail == "tooLarge":
    rejected(SourceOutcome.TooLarge, InvalidContent, "TooLarge")
  if response.failure.code != Ok:
    return SourceReport(id: request.id, outcome: SourceOutcome.FetchFailed,
      error: tklError(response.failure.code, response.failure.detail, request.id))
  let sameSource = previousSource.isSome and
    previousSource.get.source == request.url and
    previousSource.get.format == request.format
  if response.status == 304:
    if previousSource.isNone or not sameSource or request.etag.len == 0:
      rejected(SourceOutcome.FetchFailed, NetworkFailure, "Unexpected304")
    return SourceReport(id: request.id, outcome: SourceOutcome.Unchanged304)
  if response.status != 200:
    rejected(SourceOutcome.FetchFailed, NetworkFailure, "HttpStatus")
  if sameSource and response.etag.len > 0 and response.etag == request.etag:
    return SourceReport(id: request.id, outcome: SourceOutcome.UnchangedSameEtag)
  let body = addr planner.received[received]
  if body.error.code != Ok:
    return SourceReport(id: request.id, outcome: SourceOutcome.InvalidContent,
      error: body.error)
  let content = ListContent(id: request.id, source: request.url,
    etag: response.etag, format: request.format,
    fetchedAt: now, fetchedTimestamp: formatFetchedTime(now))
  planner.report.writes.add content
  if request.format == RegistryFormat:
    planner.candidateRegistry = Opt.some(RegistryContent(meta: content,
      registry: move(body.registry)))
  else:
    var update = ParsedContent(meta: content, source: move(body.source),
      bodyLen: body.bodyLen)
    update.source.list.source = content.source
    update.source.list.fetchedTimestamp = content.fetchedTimestamp
    planner.candidate.putContent(content)
    planner.updates.add move(update)
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
    var report = move(planner.report)
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
  var byId: Table[string, int]
  for index, response in responses:
    if response.id in byId:
      return err(tklError(InvalidArgument, "DuplicateFetchResult", response.id))
    byId[response.id] = index
  if byId.len != planner.plan.requests.len:
    return err(tklError(InvalidArgument, "IncompleteFetchResults"))
  for request in planner.plan.requests:
    if request.id notin byId:
      return err(tklError(InvalidArgument, "UnexpectedFetchResult"))
    if needsBody(request, responses[byId.getOrDefault(request.id)]) and
        planner.findReceived(request.id) < 0:
      return err(tklError(InvalidArgument, "MissingFetchBody", request.id))
  for request in planner.plan.requests:
    planner.report.sources.add planner.acceptResponse(request,
      responses[byId.getOrDefault(request.id)], now)
  planner.received = @[]
  if planner.phase == ListRound:
    return ok(planner.finishReport())
  if planner.candidateRegistry.isNone:
    let report = RefreshReport(step: RefreshStep.Failed,
      outcome: RefreshOutcome.Failed, sources: planner.report.sources,
      diagnostics: @[tklError(InvalidContent, "RegistryUnavailable")])
    planner.state.lastOutcome = RefreshOutcome.Failed
    planner.clearPlan()
    return ok(report)
  var requests: seq[FetchRequest]
  var present: HashSet[string]
  for source in planner.candidateRegistry.get.registry.tokenLists:
    present.incl source.id
    let format = resolveFormat(source.schema, planner.fallbackFormat(source.id))
    let initial = planner.config.initialLists.findContent(source.id)
    if source.id in ["native", "custom", planner.config.registryId] or
        format.isErr or (format.isOk and (format.get == RegistryFormat or
          (initial >= 0 and planner.config.initialLists[initial].format != format.get))):
      planner.report.sources.add SourceReport(id: source.id,
        outcome: SourceOutcome.UnsupportedSchema,
        error: tklError(UnsupportedSchema, "UnsupportedSource", source.id))
      continue
    let previous = planner.contents.findContent(source.id)
    let etag = if previous >= 0 and
        planner.contents[previous].source == source.sourceUrl and
        planner.contents[previous].format == format.get:
          planner.contents[previous].etag else: ""
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
