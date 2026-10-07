# nim-token-lists

A Nim library for fungible-token lists.

## Available functionality

- Deterministic catalogue building, immutable snapshots and paginated queries.
- A versioned C ABI exposing the catalogue and transaction operations.
- A typed Go wrapper that calls the library through C bindings.
- Token and registry types, normalized token identities, typed errors and custom-token validation.
- Standard and Status token-list parsers, including expansion of Status contracts by chain.
- Registry parsing and native validation of supported list formats.
- Revisioned publication, chain/policy rebuilds and custom-token prepare/commit/abort.
- Two-round refresh planning, conditional fetch results, transactional publication
  and host-driven scheduling.

The bindings expose bootstrap, queries, policy, custom-token transactions and
refresh planning. Hosts own HTTP, storage and the persistence/commit handshake.

## Source layout

- `tokenlists/core/`: Nim implementation.
- `tokenlists/api.nim`: public Nim API.
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
make test-core
make test-c
make test-go
make test-differential
make test-asan
```

Go tests cover concurrent access and handle destruction. The separate differential
test module compares results against pinned SDK parsers; the production Go module
has no SDK dependency. AddressSanitizer tests require Clang.

`make test-snapshot-fixture` runs the standalone prototype snapshot tests, which
are separate from the production core suite and are not required by CI.

Create a handle with `tkl.Create(config)`, then call `LoadStored` once to publish
the initial catalogue. Queries return typed pages containing a revision, total
count and items. Call `Destroy` before closing the host's storage. ABI version 2
replaces the earlier prototype interface; headers and bindings must match.

Run `make bench` for Go binding lookup, bulk-read and custom-write benchmarks.
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

## Platform readiness

Mobile build scripts produce separate isolated archives, C ABI executables and
Go test binaries under `build/<target>`. Android uses NDK 27.2.12479018 and API
28 by default; set `ANDROID_NDK_ROOT` to the installed NDK directory. iOS uses
the selected Xcode toolchain, with iOS 13 for devices and Intel simulators and
iOS 14 for ARM simulators (the first supported ARM simulator deployment target).

```sh
make lib-android ARCH=arm64
make lib-android ARCH=x86_64
make lib-ios ARCH=arm64
make lib-ios ARCH=arm64 IPHONE_SDK=iphonesimulator
make lib-ios ARCH=x86_64 IPHONE_SDK=iphonesimulator
```

The linkable archive is `build/<target>/link/libtkl.a`. Set `TKL_BUILD_TESTS=0`
to build and audit only the archive. The header remains `abi/tkl.h`.

Run tests on an already booted matching emulator or native simulator:

```sh
bash scripts/test_mobile.sh android-arm64
SIMULATOR_UDID=<booted-simulator-id> bash scripts/test_mobile.sh ios-simulator-arm64
```

The Android runner defaults to the emulator; set `ANDROID_SERIAL` for a specific
authorized device and `ADB` if adb is not on PATH. The iOS runner signs local
test executables ad hoc; it does not install a device application. Physical iOS
testing requires a separately signed application harness.

`make test-windows` is the MinGW x86_64 readiness check: build the isolated
archive, audit its symbols, and execute C and Go tests. The Windows workflow
must pass before Windows support is considered verified.
The main CI workflow calls both platform workflows and includes their results
in the `PR checks` gate; a failed, skipped or cancelled platform job fails it.

Mobile CI builds all five targets and runs Android x86_64 plus the runner's
native iOS simulator architecture. This is library coverage, not proof of full
status-go linking, SDS coexistence, application packaging or physical-device
behavior. The SDK backend must remain available until every supported target
passes those integration checks as well.

See [specs.md](docs/specs.md) for the library behavior and integration scope.
