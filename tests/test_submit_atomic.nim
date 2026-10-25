# tests/test_submit_atomic.nim
# Unit tests for atomic submit with --commit and --listen flags.

import tripwire
import tripwire/plugins/osproc as nfos
import std/[os, osproc, strutils, json, unittest]
import strand, gate, notify, config, crypto, process

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

suite "Vine Atomic Submit (--commit & --listen) Suite":

  teardown:
    try: setCurrentDir(initialWorkingDir)
    except CatchableError: discard

  test "Atomic submit with --commit auto-stages and commits dirty working tree":
    sandbox:
      allow(nfos.osprocPluginInstance)

      let repo = createTestGitRepo("vine_sub_commit")
      defer:
        try: setCurrentDir(initialWorkingDir)
        except CatchableError: discard
        removeDir(repo)

      # Create base application file in main
      createDir(repo / "src")
      writeFile(repo / "src" / "app.nim", "echo \"base app\"\n")
      discard execCmdEx("git -C " & quoteShell(repo) & " add src/app.nim")
      discard execCmdEx("git -C " & quoteShell(repo) & " commit -q -m 'Add app.nim'")

      let (sRes, sCode) = doStrandNew(
        taskId = "task-sub-commit",
        repoDirParam = repo,
        branchParam = "strand/task-sub-commit",
        forceWorktree = true
      )
      check sCode == 0
      let strandPath = sRes["strand_path"].getStr()
      defer:
        discard execCmdEx("git -C " & quoteShell(repo) & " worktree remove --force " & quoteShell(strandPath))
        discard execCmdEx("git -C " & quoteShell(repo) & " worktree prune")
        removeDir(strandPath.parentDir())

      # Create dirty files without manual git add / git commit
      # Provider (new file)
      writeFile(strandPath / "src" / "feature.nim", "proc run*(): int = 42\n")
      # Consumer (modified existing file)
      writeFile(strandPath / "src" / "app.nim", "import feature\necho run()\n")
      createDir(strandPath / "tests")
      writeFile(strandPath / "tests" / "test_feature.nim", "import ../src/feature\n")

      # Verify working directory is dirty
      let (statOut, statCode) = execCmdEx("git -C " & quoteShell(strandPath) & " status --porcelain")
      check statCode == 0
      check statOut.strip().len > 0

      # doStrandSubmit with commitMsg
      let (subRes, subCode) = doStrandSubmit(
        strandDirParam = strandPath,
        authorParam = "worker-alice",
        allowNoTests = true,
        commitMsg = "feat: atomic auto-commit on submit"
      )
      check subCode == 0
      check subRes["status"].getStr() == "ready_for_audit"
      check subRes.hasKey("auto_committed")
      check subRes["auto_committed"].getBool() == true
      check subRes.hasKey("commit")
      check subRes["commit"].getStr().len > 0

      # Verify git status is now completely clean
      let (cleanOut, cleanCode) = execCmdEx("git -C " & quoteShell(strandPath) & " status --porcelain")
      check cleanCode == 0
      check cleanOut.strip().len == 0

      # Verify the commit message in git history
      let (logOut, logCode) = execCmdEx("git -C " & quoteShell(strandPath) & " log -1 --pretty=%B")
      check logCode == 0
      check logOut.contains("feat: atomic auto-commit on submit")

      # Calling submit again with clean tree does not create empty commit
      let headSha = subRes["commit"].getStr()
      let (subRes2, subCode2) = doStrandSubmit(
        strandDirParam = strandPath,
        authorParam = "worker-alice",
        allowNoTests = true,
        commitMsg = "feat: should not commit when clean"
      )
      check subCode2 == 0
      check not subRes2.hasKey("auto_committed")
      let (revOut, revCode) = execCmdEx("git -C " & quoteShell(strandPath) & " rev-parse --short HEAD")
      check revCode == 0
      check revOut.strip() == headSha

  test "Submit with gate failure rejects and does not run listener":
    sandbox:
      allow(nfos.osprocPluginInstance)

      let repo = createTestGitRepo("vine_sub_fail")
      defer:
        try: setCurrentDir(initialWorkingDir)
        except CatchableError: discard
        removeDir(repo)

      let (sRes, sCode) = doStrandNew(
        taskId = "task-sub-fail",
        repoDirParam = repo,
        branchParam = "strand/task-sub-fail",
        forceWorktree = true
      )
      check sCode == 0
      let strandPath = sRes["strand_path"].getStr()
      defer:
        discard execCmdEx("git -C " & quoteShell(repo) & " worktree remove --force " & quoteShell(strandPath))
        discard execCmdEx("git -C " & quoteShell(repo) & " worktree prune")
        removeDir(strandPath.parentDir())

      # Create code without tests and without allowNoTests -> fails Key 2
      writeFile(strandPath / "feature.txt", "Some code\n")
      discard execCmdEx("git -C " & quoteShell(strandPath) & " add feature.txt")
      discard execCmdEx("git -C " & quoteShell(strandPath) & " commit -q -m 'feat: some code'")

      let (fRes, fCode) = doStrandSubmit(
        strandDirParam = strandPath,
        authorParam = "worker-bob",
        allowNoTests = false,
        listen = true # even if listen is true, must fail at gate
      )
      check fCode != 0
      check fRes["status"].getStr() != "ready_for_audit"
