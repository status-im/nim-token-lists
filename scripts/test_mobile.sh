#!/usr/bin/env bash
# Execute already-built tests; never silently substitute another target.
set -euo pipefail
cd "$(dirname "$0")/.."
target="${1:?Supply a mobile target built by build_mobile.sh}"
out="${OUT:-build/$target}"
case "$target" in
  android-arm64|android-x86_64)
    adb="${ADB:-adb}"
    selector=(-e)
    [ -z "${ANDROID_SERIAL:-}" ] || selector=(-s "$ANDROID_SERIAL")
    expected=arm64-v8a
    [ "$target" != android-x86_64 ] || expected=x86_64
    actual="$("$adb" "${selector[@]}" shell getprop ro.product.cpu.abi | tr -d '\r')"
    [ "$actual" = "$expected" ] || { echo "Expected $expected device, got $actual" >&2; exit 1; }
    remote="/data/local/tmp/libtkl-tests-$$"
    "$adb" "${selector[@]}" shell mkdir "$remote"
    trap '"$adb" "${selector[@]}" shell rm -r "$remote"' EXIT
    for test in smoke lengths transactions tkl.test; do
      "$adb" "${selector[@]}" push "$out/$test" "$remote/$test"
      "$adb" "${selector[@]}" shell chmod 700 "$remote/$test"
      "$adb" "${selector[@]}" shell "$remote/$test"
    done
    ;;
  ios-simulator-arm64|ios-simulator-x86_64)
    : "${SIMULATOR_UDID:?Set SIMULATOR_UDID to a booted simulator}"
    expected="${target#ios-simulator-}"
    # This runner executes native simulators, not Rosetta destinations.
    actual="$(uname -m)"
    [ "$actual" = "$expected" ] || { echo "Expected $expected simulator, got $actual" >&2; exit 1; }
    out="$(cd "$out" && pwd)"
    for test in smoke lengths transactions tkl.test; do
      codesign --force --sign - "$out/$test"
      xcrun simctl spawn "$SIMULATOR_UDID" "$out/$test"
    done
    ;;
  *) echo "Physical iOS devices require a signed application harness; unsupported runner: $target" >&2; exit 1 ;;
esac
