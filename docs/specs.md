# Shared fungible-token list library

## Purpose

`nim-token-lists` provides reusable token-list processing in Nim. Go consumers
use C bindings to call the Nim implementation.

## Current capabilities

- Token identities, address normalization, typed errors and custom-token validation.
- Standard token-list parsing and Status list parsing with per-chain contract expansion.
- Registry parsing that preserves source order and schema identifiers.
- Native validation of supported document formats.
- A prototype snapshot, C ABI and cgo wrapper.

The parsers and validators operate on supplied data without network or
filesystem access. They are not yet connected to the prototype snapshot or
exposed through the C and Go bindings. Catalogue building, refresh planning
and status-go integration remain to be implemented.

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
