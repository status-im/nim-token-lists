#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
NIM="${NIM:-nim}"
OUT="${OUT:-build}"
mkdir -p "$OUT"
# shellcheck disable=SC2086
"$NIM" c --app:staticlib --noMain --nimMainPrefix:libtkl \
  --mm:orc -d:useMalloc --threads:on -d:release -d:noSignalHandler \
  --passC:-fvisibility=hidden --skipParentCfg:on \
  --nimcache:"$OUT/nimcache" -o:"$OUT/libtkl.a" ${EXTRA_NIMFLAGS:-} abi/libtkl.nim
echo "built $OUT/libtkl.a"
