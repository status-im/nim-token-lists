#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
NIM="${NIM:-nim}"
target="${1:-parsers}"
if [[ "$target" != parsers && "$target" != planner ]]; then
  echo "usage: $0 [parsers|planner] [libFuzzer arguments...]" >&2
  exit 2
fi
if [[ $# -gt 0 ]]; then shift; fi
link_flags=(--passL:-fsanitize=fuzzer,address)
if [[ -n "${FUZZER_LIB:-}" ]]; then
  link_flags=(--passL:-fsanitize=address "--passL:$FUZZER_LIB" --passL:-lc++)
fi
paths=()
for dep in nim-result nim-stew nim-faststreams nim-serialization nim-json-serialization; do
  paths+=("--path:vendor/$dep")
done
mkdir -p "build/fuzz-$target/corpus"
if [[ "$target" == parsers ]]; then
  cp tests/fuzz/corpus/*.json "build/fuzz-$target/corpus/"
else
  cp tests/fuzz/corpus/operations "build/fuzz-$target/corpus/"
fi
"$NIM" c --cc:clang --noMain --mm:orc -d:useMalloc -d:noSignalHandler \
  -d:release --assertions:on --checks:on --threads:on \
  --skipParentCfg:on --skipUserCfg:on --path:. "${paths[@]}" \
  --styleCheck:usages --styleCheck:error \
  --passC:-fsanitize=fuzzer-no-link,address --passC:-fno-omit-frame-pointer \
  "${link_flags[@]}" --nimcache:"build/nimcache-fuzz-$target" \
  -o:"build/fuzz-$target/target" "tests/fuzz/fuzz_$target.nim"
"build/fuzz-$target/target" "build/fuzz-$target/corpus" \
  -max_len=4096 -timeout=10 -rss_limit_mb=2048 -runs=10000 "$@"
