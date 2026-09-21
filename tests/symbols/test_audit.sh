#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
if scripts/audit_symbols.sh "$tmp/missing.a"; then
  echo 'FAIL: missing archive passed audit'
  exit 1
fi
cc -c tests/symbols/unexpected.c -o "$tmp/unexpected.o"
if scripts/audit_symbols.sh "$tmp/unexpected.o"; then
  echo 'FAIL: unexpected weak global passed audit'
  exit 1
fi
scripts/audit_symbols.sh build/libtkl_isolated.a
echo 'AUDIT TESTS OK'
