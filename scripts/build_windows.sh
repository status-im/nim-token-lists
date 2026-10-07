#!/usr/bin/env bash
# Run in an x86_64 MinGW environment; CI must verify COFF symbol isolation.
set -euo pipefail
cd "$(dirname "$0")/.."
export OUT="${OUT:-build/windows-x86_64}" TKL_TARGET_OS=Windows
cc="${CC:-gcc}"
"$cc" -dumpmachine | grep -Eq '^x86_64-.*mingw' || {
  echo 'Windows builds require an x86_64 MinGW compiler' >&2; exit 1;
}
bash scripts/build_lib.sh --os:windows --cpu:amd64 --cc:gcc \
  --gcc.exe:"$cc" --gcc.linkerexe:"$cc"
bash scripts/isolate_lib.sh
mkdir -p "$OUT/link"
cp "$OUT/libtkl_isolated.a" "$OUT/link/libtkl.a"
bash scripts/audit_symbols.sh "$OUT/link/libtkl.a"
for test in smoke lengths; do
  "$cc" -std=c11 -Wall -Wextra "tests/abi/$test.c" -Iabi \
    "$OUT/link/libtkl.a" -pthread -lm -o "$OUT/$test.exe"
  "$OUT/$test.exe"
done
# Native Go launches gcc outside MSYS, so cgo environment flags must already
# contain Windows paths. Go strips quotes only at the start of a token, so
# quote the entire -I/-L argument, not just its path.
root="$(cygpath -am "$PWD")"
library_dir="$(cygpath -am "$OUT/link")"
cd go/tkl
CGO_ENABLED=1 CC="$cc" GOWORK=off CGO_CFLAGS="\"-I$root/abi\"" \
  CGO_LDFLAGS="\"-L$library_dir\"" go test -count=1 ./...
