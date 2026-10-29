#!/usr/bin/env python3
"""Check the compiler arguments scripts/build_lib.sh passes, with a stub Nim."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class BuildLibFlagsTest(unittest.TestCase):
    def run_build(self, tmp, *args, **env):
        root = Path(tmp)
        (root / "scripts").mkdir()
        shutil.copy(Path(__file__).resolve().parents[2] / "scripts/build_lib.sh", root / "scripts")
        nim = root / "nim"
        nim.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$NIM_ARGS"\n')
        nim.chmod(0o755)
        record = root / "args"
        full_env = dict(os.environ, NIM=str(nim), NIM_ARGS=str(record), OUT=str(root / "out"))
        for key in ("NIM_PARAMS", "EXTRA_NIMFLAGS", "TKL_VENDOR_DEPS"):
            full_env.pop(key, None)
        full_env.update(env)
        subprocess.run(["bash", str(root / "scripts/build_lib.sh"), *args],
                       env=full_env, check=True, capture_output=True)
        return record.read_text().splitlines()

    def test_nim_params_are_the_last_options(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = self.run_build(tmp, "--cpu:arm64", EXTRA_NIMFLAGS="-d:extra",
                                  NIM_PARAMS="--path:/deps/results --mm:refc")
            self.assertEqual(args[-3:], ["--path:/deps/results", "--mm:refc", "abi/libtkl.nim"])
            self.assertLess(args.index("-d:extra"), args.index("--cpu:arm64"))

    def test_nim_params_keep_shell_quoting(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = self.run_build(tmp, NIM_PARAMS='--path:"/tkl store/results" --path:/deps/stew')
            self.assertEqual(args[-3:], ["--path:/tkl store/results", "--path:/deps/stew", "abi/libtkl.nim"])

    def test_vendored_dependencies_by_default(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = self.run_build(tmp)
            self.assertIn("--path:vendor/nim-result", args)
            self.assertIn("--path:.", args)

    def test_vendored_dependencies_can_be_disabled(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = self.run_build(tmp, TKL_VENDOR_DEPS="0")
            self.assertFalse([a for a in args if a.startswith("--path:vendor/")], args)
            self.assertIn("--path:.", args)


if __name__ == "__main__":
    unittest.main()
