#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=build/asan EXTRA_NIMFLAGS='--cc:clang --passC:-fsanitize=address --passC:-fno-omit-frame-pointer --assertions:on --checks:on' \
  bash scripts/build_lib.sh
for test in smoke lengths transactions packed narrow; do
  clang -std=c11 -Wall -Wextra -fsanitize=address -fno-omit-frame-pointer \
    -o "build/asan/$test" "tests/abi/$test.c" -Iabi build/asan/libtkl.a -lpthread -lm
  "build/asan/$test"
done
CORE_NIMFLAGS='--cc:clang --passC:-fsanitize=address --passC:-fno-omit-frame-pointer --passL:-fsanitize=address' \
  bash scripts/test_core.sh test_decode_cleanup test_load test_planner test_store test_builder test_refresh_reuse test_stream test_encoding test_parsers test_packed test_narrow
