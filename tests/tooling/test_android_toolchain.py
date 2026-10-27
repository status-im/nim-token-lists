#!/usr/bin/env python3
"""Verify Android preparation exposes the NDK archiver to Nim's child process.

Nim archives the static library with `llvm-ar rcs` on Linux hosts and with
`ar rcs` on macOS hosts (compiler/extccomp.nim); the NDK ships only llvm-ar.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

HOSTS = (("Linux", "linux-x86_64", "llvm-ar"), ("Darwin", "darwin-x86_64", "ar"))
ARCHS = (("arm64", "aarch64"), ("x86_64", "x86_64"))


class AndroidToolchainTest(unittest.TestCase):
    def prepare(self, tmp, host_os, host_dir, nim_archiver, arch, triple, members="member.o"):
        root = Path(tmp)
        scripts = root / "scripts"
        scripts.mkdir()
        shutil.copy(Path(__file__).resolve().parents[2] / "scripts/build_mobile.sh", scripts)
        host = root / "host"
        host.mkdir()
        tools = root / f"ndk with spaces/toolchains/llvm/prebuilt/{host_dir}/bin"
        tools.mkdir(parents=True)

        def executable(path, body):
            path.write_text("#!/bin/sh\nset -eu\n" + body + "\n")
            path.chmod(0o755)

        executable(host / "uname", f"echo {host_os}")
        for name in ("ar", "llvm-ar"):
            executable(host / name, "echo wrong-host-archiver >&2; exit 99")
        # The NDK archiver records its use and lists the archive members.
        executable(tools / "llvm-ar",
                   f'case "$1" in t) printf "%s\\n" {members!r} ;; '
                   f'*) echo ndk > "$OUT/archiver-used" ;; esac')
        executable(tools / (triple + "-linux-android28-clang"), ":")
        # Nim's library step, as run on this host.
        executable(scripts / "build_lib.sh",
                   f'mkdir -p "$OUT"; : > "$OUT/libtkl.a"; {nim_archiver} rcs "$OUT/libtkl.a"')
        executable(scripts / "isolate_lib.sh",
                   'cp "$OUT/libtkl.a" "$OUT/libtkl_isolated.a"')
        executable(scripts / "audit_symbols.sh", ":")
        env = dict(os.environ, PATH=str(host) + os.pathsep + os.environ["PATH"],
                   ANDROID_NDK_ROOT=str(root / "ndk with spaces"),
                   TKL_BUILD_TESTS="0", OUT=str(root / "output"), ANDROID_API="28")
        result = subprocess.run(["bash", str(scripts / "build_mobile.sh"), "android-" + arch],
                                env=env, text=True, capture_output=True)
        return root, result

    def test_ndk_archiver_precedes_host_tools(self):
        for host_os, host_dir, nim_archiver in HOSTS:
            for arch, triple in ARCHS:
                with self.subTest(host=host_os, arch=arch), tempfile.TemporaryDirectory() as tmp:
                    root, result = self.prepare(tmp, host_os, host_dir, nim_archiver, arch, triple)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual((root / "output/archiver-used").read_text(), "ndk\n")

    def test_empty_archive_fails_before_isolation(self):
        with tempfile.TemporaryDirectory() as tmp:
            root, result = self.prepare(tmp, *HOSTS[0], *ARCHS[0], members="")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("empty archive", result.stderr)
            self.assertFalse((root / "output/libtkl_isolated.a").exists())


if __name__ == "__main__":
    unittest.main()
