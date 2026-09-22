# Shared fungible-token list library

## Purpose

`nim-token-lists` provides reusable token-list processing in Nim. Go consumers
use C bindings to call the Nim implementation.

## Current capabilities

- Token identities, address normalization, typed errors and custom-token validation.
- Standard token-list parsing and Status list parsing with per-chain contract expansion.
- Registry parsing that preserves source order and schema identifiers.
- Native validation of supported document formats.
- Deterministic catalogue building, immutable query snapshots and revisioned publication.
- Custom-token prepare, commit and abort operations.
- Refresh planning, conditional fetch results and transactional publication.
- Host-driven scheduling and parser/refresh-state fuzz targets.
- A production C ABI, typed cgo wrapper and public Nim API.

The core operates on supplied data without network or filesystem access.
The catalogue is exposed through C and Go bindings. The old toy snapshot remains
only as a standalone test fixture and is not linked into the production library.
The status-go facade and desktop integration remain to be implemented.

## Catalogue and queries

Source priority is native tokens, the main list, other initial lists sorted
by ID, remaining stored lists sorted by ID, then custom tokens. The first
token with a given chain/address key wins. An explicit custom-first policy
places custom tokens before curated lists, but after native tokens.

Stored content takes precedence over embedded content. A missing, empty or
corrupt stored initial list falls back to embedded data; failures are reported
as diagnostics. Invalid remote-only lists are skipped with diagnostics.
An invalid embedded fallback fails the build without publishing partial state.

Source JSON is decoded once when loading the catalogue. Custom edits and policy
changes rebuild from cached rows; chain changes re-filter those rows without
decoding JSON again, including rows on chains that were initially disabled.

Skipped keys affect the unique catalogue, not the retained raw lists.
Native aliases resolve to a chain's zero-address token unless that alias key
is skipped. ETH metadata is the default for native tokens; hosts provide
descriptors for other currencies, such as BNB.

Queries support keys, chain/address pairs, chains, native tokens and raw lists.
Pages include the snapshot revision and total matching count; a zero limit
returns all remaining results. Negative offsets or limits are rejected.
Key queries preserve request order and repetitions while omitting missing
tokens. Returned values can be modified without changing the source snapshot.
Direct catalogue query methods borrow the current snapshot and copy only their
results. The `snapshot` accessor deliberately copies the whole catalogue for
callers that need to retain it; it should not be used for each hot lookup.

## Publication and custom tokens

`initCatalogue` loads the supplied content and publishes revision one.
Changing chains or policy rebuilds the catalogue and advances the configuration
epoch. Failed rebuilds leave the previous configuration and snapshot intact.

Custom changes follow a persistence handshake: prepare validates a normalized
row or deletion and returns a mutation ID; the host persists it, then calls
commit to publish immediately. If persistence fails, the host calls abort.
Only one custom mutation may be pending. A configuration change supersedes a
pending mutation, so its later commit cannot publish an obsolete snapshot.
Default priority still prevents custom tokens from overriding curated tokens.
Duplicate custom chain/address keys are rejected during initialization, including
case variants, rather than silently collapsed by a later upsert.

Each publication returns a revision and affected chains and lists, including
chains whose alias lookup behavior changed. Recent changes are retained in a
bounded history; an expired cursor requires the host to read a fresh snapshot.
Change detection compares the unique indexes and raw lists directly, including
token order and alias behavior. Custom preparation computes the change before
the persistence handshake, so commit does not repeat the diff.

Catalogue state belongs to its caller, which must synchronize mutations and
snapshot acquisition. Once acquired, a value snapshot remains valid across
later publications. The existing read/write lock gives queued writers priority
over new readers. Host persistence and notifications remain outside the core.

The C adapter keeps published snapshots behind manually owned pointers and holds
the read lock through queries and result encoding. A separate writer mutex
serializes core mutation, construction, diffing and candidate ownership. The
write lock only swaps the published pointer and revision; old state is reclaimed
after previous readers finish. Core commit checks enforce revision/epoch validity.

## C and Go bindings

