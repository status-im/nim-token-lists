#!/usr/bin/env python3
"""Check the Windows script's cgo flag quoting with the real Go toolchain."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class CgoFlagsTest(unittest.TestCase):
    def test_include_and_library_paths(self):
        script = Path(__file__).resolve().parents[2] / "scripts/build_windows.sh"
        # Execute the actual environment assignments, not a copy of their quoting.
        command = "CGO_ENABLED=" + script.read_text().rsplit("CGO_ENABLED=", 1)[1]
        for name in ("checkout", "checkout with spaces"):
            with self.subTest(path=name), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp) / name
                include = root / "abi"
                library = root / "build" / "link"
                include.mkdir(parents=True)
                library.mkdir(parents=True)
                (include / "probe.h").write_text("int probe(void);\n")
                (root / "probe.c").write_text("int probe(void) { return 42; }\n")
                subprocess.run(["cc", "-c", str(root / "probe.c"), "-o",
                                str(library / "probe.o")], check=True)
                subprocess.run(["ar", "rcs", str(library / "libprobe.a"),
                                str(library / "probe.o")], check=True)
                module = root / "module"
                module.mkdir()
                (module / "go.mod").write_text("module cgoquotetest\n\ngo 1.26\n")
                (module / "probe.go").write_text(
                    'package probe\n/*\n#cgo LDFLAGS: -lprobe\n'
                    '#include "probe.h"\n*/\nimport "C"\n'
                    'func Value() int { return int(C.probe()) }\n')
                (module / "probe_test.go").write_text(
                    'package probe\nimport "testing"\n'
                    'func TestValue(t *testing.T) { if Value() != 42 { '
                    't.Fatal("incorrect C result") } }\n')
                env = dict(os.environ, root=str(root), library_dir=str(library), cc="cc")
                for key in ("GOOS", "GOARCH", "GOFLAGS", "CGO_CPPFLAGS"):
                    env.pop(key, None)
                result = subprocess.run(["bash", "-c", command], cwd=module,
                                        env=env, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
