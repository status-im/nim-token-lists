#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
NIM="${NIM:-nim}"
mkdir -p build
paths=()
for dep in nim-result nim-stew nim-faststreams nim-serialization nim-json-serialization; do
  paths+=("--path:vendor/$dep")
done
"$NIM" c -r -d:release --mm:orc -d:useMalloc --threads:on \
  --skipParentCfg:on --skipUserCfg:on --path:. "${paths[@]}" \
  --styleCheck:usages --styleCheck:error --nimcache:build/nimcache-bench-catalogue \
  -o:build/bench_catalogue tests/bench/catalogue_operations.nim
