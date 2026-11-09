#!/usr/bin/env bash
# Prelink all libtkl objects into one relocatable object and make every symbol
# except the tkl_* C API local, so no Nim runtime symbol can clash or be shared.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${OUT:-build}"
# The archive's objects say the target: lipo reads only Mach-O.
if arch="$(lipo -archs "$OUT/libtkl.a" 2>/dev/null)"; then
  # ld -r takes the platform and minimum OS from object inputs, not from an
  # archive, so link the archive's members. Current Apple ld rejects -d; all
  # input objects use -fno-common.
  rm -rf "$OUT/objects"
  mkdir "$OUT/objects"
  (cd "$OUT/objects" && ar x ../libtkl.a && find "$PWD" -name '*.o') > "$OUT/objects.txt"
  "${TKL_LD:-ld}" -r -arch "$arch" -filelist "$OUT/objects.txt" \
    -exported_symbol '_tkl_*' -o "$OUT/libtkl_prelinked.o"
  rm -f "$OUT/libtkl_isolated.a"
  "${TKL_LIBTOOL:-libtool}" -static -o "$OUT/libtkl_isolated.a" "$OUT/libtkl_prelinked.o"
else
  "${TKL_LD:-ld}" -r -d --whole-archive "$OUT/libtkl.a" -o "$OUT/libtkl_prelinked.o"
  "${TKL_OBJCOPY:-objcopy}" --wildcard --keep-global-symbol='tkl_*' "$OUT/libtkl_prelinked.o"
  rm -f "$OUT/libtkl_isolated.a"
  "${TKL_AR:-ar}" rcs "$OUT/libtkl_isolated.a" "$OUT/libtkl_prelinked.o"
fi
echo "built $OUT/libtkl_isolated.a"
