version = "0.2.0"
author = "Status"
description = "Sans-I/O fungible token list core"
license = "MIT"
requires "nim >= 2.2.10", "results >= 0.5.1", "json_serialization >= 0.5.0",
  "serialization >= 0.5.4", "stew >= 0.5.1"
skipDirs = @["abi", "go", "build", "docs", "fixtures", "tests", "vendor"]
task test, "Run core tests with vendored dependency pins":
  exec "bash scripts/test_core.sh"