ABI major 2 replaces the prototype. `tkl_create` accepts an ABI version and a JSON
object containing `config` and optional `limits`; mismatched versions fail before
creating a handle. `tkl_load_stored` accepts `contents`, `customs` and `state` and
publishes revision one. It can succeed only once per handle. Queries before load
return `InvalidArgument` with `NotLoaded`. Library version is `0.2.0`.

Every operation other than version, revision, destruction and buffer release
uses a length-delimited UTF-8 JSON object and a `TklBuf` output. C callers free
every output, including error details, through `tkl_buf_free`. No input pointer
is retained. Output buffers are not NUL terminated. Nonzero return codes can
carry `{code, detail, sourceId}`; early argument/handle failures may have no body.
Go copies and releases each output before decoding and supports `errors.Is`
against status codes. Enum strings use their declared Nim names, for example
`StandardFormat`, `StorageFailure`, `RefreshChange`, `NeedMore` and `Full`.

| Operations | Request fields | Result |
| --- | --- | --- |
| `get_by_key`, `get_by_chain_address`, `get_native` | `key`; `chainId,address`; `chainId` | Token page with one item |
| `get_by_keys`, `get_by_chains`, `get_all` | `keys`; `chains,offset,limit`; `offset,limit` | Token page |
| `get_list`, `get_lists`, `get_diagnostics` | `id`; empty object; empty object | List or diagnostic page |
| `set_chains`, `set_policy` | `chains`; `policy` | Change |
| `custom_validate_upsert`, `custom_validate_delete` | `token`; `key` | Mutation |
| `custom_commit`, `custom_abort` | `mutationId` | Change; true |
| `refresh_plan`, `refresh_apply` | `now,force`; `planId,results,now` | Plan; report |
| `refresh_commit`, `refresh_abort` | `planId,now`; `planId,reason` | Change; true |
| `set_auto_refresh`, `set_network_allowed` | `enabled,refreshSec,checkSec`; `allowed` | true |
| `next_due`, `refresh_state`, `changes_since` | `now`; empty object; `revision` | Nullable timestamp; state; change page |

Operation names in the header have the `tkl_` prefix. Omitted fields use their
zero/default values; invalid keys, intervals, transaction IDs and pagination are
rejected by the core. Queries expose empty tag metadata as an empty JSON object.
The create envelope is capped at 16 MiB; subsequent envelopes use the instance
byte limit. Embedded document strings may occupy that envelope budget; original
document limits, including leaf-string limits, are enforced when parsing them.
Creation also checks each initial-list body and embedded registry against the
resolved instance byte limit before allocating a handle. Requests with no fields
use `{}`; zero-length input remains invalid on the C boundary.

The status-go facade must serve hot per-row and per-event lookups from a
revision-keyed Go mirror. It must not cross the ABI for each activity row or
Transfer event. A changed revision triggers a bulk `get_all(0,0)` read and atomic
mirror replacement; mutations and refresh coordination continue through C.
Typed per-call lookup measured roughly 7–9 microseconds on Apple M2 hardware,
including cgo and JSON costs, so the mirror is a requirement for the facade.
`BenchmarkGetAllBulk` measures the full catalogue transfer and typed decode needed
for mirror refresh. The mirror itself belongs to the subsequent integration phase.

Handles use a bounded registry with generation counters. Destruction rejects new
calls, waits for in-flight calls and frees state; stale generations are invalid.
Calls can originate on arbitrary host threads under ORC/useMalloc. No callbacks
or library-created worker threads are used. Hosts still serialize durable writes
and commit against other mutations; per-call locking cannot cover a host database
transaction. The exported symbol allowlists contain only `tkl_` symbols.

## Refresh planning

The core performs no I/O and reads no clock. Hosts supply nonnegative timestamps
in seconds, fetch each returned batch, persist all proposed writes atomically,
and only then commit. A refresh first requests the registry, then its supported
list sources. Each response batch must contain exactly one result per request;
missing, duplicate and unexpected IDs are rejected without consuming the round.

