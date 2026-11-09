#!/usr/bin/env python3
"""Verify `make lib-android` and `make lib-ios` keep their target flags when
the caller passes NIM_PARAMS to make, which recursive make would otherwise
let override them.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
TARGETS = (
    ("lib-android", ["ARCH=arm64"], ["--os:linux", "-d:android", "--cpu:arm64"]),
    ("lib-ios", ["ARCH=arm64", "IPHONE_SDK=iphonesimulator"],
     ["--os:ios", "--cpu:arm64", "--passC:arm64-apple-ios14.0-simulator"]),
)


class MobileParamsTest(unittest.TestCase):
    def build(self, tmp, target, args):
        root = Path(tmp)
        (root / "scripts").mkdir()
        shutil.copy(REPO / "Makefile", root)
        shutil.copy(REPO / "scripts/build_mobile.sh", root / "scripts")
        host = root / "host"
        host.mkdir()
        tools = root / "ndk/toolchains/llvm/prebuilt/linux-x86_64/bin"
        tools.mkdir(parents=True)

        def executable(path, body):
            path.write_text("#!/bin/sh\nset -eu\n" + body + "\n")
            path.chmod(0o755)

        executable(host / "uname", "echo Linux")
        # Nim records its arguments and writes the archive `-o:` names.
        executable(host / "nim", f'''printf '%s\\n' "$@" > "{root}/nim-args"
for arg; do case "$arg" in -o:*) mkdir -p "$(dirname "${{arg#-o:}}")"; : > "${{arg#-o:}}" ;; esac; done''')
        executable(host / "xcrun", f'''case "$*" in
  *--find*) echo "{host}/clang" ;;
  *--show-sdk-path*) echo /sdk ;;
esac''')
        executable(host / "clang", ":")
        for name in ("llvm-ar", "aarch64-linux-android28-clang"):
            executable(tools / name, ":")
        executable(root / "scripts/isolate_lib.sh", 'cp "$OUT/libtkl.a" "$OUT/libtkl_isolated.a"')
        executable(root / "scripts/audit_symbols.sh", ":")
        env = dict(os.environ, PATH=str(host) + os.pathsep + os.environ["PATH"],
                   ANDROID_NDK_ROOT=str(root / "ndk"), TKL_BUILD_TESTS="0")
        env.pop("MAKEFLAGS", None)
        result = subprocess.run(["make", "-C", str(root), target, "NIM=nim",
                                 "NIM_PARAMS=-d:caller --cpu:amd64"] + args,
                                env=env, text=True, capture_output=True)
        nim_args = (root / "nim-args").read_text().splitlines() if result.returncode == 0 else []
        return result, nim_args

    def test_target_flags_survive_caller_params(self):
        for target, args, expected in TARGETS:
            with self.subTest(target=target), tempfile.TemporaryDirectory() as tmp:
                result, nim_args = self.build(tmp, target, args)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("-d:caller", nim_args)
                for flag in expected:
                    self.assertIn(flag, nim_args)
                # The target's --cpu comes after the caller's, so it wins.
                cpus = [a for a in nim_args if a.startswith("--cpu:")]
                self.assertEqual(cpus[-1], "--cpu:arm64")


if __name__ == "__main__":
    unittest.main()
