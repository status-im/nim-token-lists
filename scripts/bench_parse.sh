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
  --styleCheck:usages --styleCheck:error --nimcache:build/nimcache-bench-parse \
  -o:build/bench_parse tests/bench/parse_coingecko.nim