Refresh timestamps must fit the UTC range from 1970 through 9999. Writes retain
integer seconds in `fetchedAt` and format `fetchedTimestamp` as RFC 3339 UTC
(for example, `1970-01-01T00:00:12Z`) for list metadata and RPC compatibility.
Formatting uses the supplied value without consulting the system clock or timezone.

Registry errors fall back to the committed or embedded registry. Without a usable
registry the refresh fails. Newly fetched documents undergo native validation;
cached list bodies retain the existing permissive parsing contract. Source URLs
and formats scope conditional ETags. A 304 requires usable matching cached
content and a sent ETag; a successful response with that same nonempty ETag
retains the cached body. Configured initial-list formats cannot be changed by a
registry. Unsupported formats are reported without requesting those sources.

Final reports contain persistence writes, per-source outcomes and an overall
full, partial, unchanged or failed outcome. Failed sources keep their prior
content. Sources removed from the registry remain merged and receive orphaned
diagnostics. Apply builds an unpublished candidate and precomputes its change.
Commit publishes only after the host's durable write succeeds. Abort leaves
published content, ETags and last-success time unchanged. A wholly failed run
releases its plan; a partial run can commit the successful writes. An unchanged
successful commit updates last-success time without a new snapshot revision.
Publication depends only on snapshot or diagnostic changes. Registry-only writes
still require persistence and update committed ETags and last-success time, but
do not advance the catalogue revision when the visible catalogue is unchanged.

Only one refresh plan is live. Force replaces it, and plan IDs are never reused.
Plans expire after a configurable timeout (300 seconds by default). Apply and
commit recheck host time, catalogue revision and configuration epoch. Chain,
policy or custom publications therefore supersede old refresh candidates; a
refresh publication likewise supersedes a prepared custom mutation. Hosts must
serialize the persist/commit handshake against other mutations so a durable
write cannot race a superseding publication.
Host time must not decrease within a live plan: each valid plan check advances
its time watermark, and earlier apply/commit calls return `TimeBeforePlan`.

Automatic refresh is disabled initially. Positive refresh and retry-check
intervals are required; `nextDue` returns an optional absolute host timestamp.
Failed attempts are throttled by the check interval, successful runs by the
refresh interval. Force bypasses scheduling but cannot bypass network permission.
Revoking network permission cancels outstanding refresh work. Service state
tracks last attempt, last success and outcome, with explicit presence flags so
timestamp zero remains valid. No core callbacks, timers or signals are emitted.

## Parsing and validation

Parsing preserves list metadata and token order. Unsupported chains and invalid
token rows produce diagnostics. Duplicate token rows are preserved for the
caller to resolve. Status lists expand each token's contracts in numeric chain
order and retain the cross-chain ID.

Parsing cached or embedded data is separate from validating newly fetched
documents. Validation checks required metadata, field types and registry
sources. Invalid token addresses or unsupported chains are row diagnostics,
not reasons to reject a whole list. Token text is preserved, including unusual
whitespace, and empty logos and token arrays are accepted. Version components
use signed 64-bit integers, including negative metadata values, as in the SDK
on supported 64-bit hosts.

Supported formats are `standard`, `status` and `registry`. The Uniswap
token-list schema identifier also selects the standard format. Unknown format
identifiers return an error; the library does not fetch schema documents.

Hosts pass format identifiers, never inline JSON Schema text. The status-go
adapter must translate its existing schema configuration at the boundary:

| Host configuration | Core format identifier |
| --- | --- |
| Embedded `fetcher.ListOfTokenListsSchema` registry schema | `registry` |
| `https://uniswap.org/tokenlist.schema.json` | `standard` |
| No schema | Explicit source format (`status` or `standard`) |

An empty identifier uses the caller's fallback. Inline schema JSON and unknown
identifiers return `UnsupportedSchema`. The Uniswap URL is a format alias;
it does not enable extra row policy or general JSON Schema validation. Native
structural validation replaces the SDK's schema execution without rejecting
an otherwise usable document because one row is unusable.

Malformed JSON and duplicate object fields are rejected. Unknown unique
fields are accepted. Errors distinguish invalid input from document validation
failures.
