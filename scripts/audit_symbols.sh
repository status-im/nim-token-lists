#!/usr/bin/env bash
# Usage: audit_symbols.sh <archive-or-shared-lib>
# Fails if any externally visible DEFINED symbol is not a tkl_ export.
set -euo pipefail
LIB="$1"
BAD="$(nm -g "$LIB" 2>/dev/null | awk '$2 ~ /^[TDBSR]$/ {print $3}' | sed 's/^_//' | grep -v '^tkl_' || true)"
if [ -n "$BAD" ]; then
  echo "AUDIT FAIL: non-tkl_ global symbols in $LIB:"; echo "$BAD" | sort -u | head -50
  exit 1
fi
echo "AUDIT OK: only tkl_* globals in $LIB"
