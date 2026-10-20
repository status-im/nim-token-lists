#!/usr/bin/env bash
# Build an isolated archive and C ABI smoke executables for one mobile target.
set -euo pipefail
cd "$(dirname "$0")/.."
target="${1:?Usage: build_mobile.sh android-arm64|android-x86_64|ios-arm64|ios-simulator-arm64|ios-simulator-x86_64}"
fail() { echo "libtkl: $*" >&2; exit 1; }
case "$target" in
  android-arm64|ios-arm64|ios-simulator-arm64) cpu=arm64; arch=arm64 ;;
  android-x86_64|ios-simulator-x86_64) cpu=amd64; arch=x86_64 ;;
  *) fail "Unsupported mobile target: $target" ;;
esac
export OUT="${OUT:-build/$target}"
flags=(--cpu:"$cpu" --cc:clang --os:linux)
cflags=()
case "$target" in
  android-*)
    : "${ANDROID_NDK_ROOT:?Set ANDROID_NDK_ROOT to Android NDK 27.2.12479018}"
    api="${ANDROID_API:-28}"
    [[ "$api" =~ ^[0-9]+$ ]] && ((api >= 28)) || fail "ANDROID_API must be at least 28"
    case "$(uname -s)" in
      Darwin) host=darwin-x86_64 ;;
      Linux) host=linux-x86_64 ;;
      *) fail "Android cross builds require Linux or macOS" ;;
    esac
    toolchain="$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/$host/bin"
    [ -x "$toolchain/llvm-ar" ] || fail "NDK archiver not found: $toolchain/llvm-ar"
    # Nim's Linux Clang backend runs llvm-ar by name before our isolation step.
    # TKL_AR only configures isolation; use the same NDK tools for both stages.
    export PATH="$toolchain:$PATH"
    triple=aarch64-linux-android
    [ "$arch" != x86_64 ] || triple=x86_64-linux-android
    cc="$toolchain/$triple$api-clang"
    export TKL_TARGET_OS=Android TKL_LD="$toolchain/ld.lld"
    export TKL_OBJCOPY="$toolchain/llvm-objcopy" TKL_AR="$toolchain/llvm-ar"
    flags+=(-d:android --passC:-fPIC)
    goos=android
    ;;
  ios-*)
    default_minimum=13.0
    [ "$target" != ios-simulator-arm64 ] || default_minimum=14.0
    minimum="${IOS_TARGET:-$default_minimum}"
    [[ "$minimum" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || fail "Invalid IOS_TARGET"
    (( ${minimum%%.*} >= ${default_minimum%%.*} )) || fail "$target requires iOS $default_minimum or newer"
    export TKL_TARGET_OS=Darwin TKL_ARCH="$arch" TKL_MIN_OS="$minimum"
    export TKL_SDK=iphoneos TKL_PLATFORM=ios
    triple="$arch-apple-ios$minimum"
    if [[ "$target" == ios-simulator-* ]]; then
      export TKL_SDK=iphonesimulator TKL_PLATFORM=ios-simulator
      triple="$triple-simulator"
    fi
    cc="$(xcrun --sdk "$TKL_SDK" --find clang)"
    export TKL_LD="$(xcrun --sdk "$TKL_SDK" --find ld)"
    export TKL_LIBTOOL="$(xcrun --sdk "$TKL_SDK" --find libtool)"
    cflags=(-target "$triple" -isysroot "$(xcrun --sdk "$TKL_SDK" --show-sdk-path)")
    flags=(--cpu:"$cpu" --os:ios --cc:clang)
    goos=ios
    ;;
esac
[ -x "$cc" ] || fail "Compiler not found: $cc"
flags+=(--clang.exe:"$cc" --clang.linkerexe:"$cc")
# Bash 3.2 treats an empty array as unset under nounset.
for flag in "${cflags[@]+"${cflags[@]}"}"; do flags+=(--passC:"$flag"); done
bash scripts/build_lib.sh "${flags[@]}"
bash scripts/isolate_lib.sh
mkdir -p "$OUT/link"
cp "$OUT/libtkl_isolated.a" "$OUT/link/libtkl.a"
case "$target" in
  android-*) NM="$toolchain/llvm-nm" bash scripts/audit_symbols.sh "$OUT/link/libtkl.a" ;;
  ios-*) bash scripts/audit_symbols.sh "$OUT/link/libtkl.a" ;;
esac
[ "${TKL_BUILD_TESTS:-1}" = 1 ] || exit 0
for test in smoke lengths transactions; do
  "$cc" "${cflags[@]+"${cflags[@]}"}" -std=c11 -Wall -Wextra "tests/abi/$test.c" \
    -Iabi "$OUT/link/libtkl.a" -pthread -lm -o "$OUT/$test"
done
root="$PWD"
library_dir="$(cd "$OUT/link" && pwd)"
(
  cd go/tkl
  CGO_ENABLED=1 GOOS="$goos" GOARCH="$cpu" CC="$cc" GOWORK=off \
    CGO_CFLAGS="${cflags[*]+${cflags[*]}} -I$root/abi" \
    CGO_LDFLAGS="${cflags[*]+${cflags[*]}} -L$library_dir -lm" \
    go test -c -o "$library_dir/../tkl.test" .
)
echo "Built $target archive and ABI smoke executables in $OUT"
