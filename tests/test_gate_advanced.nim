# tests/test_gate_advanced.nim
# Advanced Two-Key Gate verification suite: Green Mirage elimination,
# Two-Point Diff enforcement, Cryptographic Gate Tokens, and Forensic Timeout Rails.

import tripwire
import tripwire/plugins/osproc as nfos
import std/[os, osproc, strutils, json, tables, unittest]
import strand, gate, weave, guide, config, crypto, process

var testRepoCounter = 0
let initialWorkingDir = getCurrentDir()

proc createTestGitRepo(prefix: string): string =
  try: setCurrentDir(initialWorkingDir)
  except CatchableError: discard
  inc testRepoCounter
  let repo = getTempDir() / (prefix & "_" & $getCurrentProcessId() & "_" & $testRepoCounter)
  removeDir(repo)
  createDir(repo)
  discard execCmdEx("git init -b main -q " & quoteShell(repo))
  discard execCmdEx("git -C " & quoteShell(repo) & " config user.email agent@braid.mesh")
  discard execCmdEx("git -C " & quoteShell(repo) & " config user.name 'Braid Agent'")
  writeFile(repo / "README.md", "# Test Repo\n")
  discard execCmdEx("git -C " & quoteShell(repo) & " add README.md")
  discard execCmdEx("git -C " & quoteShell(repo) & " commit -q -m 'Initial commit'")
  return repo

