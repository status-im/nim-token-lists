version = "0.2.0"
author = "Status"
description = "Sans-I/O fungible token list core"
license = "MIT"
requires "nim >= 2.2.10", "results >= 0.5.1"
# The fixed JSON escape table (0x0f/0x1f) is only in this commit and v0.5.0+,
# whose format v1 our flavor does not compile against; pin the vendored set.
requires "json_serialization#a8c5169c5e1aa34273e97a1a60bf82e9c8911641",
  "serialization >= 0.5.4", "stew >= 0.5.1"
skipDirs = @["abi", "go", "build", "docs", "fixtures", "tests", "vendor"]
task test, "Run core tests with vendored dependency pins":
  exec "bash scripts/test_core.sh"
