#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
NIM="${NIM:-nim}"
OUT="${OUT:-build}"
mkdir -p "$OUT"
paths=(--path:.)
for dep in nim-result nim-stew nim-faststreams nim-serialization nim-json-serialization; do
  paths+=("--path:vendor/$dep")
done
# shellcheck disable=SC2086
"$NIM" c --app:staticlib --noMain --nimMainPrefix:libtkl \
  --mm:orc -d:useMalloc --threads:on -d:release -d:noSignalHandler \
  --passC:-fvisibility=hidden --passC:-fno-common --skipParentCfg:on --skipUserCfg:on \
  "${paths[@]}" \
  --nimcache:"$OUT/nimcache" -o:"$OUT/libtkl.a" ${EXTRA_NIMFLAGS:-} "$@" abi/libtkl.nim
echo "built $OUT/libtkl.a"
