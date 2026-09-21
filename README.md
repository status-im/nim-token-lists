# nim-token-lists

A Nim library for fungible-token lists.

## Available functionality

- A prototype snapshot with JSON input, token lookup and first-occurrence deduplication.

## Source layout

- `tokenlists/core/`: Nim implementation.
- `tests/`: implementation tests.

## Build and test

Install Nim 2.2.10 and make `nim` available on `PATH`.
Set `NIM` only if you need to select a different compiler executable.

```sh
mkdir -p build
make test-nim
```
