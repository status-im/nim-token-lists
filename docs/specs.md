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
- Host-driven scheduling and parser, parser-differential and refresh-state fuzz targets.
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

Stored content takes precedence over bundled content. A missing, empty or
corrupt stored initial list falls back to the bundled list; failures are reported
as diagnostics. Invalid remote-only lists are skipped with diagnostics.
An invalid bundled fallback fails the load without publishing partial state.

The library ships no list data and retains no list body. A load supplies the
metadata of the host's persisted lists, then each body once, borrowed only for
that call: stored and bundled copies of a list share its ID and say which they
are. Each body is parsed when it is supplied and dropped. A bundled list is
parsed only while no usable stored copy of it has been supplied, so hosts pass
stored bodies first. Finishing picks each stored list if it parsed, else its
bundled list, and publishes once; aborting publishes nothing.

Parsed rows are stored compactly, once per catalogue: each row is a fixed-size
record (chain, 20-byte address, decimals, flags and string IDs) and its strings
live in one interned arena, with shared logo URL prefixes stored once.
Identical rows of different lists share one record. Rows keep their document
order, including rows on disabled chains and invalid rows, which are reported
when a snapshot is built. Snapshots are index views over that store: raw lists,
the unique catalogue and a sorted lookup index are arrays of record indices.
Custom edits, policy and chain changes build new views over the same store
without decoding JSON or copying rows, including rows on chains that were
initially disabled. A refresh parses only the bodies it fetched; every other
list keeps its parsed rows, including lists that fell back at load, whose
diagnostics stay until they are fetched again. A refresh that changes a list
builds a new store from the kept and fetched rows; the published one is
untouched until commit.

Skipped keys affect the unique catalogue, not the retained raw lists.
Native aliases resolve to a chain's zero-address token unless that alias key
is skipped. ETH metadata is the default for native tokens; hosts provide
descriptors for other currencies, such as BNB.

Queries support keys, chain/address pairs, chains, native tokens and raw lists.
Pages include the snapshot revision and total matching count; a zero limit
returns all remaining results. Negative offsets or limits are rejected.
Key and chain/address batch queries preserve request order and repetitions
while omitting missing tokens; a malformed key or address fails the batch.
Lookups binary-search the sorted index without allocating; `Token` and
`TokenList` values are materialized only for results. Returned values can be
modified without changing the source snapshot. Direct catalogue query methods
borrow the current snapshot and copy only their results. The `snapshot`
accessor deliberately copies the whole snapshot, store included, for callers
that need to retain it: the copy shares no reference, so readers can take one
under a shared lock. It should not be used for each hot lookup. `published`
shares the immutable snapshot itself without copying it; snapshots built by
chain, policy and custom changes share one store.

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

Each publication builds one new immutable snapshot; none is changed afterwards.
Snapshot values cannot be copied implicitly, since a copy would share the store
reference with readers on other threads; `detached` makes an independent copy.
The C adapter publishes the core's snapshot itself, never a copy. Readers borrow
it under the read lock through queries and result encoding without touching its
reference count. A separate writer mutex serializes core mutation, construction,
diffing and candidate ownership, and only writers copy or release the shared
reference. The write lock only swaps the published reference and revision; the
replaced snapshot is released after the swap, once no reader can still borrow it.
Core commit checks enforce revision/epoch validity.

Query results are written as JSON straight from the token records and the
string arena into the output buffer handed to the host: one allocation of the
exact size, measured first, with no intermediate token values. The bytes are
those of the json_serialization encoding of the materialized page, except that
control bytes 0x0f and 0x1f are escaped where that writer fails.

## C and Go bindings

ABI major 3 replaces version 2, whose create, load and refresh JSON carried list
bodies. `tkl_create` accepts an ABI version and a JSON object containing `config`
and optional `limits`; mismatched versions fail before creating a handle. Config
list entries are metadata only (ID, format, source, fetch metadata).