suite "Vine Advanced Two-Key Gate & Timeout Rail Suite":

  teardown:
    try: setCurrentDir(initialWorkingDir)
    except CatchableError: discard

  test "Key 2 Green Mirage Elimination: fails when no tests detected unless allowNoTests is set":
    sandbox:
      allow(nfos.osprocPluginInstance)

      let repo = createTestGitRepo("vine_tw_mirage")
      defer:
        try: setCurrentDir(initialWorkingDir)
        except CatchableError: discard
        removeDir(repo)

      let (sRes, sCode) = doStrandNew(
        taskId = "task-tw-mirage",
        repoDirParam = repo,
        branchParam = "strand/task-tw-mirage",
        forceWorktree = true
      )
      check sCode == 0
      let strandPath = sRes["strand_path"].getStr()
      defer:
        discard execCmdEx("git -C " & quoteShell(repo) & " worktree remove --force " & quoteShell(strandPath))
        discard execCmdEx("git -C " & quoteShell(repo) & " worktree prune")
        removeDir(strandPath.parentDir())

      # Commit a change in strand
      writeFile(strandPath / "feature.txt", "Some code\n")
      discard execCmdEx("git -C " & quoteShell(strandPath) & " add feature.txt")
      discard execCmdEx("git -C " & quoteShell(strandPath) & " commit -q -m 'feat: some code'")

      # Gate WITHOUT allowNoTests MUST fail with exit code 2 and GATE_FAILED
      let (gFailRes, gFailCode) = doBraidGate(
        branchParam = "strand/task-tw-mirage",
        baseRefParam = "main",
        strandDirParam = strandPath,
        allowNoTests = false
      )
      check gFailCode == 2
      check gFailRes["clean"].getBool() == false
      check gFailRes["status"].getStr() == "semantic_failure"
      check gFailRes["key2_semantic"].getStr().contains("FAIL")

      let mFail = parseFile(strandPath / ".vine.json")
      check mFail["status"].getStr() == "GATE_FAILED"

      # Gate WITH allowNoTests MUST pass
      let (gPassRes, gPassCode) = doBraidGate(
        branchParam = "strand/task-tw-mirage",
        baseRefParam = "main",
        strandDirParam = strandPath,
        allowNoTests = true
      )
      check gPassCode == 0
      check gPassRes["clean"].getBool() == true
      check gPassRes.hasKey("gate_token")

      let mPass = parseFile(strandPath / ".vine.json")
      check mPass["status"].getStr() == "READY_FOR_WEAVE"
      check mPass["lifecycle_state"].getStr() == "GATE_PASSED"

  test "Two-Point Diff Invariant 1: rejects strands where 100% of changes are in tests/":
    sandbox:
      allow(nfos.osprocPluginInstance)

      let repo = createTestGitRepo("vine_tw_tpd_tests_only")
      defer:
        try: setCurrentDir(initialWorkingDir)
        except CatchableError: discard
        removeDir(repo)

      writeFile(repo / "vine.toml", "[verification]\ntest_command = \"sh -c 'exit 0'\"\n")
      discard execCmdEx("git -C " & quoteShell(repo) & " add vine.toml")
      discard execCmdEx("git -C " & quoteShell(repo) & " commit -q -m 'Add config'")

      let (sRes, sCode) = doStrandNew(
        taskId = "task-tw-tpd-1",
        repoDirParam = repo,
        branchParam = "strand/task-tw-tpd-1",
        forceWorktree = true
      )
      check sCode == 0
      let strandPath = sRes["strand_path"].getStr()
      defer:
        discard execCmdEx("git -C " & quoteShell(repo) & " worktree remove --force " & quoteShell(strandPath))
        discard execCmdEx("git -C " & quoteShell(repo) & " worktree prune")
        removeDir(strandPath.parentDir())

      # Commit changes ONLY in tests/
      createDir(strandPath / "tests")
      writeFile(strandPath / "tests" / "test_shelfware.nim", "echo \"test only\"\n")
      discard execCmdEx("git -C " & quoteShell(strandPath) & " add tests/test_shelfware.nim")
      discard execCmdEx("git -C " & quoteShell(strandPath) & " commit -q -m 'test: only tests'")

      let (gRes, gCode) = doBraidGate(
        branchParam = "strand/task-tw-tpd-1",
        baseRefParam = "main",
        strandDirParam = strandPath
      )
      check gCode == 3
      check gRes["clean"].getBool() == false
      check gRes["status"].getStr() == "two_point_diff_failed"
      check gRes["two_point_diff"].getStr() == "FAIL"

      let m = parseFile(strandPath / ".vine.json")
      check m["status"].getStr() == "GATE_FAILED"

  test "Two-Point Diff Invariant 2: rejects strands with new capability lacking consumer call-site":
    sandbox:
      allow(nfos.osprocPluginInstance)

      let repo = createTestGitRepo("vine_tw_tpd_no_consumer")
      defer:
        try: setCurrentDir(initialWorkingDir)
        except CatchableError: discard
        removeDir(repo)

      writeFile(repo / "vine.toml", "[verification]\ntest_command = \"sh -c 'exit 0'\"\n")
      createDir(repo / "src")
      writeFile(repo / "src" / "existing.nim", "echo \"existing app file\"\n")
      discard execCmdEx("git -C " & quoteShell(repo) & " add vine.toml src/existing.nim")
      discard execCmdEx("git -C " & quoteShell(repo) & " commit -q -m 'Initial app code'")

      let (sRes, sCode) = doStrandNew(
        taskId = "task-tw-tpd-2",
        repoDirParam = repo,
        branchParam = "strand/task-tw-tpd-2",
        forceWorktree = true
      )
      check sCode == 0
      let strandPath = sRes["strand_path"].getStr()
      defer:
        discard execCmdEx("git -C " & quoteShell(repo) & " worktree remove --force " & quoteShell(strandPath))
        discard execCmdEx("git -C " & quoteShell(repo) & " worktree prune")
        removeDir(strandPath.parentDir())

      # Add new capability src/unconsumed_feature.nim (without any consumer calling it)
      writeFile(strandPath / "src" / "unconsumed_feature.nim", "proc feature*() = discard\n")
      createDir(strandPath / "tests")
      writeFile(strandPath / "tests" / "test_feature.nim", "import ../src/unconsumed_feature\n")
      discard execCmdEx("git -C " & quoteShell(strandPath) & " add src/unconsumed_feature.nim tests/test_feature.nim")
      discard execCmdEx("git -C " & quoteShell(strandPath) & " commit -q -m 'feat: unconsumed shelfware'")

      let (gRes, gCode) = doBraidGate(
        branchParam = "strand/task-tw-tpd-2",
        baseRefParam = "main",
        strandDirParam = strandPath
      )
      check gCode == 3
      check gRes["clean"].getBool() == false
      check gRes["two_point_diff"].getStr() == "FAIL"
      check gRes["two_point_diff_error"].getStr().contains("lacks a consumer call-site")

  test "Two-Point Diff & Cryptographic Gate Token: passes with consumer and stamps valid gate_token":
    sandbox:
      allow(nfos.osprocPluginInstance)

      let repo = createTestGitRepo("vine_tw_tpd_success")
      defer:
        try: setCurrentDir(initialWorkingDir)
        except CatchableError: discard
        removeDir(repo)

      writeFile(repo / "vine.toml", "[verification]\ntest_command = \"sh -c 'echo Running Tests && exit 0'\"\n")
      createDir(repo / "src")
      writeFile(repo / "src" / "main.nim", "echo \"main entrypoint\"\n")
      discard execCmdEx("git -C " & quoteShell(repo) & " add vine.toml src/main.nim")
      discard execCmdEx("git -C " & quoteShell(repo) & " commit -q -m 'Initial app code'")

      let (sRes, sCode) = doStrandNew(
        taskId = "task-tw-tpd-3",
        repoDirParam = repo,
        branchParam = "strand/task-tw-tpd-3",
        forceWorktree = true
      )
      check sCode == 0
      let strandPath = sRes["strand_path"].getStr()
      defer:
        discard execCmdEx("git -C " & quoteShell(repo) & " worktree remove --force " & quoteShell(strandPath))
        discard execCmdEx("git -C " & quoteShell(repo) & " worktree prune")
        removeDir(strandPath.parentDir())

      # Provider: new capability
      writeFile(strandPath / "src" / "my_provider.nim", "proc provide*(): string = \"live\"\n")
      # Consumer: updated main entrypoint calling the provider
      writeFile(strandPath / "src" / "main.nim", "import my_provider\necho provide()\n")
      # Test: test file
      createDir(strandPath / "tests")
      writeFile(strandPath / "tests" / "test_provider.nim", "import ../src/my_provider\n")
      discard execCmdEx("git -C " & quoteShell(strandPath) & " add src/my_provider.nim src/main.nim tests/test_provider.nim")
      discard execCmdEx("git -C " & quoteShell(strandPath) & " commit -q -m 'feat: provider and consumer integrated'")

      let (gRes, gCode) = doBraidGate(
        branchParam = "strand/task-tw-tpd-3",
        baseRefParam = "main",
        strandDirParam = strandPath
      )
      check gCode == 0
      check gRes["clean"].getBool() == true
      check gRes["two_point_diff"].getStr() == "PASS"
      check gRes["key2_semantic"].getStr() == "PASS"

      # Verify cryptographic gate certificate
      let manifest = parseFile(strandPath / ".vine.json")
      check manifest["status"].getStr() == "READY_FOR_WEAVE"
      check manifest["lifecycle_state"].getStr() == "GATE_PASSED"
      check manifest.hasKey("merge_tree_sha")
      check manifest.hasKey("test_output_hash")
      check manifest.hasKey("gate_token")

      let expectedToken = computeGateToken(manifest["merge_tree_sha"].getStr(), manifest["test_output_hash"].getStr())
      check manifest["gate_token"].getStr() == expectedToken
      check manifest["gate_token"].getStr().len == 64

  test "Key 2 Timeout Gate: frozen test suite terminates, dumps envelope, and exits code 4 (GATE_TIMEOUT)":
    sandbox:
      allow(nfos.osprocPluginInstance)

      let repo = createTestGitRepo("vine_tw_timeout")
      defer:
        try: setCurrentDir(initialWorkingDir)
        except CatchableError: discard
        removeDir(repo)

      # Test command that hangs indefinitely (e.g. sleep 100)
      writeFile(repo / "vine.toml", "[verification]\ntest_command = \"sh -c 'echo [START] Hanging test... && sleep 100 && echo [END]'\"\n")
      createDir(repo / "src")
      writeFile(repo / "src" / "main.nim", "echo \"main entrypoint\"\n")
      discard execCmdEx("git -C " & quoteShell(repo) & " add vine.toml src/main.nim")
      discard execCmdEx("git -C " & quoteShell(repo) & " commit -q -m 'Initial app code'")

      let (sRes, sCode) = doStrandNew(
        taskId = "task-tw-timeout-1",
        repoDirParam = repo,
        branchParam = "strand/task-tw-timeout-1",
        forceWorktree = true
      )
      check sCode == 0
      let strandPath = sRes["strand_path"].getStr()
      defer:
        discard execCmdEx("git -C " & quoteShell(repo) & " worktree remove --force " & quoteShell(strandPath))
        discard execCmdEx("git -C " & quoteShell(repo) & " worktree prune")
        removeDir(strandPath.parentDir())

      # Provider & Consumer
      writeFile(strandPath / "src" / "my_provider.nim", "proc provide*(): string = \"live\"\n")
      writeFile(strandPath / "src" / "main.nim", "import my_provider\necho provide()\n")
      createDir(strandPath / "tests")
      writeFile(strandPath / "tests" / "test_provider.nim", "import ../src/my_provider\n")
      discard execCmdEx("git -C " & quoteShell(strandPath) & " add src/my_provider.nim src/main.nim tests/test_provider.nim")
      discard execCmdEx("git -C " & quoteShell(strandPath) & " commit -q -m 'feat: provider and consumer integrated'")

      # Run gate with a 0.5 second timeout threshold
      let (gRes, gCode) = doBraidGate(
        branchParam = "strand/task-tw-timeout-1",
        baseRefParam = "main",
        strandDirParam = strandPath,
        timeoutSecParam = 0.5
      )

      # 1. Exit code must be 4 (ExitGateTimeout / EXIT_GATE_TIMEOUT)
      check gCode == 4
      check gCode == ExitGateTimeout

      # 2. Gate result attributes
      check gRes["clean"].getBool() == false
      check gRes["key2_semantic"].getStr() == "TIMEOUT"
      check gRes["status"].getStr() == "gate_timeout"
      check gRes.hasKey("forensic_envelope")
      let envelope = gRes["forensic_envelope"].getStr()
      check envelope.contains("[GATE TIMEOUT] Semantic Test Suite Frozen")
      check envelope.contains("[START] Hanging test...")
      check envelope.contains("Do NOT bypass or skip tests")

      # 3. Strand manifest lifecycle state
      let manifest = parseFile(strandPath / ".vine.json")
      check manifest["status"].getStr() == "GATE_TIMEOUT"
      check manifest["lifecycle_state"].getStr() == "GATE_TIMEOUT"
      check manifest.hasKey("timed_out_command")
      check manifest.hasKey("timeout_elapsed_sec")
