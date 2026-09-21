# nim-token-lists

A Nim library for fungible-token lists.

## Available functionality

- A prototype snapshot with JSON input, token lookup and first-occurrence deduplication.
- A C ABI exposing the prototype snapshot.
- A Go wrapper that calls the library through C bindings.

## Source layout

- `tokenlists/core/`: Nim implementation.
- `abi/`: C API header and Nim exports.
- `go/tkl/`: cgo wrapper and Go tests.
- `tests/`: implementation tests.
- `scripts/`: build and verification tools.

## Build and test

Install Nim 2.2.10 and make `nim` available on `PATH`.
Set `NIM` only if you need to select a different compiler executable.

```sh
mkdir -p build
make test-nim
make test-c
make test-go
```

Go tests cover concurrent access and handle destruction.

Run `make bench` for Go binding benchmarks.

Symbol-isolation tooling and coexistence probes are included for embedding the library alongside other Nim libraries.
Run `make audit` to check the exported-symbol contract.

C tests cover buffer lengths and ABI argument handling.
