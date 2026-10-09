{.push raises: [], gcsafe.}

import ./core/catalogue
export catalogue

type
  FetchedBody* = object
    ## One fetch result with its body, for Nim callers. The C ABI passes
    ## bodies separately with `refresh_put_body`.
    id*: string
    status*: int
    body*: string
    etag*: string
    failure*: TklError

proc initCatalogue*(
    config: CatalogueConfig, bodies: openArray[SourceBody] = [],
    stored: seq[ListContent] = @[], customs: seq[Token] = @[],
    limits = DefaultParseLimits, refreshState = RefreshState(),
    planTimeoutSec = 300'i64
): Result[Catalogue, TklError] =
  ## Loads in one call, supplying stored bodies first.
  var load = ?beginLoad(config, stored, customs, limits, refreshState,
    planTimeoutSec)
  for origin in [StoredBody, BundledBody]:
    for body in bodies:
      if body.origin == origin:
        ?load.loadList(body.id, body.origin, body.body)
  finishLoad(move(load))

proc refreshApply*(
    catalogue: var Catalogue, planId: uint64, fetched: openArray[FetchedBody],
    now: int64
): Result[RefreshReport, TklError] =
  ## Puts the body of every successful response, then applies the batch.
  var results = newSeqOfCap[FetchResult](fetched.len)
  for response in fetched:
    if response.status == 200 and response.failure.code == Ok:
      ?catalogue.refreshPutBody(planId, response.id, response.body)
    results.add FetchResult(id: response.id, status: response.status,
      etag: response.etag, failure: response.failure)
  catalogue.refreshApply(planId, results, now)
