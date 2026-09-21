#!/usr/bin/env bash
# Usage: audit_symbols.sh <archive-or-shared-lib>
# Require exactly the ABI allowlist, including weak/common defined globals.
set -euo pipefail
LIB="$1"
if ! SYMBOLS="$("${NM:-nm}" -g "$LIB")"; then
  echo "AUDIT FAIL: cannot inspect $LIB" >&2
  exit 1
fi
ACTUAL="$(printf '%s\n' "$SYMBOLS" |
  awk 'NF >= 2 && $(NF-1) ~ /^[A-Za-z?]$/ && $(NF-1) !~ /^[Uuvw]$/ {print $NF}' |
  sed 's/^_//' | LC_ALL=C sort -u)"
EXPECTED="$(LC_ALL=C sort -u "$(dirname "$0")/../abi/exports-linux.txt")"
if [ "$ACTUAL" != "$EXPECTED" ]; then
  echo "AUDIT FAIL: defined globals differ from ABI allowlist in $LIB" >&2
  diff <(printf '%s\n' "$EXPECTED") <(printf '%s\n' "$ACTUAL") || exit 1
  exit 1
fi
echo "AUDIT OK: exactly 10 tkl_* globals in $LIB"
