#!/usr/bin/env bash
# Prelink all libtkl objects into one relocatable object and make every symbol
# except the tkl_* exports local, so no Nim runtime symbol can clash or be shared.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${OUT:-build}"
case "${TKL_TARGET_OS:-$(uname -s)}" in
  Darwin)
    SDK_VERSION="$(xcrun --sdk "${TKL_SDK:-macosx}" --show-sdk-version)"
    # Current Apple ld rejects -d; all input objects use -fno-common.
    ld -r -arch "${TKL_ARCH:-$(uname -m)}" -all_load "$OUT/libtkl.a" \
      -platform_version "${TKL_PLATFORM:-macos}" "${TKL_MIN_OS:-${MACOSX_DEPLOYMENT_TARGET:-$SDK_VERSION}}" "$SDK_VERSION" \
      -exported_symbols_list abi/exports-macos.txt -o "$OUT/libtkl_prelinked.o"
    rm -f "$OUT/libtkl_isolated.a"
    libtool -static -o "$OUT/libtkl_isolated.a" "$OUT/libtkl_prelinked.o"
    ;;
  Linux|Android)
    "${TKL_LD:-ld}" -r -d --whole-archive "$OUT/libtkl.a" -o "$OUT/libtkl_prelinked.o"
    "${TKL_OBJCOPY:-objcopy}" --keep-global-symbols=abi/exports-linux.txt "$OUT/libtkl_prelinked.o"
    rm -f "$OUT/libtkl_isolated.a"
    "${TKL_AR:-ar}" rcs "$OUT/libtkl_isolated.a" "$OUT/libtkl_prelinked.o"
    ;;
  *) echo "isolate_lib.sh: unsupported OS $(uname -s)"; exit 2 ;;
esac
echo "built $OUT/libtkl_isolated.a"
