#!/usr/bin/env python3
"""Verify Android preparation exposes the NDK archiver to Nim's child process."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class AndroidToolchainTest(unittest.TestCase):
    def test_ndk_archiver_precedes_host_tools(self):
        source = Path(__file__).resolve().parents[2]
        for arch, triple in (("arm64", "aarch64"), ("x86_64", "x86_64")):
            with self.subTest(arch=arch), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                scripts = root / "scripts"
                scripts.mkdir()
                shutil.copy(source / "scripts/build_mobile.sh", scripts)
                host = root / "host"
                host.mkdir()
                tools = root / "ndk with spaces/toolchains/llvm/prebuilt/linux-x86_64/bin"
                tools.mkdir(parents=True)

                def executable(path, body):
                    path.write_text("#!/bin/sh\nset -eu\n" + body + "\n")
                    path.chmod(0o755)

                executable(host / "uname", "echo Linux")
                executable(host / "llvm-ar", "echo wrong-host-archiver >&2; exit 99")
                executable(tools / "llvm-ar", 'echo ndk > "$OUT/archiver-used"')
                executable(tools / (triple + "-linux-android28-clang"), ":")
                executable(scripts / "build_lib.sh",
                           'mkdir -p "$OUT"; llvm-ar; : > "$OUT/libtkl.a"')
                executable(scripts / "isolate_lib.sh",
                           'cp "$OUT/libtkl.a" "$OUT/libtkl_isolated.a"')
                executable(scripts / "audit_symbols.sh", ":")
                env = dict(os.environ, PATH=str(host) + os.pathsep + os.environ["PATH"],
                           ANDROID_NDK_ROOT=str(root / "ndk with spaces"),
                           TKL_BUILD_TESTS="0", OUT=str(root / "output"), ANDROID_API="28")
                result = subprocess.run(["bash", str(scripts / "build_mobile.sh"),
                                         "android-" + arch], env=env, text=True,
                                        capture_output=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual((root / "output/archiver-used").read_text(), "ndk\n")


if __name__ == "__main__":
    unittest.main()