Loading is a transaction. `tkl_load_begin` accepts `stored` (persisted list and
registry metadata, including failures), `customs` and `state` and returns a load
ID. `tkl_load_list` passes one body as a borrowed pointer and length with its
list ID and origin (`TKL_BODY_BUNDLED` or `TKL_BODY_STORED`); a zero length is
an empty body. The registry is loaded the same way under the registry ID.
`tkl_load_finish` publishes revision one and can succeed only once per handle;
`tkl_load_abort` publishes nothing. A new begin replaces an open load, and
finish, abort or destroy ends it; a stale load ID is rejected. Unknown IDs,
origins and repeated bodies are rejected without ending the load. Queries before
load return `InvalidArgument` with `NotLoaded`. Library version is `0.3.0`.

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
| `get_by_keys`, `get_by_chain_addresses` | `keys`; `chainIds,addresses` (equal lengths) | Token page in request order |
| `get_by_chains`, `get_all` | `chains,offset,limit`; `offset,limit` | Token page |
| `get_list`, `get_lists`, `get_diagnostics` | `id`; empty object; empty object | List or diagnostic page |
| `set_chains`, `set_policy` | `chains`; `policy` | Change |
| `custom_validate_upsert`, `custom_validate_delete` | `token`; `key` | Mutation |
| `custom_commit`, `custom_abort` | `mutationId` | Change; true |
| `load_begin` | `stored,customs,state` | Load ID; no body |
| `load_list`, `load_finish`, `load_abort` | load ID, list ID, origin, body; load ID | No body; change page; no body |
| `refresh_plan`, `refresh_put_body`, `refresh_apply` | `now,force`; plan ID, request ID, body; `planId,results,now` | Plan; no body; report |
| `refresh_commit`, `refresh_abort` | `planId,now`; `planId,reason` | Change; true |
| `set_auto_refresh`, `set_network_allowed` | `enabled,refreshSec,checkSec`; `allowed` | true |
| `next_due`, `refresh_state`, `changes_since` | `now`; empty object; `revision` | Nullable timestamp; state; change page |

Operation names in the header have the `tkl_` prefix. Omitted fields use their
zero/default values; invalid keys, intervals, transaction IDs and pagination are
rejected by the core. Queries expose empty tag metadata as an empty JSON object.
The create envelope is capped at 16 MiB; subsequent envelopes use the instance
byte limit. Bodies are not JSON envelopes: each is checked against the instance
document limits when it is parsed. Requests with no fields use `{}`; zero-length
JSON input remains invalid on the C boundary. No input pointer, JSON or body, is
retained after the call returns.

The library is the single owner of the query index; hosts keep no mirror of it.
A typed per-call lookup costs roughly 7 microseconds on Apple M2 hardware, mostly
cgo and request JSON, so hosts must not cross the ABI for each activity row or
Transfer event: they batch lookups with `get_by_keys`, `get_by_chain_addresses`
or `get_by_chains` and keep only what one screen or event batch needs.
`BenchmarkGetAllBulk` measures the full catalogue transfer and typed decode.

`tkl_get_by_chains_packed(handle, chainIds, count, out)` is the one query
without JSON, for balance fetching, which reads only chain, address and
decimals of whole chains. It answers the tokens of `get_by_chains` with the same
chains, in the same order, as fixed little-endian records written straight from
the store into one exactly sized buffer:

| Bytes | Field |
| --- | --- |
| 0..3 | magic `0x31504B54` ("TKP1", layout version 1) |
| 4..7 | record count, u32 |
| 8..15 | revision, u64 |
| 16 + 32i .. | record i: chainId u64, address 20 bytes, decimals u8, 3 zero bytes |

`chainIds` holds `count` u64 ids (NULL with count 0 answers no tokens; at most
the instance `maxArrayItems`); errors return the usual JSON body. Go's
`GetByChainsPacked` decodes into a reusable `[]ChainToken`: about 0.12 ms and one
allocation for six mainnets (11774 tokens) on Apple M1, against 25 ms for
`GetByChains`.

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

Registry errors fall back to the committed or bundled registry, kept parsed.
Without a usable registry the refresh fails. The host passes the body of each
200 response of a round with `refresh_put_body` before applying the round; it
is validated natively and parsed in that call, a later put for the same request
replaces it, and an oversized body is reported as too large without parsing.
Results carry no bodies. Applying a round requires a put body for every 200
response whose ETag differs from the one sent; bodies put for a round are
dropped once it is applied. Loaded list bodies retain the existing permissive
parsing contract. Source URLs and formats scope conditional ETags. A 304
requires usable matching cached content and a sent ETag; a successful response
with that same nonempty ETag keeps the committed list. Configured initial-list
formats cannot be changed by a registry. Unsupported formats are reported
without requesting those sources.

Final reports contain persistence writes, per-source outcomes and an overall
full, partial, unchanged or failed outcome. Writes are metadata only: the host
persists the bytes it fetched under each written ID and supplies them as stored
bodies at the next load. Failed sources keep their prior content. Sources removed from the registry remain merged and receive orphaned
diagnostics. Apply builds an unpublished candidate and precomputes its change.
It parses only lists written by the run; a run that leaves every list and
diagnostic unchanged skips the rebuild.
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

Standard and Status lists are parsed in a single pass over the borrowed body.
JSON well-formedness, limits, duplicate fields, field types and, for fetched
documents, validation are checked while rows are written into the store, with
no intermediate document tree or row strings. The results and error details
are those of the typed decoder and validator this parser replaced, which
`tests/oracle/` keeps for differential tests and fuzzing.

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
