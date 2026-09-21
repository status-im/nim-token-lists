#!/usr/bin/env bash
# Prelink all libtkl objects into one relocatable object and make every symbol
# except the tkl_* exports local, so no Nim runtime symbol can clash or be shared.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${OUT:-build}"
case "$(uname -s)" in
  Darwin)
    SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
    ld -r -arch "$(uname -m)" -all_load "$OUT/libtkl.a" \
      -platform_version macos "${MACOSX_DEPLOYMENT_TARGET:-$SDK_VERSION}" "$SDK_VERSION" \
      -exported_symbols_list abi/exports-macos.txt -o "$OUT/libtkl_prelinked.o"
    rm -f "$OUT/libtkl_isolated.a"
    libtool -static -o "$OUT/libtkl_isolated.a" "$OUT/libtkl_prelinked.o"
    ;;
  Linux)
    ld -r --whole-archive "$OUT/libtkl.a" -o "$OUT/libtkl_prelinked.o"
    objcopy --keep-global-symbols=abi/exports-linux.txt "$OUT/libtkl_prelinked.o"
    rm -f "$OUT/libtkl_isolated.a"
    ar rcs "$OUT/libtkl_isolated.a" "$OUT/libtkl_prelinked.o"
    ;;
  *) echo "isolate_lib.sh: unsupported OS $(uname -s)"; exit 2 ;;
esac
echo "built $OUT/libtkl_isolated.a"
