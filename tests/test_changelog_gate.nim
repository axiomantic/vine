# tests/test_changelog_gate.nim
# Comprehensive unit & integration suite for the Pre-Weave Changelog Gate and 'vine changelog' command.

import std/[os, osproc, strutils, json, unittest]
import tripwire
import tripwire/plugins/osproc as nfos
import gate, config, strand, crypto, process

suite "Vine Pre-Weave Changelog Gate & 'vine changelog' Suite":

  test "hasUnreleasedSection detection":
    check hasUnreleasedSection("## [Unreleased]\n\n### Added\n- Something") == true
    check hasUnreleasedSection("## Unreleased\n\n### Added\n- Something") == true
    check hasUnreleasedSection("## [unreleased] - yyyy-mm-dd\n\n- Fix") == true
    check hasUnreleasedSection("# Changelog\n\n## [0.2.11] - 2026-10-17\n### Added") == false
    check hasUnreleasedSection("# Readme\nNo changelog here.") == false

  test "ensureUnreleasedSection creates section before first version":
    let before = "# Changelog\n\nAll notable changes...\n\n## [0.2.11] - 2026-10-17\n### Added\n- Feature A\n"
    let after = ensureUnreleasedSection(before)
    check hasUnreleasedSection(after)
    check after.contains("## [Unreleased]\n\n### Added\n\n## [0.2.11]")
    # Idempotent:
    let afterAgain = ensureUnreleasedSection(after)
    check afterAgain == after

  test "addChangelogEntry appends entries cleanly under specified sections":
    let initial = "# Changelog\n\n## [0.1.0] - 2026-10-01\n"
    let withFeature = addChangelogEntry(initial, "Added SSE streaming", "Added")
    check withFeature.contains("## [Unreleased]")
    check withFeature.contains("### Added\n- Added SSE streaming")

    let withFix = addChangelogEntry(withFeature, "Fixed socket hang", "Fixed")
    check withFix.contains("### Fixed\n- Fixed socket hang")

    let withSecondFeature = addChangelogEntry(withFix, "Added CLI flag --json", "Added")
    check withSecondFeature.contains("- Added SSE streaming\n- Added CLI flag --json")

  test "doChangelogOperation CLI lifecycle":
    let tmpDir = getTempDir() / ("vine_cl_test_" & $getCurrentProcessId())
    removeDir(tmpDir)
    createDir(tmpDir)
    defer: removeDir(tmpDir)

    # 1. No changelog -> creates CHANGELOG.md with entry
    let (msg1, code1) = doChangelogOperation(tmpDir, entry = "Initial capability", section = "Added")
    check code1 == 0
    check fileExists(tmpDir / "CHANGELOG.md")
    let c1 = readFile(tmpDir / "CHANGELOG.md")
    check c1.contains("## [Unreleased]")
    check c1.contains("- Initial capability")

    # 2. Ensure unreleased on existing
    let (msg2, code2) = doChangelogOperation(tmpDir, ensureUnreleased = true)
    check code2 == 0
    check msg2.contains("already exists")

    # 3. Add second entry
    let (msg3, code3) = doChangelogOperation(tmpDir, entry = "Fixed edge case", section = "Fixed")
    check code3 == 0
    let c3 = readFile(tmpDir / "CHANGELOG.md")
    check c3.contains("### Fixed\n- Fixed edge case")

  test "doBraidGate Changelog Gating Invariants":
    sandbox:
      allow(nfos.osprocPluginInstance)

      let repo = getTempDir() / ("vine_gate_cl_repo_" & $getCurrentProcessId())
      removeDir(repo)
      createDir(repo)
      defer: removeDir(repo)

      discard execCmdEx("git init -b main -q " & quoteShell(repo))
      discard execCmdEx("git -C " & quoteShell(repo) & " config user.email agent@axiomantic.dev")
      discard execCmdEx("git -C " & quoteShell(repo) & " config user.name 'Axiomantic Agent'")
      writeFile(repo / "README.md", "# Test Repo\n")
      createDir(repo / "src")
      writeFile(repo / "src" / "main.txt", "Original\n")
      discard execCmdEx("git -C " & quoteShell(repo) & " add README.md src/main.txt")
      discard execCmdEx("git -C " & quoteShell(repo) & " commit -q -m 'Initial commit'")

      # Scenario A: Repo has NO changelog -> Gate passes (changelog_gate: SKIPPED)
      let (sResA, sCodeA) = doStrandNew("task-cl-a", repo, "strand/task-cl-a", forceWorktree = true)
      check sCodeA == 0
      let strandA = sResA["strand_path"].getStr()
      defer:
        discard execCmdEx("git -C " & quoteShell(repo) & " worktree remove --force " & quoteShell(strandA))
        discard execCmdEx("git -C " & quoteShell(repo) & " worktree prune")
        removeDir(strandA.parentDir())

      writeFile(strandA / "src" / "main.txt", "Updated main\n")
      discard execCmdEx("git -C " & quoteShell(strandA) & " add src/main.txt")
      discard execCmdEx("git -C " & quoteShell(strandA) & " commit -q -m 'feat: update main'")

      let (gateResA, gateCodeA) = doBraidGate(
        branchParam = "strand/task-cl-a",
        baseRefParam = "main",
        strandDirParam = strandA,
        allowNoTests = true
      )
      check gateCodeA == 0
      check gateResA{"changelog_gate"}.getStr("").startsWith("SKIPPED (no changelog")

      # Now add CHANGELOG.md to main repo
      writeFile(repo / "CHANGELOG.md", "# Changelog\n\n## [0.1.0] - 2026-10-01\n### Added\n- Init\n")
      discard execCmdEx("git -C " & quoteShell(repo) & " add CHANGELOG.md")
      discard execCmdEx("git -C " & quoteShell(repo) & " commit -q -m 'docs: add changelog'")

      # Scenario B: Repo HAS CHANGELOG.md, but strand does NOT modify it -> Gate FAILS (code 5)
      let (sResB, sCodeB) = doStrandNew("task-cl-b", repo, "strand/task-cl-b", forceWorktree = true)
      check sCodeB == 0
      let strandB = sResB["strand_path"].getStr()
      defer:
        discard execCmdEx("git -C " & quoteShell(repo) & " worktree remove --force " & quoteShell(strandB))
        discard execCmdEx("git -C " & quoteShell(repo) & " worktree prune")
        removeDir(strandB.parentDir())

      writeFile(strandB / "src" / "main.txt", "Feature without changelog\n")
      discard execCmdEx("git -C " & quoteShell(strandB) & " add src/main.txt")
      discard execCmdEx("git -C " & quoteShell(strandB) & " commit -q -m 'feat: main without changelog'")

      let (gateResB, gateCodeB) = doBraidGate(
        branchParam = "strand/task-cl-b",
        baseRefParam = "main",
        strandDirParam = strandB,
        allowNoTests = true
      )
      check gateCodeB == ExitGateChangelogViolation
      check gateResB{"status"}.getStr("") == "changelog_violation"
      check gateResB{"changelog_gate"}.getStr("") == "FAIL"

      # Scenario C: Strand bypasses with allowNoChangelog -> Gate passes
      let (gateResC, gateCodeC) = doBraidGate(
        branchParam = "strand/task-cl-b",
        baseRefParam = "main",
        strandDirParam = strandB,
        allowNoTests = true,
        allowNoChangelog = true
      )
      check gateCodeC == 0
      check gateResC{"changelog_gate"}.getStr("") == "SKIPPED (allow-no-changelog)"

      # Scenario D: Strand updates CHANGELOG.md under ## [Unreleased] -> Gate PASSES
      discard doChangelogOperation(strandB, entry = "Feature with changelog", section = "Added")
      discard execCmdEx("git -C " & quoteShell(strandB) & " add CHANGELOG.md")
      discard execCmdEx("git -C " & quoteShell(strandB) & " commit -q -m 'docs: update changelog'")

      let (gateResD, gateCodeD) = doBraidGate(
        branchParam = "strand/task-cl-b",
        baseRefParam = "main",
        strandDirParam = strandB,
        allowNoTests = true
      )
      check gateCodeD == 0
      check gateResD{"changelog_gate"}.getStr("") == "PASS"
