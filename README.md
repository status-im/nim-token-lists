# nim-token-lists

A Nim library for fungible-token lists.

## Available functionality

- Deterministic catalogue building, immutable snapshots and paginated queries.
- A prototype C ABI exposing a separate toy snapshot.
- A Go wrapper that calls the library through C bindings.
- Token and registry types, normalized token identities, typed errors and custom-token validation.
- Standard and Status token-list parsers, including expansion of Status contracts by chain.
- Registry parsing and native validation of supported list formats.
- Revisioned publication, chain/policy rebuilds and custom-token prepare/commit/abort.
- Two-round refresh planning, conditional fetch results, transactional publication
  and host-driven scheduling.

The catalogue and parsers are not exposed through the prototype bindings yet.

## Source layout

- `tokenlists/core/`: Nim implementation.
- `abi/`: C API header and Nim exports.
- `go/tkl/`: cgo wrapper and Go tests.
- `tests/`: implementation tests.
- `scripts/`: build and verification tools.
- `fixtures/`: token-list samples used for compatibility tests.

## Build and test

Install Nim 2.2.10 and make `nim` available on `PATH`.
Set `NIM` only if you need to select a different compiler executable.

```sh
git submodule update --init
mkdir -p build
make test-nim
make test-c
make test-go
make test-core
```

Go tests cover concurrent access and handle destruction.

Run `make bench` for Go binding benchmarks.
Run `make bench-parse` to measure parsing the embedded
CoinGecko Ethereum list in a release build.
Run `make bench-catalogue` to measure custom updates, owned snapshot copies and
direct lookups using all eight embedded lists in a release build.
Run `make fuzz-core` with Clang and its libFuzzer runtime for bounded parser and
refresh-state fuzz campaigns under AddressSanitizer. For longer campaigns, run
`bash scripts/fuzz_core.sh parsers -runs=100000` (or use `planner`).
If Clang lacks the runtime, set `FUZZER_LIB` to a separately built libFuzzer archive.

The core performs no HTTP or storage operations. A host fetches the requests
returned by `refreshPlan` and `refreshApply`, persists the final writes in one
transaction, then calls `refreshCommit`. On persistence failure it calls
`refreshAbort`; queries continue to return the previously committed catalogue.

Symbol-isolation tooling and coexistence probes are included for embedding the library alongside other Nim libraries.
Run `make audit` to check the exported-symbol contract.

C tests cover buffer lengths and ABI argument handling.

See [specs.md](docs/specs.md) for the library behavior and integration scope.
