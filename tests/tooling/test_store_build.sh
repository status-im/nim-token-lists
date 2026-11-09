#!/usr/bin/env bash
# Build libtkl the way a caller does: from another directory, `nim c` the
# read-only store entry's abi/libtkl.nim with the dependency --paths and
# nothing resolved from the nimble store. Nothing may be written into the
# store. Every path (store, checkout, outputs) contains a space, a non-ASCII
# letter and a quote.
set -euo pipefail
cd "$(dirname "$0")/../.."
# nimble cannot run a Nim it installs into a store path with spaces: use the one on PATH.
nimble() { command "${NIMBLE:-nimble}" --useSystemNim "$@"; }
NIM="${NIM:-nim}"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/tkl build José's.XXXXXX")"
trap 'chmod -R u+w "$tmp"; rm -rf "$tmp"' EXIT
export NIMBLE_DIR="$tmp/store"
# Install from a plain copy: nimble may run git submodule commands in a
# checkout and repoint its submodules at a temporary copy.
mkdir "$tmp/src"
git ls-files -s | awk '$1 != "160000" {print $4}' | tar -cf - -T - | tar -xf - -C "$tmp/src"
(cd "$tmp/src" && nimble -y install >/dev/null)
pkg="$(echo "$NIMBLE_DIR"/pkgs2/tokenlists-*)"
[ -f "$pkg/tokenlists.nimble" ] || { echo "FAIL: tokenlists not installed in $NIMBLE_DIR" >&2; exit 1; }
paths=(--noNimblePath)
while IFS= read -r path; do paths+=("--path:$path"); done < <(nimble path results json_serialization serialization stew faststreams | grep "^/")
chmod -R a-w "$NIMBLE_DIR/pkgs2"
# build <out> <flags...>: as status-go builds it, under --skipParentCfg.
build() { local out="$1"; shift; (cd "$tmp" && "$NIM" c --skipParentCfg "$@" --nimcache:"$out/nimcache" -o:"$out/libtkl.a" "$pkg/abi/libtkl.nim"); }
build "$tmp/out" "${paths[@]}"
[ -f "$tmp/out/libtkl.a" ] || { echo "FAIL: missing $tmp/out/libtkl.a" >&2; exit 1; }
# Sealed as status-go links it, the archive exports exactly the tkl_* ABI.
OUT="$tmp/out" bash scripts/isolate_lib.sh
bash scripts/audit_symbols.sh "$tmp/out/libtkl_isolated.a"
# A policy the library cannot run under fails the build and says why.
if build "$tmp/out-refc" "${paths[@]}" --mm:refc >"$tmp/refc.log" 2>&1; then
  echo "FAIL: libtkl built with --mm:refc" >&2; exit 1
fi
grep -qF "libtkl needs --mm:orc (or arc) and --threads:on" "$tmp/refc.log" || { echo "FAIL: refc build did not say why" >&2; cat "$tmp/refc.log" >&2; exit 1; }
echo 'STORE BUILD OK'
