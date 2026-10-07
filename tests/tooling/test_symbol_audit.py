#!/usr/bin/env python3
"""Check symbol audit parsing and failure diagnostics without platform tools."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class SymbolAuditTest(unittest.TestCase):
    def test_line_endings_and_mismatch(self):
        source = Path(__file__).resolve().parents[2]
        for ending in ("\n", "\r\n"):
            for unexpected in (False, True):
                with self.subTest(ending=repr(ending), unexpected=unexpected):
                    with tempfile.TemporaryDirectory() as tmp:
                        root = Path(tmp)
                        (root / "scripts").mkdir()
                        (root / "abi").mkdir()
                        shutil.copy(source / "scripts/audit_symbols.sh", root / "scripts")
                        (root / "abi/exports-linux.txt").write_bytes(
                            ("tkl_create" + ending).encode())
                        symbols = "00000000 T tkl_create" + ending
                        if unexpected:
                            symbols += "00000001 T leaked_runtime_symbol" + ending
                        (root / "symbols").write_bytes(symbols.encode())
                        nm = root / "nm"
                        nm.write_text('#!/bin/sh\ncat "$AUDIT_TEST_SYMBOLS"\n')
                        nm.chmod(0o755)
                        result = subprocess.run(
                            ["bash", str(root / "scripts/audit_symbols.sh"), "fixture.a"],
                            env=dict(os.environ, NM=str(nm), AUDIT_TEST_SYMBOLS=str(root / "symbols")),
                            text=True, capture_output=True)
                        self.assertEqual(result.returncode, int(unexpected), result.stderr)
                        if unexpected:
                            self.assertIn("+leaked_runtime_symbol", result.stdout)
                            self.assertNotIn("/dev/fd", result.stderr)
                        else:
                            self.assertIn("AUDIT OK", result.stdout)


if __name__ == "__main__":
    unittest.main()
