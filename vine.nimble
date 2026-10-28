# Package
version       = "0.2.16"
author        = "Axiomantic"
description   = "Zero-Cost Rift CoW Workspaces & Zero-Mirage Git Weaving Engine"
license       = "MIT"
srcDir        = "src"
bin           = @["vine"]
binDir        = "bin"

# Dependencies
requires "nim >= 2.0.0"

task test, "Run test suite":
  exec "nim r tests/test_vine_tripwire.nim"
  exec "nim r tests/test_gate_advanced.nim"
  exec "nim r tests/test_changelog_gate.nim"
  exec "nim r tests/test_notify.nim"
  exec "nim r tests/test_submit_atomic.nim"

after build:
  when defined(macosx) or defined(darwin):
    echo "[BUILD] Ad-hoc codesigning binary on macOS to prevent AMFI SIGKILL..."
    exec "codesign -s - -f bin/vine"
