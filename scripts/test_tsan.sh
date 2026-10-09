#!/usr/bin/env bash
# Concurrent queries during publications under ThreadSanitizer.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=build/tsan EXTRA_NIMFLAGS='--cc:clang --passC:-fsanitize=thread --passC:-fno-omit-frame-pointer' \
  bash scripts/build_lib.sh
for test in smoke transactions; do
  clang -std=c11 -Wall -Wextra -fsanitize=thread \
    -o "build/tsan/$test" "tests/abi/$test.c" -Iabi build/tsan/libtkl.a -lpthread -lm
  "build/tsan/$test"
done
