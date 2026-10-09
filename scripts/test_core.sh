#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
NIM="${NIM:-nim}"
mkdir -p build
paths=()
for dep in nim-result nim-stew nim-faststreams nim-serialization nim-json-serialization; do
  paths+=("--path:vendor/$dep")
done
tests=("${@:-}")
if [[ $# == 0 ]]; then
  tests=(test_keys test_parsers test_validators test_decode_cleanup test_fixtures test_builder test_catalogue test_publication test_planner test_refresh_reuse)
fi
for test in "${tests[@]}"; do
  "$NIM" c -r --mm:orc -d:useMalloc --threads:on --skipParentCfg:on --skipUserCfg:on \
    --path:. "${paths[@]}" --nimcache:"build/nimcache-$test" \
    -o:"build/$test" ${CORE_NIMFLAGS:-} "tests/core/$test.nim"
done
