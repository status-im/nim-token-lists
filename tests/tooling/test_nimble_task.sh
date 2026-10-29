#!/usr/bin/env bash
# Build libtkl the way an embedder does: from another directory, run
# `nim libtkl <dir>/tokenlists.nims`, a wrapper that includes the read-only
# store entry's tokenlists.nimble, with the dependency --paths in NIM_PARAMS.
# Nothing may be written into the store. Every path (store, checkout, outputs)
# contains a space, a non-ASCII letter and a quote; NIM_PARAMS quotes each
# --path for the shell, as embedders do.
set -euo pipefail
cd "$(dirname "$0")/../.."
# nimble cannot run a Nim it installs into a store path with spaces: use the one on PATH.
nimble() { command "${NIMBLE:-nimble}" --useSystemNim "$@"; }
NIM="${NIM:-nim}"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tkl task José's.XXXXXX")"
trap 'chmod -R u+w "$tmp"; rm -rf "$tmp"' EXIT
export NIMBLE_DIR="$tmp/store"
# Install from a plain copy: nimble may run git submodule commands in a
# checkout and repoint its submodules at a temporary copy.
mkdir "$tmp/src"
git ls-files -s | awk '$1 != "160000" {print $4}' | tar -cf - -T - | tar -xf - -C "$tmp/src"
(cd "$tmp/src" && nimble -y install >/dev/null)
pkg="$(echo "$NIMBLE_DIR"/pkgs2/tokenlists-*)"
[ -f "$pkg/tokenlists.nimble" ] || { echo "FAIL: tokenlists not installed in $NIMBLE_DIR" >&2; exit 1; }
quote() { local q="'\\''"; printf "'%s'" "${1//\'/$q}"; }
deps=()
paths=()
while IFS= read -r path; do deps+=("$path"); paths+=("$(quote "--path:$path")"); done < <(nimble path results json_serialization serialization stew faststreams | grep "^/")
params="${paths[*]}"
chmod -R a-w "$NIMBLE_DIR/pkgs2"
store_files() { (cd "$NIMBLE_DIR/pkgs2" && find . | LC_ALL=C sort); }
before="$(store_files)"
# nims <package dir>: a .nims wrapper including its tokenlists.nimble, as embedders write.
nims() { local dir; dir="$(mktemp -d "$tmp/nims.XXXX")"; printf 'include "%s"\n' "$1/tokenlists.nimble" >"$dir/tokenlists.nims"; echo "$dir/tokenlists.nims"; }
touch "$tmp/stamp"
(cd "$tmp" && LIB_OUT_DIR="$tmp/out" NIM_PARAMS="$params" "$NIM" libtkl "$(nims "$pkg")")
[ "$before" = "$(store_files)" ] || { echo "FAIL: libtkl changed the store file list" >&2; diff <(echo "$before") <(store_files) || true; exit 1; }
modified="$(find "$NIMBLE_DIR/pkgs2" -newer "$tmp/stamp")"
[ -z "$modified" ] || { echo "FAIL: libtkl modified store files: $modified" >&2; exit 1; }
for file in link/libtkl.a link/tkl.h nimcache; do
  [ -e "$tmp/out/$file" ] || { echo "FAIL: missing $tmp/out/$file" >&2; exit 1; }
done
bash scripts/audit_symbols.sh "$tmp/out/link/libtkl.a"
# The embedded entry ignores a nimble.paths left in the package: one listing
# the real dependencies does not stand in for NIM_PARAMS --paths.
cp -R "$pkg" "$tmp/resolved"
chmod -R u+w "$tmp/resolved"
printf -- '--path:"%s"\n' "${deps[@]}" >"$tmp/resolved/nimble.paths"
chmod -R a-w "$tmp/resolved"
# A read-only package that is not a store entry (no nimblemeta.json).
cp -R "$pkg" "$tmp/plain"
chmod -R u+w "$tmp/plain"
rm "$tmp/plain/nimblemeta.json"
chmod -R a-w "$tmp/plain"
# expect_fail <task> <tokenlists.nims> <message> <env...>: the embedded task must fail and say why.
expect_fail() {
  local task="$1" script="$2" message="$3" log="$tmp/fail.log"
  shift 3
  if (cd "$tmp" && env "$@" "$NIM" "$task" "$script") >"$log" 2>&1; then
    echo "FAIL: $task $script with $* succeeded" >&2; exit 1
  fi
  grep -qF -- "$message" "$log" || { echo "FAIL: $task $script with $* did not report: $message" >&2; cat "$log" >&2; exit 1; }
}
# Without NIM_PARAMS --paths the dependencies are missing; no global store fallback.
expect_fail libtkl "$(nims "$pkg")" "Error: cannot open file:" LIB_OUT_DIR="$tmp/out-empty" NIM_PARAMS=
expect_fail libtkl "$(nims "$tmp/resolved")" "Error: cannot open file:" LIB_OUT_DIR="$tmp/out-resolved" NIM_PARAMS=
expect_fail libtkl "$(nims "$pkg")" "set LIB_OUT_DIR; the package dir is read-only" LIB_OUT_DIR= NIM_PARAMS="$params"
expect_fail libtkl "$(nims "$tmp/plain")" "set LIB_OUT_DIR; the package dir is read-only" LIB_OUT_DIR= NIM_PARAMS="$params"
expect_fail libtklIOS "$(nims "$pkg")" "IPHONE_SDK must be iphoneos or iphonesimulator" LIB_OUT_DIR="$tmp/out-ios" IPHONE_SDK=macosx
expect_fail libtklIOS "$(nims "$pkg")" "iphoneos supports ARCH=arm64 only" LIB_OUT_DIR="$tmp/out-ios" IPHONE_SDK=iphoneos ARCH=x86_64
expect_fail libtklIOS "$(nims "$pkg")" "ARCH must be arm64 or x86_64" LIB_OUT_DIR="$tmp/out-ios" IPHONE_SDK=iphonesimulator ARCH=armv7
[ "$before" = "$(store_files)" ] || { echo "FAIL: a failed task changed the store file list" >&2; exit 1; }
# Standalone, in a `nimble setup` checkout: nimble.paths entries stay one argument each.
cp -R "$tmp/src" "$tmp/check out"
(cd "$tmp/check out" && nimble -y setup >/dev/null && LIB_OUT_DIR="$tmp/out standalone" nimble libtkl)
grep -qF "\\xC3\\xA9\\'s" "$tmp/check out/nimble.paths" || { echo "FAIL: nimble setup wrote no escaped --path" >&2; exit 1; }
bash scripts/audit_symbols.sh "$tmp/out standalone/link/libtkl.a"
echo 'NIMBLE TASK OK'
