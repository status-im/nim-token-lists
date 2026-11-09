#!/usr/bin/env bash
# Usage: audit_symbols.sh <archive-or-shared-lib>
# Require exactly the functions tkl.h declares, including weak/common defined globals.
set -euo pipefail
LIB="$1"
if ! SYMBOLS="$("${NM:-nm}" -g "$LIB")"; then
  echo "AUDIT FAIL: cannot inspect $LIB" >&2
  exit 1
fi
ACTUAL="$(printf '%s\n' "$SYMBOLS" |
  tr -d '\r' |
  awk 'NF >= 2 && $(NF-1) ~ /^[A-Za-z?]$/ && $(NF-1) !~ /^[Uuvw]$/ {print $NF}' |
  sed 's/^_//' | LC_ALL=C sort -u)"
EXPECTED="$(tr -d '\r' < "$(dirname "$0")/../abi/tkl.h" |
  grep -oE '\btkl_[a-z0-9_]+[[:space:]]*\(' | sed -E 's/[[:space:]]*\($//' | LC_ALL=C sort -u)"
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "AUDIT FAIL: defined globals differ from the functions in tkl.h in $LIB" >&2
  # Native Windows diff cannot open Bash's /dev/fd process substitutions.
  tmp="$(mktemp -d)"
  trap 'rm -r -- "$tmp"' EXIT
  printf '%s\n' "$EXPECTED" > "$tmp/expected.txt"
  printf '%s\n' "$ACTUAL" > "$tmp/actual.txt"
  diff -u "$tmp/expected.txt" "$tmp/actual.txt" || true
  exit 1
fi
echo "AUDIT OK: exported globals match the functions in tkl.h in $LIB"
