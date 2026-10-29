#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
NIM="${NIM:-nim}"
OUT="${OUT:-build}"
mkdir -p "$OUT"
paths=(--path:.)
# The nimble tasks set TKL_VENDOR_DEPS=0 and pass dependency --paths in NIM_PARAMS.
if [ "${TKL_VENDOR_DEPS:-1}" != 0 ]; then
  for dep in nim-result nim-stew nim-faststreams nim-serialization nim-json-serialization; do
    paths+=("--path:vendor/$dep")
  done
fi
# NIM_PARAMS is trusted, shell-quoted input: a quoted path stays one argument.
nim_params=()
eval "nim_params=(${NIM_PARAMS:-})"
# shellcheck disable=SC2086
"$NIM" c --app:staticlib --noMain --nimMainPrefix:libtkl \
  --mm:orc -d:useMalloc --threads:on -d:release -d:noSignalHandler \
  --passC:-fvisibility=hidden --passC:-fno-common --skipParentCfg:on --skipUserCfg:on \
  "${paths[@]}" \
  --nimcache:"$OUT/nimcache" -o:"$OUT/libtkl.a" ${EXTRA_NIMFLAGS:-} "$@" "${nim_params[@]+"${nim_params[@]}"}" abi/libtkl.nim
echo "built $OUT/libtkl.a"
