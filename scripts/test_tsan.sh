#!/usr/bin/env bash
# Concurrent queries during publications under ThreadSanitizer.
set -euo pipefail
cd "$(dirname "$0")/.."
NIM_PARAMS='--cc:clang --passC:-fsanitize=thread --passC:-fno-omit-frame-pointer' \
  make --no-print-directory lib OUT=build/tsan
for test in smoke transactions; do
  clang -std=c11 -Wall -Wextra -fsanitize=thread \
    -o "build/tsan/$test" "tests/abi/$test.c" -Iabi build/tsan/libtkl.a -lpthread -lm
  "build/tsan/$test"
done
CORE_NIMFLAGS='--cc:clang --passC:-fsanitize=thread --passC:-fno-omit-frame-pointer --passL:-fsanitize=thread' \
  bash scripts/test_core.sh test_publication
