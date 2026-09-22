#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=build/asan EXTRA_NIMFLAGS='--cc:clang --passC:-fsanitize=address --passC:-fno-omit-frame-pointer --assertions:on --checks:on' \
  bash scripts/build_lib.sh
for test in smoke lengths; do
  clang -std=c11 -Wall -Wextra -fsanitize=address -fno-omit-frame-pointer \
    -o "build/asan/$test" "tests/abi/$test.c" -Iabi build/asan/libtkl.a -lpthread -lm
  "build/asan/$test"
done
