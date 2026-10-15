# braid/tests/test_braid_tripwire.nim
# Native Nim integration tests for Braid with Tripwire Git passthrough & timeline spying.

import tripwire
import tripwire/plugins/osproc as nfos
import std/[os, osproc, strutils, json, tables, unittest]
import strand, gate, weave, guide, config, crypto

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

suite "Vine Native Tripwire Git Passthrough Suite":

  teardown:
    try: setCurrentDir(initialWorkingDir)
    except CatchableError: discard

  test "Two-Key Gate executes real git merge-tree with Tripwire spy verification":
    sandbox:
      # Allow Git commands to passthrough to real Git binary
      allow(nfos.osprocPluginInstance)

      let repo = createTestGitRepo("braid_tw_gate")
      defer:
        try: setCurrentDir(initialWorkingDir)
        except CatchableError: discard
        removeDir(repo)

      # 1. Create a strand
      let (sRes, sCode) = doStrandNew(
        taskId = "task-tw-1",
        repoDirParam = repo,
        branchParam = "strand/task-tw-1",
        forceWorktree = true
      )
      check sCode == 0
      let strandPath = sRes["strand_path"].getStr()
      defer:
        discard execCmdEx("git -C " & quoteShell(repo) & " worktree remove --force " & quoteShell(strandPath))
        discard execCmdEx("git -C " & quoteShell(repo) & " worktree prune")
        removeDir(strandPath.parentDir())

      # 2. Commit a feature file inside the strand
      writeFile(strandPath / "feature.txt", "Tripwire verified feature\n")
      discard execCmdEx("git -C " & quoteShell(strandPath) & " add feature.txt")
      discard execCmdEx("git -C " & quoteShell(strandPath) & " commit -q -m 'feat: feature 1'")

      # 3. Run the Two-Key Gate
      let (gRes, gCode) = doBraidGate(
        branchParam = "strand/task-tw-1",
        baseRefParam = "main",
        strandDirParam = strandPath,
        allowNoTests = true
      )
      check gCode == 0
      check gRes["clean"].getBool() == true
      check gRes["key1_mechanical"].getStr() == "PASS"
      check gRes.hasKey("gate_token")

      # 4. TRIPWIRE SPY: Verify Git merge-tree was executed with exact flags
      let entries = currentVerifier().timeline.entries
      check entries.len > 0
      var foundMergeTree = false
      for e in entries:
        if e.procName == "execCmdEx" and tables.hasKey(e.args, ".fp") and e.args[".fp"].contains("merge-tree --write-tree"):
          foundMergeTree = true
      check foundMergeTree

  test "Diverged canonical trunk triggers sync and passes Two-Key gate":
    sandbox:
      allow(nfos.osprocPluginInstance)

      let repo = createTestGitRepo("braid_tw_sync")
      defer:
        try: setCurrentDir(initialWorkingDir)
        except CatchableError: discard
        removeDir(repo)

      # 1. Create a strand at C0
      let (sRes, sCode) = doStrandNew(
        taskId = "task-tw-sync",
        repoDirParam = repo,
        branchParam = "strand/task-tw-sync",
        forceWorktree = true
      )
      check sCode == 0
      let strandPath = sRes["strand_path"].getStr()
      defer:
        discard execCmdEx("git -C " & quoteShell(repo) & " worktree remove --force " & quoteShell(strandPath))
        discard execCmdEx("git -C " & quoteShell(repo) & " worktree prune")
        removeDir(strandPath.parentDir())

      # 2. Strand commits feature
      writeFile(strandPath / "feature.txt", "Parallel strand feature\n")
      discard execCmdEx("git -C " & quoteShell(strandPath) & " add feature.txt")
      discard execCmdEx("git -C " & quoteShell(strandPath) & " commit -q -m 'feat: parallel strand'")

      # 3. Canonical trunk advances independently
      writeFile(repo / "trunk.txt", "Independent trunk update\n")
      discard execCmdEx("git -C " & quoteShell(repo) & " add trunk.txt")
      discard execCmdEx("git -C " & quoteShell(repo) & " commit -q -m 'chore: trunk update'")

      # 4. Weave without sync fails fast
      let (wFailRes, wFailCode) = doBraidWeave(
        branchParam = "strand/task-tw-sync",
        baseRefParam = "main",
        strandDirParam = strandPath,
        allowNoTests = true
      )
      check wFailCode != 0
      check wFailRes["status"].getStr() == "fast_forward_failed"

      # 5. Run braid sync to incorporate trunk
      let (syncRes, syncCode) = doStrandSync(
        strandDirParam = strandPath,
        baseRefParam = "main"
      )
      check syncCode == 0
      check syncRes["status"].getStr() == "synced"
      check fileExists(strandPath / "trunk.txt")

      # 6. Weave succeeds with fast-forward
      let (wRes, wCode) = doBraidWeave(
        branchParam = "strand/task-tw-sync",
        baseRefParam = "main",
        strandDirParam = strandPath,
        allowNoTests = true
      )
      check wCode == 0
      check wRes["status"].getStr() == "woven"
      check fileExists(repo / "feature.txt")
      check fileExists(repo / "trunk.txt")

  test "Key 1 Mechanical Conflict Negative Control blocks weave and identifies conflicts":
    sandbox:
      allow(nfos.osprocPluginInstance)

      let repo = createTestGitRepo("braid_tw_conflict")
      defer:
        try: setCurrentDir(initialWorkingDir)
        except CatchableError: discard
        removeDir(repo)

      # Create a file in main
      writeFile(repo / "common.txt", "Initial line 1\nInitial line 2\n")
      discard execCmdEx("git -C " & quoteShell(repo) & " add common.txt")
      discard execCmdEx("git -C " & quoteShell(repo) & " commit -q -m 'Add common.txt'")

      # Create strand
      let (sRes, sCode) = doStrandNew(
        taskId = "task-tw-conflict",
        repoDirParam = repo,
        branchParam = "strand/task-tw-conflict",
        forceWorktree = true
      )
      check sCode == 0
      let strandPath = sRes["strand_path"].getStr()
      defer:
        discard execCmdEx("git -C " & quoteShell(repo) & " worktree remove --force " & quoteShell(strandPath))
        discard execCmdEx("git -C " & quoteShell(repo) & " worktree prune")
        removeDir(strandPath.parentDir())

      # Edit common.txt in strand
      writeFile(strandPath / "common.txt", "Strand changed line 1\nInitial line 2\n")
      discard execCmdEx("git -C " & quoteShell(strandPath) & " add common.txt")
      discard execCmdEx("git -C " & quoteShell(strandPath) & " commit -q -m 'strand: modify line 1'")

      # Edit common.txt differently in trunk
      writeFile(repo / "common.txt", "Trunk changed line 1 differently\nInitial line 2\n")
      discard execCmdEx("git -C " & quoteShell(repo) & " add common.txt")
      discard execCmdEx("git -C " & quoteShell(repo) & " commit -q -m 'trunk: modify line 1 differently'")

      # Run Gate: Key 1 MUST fail
      let (gRes, gCode) = doBraidGate(
        branchParam = "strand/task-tw-conflict",
        baseRefParam = "main",
        strandDirParam = strandPath
      )
      check gCode == 1
      check gRes["clean"].getBool() == false
      check gRes["key1_mechanical"].getStr() == "FAIL"
      check gRes["status"].getStr() == "conflict"
      check gRes.hasKey("conflicts")
      check gRes["conflicts"].len > 0

      # Attempting weave MUST fail fast
      let (wRes, wCode) = doBraidWeave(
        branchParam = "strand/task-tw-conflict",
        baseRefParam = "main",
        strandDirParam = strandPath
      )
      check wCode != 0
      check wRes["status"].getStr() == "weave_rejected"

      # TRIPWIRE SPY: Verify merge-tree was executed and recorded on timeline
      let entries = currentVerifier().timeline.entries
      var foundConflictMergeTree = false
      for e in entries:
        if e.procName == "execCmdEx" and tables.hasKey(e.args, ".fp") and e.args[".fp"].contains("merge-tree --write-tree"):
          foundConflictMergeTree = true
      check foundConflictMergeTree

  test "Key 2 Semantic Compiler Failure Negative Control enforces Zero Green Mirage":
    sandbox:
      allow(nfos.osprocPluginInstance)

      let repo = createTestGitRepo("braid_tw_semantic")
      defer:
        try: setCurrentDir(initialWorkingDir)
        except CatchableError: discard
        removeDir(repo)

      # Write braid.toml with a test command that is guaranteed to fail
      writeFile(repo / "vine.toml", "[verification]\ntest_command = \"sh -c 'echo Compiler Error && exit 42'\"\n")
      discard execCmdEx("git -C " & quoteShell(repo) & " add vine.toml")
      discard execCmdEx("git -C " & quoteShell(repo) & " commit -q -m 'Add failing test config'")

      # Create strand
      let (sRes, sCode) = doStrandNew(
        taskId = "task-tw-semantic",
        repoDirParam = repo,
        branchParam = "strand/task-tw-semantic",
        forceWorktree = true
      )
      check sCode == 0
      let strandPath = sRes["strand_path"].getStr()
      defer:
        discard execCmdEx("git -C " & quoteShell(repo) & " worktree remove --force " & quoteShell(strandPath))
        discard execCmdEx("git -C " & quoteShell(repo) & " worktree prune")
        removeDir(strandPath.parentDir())

      # Commit a change in strand with NO text conflicts
      writeFile(strandPath / "code.txt", "Syntactically clean code\n")
      discard execCmdEx("git -C " & quoteShell(strandPath) & " add code.txt")
      discard execCmdEx("git -C " & quoteShell(strandPath) & " commit -q -m 'feat: clean code'")

      # Run Gate: Key 1 must PASS, but Key 2 must FAIL!
      let (gRes, gCode) = doBraidGate(
        branchParam = "strand/task-tw-semantic",
        baseRefParam = "main",
        strandDirParam = strandPath
      )
      check gCode == 2
      check gRes["key1_mechanical"].getStr() == "PASS"
      check gRes["key2_semantic"].getStr() == "FAIL"
      check gRes["clean"].getBool() == false
      check gRes["status"].getStr() == "semantic_failure"
      check gRes["compiler_output"].getStr().contains("Compiler Error")

      # Weave MUST reject this green mirage!
      let (wRes, wCode) = doBraidWeave(
        branchParam = "strand/task-tw-semantic",
        baseRefParam = "main",
        strandDirParam = strandPath
      )
      check wCode != 0
      check wRes["status"].getStr() == "weave_rejected"

  test "Strand Prune cleans up expired strands and prunes git worktrees":
    sandbox:
      allow(nfos.osprocPluginInstance)

      let repo = createTestGitRepo("braid_tw_prune")
      defer:
        try: setCurrentDir(initialWorkingDir)
        except CatchableError: discard
        removeDir(repo)

      # 1. Create a strand
      let (sRes, sCode) = doStrandNew(
        taskId = "task-tw-prune",
        repoDirParam = repo,
        branchParam = "strand/task-tw-prune",
        forceWorktree = true
      )
      check sCode == 0
      let strandPath = sRes["strand_path"].getStr()
      check dirExists(strandPath)

      # 2. Verify git worktree list includes strand
      let (wtBefore, _) = execCmdEx("git -C " & quoteShell(repo) & " worktree list")
      check wtBefore.contains(strandPath)

      # 3. Run prune with maxAgeHours = 0.0 and dryRun = false
      let pruneRes = doStrandPrune(repoDirParam = repo, maxAgeHours = 0.0, dryRun = false)
      check pruneRes["pruned_count"].getInt() >= 1

      # 4. Verify strand directory is removed
      check not dirExists(strandPath)

      # 5. Verify git worktree list does not contain strandPath
      let (wtAfter, _) = execCmdEx("git -C " & quoteShell(repo) & " worktree list")
      check not wtAfter.contains(strandPath)

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

