# /Users/eek/Development/vine/tests/test_vine_comprehensive.nim
# Comprehensive in-process Nim test suite migrated 100% from tests/test_vine.py (all 39 test cases).

import tripwire
import tripwire/plugins/osproc as nfos
import std/[os, osproc, strutils, json, times, unittest]
import strand, gate, weave, guide, config, update, notify, crypto, process, redis_client, vine
import ./test_helpers

gBraidWeaveProc = doBraidWeave

let initialWorkingDir = getCurrentDir()
let testTmpDir = getTempDir() / ("vine-tests-nim-" & $getCurrentProcessId())
let testWorkspaces = testTmpDir / "workspaces"
let testRedisPrefix = "test_vine_" & $getCurrentProcessId() & ":"
var testCounter = 0

removeDir(testTmpDir)
createDir(testWorkspaces)
putEnv("VINE_WORKSPACES_DIR", testWorkspaces)
putEnv("VINE_REDIS_PREFIX", testRedisPrefix)
putEnv("RHIZO_REDIS_PREFIX", testRedisPrefix)

proc cleanupTestEnvironment() =
  try: setCurrentDir(initialWorkingDir) except CatchableError: discard
  try: removeDir(testTmpDir) except CatchableError: discard
  try:
    if isRedisAvailable():
      discard executeRawRedis([
        "EVAL",
        "local ks = redis.call('KEYS', ARGV[1]); for i=1,#ks do redis.call('DEL', ks[i]) end; return #ks",
        "0",
        testRedisPrefix & "*"
      ])
  except CatchableError:
    discard

proc safeRemoveDir(d: string) =
  try: setCurrentDir(initialWorkingDir) except CatchableError: discard
  try: removeDir(d) except CatchableError: discard

proc nextTaskId(prefix: string): string =
  inc testCounter
  result = prefix & "-" & $getCurrentProcessId() & "-" & $testCounter

proc gitRun(dir: string, args: string): tuple[outStr: string, code: int] =
  let (o, c) = execCmdEx("git -C " & quoteShell(dir) & " " & args)
  result = (o, c)

proc createRepo(prefix: string): string =
  try: setCurrentDir(initialWorkingDir) except CatchableError: discard
  inc testCounter
  let repo = testTmpDir / (prefix & "_" & $testCounter)
  removeDir(repo)
  createDir(repo)
  doAssert execCmdEx("git init -b main -q " & quoteShell(repo)).exitCode == 0
  doAssert gitRun(repo, "config user.email agent@vine.mesh").code == 0
  doAssert gitRun(repo, "config user.name \"Vine Agent\"").code == 0
  return repo

proc commitFile(dir, relPath, content, msg: string) =
  let fullPath = dir / relPath
  createDir(fullPath.parentDir())
  writeFile(fullPath, content)
  doAssert gitRun(dir, "add " & quoteShell(relPath)).code == 0
  doAssert gitRun(dir, "commit -q -m " & quoteShell(msg)).code == 0

proc cleanupStrand(repoDir, strandPath: string) =
  try: setCurrentDir(initialWorkingDir) except CatchableError: discard
  if strandPath.len > 0 and dirExists(strandPath):
    discard gitRun(repoDir, "worktree remove --force " & quoteShell(strandPath))
    discard gitRun(repoDir, "worktree prune")
    try: removeDir(strandPath.parentDir()) except CatchableError: discard

suite "Vine Comprehensive In-Process Verification Suite (39 Tests)":

  teardown:
    try: setCurrentDir(initialWorkingDir) except CatchableError: discard
    putEnv("VINE_WORKSPACES_DIR", testWorkspaces)
    putEnv("VINE_REDIS_PREFIX", testRedisPrefix)

  test "01: test_vine_version":
    let pkgJson = parseJson(readFile(initialWorkingDir / "package.json"))
    let canonicalVersion = pkgJson["version"].getStr("0.1.6")
    let res = runVineInProcess(["--version"])
    check res.code == 0
    check res.outStr.contains("vine " & canonicalVersion)
    check Version == canonicalVersion

  test "02: test_vine_skill_reconciliation":
    let rootSkill = readFile(initialWorkingDir / "SKILL.md").replace("\r\n", "\n")
    let pkgSkill = readFile(initialWorkingDir / "skills" / "vine" / "SKILL.md").replace("\r\n", "\n")
    check rootSkill == pkgSkill
    check rootSkill.contains("Three-Key Gate")
    check rootSkill.contains("The Worker is NOT the Auditor")

  test "03: test_vine_guide_lifecycle":
    let tmpDir = testTmpDir / ("guide_life_" & nextTaskId("t"))
    createDir(tmpDir)
    defer: safeRemoveDir(tmpDir)
    let target = tmpDir / "AGENTS.md"

    # 1. Check missing
    let r1 = runVineInProcess(["guide", "check", target])
    check r1.code == 0
    check r1.outStr.contains("[MISSING]")

    # 2. Install into new file
    let r2 = runVineInProcess(["guide", "install", target])
    check r2.code == 0
    check r2.outStr.contains("Created")
    check fileExists(target)
    let content = readFile(target)
    check content.contains("<!-- BEGIN VINE GUIDE [v1.8] -->")
    check content.contains("<!-- END VINE GUIDE -->")
    check content.contains("Vine Workspace & Strand Coordination Guide")

    # 3. Check installed
    let r3 = runVineInProcess(["guide", "check", target])
    check r3.code == 0
    check r3.outStr.contains("[INSTALLED]")

    # 4. Uninstall
    let r4 = runVineInProcess(["guide", "uninstall", target])
    check r4.code == 0
    check r4.outStr.contains("Successfully uninstalled")
    check not readFile(target).contains("BEGIN VINE GUIDE")

  test "04: test_vine_guide_unbalanced_markers_fail_safe":
    let tmpDir = testTmpDir / ("guide_mal_" & nextTaskId("t"))
    createDir(tmpDir)
    defer: safeRemoveDir(tmpDir)
    let target = tmpDir / "AGENTS.md"
    let corrupted = "# Agent Guide\n<!-- BEGIN VINE GUIDE [v1.0] -->\nOnly opening marker without closing marker\n"
    writeFile(target, corrupted)

    let r1 = runVineInProcess(["guide", "check", target])
    check r1.code == 1
    check r1.errStr.contains("[MALFORMED]")

    let r2 = runVineInProcess(["guide", "install", target])
    check r2.code == 1
    check r2.errStr.contains("Malformed markers")
    check readFile(target) == corrupted

    let r3 = runVineInProcess(["guide", "uninstall", target])
    check r3.code == 1
    check r3.errStr.contains("Malformed markers")
    check readFile(target) == corrupted

  test "05: test_vine_config":
    let tmpDir = testTmpDir / ("cfg_" & nextTaskId("t"))
    createDir(tmpDir)
    defer: safeRemoveDir(tmpDir)
    setCurrentDir(tmpDir)

    let r1 = runVineInProcess(["config", "show"])
    check r1.code == 0
    let data = parseJson(r1.outStr)
    check data["primary_branch"].getStr() == "main"
    check data["venv_policy"].getStr() == "prompt"
    var foundDeps = false
    for v in data["vendor_dirs"]:
      if v.getStr() == "deps": foundDeps = true
    check foundDeps

    let r2 = runVineInProcess(["config", "init"])
    check r2.code == 0
    let tomlPath = tmpDir / "vine.toml"
    check fileExists(tomlPath)
    check readFile(tomlPath).contains("primary_branch")

  test "06: test_vine_custom_config_parsing":
    let tmpDir = testTmpDir / ("cfg_custom_" & nextTaskId("t"))
    createDir(tmpDir)
    defer: safeRemoveDir(tmpDir)
    let tomlPath = tmpDir / "vine.toml"
    writeFile(tomlPath, """[project]
primary_branch = "develop"

[strand]
venv_policy = "recreate"
vendor_dirs = ["deps", "third_party", "node_modules"]

[verification]
test_command = "pytest tests/ -v"
""")
    setCurrentDir(tmpDir)
    let r = runVineInProcess(["config", "show"])
    check r.code == 0
    let data = parseJson(r.outStr)
    check data["primary_branch"].getStr() == "develop"
    check data["venv_policy"].getStr() == "recreate"
    check data["vendor_dirs"] == %["deps", "third_party", "node_modules"]
    check data["test_command"].getStr() == "pytest tests/ -v"
    check expandFilename(data["active_config"].getStr()).normalizedPath == expandFilename(tomlPath).normalizedPath

  test "07: test_vine_strand_lifecycle_and_gate":
    sandbox:
      allow(nfos.osprocPluginInstance)
      let repoDir = createRepo("vine_repo")
      defer: safeRemoveDir(repoDir)
      commitFile(repoDir, "README.md", "# Vine Repo\n", "Initial commit")
      createDir(repoDir / "deps" / "pkg")
      writeFile(repoDir / "deps" / "pkg" / "lib.txt", "vendored library\n")

      let taskId = nextTaskId("task")
      let rNew = runVineInProcess(["new", taskId, "--repo", repoDir, "--branch", "strand/" & taskId, "--worktree"])
      check rNew.code == 0
      let data = parseJson(rNew.outStr)
      check data["status"].getStr() == "created"
      let strandPath = data["strand_path"].getStr()
      check dirExists(strandPath)
      defer: cleanupStrand(repoDir, strandPath)

      check not fileExists(strandPath / ".vine.json")
      check not fileExists(strandPath / ".vine" / "strand.json")

      let rStat1 = runVineInProcess(["status", "--dir", strandPath, "--json"])
      check rStat1.code == 0
      let sData1 = parseJson(rStat1.outStr)
      check sData1["task_id"].getStr() == taskId
      check sData1["status"].getStr() in ["IN_PROGRESS", "PROVISIONED"]
      check fileExists(strandPath / "deps" / "pkg" / "lib.txt")

      commitFile(strandPath, "feature.txt", "Vine feature line\n", "feat: add feature")

      let rGate = runVineInProcess(["gate", "--dir", strandPath, "--base", "main", "--allow-no-tests", "--json"])
      check rGate.code == 0
      let gData = parseJson(rGate.outStr)
      check gData["clean"].getBool() == true
      check gData["key1_mechanical"].getStr() == "PASS"

      let rStat2 = runVineInProcess(["status", "--dir", strandPath, "--json"])
      check rStat2.code == 0
      let sData2 = parseJson(rStat2.outStr)
      check (sData2["status"].getStr() in ["READY_FOR_WEAVE", "GATE_PASSED"] or
             sData2{"stored_status"}.getStr("") in ["READY_FOR_WEAVE", "GATE_PASSED"])

      let rList = runVineInProcess(["list", "--repo", repoDir])
      check rList.code == 0
      check parseJson(rList.outStr)["count"].getInt() >= 1

      # Unaudited weave must fail with 6
      let rWFail = runVineInProcess(["weave", "--dir", strandPath, "--base", "main", "--allow-no-tests"])
      check rWFail.code == 6

      # Submit for audit
      let rSub = runVineInProcess(["submit", "--dir", strandPath, "--author", "worker-alice", "--allow-no-tests", "--json"])
      check rSub.code == 0
      check parseJson(rSub.outStr)["status"].getStr() == "ready_for_audit"

      # Self-audit rejected
      let rSelf = runVineInProcess(["audit", "approve", strandPath, "--auditor", "worker-alice", "--json"])
      check rSelf.code == 6

      # Inspect & ratify
      check runVineInProcess(["audit", "inspect", strandPath, "--json"]).code == 0
      let rAud = runVineInProcess(["audit", "approve", strandPath, "--auditor", "auditor-bob", "--evidence", "Verified feature.txt: feature line verified across call sites", "--json"])
      check rAud.code == 0
      let audData = parseJson(rAud.outStr)
      check audData["status"].getStr() == "audit_ratified"
      check audData["audit_token"].getStr().len > 0

      # Weave
      let rWeave = runVineInProcess(["weave", "--dir", strandPath, "--base", "main", "--allow-no-tests"])
      check rWeave.code == 0
      check parseJson(rWeave.outStr)["status"].getStr() == "woven"
      check fileExists(repoDir / "feature.txt")
      check readFile(repoDir / "feature.txt").contains("Vine feature line")
      check not dirExists(strandPath)

  test "08: test_vine_gate_catches_mechanical_conflict":
    sandbox:
      allow(nfos.osprocPluginInstance)
      let repoDir = createRepo("vine_conflict")
      defer: safeRemoveDir(repoDir)
      commitFile(repoDir, "README.md", "Line 1: Original text\n", "Initial commit")

      let taskId = nextTaskId("task-conf")
      let rNew = runVineInProcess(["new", taskId, "--repo", repoDir, "--branch", "strand/" & taskId, "--worktree"])
      check rNew.code == 0
      let strandPath = parseJson(rNew.outStr)["strand_path"].getStr()
      defer: cleanupStrand(repoDir, strandPath)

      commitFile(strandPath, "README.md", "Line 1: Strand modified text\n", "feat: strand edit")
      commitFile(repoDir, "README.md", "Line 1: Canonical trunk conflicting edit\n", "fix: trunk edit")

      let rGate = runVineInProcess(["gate", "--dir", strandPath, "--base", "main", "--json"])
      check rGate.code == 1
      let gData = parseJson(rGate.outStr)
      check gData["clean"].getBool() == false
      check gData["status"].getStr() == "conflict"
      check gData["key1_mechanical"].getStr() == "FAIL"
      var hasReadme = false
      for c in gData["conflicts"]:
        if c.getStr().contains("README.md"): hasReadme = true
      check hasReadme

      let rWeave = runVineInProcess(["weave", "--dir", strandPath, "--base", "main"])
      check rWeave.code != 0
      check (rWeave.errStr.contains("Two-Key Gate") or rWeave.errStr.contains("Three-Key Gate") or rWeave.errStr.contains("weave_rejected"))

  test "09: test_vine_gate_catches_semantic_compiler_failure":
    sandbox:
      allow(nfos.osprocPluginInstance)
      let repoDir = createRepo("vine_compiler_fail")
      defer: safeRemoveDir(repoDir)
      commitFile(repoDir, "README.md", "# Project\n", "Initial commit")
      when defined(windows):
        writeFile(repoDir / "fail.bat", "@echo off\r\necho Simulated compiler error\r\nexit /b 1\r\n")
        writeFile(repoDir / "vine.toml", "[verification]\ntest_command = \"cmd /c fail.bat\"\n")
        doAssert gitRun(repoDir, "add vine.toml fail.bat").code == 0
      else:
        writeFile(repoDir / "fail.sh", "#!/bin/sh\necho 'Simulated compiler error'\nexit 1\n")
        writeFile(repoDir / "vine.toml", "[verification]\ntest_command = \"sh fail.sh\"\n")
        doAssert gitRun(repoDir, "add vine.toml fail.sh").code == 0
      doAssert gitRun(repoDir, "commit -q -m \"chore: add vine.toml and fail.sh\"").code == 0

      let taskId = nextTaskId("task-sem")
      let rNew = runVineInProcess(["new", taskId, "--repo", repoDir, "--branch", "strand/" & taskId, "--worktree"])
      check rNew.code == 0
      let strandPath = parseJson(rNew.outStr)["strand_path"].getStr()
      defer: cleanupStrand(repoDir, strandPath)

      commitFile(strandPath, "feature.txt", "Broken feature\n", "feat: broken feature")

      let rGate = runVineInProcess(["gate", "--dir", strandPath, "--base", "main", "--json"])
      check rGate.code == 2
      let gData = parseJson(rGate.outStr)
      check gData["clean"].getBool() == false
      check gData["status"].getStr() == "semantic_failure"
      check gData["key1_mechanical"].getStr() == "PASS"
      check gData["key2_semantic"].getStr() == "FAIL"
      check gData["compiler_output"].getStr().contains("Simulated compiler error")

  test "10: test_vine_strand_envrc_generation":
    sandbox:
      allow(nfos.osprocPluginInstance)
      let repoDir = createRepo("vine_envrc")
      defer: safeRemoveDir(repoDir)
      writeFile(repoDir / ".envrc", "export PARENT_FLAG=active\n")
      commitFile(repoDir, "README.md", "# Project\n", "Initial commit")

      let taskId = nextTaskId("task-envrc")
      let rNew = runVineInProcess(["new", taskId, "--repo", repoDir, "--branch", "strand/" & taskId, "--worktree"])
      check rNew.code == 0
      let strandPath = parseJson(rNew.outStr)["strand_path"].getStr()
      defer: cleanupStrand(repoDir, strandPath)

      let envrcFile = strandPath / ".envrc"
      check fileExists(envrcFile)
      let content = readFile(envrcFile)
      check content.contains("source_env")
      check content.contains("! \"$PWD/.envrc\" -ef")
      check content.contains("PROJECT_ROOT=")
      check content.contains("CACHE_ROOT=")
      check content.contains("CCACHE_BASEDIR=")
      check content.contains("CCACHE_NOHASHDIR=1")
      check content.contains("CARGO_TARGET_DIR=")
      check content.contains("UV_LINK_MODE=\"clone\"")
      check content.contains("NIMCACHE=")

      check not gitRun(strandPath, "status --porcelain").outStr.contains(".envrc")
      doAssert gitRun(strandPath, "add -A").code == 0
      check not gitRun(strandPath, "status --porcelain").outStr.contains(".envrc")

  test "11: test_vine_strand_tracked_envrc_preservation":
    sandbox:
      allow(nfos.osprocPluginInstance)
      let repoDir = createRepo("vine_tracked_envrc")
      defer: safeRemoveDir(repoDir)
      let canonicalContent = "# CANONICAL TRACKED ENVRC\nexport CANONICAL_ENVRC_LOADED=1\n"
      commitFile(repoDir, ".envrc", canonicalContent, "Commit canonical tracked .envrc")

      let taskId = nextTaskId("task-tracked-envrc")
      let rNew = runVineInProcess(["new", taskId, "--repo", repoDir, "--branch", "strand/" & taskId, "--worktree"])
      check rNew.code == 0
      let strandPath = parseJson(rNew.outStr)["strand_path"].getStr()
      defer: cleanupStrand(repoDir, strandPath)

      let envrcFile = strandPath / ".envrc"
      check fileExists(envrcFile)
      check readFile(envrcFile).replace("\r\n", "\n") == canonicalContent
      check gitRun(strandPath, "status --porcelain").outStr.strip() == ""

  test "12: test_vine_prune":
    sandbox:
      allow(nfos.osprocPluginInstance)
      let repoDir = createRepo("vine_prune")
      defer: safeRemoveDir(repoDir)
      commitFile(repoDir, "README.md", "# Prune test\n", "Initial commit")

      let taskId = nextTaskId("task-prune")
      let rNew = runVineInProcess(["new", taskId, "--repo", repoDir, "--branch", "strand/" & taskId, "--worktree"])
      check rNew.code == 0
      let strandPath = parseJson(rNew.outStr)["strand_path"].getStr()
      defer: cleanupStrand(repoDir, strandPath)

      if isRedisAvailable():
        discard executeRawRedis(["HSET", testRedisPrefix & "strand:" & taskId, "state", "WOVEN", "status", "WOVEN", "lifecycle_state", "WOVEN"])
        discard executeRawRedis(["SADD", testRedisPrefix & "strands:state:woven", taskId])
      else:
        discard updateGateRedis(taskId, "WOVEN")

      let rDry = runVineInProcess(["prune", "--repo", repoDir])
      check rDry.code == 0
      let pData = parseJson(rDry.outStr)
      check pData["dry_run"].getBool() == true
      check pData["pruned_count"].getInt() == 1
      check dirExists(strandPath)

      let rApply = runVineInProcess(["prune", "--repo", repoDir, "--apply"])
      check rApply.code == 0
      let aData = parseJson(rApply.outStr)
      check aData["dry_run"].getBool() == false
      check aData["pruned_count"].getInt() == 1
      check not dirExists(strandPath)
      check not gitRun(repoDir, "worktree list").outStr.replace('\\', '/').contains(taskId)

  test "13: test_vine_diverged_trunk_sync_and_weave":
    sandbox:
      allow(nfos.osprocPluginInstance)
      let repoDir = createRepo("vine_sync")
      defer: safeRemoveDir(repoDir)
      commitFile(repoDir, "README.md", "# Diverged Trunk Test Repo\n", "Initial commit C0")

      let taskId = nextTaskId("task-sync")
      let rNew = runVineInProcess(["new", taskId, "--repo", repoDir, "--branch", "strand/" & taskId, "--worktree"])
      check rNew.code == 0
      let strandPath = parseJson(rNew.outStr)["strand_path"].getStr()
      defer: cleanupStrand(repoDir, strandPath)

      commitFile(strandPath, "feature.txt", "New feature from parallel worker\n", "feat: parallel strand feature")
      commitFile(repoDir, "trunk_update.txt", "Trunk change committed by another worker\n", "chore: independent trunk commit C_trunk")

      let rWFail = runVineInProcess(["weave", "--dir", strandPath, "--base", "main", "--allow-no-tests", "--allow-unaudited"])
      check rWFail.code != 0
      check (rWFail.errStr.contains("fast_forward_failed") or rWFail.errStr.contains("diverged"))
      check rWFail.errStr.contains("vine sync")

      # Dirty working tree blocks sync
      writeFile(strandPath / "uncommitted.txt", "uncommitted work\n")
      doAssert gitRun(strandPath, "add uncommitted.txt").code == 0
      let rSFail = runVineInProcess(["sync", "--dir", strandPath, "--base", "main"])
      check rSFail.code != 0
      check rSFail.errStr.contains("dirty_working_tree")
      removeFile(strandPath / "uncommitted.txt")
      doAssert gitRun(strandPath, "reset HEAD -- uncommitted.txt").code == 0

      let rSync = runVineInProcess(["sync", "--dir", strandPath, "--base", "main"])
      check rSync.code == 0
      let sData = parseJson(rSync.outStr)
      check sData["status"].getStr() == "synced"
      check sData["base_branch"].getStr() == "main"
      check fileExists(strandPath / "trunk_update.txt")
      check fileExists(strandPath / "feature.txt")

      let rGate = runVineInProcess(["gate", "--dir", strandPath, "--base", "main", "--allow-no-tests", "--json"])
      check rGate.code == 0
      check parseJson(rGate.outStr)["clean"].getBool() == true

      let rWOk = runVineInProcess(["weave", "--dir", strandPath, "--base", "main", "--allow-no-tests", "--allow-unaudited"])
      check rWOk.code == 0
      check parseJson(rWOk.outStr)["status"].getStr() == "woven"
      check fileExists(repoDir / "feature.txt")
      check fileExists(repoDir / "trunk_update.txt")
      check not dirExists(strandPath)

  test "14: test_vine_gate_custom_test_command":
    sandbox:
      allow(nfos.osprocPluginInstance)
      let repoDir = createRepo("vine_custom_gate")
      defer: safeRemoveDir(repoDir)
      commitFile(repoDir, "README.md", "# Gate Custom Test\n", "Initial commit")

      let taskId = nextTaskId("task-gate")
      let rNew = runVineInProcess(["new", taskId, "--repo", repoDir, "--branch", "strand/" & taskId, "--worktree"])
      check rNew.code == 0
      let strandPath = parseJson(rNew.outStr)["strand_path"].getStr()
      defer: cleanupStrand(repoDir, strandPath)

      let passCmd = when defined(windows): "cmd /c echo Tests passed" else: "sh -c 'echo Tests passed'"
      let r1 = runVineInProcess(["gate", "--dir", strandPath, "--base", "main", "--test-command", passCmd, "--json"])
      check r1.code == 0
      let d1 = parseJson(r1.outStr)
      check d1["clean"].getBool() == true
      check d1["key2_semantic"].getStr() == "PASS"
      check d1["test_command"].getStr() == passCmd

      let failCmd = when defined(windows): "cmd /c \"echo Synthetic test failure 1>&2 && exit /b 42\"" else: "sh -c 'echo \"Synthetic test failure\" >&2; exit 42'"
      let r2 = runVineInProcess(["gate", "--dir", strandPath, "--base", "main", "--test-command", failCmd, "--json"])
      check r2.code == 2
      let d2 = parseJson(r2.outStr)
      check d2["clean"].getBool() == false
      check d2["key2_semantic"].getStr() == "FAIL"
      check d2["compiler_output"].getStr().contains("Synthetic test failure")

      let r3 = when defined(windows):
                 runVineInProcess(["gate", "--dir", strandPath, "--base", "main", "--json", "--", "cmd", "/c", "echo Passing via double dash"])
               else:
                 runVineInProcess(["gate", "--dir", strandPath, "--base", "main", "--json", "--", "sh", "-c", "echo Passing via double dash"])
      check r3.code == 0
      let d3 = parseJson(r3.outStr)
      check d3["clean"].getBool() == true
      check d3["key2_semantic"].getStr() == "PASS"

      let r4 = when defined(windows):
                 runVineInProcess(["gate", "--dir", strandPath, "--base", "main", "--json", "--", "cmd", "/c", "echo Synthetic failure via double dash 1>&2 & exit /b 42"])
               else:
                 runVineInProcess(["gate", "--dir", strandPath, "--base", "main", "--json", "--", "sh", "-c", "echo Synthetic failure via double dash >&2; exit 42"])
      check r4.code == 2
      let d4 = parseJson(r4.outStr)
      check d4["clean"].getBool() == false
      check d4["key2_semantic"].getStr() == "FAIL"
      check d4["compiler_output"].getStr().contains("Synthetic failure via double dash")

  test "15: test_vine_strand_deep_lifecycle_and_status":
    sandbox:
      allow(nfos.osprocPluginInstance)
      let repoDir = createRepo("vine_lifecycle")
      defer: safeRemoveDir(repoDir)
      commitFile(repoDir, "README.md", "# Lifecycle Test\n", "Initial commit")
      doAssert gitRun(repoDir, "checkout -b develop").code == 0
      commitFile(repoDir, "develop.txt", "Develop branch base\n", "develop commit")

      let taskId = nextTaskId("task-life")
      let rNew = runVineInProcess(["new", taskId, "--repo", repoDir, "--branch", "strand/" & taskId, "--parent", "develop", "--worktree"])
      check rNew.code == 0
      let data = parseJson(rNew.outStr)
      let strandPath = data["strand_path"].getStr()
      defer: cleanupStrand(repoDir, strandPath)
      check data["parent_branch"].getStr() == "develop"
      check data["intended_merge_base"].getStr().len == 40

      let rS1 = runVineInProcess(["status", "--dir", strandPath, "--json"])
      check rS1.code == 0
      let d1 = parseJson(rS1.outStr)
      check d1["lifecycle_state"].getStr() == "PROVISIONED"
      check d1["parent_branch"].getStr() == "develop"
      check d1["commits_ahead"].getInt() == 0
      check d1["dirty_count"].getInt() == 0

      writeFile(strandPath / "work.txt", "in progress work\n")
      let rS2 = runVineInProcess(["status", "--dir", strandPath, "--json"])
      check rS2.code == 0
      let d2 = parseJson(rS2.outStr)
      check d2["lifecycle_state"].getStr() == "IN_PROGRESS"
      check d2["dirty_count"].getInt() == 1

      commitFile(strandPath, "work.txt", "in progress work\n", "feat: completed work")
      let rS3 = runVineInProcess(["status", "--dir", strandPath, "--json"])
      check rS3.code == 0
      let d3 = parseJson(rS3.outStr)
      check d3["commits_ahead"].getInt() == 1
      check d3["dirty_count"].getInt() == 0

      let rFail = runVineInProcess(["gate", "--dir", strandPath, "--base", "develop", "--test-command", (when defined(windows): "cmd /c exit /b 1" else: "sh -c 'exit 1'"), "--json"])
      check rFail.code == 2
      let rSFail = runVineInProcess(["status", "--dir", strandPath, "--json"])
      check rSFail.code == 0
      let dFail = parseJson(rSFail.outStr)
      check dFail["lifecycle_state"].getStr() == "IN_PROGRESS"
      check dFail.hasKey("last_gate_error")

      let rPass = runVineInProcess(["gate", "--dir", strandPath, "--base", "develop", "--skip-tests", "--allow-no-tests", "--json"])
      check rPass.code == 0
      let rS4 = runVineInProcess(["status", "--dir", strandPath, "--json"])
      check rS4.code == 0
      check parseJson(rS4.outStr)["lifecycle_state"].getStr() == "GATE_PASSED"

  test "16: test_vine_collisions_forecasting":
    sandbox:
      allow(nfos.osprocPluginInstance)
      let repoDir = createRepo("vine_colls")
      defer: safeRemoveDir(repoDir)
      commitFile(repoDir, "shared.txt", "Line 0\n", "Initial commit")

      let taskA = nextTaskId("task-a")
      let taskB = nextTaskId("task-b")
      let rA = runVineInProcess(["new", taskA, "--repo", repoDir, "--branch", "strand/" & taskA, "--worktree"])
      check rA.code == 0
      let pathA = parseJson(rA.outStr)["strand_path"].getStr()
      defer: cleanupStrand(repoDir, pathA)

      let rB = runVineInProcess(["new", taskB, "--repo", repoDir, "--branch", "strand/" & taskB, "--worktree"])
      check rB.code == 0
      let pathB = parseJson(rB.outStr)["strand_path"].getStr()
      defer: cleanupStrand(repoDir, pathB)

      writeFile(pathA / "shared.txt", readFile(pathA / "shared.txt") & "Modified by A\n")
      writeFile(pathB / "shared.txt", readFile(pathB / "shared.txt") & "Modified by B\n")

      let rColl = runVineInProcess(["collisions", "--repo", repoDir, "--json"])
      check rColl.code == 0
      let cData = parseJson(rColl.outStr)
      check cData["has_collisions"].getBool() == true
      check cData["collision_count"].getInt() >= 1
      var found = false
      for c in cData["collisions"]:
        if c["file"].getStr() == "shared.txt":
          found = true
          var hasA = false
          var hasB = false
          for s in c["strands"]:
            if s.getStr() == taskA: hasA = true
            if s.getStr() == taskB: hasB = true
          check hasA
          check hasB
      check found

  test "17: test_vine_cmake_test_runner_detection":
    sandbox:
      allow(nfos.osprocPluginInstance)
      let repoDir = createRepo("vine_cmake")
      defer: safeRemoveDir(repoDir)
      commitFile(repoDir, "CMakeLists.txt", "cmake_minimum_required(VERSION 3.20)\nproject(TestProject)\n", "Initial cmake commit")

      let taskId = nextTaskId("task-cmake")
      let rNew = runVineInProcess(["new", taskId, "--repo", repoDir, "--branch", "strand/" & taskId, "--worktree"])
      check rNew.code == 0
      let strandPath = parseJson(rNew.outStr)["strand_path"].getStr()
      defer: cleanupStrand(repoDir, strandPath)

      let rGate = runVineInProcess(["gate", "--dir", strandPath, "--base", "main", "--skip-tests", "--allow-no-tests", "--json"])
      check rGate.code == 0
      check parseJson(rGate.outStr)["clean"].getBool() == true

  test "18: test_vine_environment_variable_precedence":
    sandbox:
      allow(nfos.osprocPluginInstance)
      let tmpDir = testTmpDir / ("env_test_" & nextTaskId("e"))
      createDir(tmpDir)
      defer: safeRemoveDir(tmpDir)

      let customToml = tmpDir / "custom_vine.toml"
      writeFile(customToml, "[project]\nprimary_branch = \"trunk\"\n[strand]\nvenv_policy = \"always\"\n[verification]\ntest_command = \"cargo test\"\n")

      let envKeys = ["VINE_CONFIG", "VINE_PRIMARY_BRANCH", "VINE_TEST_COMMAND", "VINE_VENV_POLICY"]
      var saved: seq[tuple[k, v: string, present: bool]] = @[]
      for k in envKeys:
        saved.add((k, getEnv(k, ""), existsEnv(k)))
      defer:
        for item in saved:
          if item.present: putEnv(item.k, item.v)
          else: delEnv(item.k)
        putEnv("VINE_WORKSPACES_DIR", testWorkspaces)

      setCurrentDir(tmpDir)
      putEnv("VINE_CONFIG", customToml)
      let r1 = runVineInProcess(["config", "show"])
      check r1.code == 0
      let d1 = parseJson(r1.outStr)
      check d1["primary_branch"].getStr() == "trunk"
      check d1["venv_policy"].getStr() == "always"
      check d1["test_command"].getStr() == "cargo test"

      putEnv("VINE_PRIMARY_BRANCH", "production")
      putEnv("VINE_TEST_COMMAND", "nimble test")
      putEnv("VINE_VENV_POLICY", "never")
      let r2 = runVineInProcess(["config", "show"])
      check r2.code == 0
      let d2 = parseJson(r2.outStr)
      check d2["primary_branch"].getStr() == "production"
      check d2["test_command"].getStr() == "nimble test"
      check d2["venv_policy"].getStr() == "never"

      for k in envKeys: delEnv(k)
      let customWs = tmpDir / "custom_workspaces"
      putEnv("VINE_WORKSPACES_DIR", customWs)
      let repoDir = createRepo("env_ws_repo")
      defer: safeRemoveDir(repoDir)
      commitFile(repoDir, "README.md", "# Test\n", "init")

      let taskId = nextTaskId("task-ws")
      let r3 = runVineInProcess(["new", taskId, "--repo", repoDir, "--branch", "strand/" & taskId, "--worktree"])
      check r3.code == 0
      let sp3 = parseJson(r3.outStr)["strand_path"].getStr()
      defer: cleanupStrand(repoDir, sp3)
      check sp3.contains(customWs.normalizedPath)
      check dirExists(sp3)

  test "19: test_vine_weave_and_gate_auto_resolve_by_task_id":
    sandbox:
      allow(nfos.osprocPluginInstance)
      let repoDir = createRepo("vine_autoresolve")
      defer: safeRemoveDir(repoDir)
      commitFile(repoDir, "README.md", "# Autoresolve Test\n", "Initial commit")

      let taskId = nextTaskId("task-auto")
      let rNew = runVineInProcess(["new", taskId, "--repo", repoDir, "--branch", "strand/" & taskId, "--worktree"])
      check rNew.code == 0
      let strandPath = parseJson(rNew.outStr)["strand_path"].getStr()
      defer: cleanupStrand(repoDir, strandPath)

      commitFile(strandPath, "feature.txt", "Autoresolved feature\n", "feat: add feature")
      setCurrentDir(repoDir)

      let rG1 = runVineInProcess(["gate", "strand/" & taskId, "--skip-tests", "--allow-no-tests", "--json"])
      check rG1.code == 0
      check parseJson(rG1.outStr)["strand_path"].getStr() == strandPath

      let rG2 = runVineInProcess(["gate", taskId, "--skip-tests", "--allow-no-tests", "--json"])
      check rG2.code == 0
      check parseJson(rG2.outStr)["strand_path"].getStr() == strandPath

      let rS = runVineInProcess(["status", taskId, "--json"])
      check rS.code == 0
      check parseJson(rS.outStr)["commits_ahead"].getInt() == 1

      let rW = runVineInProcess(["weave", taskId, "--force"])
      check rW.code == 0
      check parseJson(rW.outStr)["status"].getStr() == "woven"
      check fileExists(repoDir / "feature.txt")

  test "20: test_vine_changelog_command":
    sandbox:
      allow(nfos.osprocPluginInstance)
      let repoDir = createRepo("vine_cl_test")
      defer: safeRemoveDir(repoDir)

      let r1 = runVineInProcess(["changelog", "--check", "--repo", repoDir])
      check r1.code == 0
      check r1.outStr.contains("No changelog file detected in project")

      let r2 = runVineInProcess(["changelog", "--ensure-unreleased", "--repo", repoDir])
      check r2.code == 0
      let clPath = repoDir / "CHANGELOG.md"
      check fileExists(clPath)
      check readFile(clPath).contains("## [Unreleased]")

      let r3 = runVineInProcess(["changelog", "Added great new feature", "--repo", repoDir])
      check r3.code == 0
      check readFile(clPath).contains("- Added great new feature")

      doAssert gitRun(repoDir, "add CHANGELOG.md").code == 0
      doAssert gitRun(repoDir, "commit -q -m \"chore: init changelog\"").code == 0

      let r4 = runVineInProcess(["changelog", "--check", "--repo", repoDir])
      check r4.code == 5
      check r4.combined.contains("is NOT modified in diff")

      let r5 = runVineInProcess(["changelog", "Second entry in progress", "--repo", repoDir])
      check r5.code == 0

      let r6 = runVineInProcess(["changelog", "--check", "--repo", repoDir])
      check r6.code == 0
      check r6.outStr.contains("Clean: CHANGELOG.md is modified in diff")

  test "21: test_vine_key3_adversarial_audit_lifecycle":
    sandbox:
      allow(nfos.osprocPluginInstance)
      let repoDir = createRepo("vine_audit_lifecycle")
      defer: safeRemoveDir(repoDir)
      commitFile(repoDir, "README.md", "# Main Repo\n", "chore: initial readme")
      commitFile(repoDir, "src/main.py", "# Main entrypoint\n", "chore: initial main")

      let taskId = nextTaskId("task-audit")
      let rNew = runVineInProcess(["new", taskId, "--repo", repoDir, "--worktree"])
      check rNew.code == 0
      let strandPath = parseJson(rNew.outStr)["strand_path"].getStr()
      defer: cleanupStrand(repoDir, strandPath)

      writeFile(strandPath / "src" / "engine.py", "def run(): return 42\n")
      writeFile(strandPath / "src" / "main.py", "from engine import run\nprint(run())\n")
      doAssert gitRun(strandPath, "add src/").code == 0
      doAssert gitRun(strandPath, "commit -q -m \"feat: provider and consumer\"").code == 0

      check runVineInProcess(["audit", "approve", strandPath, "--auditor", "auditor-rex", "--json"]).code == 6

      let rSub1 = runVineInProcess(["submit", "--dir", strandPath, "--author", "worker-claudia", "--allow-no-tests", "--json"])
      check rSub1.code == 0
      let subData = parseJson(rSub1.outStr)
      check subData["status"].getStr() == "ready_for_audit"
      check subData["author"].getStr() == "worker-claudia"

      let rSt = runVineInProcess(["audit", "status", strandPath, "--json"])
      check rSt.code == 0
      check parseJson(rSt.outStr)["status"].getStr() == "READY_FOR_AUDIT"
      check parseJson(rSt.outStr)["author"].getStr() == "worker-claudia"

      let rRej = runVineInProcess(["audit", "reject", strandPath, "--auditor", "auditor-rex", "--reason", "Missing input validation in engine.py", "--json"])
      check rRej.code == 0
      check parseJson(rRej.outStr)["status"].getStr() == "audit_rejected"

      check runVineInProcess(["weave", "--dir", strandPath, "--base", "main", "--allow-no-tests"]).code == 6

      commitFile(strandPath, "src/engine.py", "def run():\n    # Validated\n    return 42\n", "fix: add input validation")
      check runVineInProcess(["submit", "--dir", strandPath, "--author", "worker-claudia", "--allow-no-tests", "--json"]).code == 0

      let rSelf = runVineInProcess(["audit", "approve", strandPath, "--auditor", "worker-claudia", "--json"])
      check rSelf.code == 6
      check parseJson(rSelf.outStr){"error"}.getStr("").contains("Self-audit violation")

      check runVineInProcess(["audit", "inspect", strandPath, "--json"]).code == 0
      let rApp = runVineInProcess(["audit", "approve", strandPath, "--auditor", "auditor-rex", "--evidence", "Input validation ratified in engine.py across all call sites", "--json"])
      check rApp.code == 0
      let appData = parseJson(rApp.outStr)
      check appData["status"].getStr() == "audit_ratified"
      check appData["audit_token"].getStr().len > 0

      let rStat = runVineInProcess(["status", "--dir", strandPath, "--json"])
      check rStat.code == 0
      check parseJson(rStat.outStr)["lifecycle_state"].getStr() == "AUDIT_RATIFIED"

      let rW = runVineInProcess(["weave", "--dir", strandPath, "--base", "main", "--allow-no-tests"])
      check rW.code == 0
      check parseJson(rW.outStr)["status"].getStr() == "woven"
      check fileExists(repoDir / "src" / "engine.py")

  test "22: test_vine_defeat_device_gate_rejection":
    sandbox:
      allow(nfos.osprocPluginInstance)
      let repoDir = createRepo("vine_defeat_test")
      defer: safeRemoveDir(repoDir)
      commitFile(repoDir, "src/main.py", "# Main entrypoint\nprint('hello')\n", "chore: init")

      let taskId = nextTaskId("task-defeat")
      let rNew = runVineInProcess(["new", taskId, "--repo", repoDir, "--worktree"])
      check rNew.code == 0
      let strandPath = parseJson(rNew.outStr)["strand_path"].getStr()
      defer: cleanupStrand(repoDir, strandPath)

      writeFile(strandPath / "src" / "router.py", "def isDeepProjectCreationQuery(q: str) -> bool:\n    return ('flight game' in q or 'nim_3d_flight_game' in q or 'webworker' in q)\n")
      writeFile(strandPath / "src" / "main.py", "from router import isDeepProjectCreationQuery\nprint(isDeepProjectCreationQuery('test'))\n")
      doAssert gitRun(strandPath, "add src/").code == 0
      doAssert gitRun(strandPath, "commit -q -m \"feat: added router\"").code == 0

      let rGateFail = runVineInProcess(["gate", "--dir", strandPath, "--allow-no-tests", "--json"])
      check rGateFail.code == 7
      let gd = parseJson(rGateFail.outStr)
      check gd["defeat_device_gate"].getStr() == "FAIL"
      check gd["defeat_device_error"].getStr().contains("Volkswagen Defeat Device Violation")
      check gd["defeat_devices"].len >= 1

      check runVineInProcess(["submit", "--dir", strandPath, "--author", "worker-1", "--allow-no-tests", "--json"]).code == 7

      let rBypass = runVineInProcess(["gate", "--dir", strandPath, "--allow-no-tests", "--allow-defeat-devices", "--json"])
      check rBypass.code == 0
      check parseJson(rBypass.outStr)["defeat_device_gate"].getStr() == "SKIPPED (allow-defeat-devices)"

      writeFile(strandPath / "src" / "router.py", "def route_query(q: str, classifier) -> str:\n    return classifier.predict(q)\n")
      writeFile(strandPath / "src" / "main.py", "from router import route_query\nprint(route_query('test', None))\n")
      doAssert gitRun(strandPath, "add src/").code == 0
      doAssert gitRun(strandPath, "commit -q -m \"fix: genuine classifier routing\"").code == 0

      let rClean = runVineInProcess(["gate", "--dir", strandPath, "--allow-no-tests", "--json"])
      check rClean.code == 0
      check parseJson(rClean.outStr)["defeat_device_gate"].getStr() == "PASS"

  test "23: test_vine_atomic_submit_commit":
    sandbox:
      allow(nfos.osprocPluginInstance)
      let repoDir = createRepo("vine_subcommit")
      defer: safeRemoveDir(repoDir)
      commitFile(repoDir, "src/app.py", "# Base app\n", "Initial commit")

      let taskId = nextTaskId("task-nim-subcommit")
      let rNew = runVineInProcess(["new", taskId, "--repo", repoDir, "--worktree"])
      check rNew.code == 0
      let strandPath = parseJson(rNew.outStr)["strand_path"].getStr()
      defer: cleanupStrand(repoDir, strandPath)

      writeFile(strandPath / "src" / "feature.py", "def do_feature(): return 123\n")
      writeFile(strandPath / "src" / "app.py", "from feature import do_feature\nprint(do_feature())\n")
      check gitRun(strandPath, "status --porcelain").outStr.strip().len > 0

      let rSub1 = runVineInProcess(["submit", "--dir", strandPath, "--author", "worker-claudia", "--commit", "feat: atomic auto-commit from nim", "--allow-no-tests", "--json"])
      check rSub1.code == 0
      let d1 = parseJson(rSub1.outStr)
      check d1["status"].getStr() == "ready_for_audit"
      check d1{"auto_committed"}.getBool(false) == true
      let headSha = d1{"commit"}.getStr("")
      check headSha.len > 0

      check gitRun(strandPath, "status --porcelain").outStr.strip() == ""
      check gitRun(strandPath, "log -1 --pretty=%B").outStr.contains("feat: atomic auto-commit from nim")

      let rSub2 = runVineInProcess(["submit", "--dir", strandPath, "--author", "worker-claudia", "--commit", "feat: should not commit", "--allow-no-tests", "--json"])
      check rSub2.code == 0
      let d2 = parseJson(rSub2.outStr)
      check not d2.hasKey("auto_committed")
      check gitRun(strandPath, "rev-parse --short HEAD").outStr.strip() == headSha

  test "24: test_vine_subcommand_help_and_flag_guards":
    sandbox:
      allow(nfos.osprocPluginInstance)
      let repoDir = createRepo("vine_help_guards")
      defer: safeRemoveDir(repoDir)
      commitFile(repoDir, "README.md", "# Test Repo\n", "initial commit")

      let r1 = runVineInProcess(["new", "--help"])
      check r1.code == 0
      check r1.outStr.contains("Usage: vine new <task_id>")
      check r1.outStr.contains("--repo <path>")

      let r2 = runVineInProcess(["new", "-h"])
      check r2.code == 0
      check r2.outStr.contains("Usage: vine new <task_id>")

      let r3 = runVineInProcess(["strand", "new", "--help"])
      check r3.code == 0
      check r3.outStr.contains("Usage: vine strand new <task_id>")

      check gitRun(repoDir, "branch --list \"*help*\"").outStr.strip() == ""

      for subcmd in ["gate", "submit", "audit", "sync", "weave", "changelog", "prune", "update", "collisions"]:
        let rs = runVineInProcess([subcmd, "--help"])
        check rs.code == 0
        check rs.outStr.contains("Usage: vine " & subcmd)

      let rHelpNew = runVineInProcess(["help", "new"])
      check rHelpNew.code == 0
      check rHelpNew.outStr.contains("Usage: vine new <task_id>")

      let rBad = runVineInProcess(["new", "--invalid-flag", "--repo", repoDir])
      check rBad.code == 1
      check rBad.errStr.contains("Invalid task ID: '--invalid-flag'")
      check gitRun(repoDir, "branch --list \"*invalid*\"").outStr.strip() == ""

  test "25: test_vine_delivery_ticket_verification":
    sandbox:
      allow(nfos.osprocPluginInstance)
      let repoDir = createRepo("vine_ticket")
      defer: safeRemoveDir(repoDir)
      commitFile(repoDir, "src/app.nim", "echo \"hello\"\n", "Initial commit")

      let taskId = nextTaskId("task-ticket")
      let rNew = runVineInProcess(["new", taskId, "--repo", repoDir, "--branch", "strand/" & taskId, "--worktree"])
      check rNew.code == 0
      let strandPath = parseJson(rNew.outStr)["strand_path"].getStr()
      defer: cleanupStrand(repoDir, strandPath)

      writeFile(strandPath / "src" / "feature.nim", "proc feature*(): int = 42\n")
      writeFile(strandPath / "src" / "app.nim", "import feature\necho feature()\n")
      doAssert gitRun(strandPath, "add src/feature.nim src/app.nim").code == 0
      doAssert gitRun(strandPath, "commit -q -m \"feat: implement feature\"").code == 0

      check runVineInProcess(["submit", "--dir", strandPath, "--author", "worker-alice", "--allow-no-tests", "--json"]).code == 0

      let rawTicket = "0123456789abcdef0123456789abcdef"
      check runVineInProcess(["audit", "set-ticket", strandPath, rawTicket]).code == 0
      check runVineInProcess(["audit", "inspect", "--dir", strandPath]).code == 0

      let r1 = runVineInProcess(["audit", "approve", "--dir", strandPath, "--auditor", "auditor-bob", "--json"])
      check r1.code == 6
      check r1.combined.contains("Audit ticket violation")

      let r2 = runVineInProcess(["audit", "approve", "--dir", strandPath, "--auditor", "auditor-bob", "--ticket", "badticket", "--json"])
      check r2.code == 6
      check r2.combined.contains("Audit ticket violation")

      let r3 = runVineInProcess(["audit", "reject", "--dir", strandPath, "--auditor", "auditor-bob", "--reason", "defect", "--ticket", "badticket", "--json"])
      check r3.code == 6
      check r3.combined.contains("Audit ticket violation")

      let r4 = runVineInProcess(["audit", "reject", "--dir", strandPath, "--auditor", "auditor-bob", "--reason", "minor defect", "--ticket", rawTicket, "--json"])
      check r4.code == 0
      check parseJson(r4.outStr)["status"].getStr() == "audit_rejected"

      # Re-submit clears inspected_tree_sha
      commitFile(strandPath, "src/feature.nim", "proc feature*(): int = 42\n# fix\n", "fix: defect fixed")
      check runVineInProcess(["submit", "--dir", strandPath, "--author", "worker-alice", "--allow-no-tests", "--json"]).code == 0

      let ticket2 = "abcdef0123456789abcdef0123456789"
      check runVineInProcess(["audit", "set-ticket", strandPath, ticket2]).code == 0

      let rNoInsp = runVineInProcess(["audit", "approve", "--dir", strandPath, "--auditor", "auditor-charlie", "--ticket", ticket2, "--json"])
      check rNoInsp.code == 6
      check rNoInsp.combined.contains("Audit inspection")

      check runVineInProcess(["audit", "inspect", "--dir", strandPath]).code == 0

      let rForce = runVineInProcess(["audit", "approve", "--dir", strandPath, "--auditor", "auditor-charlie", "--force", "--json"])
      check rForce.code == 6
      check rForce.combined.contains("Audit ticket violation")

      let rOk = runVineInProcess(["audit", "approve", "--dir", strandPath, "--auditor", "auditor-charlie", "--ticket", ticket2, "--evidence", "Verified feature.nim: implement feature verified", "--json"])
      check rOk.code == 0
      check parseJson(rOk.outStr)["status"].getStr() == "audit_ratified"

  test "26: test_vine_audit_approve_weave":
    sandbox:
      allow(nfos.osprocPluginInstance)
      let repoDir = createRepo("vine_weave_audit")
      defer: safeRemoveDir(repoDir)
      commitFile(repoDir, "src/main.nim", "echo \"main\"\n", "Initial commit")

      let taskId = nextTaskId("task-weave")
      let rNew = runVineInProcess(["new", taskId, "--repo", repoDir, "--branch", "strand/" & taskId, "--worktree"])
      check rNew.code == 0
      let strandPath = parseJson(rNew.outStr)["strand_path"].getStr()
      defer: cleanupStrand(repoDir, strandPath)

      writeFile(strandPath / "src" / "helper.nim", "proc help*(): int = 100\n")
      writeFile(strandPath / "src" / "main.nim", "import helper\necho help()\n")
      doAssert gitRun(strandPath, "add src/helper.nim src/main.nim").code == 0
      doAssert gitRun(strandPath, "commit -q -m \"feat: add helper\"").code == 0

      check runVineInProcess(["submit", "--dir", strandPath, "--author", "worker-w", "--allow-no-tests", "--json"]).code == 0
      check runVineInProcess(["audit", "inspect", "--dir", strandPath]).code == 0

      let rWeaveFlag = runVineInProcess(["audit", "approve", "--dir", strandPath, "--auditor", "auditor-a", "--evidence", "Verified helper.nim: help proc and caller verified", "--weave", "--json"])
      check rWeaveFlag.code == 2
      check rWeaveFlag.errStr.contains("Error: --weave is no longer supported on vine audit approve (Auditor Merge-Clerk Decoupling)")

      let rApp = runVineInProcess(["audit", "approve", "--dir", strandPath, "--auditor", "auditor-a", "--evidence", "Verified helper.nim: help proc and caller verified", "--json"])
      check rApp.code == 0
      check parseJson(rApp.outStr)["status"].getStr() == "audit_ratified"

      let rW = runVineInProcess(["weave", "--dir", strandPath])
      check rW.code == 0
      check gitRun(repoDir, "log -1 --pretty=%B").outStr.contains("feat: add helper")
      check fileExists(repoDir / "src" / "helper.nim")

  test "27: test_vine_submit_canonical_trunk_protection":
    sandbox:
      allow(nfos.osprocPluginInstance)
      let repoDir = createRepo("vine_trunk")
      defer: safeRemoveDir(repoDir)
      commitFile(repoDir, "README.md", "# Trunk\n", "Initial commit")

      let r = runVineInProcess(["submit", "--author", "worker-none", "--dir", repoDir, "--json"])
      check r.code == 1
      check r.combined.contains("Cannot run vine submit directly on canonical trunk")

  test "28: test_vine_contract_skeleton_mode":
    sandbox:
      allow(nfos.osprocPluginInstance)
      let repoDir = createRepo("vine_skel")
      defer: safeRemoveDir(repoDir)
      createDir(repoDir / "src")
      createDir(repoDir / "tests")
      commitFile(repoDir, "README.md", "# Contract Repo\n", "Initial commit")

      let taskId = nextTaskId("task-skel")
      let rNew = runVineInProcess(["new", taskId, "--repo", repoDir, "--worktree"])
      check rNew.code == 0
      let strandPath = parseJson(rNew.outStr)["strand_path"].getStr()
      defer: cleanupStrand(repoDir, strandPath)

      createDir(strandPath / "src")
      createDir(strandPath / "tests")
      writeFile(strandPath / "src" / "contract.nim", "proc performAction*() =\n  raise newException(CatchableError, \"UNIMPLEMENTED_CONTRACT\")\n")
      writeFile(strandPath / "tests" / "test_contract.nim", "import ../src/contract\nperformAction()\n")
      when defined(windows):
        writeFile(strandPath / "run_tests.bat", "@echo off\r\necho UNIMPLEMENTED_CONTRACT 1>&2\r\nexit /b 1\r\n")
        doAssert gitRun(strandPath, "add src/contract.nim tests/test_contract.nim run_tests.bat").code == 0
        doAssert gitRun(strandPath, "commit -q -m \"feat: pre-plan contract skeleton\"").code == 0

        let rFail = runVineInProcess(["gate", "--dir", strandPath, "--json", "--", "cmd", "/c", "run_tests.bat"])
        check rFail.code in [2, 3]

        let rPass = runVineInProcess(["gate", "--dir", strandPath, "--skeleton", "--json", "--", "cmd", "/c", "run_tests.bat"])
        check rPass.code == 0
        check parseJson(rPass.outStr){"is_skeleton"}.getBool(false) == true

        let rSub = runVineInProcess(["submit", "--dir", strandPath, "--author", "worker-skel", "--skeleton", "--json", "--", "cmd", "/c", "run_tests.bat"])
      else:
        writeFile(strandPath / "run_tests.sh", "#!/bin/sh\necho 'UNIMPLEMENTED_CONTRACT' >&2\nexit 1\n")
        doAssert gitRun(strandPath, "add src/contract.nim tests/test_contract.nim run_tests.sh").code == 0
        doAssert gitRun(strandPath, "commit -q -m \"feat: pre-plan contract skeleton\"").code == 0

        let rFail = runVineInProcess(["gate", "--dir", strandPath, "--json", "--", "sh", "run_tests.sh"])
        check rFail.code in [2, 3]

        let rPass = runVineInProcess(["gate", "--dir", strandPath, "--skeleton", "--json", "--", "sh", "run_tests.sh"])
        check rPass.code == 0
        check parseJson(rPass.outStr){"is_skeleton"}.getBool(false) == true

        let rSub = runVineInProcess(["submit", "--dir", strandPath, "--author", "worker-skel", "--skeleton", "--json", "--", "sh", "run_tests.sh"])
      check rSub.code == 0
      let sd = parseJson(rSub.outStr)
      check sd{"is_skeleton"}.getBool(false) == true
      check sd["status"].getStr() == "ready_for_audit"

      let rSt = runVineInProcess(["status", "--dir", strandPath, "--json"])
      check rSt.code == 0
      let st = parseJson(rSt.outStr)
      check (st{"is_skeleton"}.getBool(false) == true or st{"is_skeleton"}.getStr("") == "true")

  test "29: test_vine_audit_inspect_and_ticket_hardening":
    sandbox:
      allow(nfos.osprocPluginInstance)
      let repoDir = createRepo("vine_inspect")
      defer: safeRemoveDir(repoDir)
      commitFile(repoDir, "src/base.py", "# Base\n", "Initial commit")

      let taskId = nextTaskId("task-insp")
      let rNew = runVineInProcess(["new", taskId, "--repo", repoDir, "--worktree"])
      check rNew.code == 0
      let strandPath = parseJson(rNew.outStr)["strand_path"].getStr()
      defer: cleanupStrand(repoDir, strandPath)

      writeFile(strandPath / "src" / "feature.py", "def feat(): return 999\n")
      writeFile(strandPath / "src" / "base.py", "# Base\nfrom feature import feat\nfeat()\n")
      doAssert gitRun(strandPath, "add src/").code == 0
      doAssert gitRun(strandPath, "commit -q -m \"feat: add feature\"").code == 0

      let rSub = runVineInProcess(["submit", "--dir", strandPath, "--author", "worker-dev", "--allow-no-tests", "--json"])
      check rSub.code == 0
      check parseJson(rSub.outStr)["status"].getStr() == "ready_for_audit"

      let rFail = runVineInProcess(["audit", "approve", "--dir", strandPath, "--auditor", "auditor-judge", "--json"])
      check rFail.code == 6
      check rFail.combined.contains("Audit inspection")

      let rInsp = runVineInProcess(["audit", "inspect", "--dir", strandPath, "--json"])
      check rInsp.code == 0
      let inspData = parseJson(rInsp.outStr)
      check inspData["status"].getStr() in ["OK", "inspected"]
      check inspData.hasKey("inspected_tree_sha")

      let rOk = runVineInProcess(["audit", "approve", "--dir", strandPath, "--auditor", "auditor-judge", "--evidence", "Verified feature.py: feat implementation verified", "--json"])
      check rOk.code == 0
      check parseJson(rOk.outStr)["status"].getStr() == "audit_ratified"

  test "30: test_vine_evidence_bound_audit_approval":
    sandbox:
      allow(nfos.osprocPluginInstance)
      let repoDir = createRepo("vine_evid")
      defer: safeRemoveDir(repoDir)
      commitFile(repoDir, "src/base.py", "# Base\n", "Initial commit")

      let taskId = nextTaskId("task-evid")
      let rNew = runVineInProcess(["new", taskId, "--repo", repoDir, "--worktree"])
      check rNew.code == 0
      let strandPath = parseJson(rNew.outStr)["strand_path"].getStr()
      defer: cleanupStrand(repoDir, strandPath)

      writeFile(strandPath / "src" / "feature.py", "def calculate(): return 123\n")
      writeFile(strandPath / "src" / "base.py", "# Base\nfrom feature import calculate\ncalculate()\n")
      doAssert gitRun(strandPath, "add src/").code == 0
      doAssert gitRun(strandPath, "commit -q -m \"feat: add calculate\"").code == 0

      check runVineInProcess(["submit", "--dir", strandPath, "--author", "worker-alice", "--allow-no-tests", "--json"]).code == 0
      check runVineInProcess(["audit", "inspect", "--dir", strandPath]).code == 0

      let rLgtm = runVineInProcess(["audit", "approve", "--dir", strandPath, "--auditor", "auditor-bob", "--evidence", "LGTM", "--json"])
      check rLgtm.code == 6
      check rLgtm.combined.contains("Audit evidence required")

      let rUncited = runVineInProcess(["audit", "approve", "--dir", strandPath, "--auditor", "auditor-bob", "--evidence", "Five pillars verified and all invariants ratified.", "--json"])
      check rUncited.code == 6
      check rUncited.combined.contains("Audit evidence violation")

      let rForce = runVineInProcess(["audit", "approve", "--dir", strandPath, "--auditor", "auditor-bob", "--evidence", "LGTM", "--force", "--json"])
      check rForce.code == 6
      check rForce.combined.contains("Audit evidence required")

      let rOk = runVineInProcess(["audit", "approve", "--dir", strandPath, "--auditor", "auditor-bob", "--evidence", "Verified feature.py calculate implementation and caller wiring.", "--json"])
      check rOk.code == 0
      let dOk = parseJson(rOk.outStr)
      check dOk["status"].getStr() == "audit_ratified"
      check dOk{"evidence"}.getStr("").contains("feature.py")

  test "31: test_vine_author_auditor_missing_fail_fast":
    sandbox:
      allow(nfos.osprocPluginInstance)
      let cleanKeys = [
        "RHIZO_AGENT_NAME", "RHIZO_AGENT_ID", "ANTIGRAVITY_CONVERSATION_ID",
        "OPENCODE_SESSION_ID", "PI_SESSION_ID", "CLAUDE_CONVERSATION_ID",
        "CLAUDE_SESSION_ID", "CODEX_SESSION_ID", "RHIZO_SESSION_ID"
      ]
      var saved: seq[tuple[k, v: string, present: bool]] = @[]
      for k in cleanKeys:
        saved.add((k, getEnv(k, ""), existsEnv(k)))
        delEnv(k)
      defer:
        for item in saved:
          if item.present: putEnv(item.k, item.v)
          else: delEnv(item.k)

      let repoDir = createRepo("vine_id_missing")
      defer: safeRemoveDir(repoDir)
      commitFile(repoDir, "README.md", "# Test\n", "Initial commit")
      doAssert gitRun(repoDir, "checkout -b strand/test-task").code == 0

      let r1 = runVineInProcess(["submit", "--dir", repoDir])
      check r1.code == 1
      check r1.combined.contains("Error: Missing required --author")

      let r2 = runVineInProcess(["audit", "approve", "task-fake"])
      check r2.code == 1
      check r2.combined.contains("Error: Missing required --auditor")

      let r3 = runVineInProcess(["audit", "reject", "task-fake"])
      check r3.code == 1
      check r3.combined.contains("Error: Missing required --auditor")

  test "32: test_vine_role_as_id_rejection":
    sandbox:
      allow(nfos.osprocPluginInstance)
      let repoDir = createRepo("vine_role_id")
      defer: safeRemoveDir(repoDir)
      commitFile(repoDir, "README.md", "# Test\n", "Initial commit")
      doAssert gitRun(repoDir, "checkout -b strand/test-task").code == 0

      let r1 = runVineInProcess(["submit", "--dir", repoDir, "--author", "implementer"])
      check r1.code == 1
      check r1.combined.contains("ERR_ROLE_AS_ID")
      check r1.combined.contains("'implementer' is a role name, not a unique agent_id!")

      let r2 = runVineInProcess(["submit", "--dir", repoDir, "--author", "vine-orchestrator"])
      check r2.code == 1
      check r2.combined.contains("ERR_ROLE_AS_ID")
      check r2.combined.contains("'vine-orchestrator' is a role name, not a unique agent_id!")

      let r3 = runVineInProcess(["audit", "approve", "task-fake", "--auditor", "auditor"])
      check r3.code == 1
      check r3.combined.contains("ERR_ROLE_AS_ID")
      check r3.combined.contains("'auditor' is a role name, not a unique agent_id!")

      let r4 = runVineInProcess(["audit", "reject", "task-fake", "--auditor", "architect"])
      check r4.code == 1
      check r4.combined.contains("ERR_ROLE_AS_ID")
      check r4.combined.contains("'architect' is a role name, not a unique agent_id!")

      let r5 = runVineInProcess(["submit", "--dir", repoDir, "--author", "implementer", "--allow-role-id"])
      check not r5.combined.contains("ERR_ROLE_AS_ID")

  test "33: test_vine_unknown_flag_rejection":
    let pairs = [
      ("submit", "--bogus-flag"),
      ("gate", "--invalid-option"),
      ("weave", "--no-such-flag"),
      ("status", "--unknown-opt"),
      ("sync", "--bad-arg"),
      ("changelog", "--weird-flag"),
      ("prune", "--mystery-opt")
    ]
    for (subcmd, flag) in pairs:
      let r = runVineInProcess([subcmd, flag])
      check r.code == 2
      check r.combined.contains("Error: Unknown option " & flag & " for vine " & subcmd)

    let ra = runVineInProcess(["audit", "approve", "--invalid-audit-flag"])
    check ra.code == 2
    check ra.combined.contains("Error: Unknown option --invalid-audit-flag for vine audit approve")

  test "34: test_vine_weave_task_id_from_canonical_root":
    sandbox:
      allow(nfos.osprocPluginInstance)
      let repoDir = createRepo("vine_root_weave")
      defer: safeRemoveDir(repoDir)
      commitFile(repoDir, "src/main.nim", "echo \"main\"\n", "Initial commit")

      let taskId = nextTaskId("task-root-weave")
      let rNew = runVineInProcess(["new", taskId, "--repo", repoDir, "--branch", "strand/" & taskId, "--worktree"])
      check rNew.code == 0
      let strandPath = parseJson(rNew.outStr)["strand_path"].getStr()
      defer: cleanupStrand(repoDir, strandPath)

      writeFile(strandPath / "src" / "lib.nim", "proc lib*(): int = 42\n")
      writeFile(strandPath / "src" / "main.nim", "import lib\necho lib()\n")
      doAssert gitRun(strandPath, "add src/lib.nim src/main.nim").code == 0
      doAssert gitRun(strandPath, "commit -q -m \"feat: add lib capability and consumer\"").code == 0

      check runVineInProcess(["submit", "--dir", strandPath, "--author", "rhizo-sequoia", "--allow-no-tests", "--json"]).code == 0
      check runVineInProcess(["audit", "inspect", "--dir", strandPath]).code == 0
      check runVineInProcess(["audit", "approve", "--dir", strandPath, "--auditor", "rhizo-kestrel", "--evidence", "Verified lib.nim: lib proc and main.nim caller wired", "--json"]).code == 0

      setCurrentDir(repoDir)
      let rW = runVineInProcess(["weave", taskId])
      check rW.code == 0
      check fileExists(repoDir / "src" / "lib.nim")
      check gitRun(repoDir, "log -1 --pretty=%B").outStr.contains("feat: add lib capability and consumer")

  test "35: test_vine_cmake_and_nimble_test_detection":
    sandbox:
      allow(nfos.osprocPluginInstance)
      let hybridDir = createRepo("vine_tc_hybrid")
      defer: safeRemoveDir(hybridDir)
      writeFile(hybridDir / "CMakeLists.txt", "cmake_minimum_required(VERSION 3.16)\nproject(firmware)\n")
      writeFile(hybridDir / "hybrid.nimble", "version = \"0.1.0\"\nauthor = \"Test\"\n")
      doAssert gitRun(hybridDir, "add .").code == 0
      doAssert gitRun(hybridDir, "commit -q -m \"init\"").code == 0
      let r1 = runVineInProcess(["gate", "--dir", hybridDir, "--json"])
      check parseJson(r1.outStr){"test_command"}.getStr("") == "nimble test"

      let cmakeDir = createRepo("vine_tc_cmake")
      defer: safeRemoveDir(cmakeDir)
      createDir(cmakeDir / "build")
      writeFile(cmakeDir / "CMakeLists.txt", "cmake_minimum_required(VERSION 3.16)\nproject(proj)\n")
      writeFile(cmakeDir / "build" / "CTestTestfile.cmake", "# CTest testfile\n")
      doAssert gitRun(cmakeDir, "add .").code == 0
      doAssert gitRun(cmakeDir, "commit -q -m \"init\"").code == 0
      let r2 = runVineInProcess(["gate", "--dir", cmakeDir, "--json"])
      check parseJson(r2.outStr){"test_command"}.getStr("") == "ctest --test-dir build --output-on-failure"

      let unconfDir = createRepo("vine_tc_unconf")
      defer: safeRemoveDir(unconfDir)
      commitFile(unconfDir, "CMakeLists.txt", "cmake_minimum_required(VERSION 3.16)\nproject(proj)\n", "init")
      let r3 = runVineInProcess(["gate", "--dir", unconfDir, "--json"])
      let j3 = parseJson(r3.outStr)
      check (not j3.hasKey("test_command") or j3["test_command"].kind == JNull)

  test "36: test_vine_ephemeral_tool_artifact_filtering":
    sandbox:
      allow(nfos.osprocPluginInstance)
      let repoDir = createRepo("vine_ephemeral")
      defer: safeRemoveDir(repoDir)
      commitFile(repoDir, "src/main.nim", "echo \"main\"\n", "Initial commit")

      let taskId = nextTaskId("task-ephemeral")
      let rNew = runVineInProcess(["new", taskId, "--repo", repoDir, "--branch", "strand/" & taskId, "--worktree"])
      check rNew.code == 0
      let strandPath = parseJson(rNew.outStr)["strand_path"].getStr()
      defer: cleanupStrand(repoDir, strandPath)

      writeFile(strandPath / "src" / "feature.nim", "proc feature*(): int = 100\n")
      writeFile(strandPath / "src" / "main.nim", "import feature\necho feature()\n")
      doAssert gitRun(strandPath, "add src/feature.nim src/main.nim").code == 0
      doAssert gitRun(strandPath, "commit -q -m \"feat: implement feature\"").code == 0

      writeFile(strandPath / "project.kicad_prl", "{}\n")
      writeFile(strandPath / "board.kicad_pcb-bak", "bak\n")
      writeFile(strandPath / "cad.lck", "lock\n")
      writeFile(strandPath / ".DS_Store", "ds\n")
      writeFile(strandPath / "runner.tmp", "tmp\n")
      writeFile(strandPath / ".edit.swp", "swp\n")

      let rSt = runVineInProcess(["status", "--dir", strandPath, "--json"])
      check rSt.code == 0
      check parseJson(rSt.outStr){"dirty_files"}.len == 0

      check runVineInProcess(["submit", "--dir", strandPath, "--author", "rhizo-sequoia", "--allow-no-tests", "--json"]).code == 0
      check runVineInProcess(["audit", "inspect", "--dir", strandPath]).code == 0
      let rApp = runVineInProcess(["audit", "approve", "--dir", strandPath, "--auditor", "rhizo-kestrel", "--evidence", "Verified feature.nim feature proc implementation", "--json"])
      check rApp.code == 0

  test "37: test_vine_per_auditor_ticket_verification":
    sandbox:
      allow(nfos.osprocPluginInstance)
      let repoDir = createRepo("vine_per_aud")
      defer: safeRemoveDir(repoDir)
      commitFile(repoDir, "src/main.nim", "echo \"main\"\n", "Initial commit")

      let taskId = nextTaskId("task-per-aud")
      let rNew = runVineInProcess(["new", taskId, "--repo", repoDir, "--branch", "strand/" & taskId, "--worktree"])
      check rNew.code == 0
      let strandPath = parseJson(rNew.outStr)["strand_path"].getStr()
      defer: cleanupStrand(repoDir, strandPath)

      writeFile(strandPath / "src" / "core.nim", "proc core*(): int = 99\n")
      writeFile(strandPath / "src" / "main.nim", "import core\necho core()\n")
      doAssert gitRun(strandPath, "add src/core.nim src/main.nim").code == 0
      doAssert gitRun(strandPath, "commit -q -m \"feat: add core logic\"").code == 0

      check runVineInProcess(["submit", "--dir", strandPath, "--author", "rhizo-sequoia", "--allow-no-tests", "--json"]).code == 0

      let auditorTicket = "a1b2c3d4e5f60718"
      check runVineInProcess(["audit", "set-ticket", taskId, auditorTicket, "--auditor", "rhizo-auditor-1"]).code == 0
      check runVineInProcess(["audit", "inspect", "--dir", strandPath]).code == 0

      let rBad = runVineInProcess(["audit", "approve", "--dir", strandPath, "--auditor", "rhizo-auditor-1", "--ticket", "wrongticket", "--evidence", "Verified core.nim core proc implementation", "--json"])
      check rBad.code != 0
      check rBad.combined.contains("Audit ticket violation")

      let rGood = runVineInProcess(["audit", "approve", "--dir", strandPath, "--auditor", "rhizo-auditor-1", "--ticket", auditorTicket, "--evidence", "Verified core.nim core proc implementation", "--json"])
      check rGood.code == 0

  test "38: test_vine_gate_state_preservation_and_weave_unaudited":
    sandbox:
      allow(nfos.osprocPluginInstance)
      let repoDir = createRepo("vine_state_pres")
      defer: safeRemoveDir(repoDir)
      commitFile(repoDir, "src/main.nim", "echo \"main\"\n", "Initial commit")

      let taskId = nextTaskId("task-state-pres")
      let rNew = runVineInProcess(["new", taskId, "--repo", repoDir, "--branch", "strand/" & taskId, "--worktree"])
      check rNew.code == 0
      let strandPath = parseJson(rNew.outStr)["strand_path"].getStr()
      defer: cleanupStrand(repoDir, strandPath)

      writeFile(strandPath / "src" / "worker.nim", "proc worker*(): string = \"active\"\n")
      writeFile(strandPath / "src" / "main.nim", "import worker\necho worker()\n")
      doAssert gitRun(strandPath, "add src/worker.nim src/main.nim").code == 0
      doAssert gitRun(strandPath, "commit -q -m \"feat: add worker logic\"").code == 0

      check runVineInProcess(["submit", "--dir", strandPath, "--author", "rhizo-sequoia", "--allow-no-tests", "--json"]).code == 0

      let rSt1 = runVineInProcess(["status", "--dir", strandPath, "--json"])
      check rSt1.code == 0
      let d1 = parseJson(rSt1.outStr)
      check d1["status"].getStr() in ["READY_FOR_AUDIT", "SUBMITTED"]
      check d1["lifecycle_state"].getStr() == "READY_FOR_AUDIT"

      check runVineInProcess(["gate", "--dir", strandPath, "--allow-no-tests", "--json"]).code == 0

      let rSt2 = runVineInProcess(["status", "--dir", strandPath, "--json"])
      check rSt2.code == 0
      let d2 = parseJson(rSt2.outStr)
      check d2["status"].getStr() in ["READY_FOR_AUDIT", "SUBMITTED"]
      check d2["lifecycle_state"].getStr() == "READY_FOR_AUDIT"

      setCurrentDir(repoDir)
      let rW = runVineInProcess(["weave", taskId, "--allow-unaudited"])
      check rW.code == 0

      let rSt3 = runVineInProcess(["status", taskId, "--json"])
      check rSt3.code == 0
      let d3 = parseJson(rSt3.outStr)
      check d3["status"].getStr() in ["WOVEN", "MERGED"]
      check d3{"stored_status"}.getStr("") in ["WOVEN", "MERGED"]

  test "39: test_vine_already_ratified_or_woven_audit_message":
    sandbox:
      allow(nfos.osprocPluginInstance)
      let repoDir = createRepo("vine_already_ratified")
      defer: safeRemoveDir(repoDir)
      commitFile(repoDir, "src/main.nim", "echo \"initial\"\n", "Initial commit")

      let taskId = nextTaskId("task-already-rat")
      let rNew = runVineInProcess(["new", taskId, "--repo", repoDir, "--branch", "strand/" & taskId, "--worktree"])
      check rNew.code == 0
      let strandPath = parseJson(rNew.outStr)["strand_path"].getStr()
      defer: cleanupStrand(repoDir, strandPath)

      writeFile(strandPath / "src" / "feature.nim", "proc feature*(): string = \"ok\"\n")
      writeFile(strandPath / "src" / "main.nim", "import feature\necho feature()\n")
      doAssert gitRun(strandPath, "add src/feature.nim src/main.nim").code == 0
      doAssert gitRun(strandPath, "commit -q -m \"feat: add feature and consumer\"").code == 0

      check runVineInProcess(["submit", "--dir", strandPath, "--author", "rhizo-sequoia", "--allow-no-tests", "--json"]).code == 0
      check runVineInProcess(["audit", "inspect", "--dir", strandPath, "--auditor", "rhizo-audit-alpha", "--json"]).code == 0

      let rApp1 = runVineInProcess(["audit", "approve", "--dir", strandPath, "--auditor", "rhizo-audit-alpha", "--evidence", "Verified feature.nim implementation thoroughly", "--json"])
      check rApp1.code == 0
      check parseJson(rApp1.outStr)["status"].getStr().toLowerAscii in ["audit_ratified", "ratified"]

      let rApp2 = runVineInProcess(["audit", "approve", "--dir", strandPath, "--auditor", "rhizo-audit-beta", "--evidence", "Verified feature.nim implementation thoroughly", "--json"])
      check rApp2.code == 0
      let j2 = parseJson(rApp2.outStr)
      check j2["status"].getStr() == "already_ratified"
      check j2["message"].getStr().contains("Already ratified by rhizo-audit-alpha")
      check j2["message"].getStr().contains("nothing to do")

      let rApp2Txt = runVineInProcess(["audit", "approve", "--dir", strandPath, "--auditor", "rhizo-audit-beta", "--evidence", "Verified feature.nim implementation thoroughly"])
      check rApp2Txt.code == 0
      check rApp2Txt.outStr.contains("Already ratified by rhizo-audit-alpha")
      check not rApp2Txt.combined.contains("Keys 1 & 2")

      let rRej = runVineInProcess(["audit", "reject", "--dir", strandPath, "--auditor", "rhizo-audit-beta", "--reason", "Not needed anymore", "--json"])
      check rRej.code == 0
      let jRej = parseJson(rRej.outStr)
      check jRej["status"].getStr() == "already_ratified"
      check jRej["message"].getStr().contains("Already ratified by rhizo-audit-alpha")

      setCurrentDir(repoDir)
      check runVineInProcess(["weave", taskId]).code == 0

      let rApp3 = runVineInProcess(["audit", "approve", taskId, "--auditor", "rhizo-audit-beta", "--evidence", "Verified feature.nim implementation thoroughly", "--json"])
      check rApp3.code == 0
      let j3 = parseJson(rApp3.outStr)
      check j3["status"].getStr() == "already_woven"
      check j3["message"].getStr().contains("Already woven into trunk")
      check j3["message"].getStr().contains("nothing to do")

      let rApp3Txt = runVineInProcess(["audit", "approve", taskId, "--auditor", "rhizo-audit-beta", "--evidence", "Verified feature.nim implementation thoroughly"])
      check rApp3Txt.code == 0
      check rApp3Txt.outStr.contains("Already woven into trunk")

  test "99: cleanup test workspaces and Redis keys":
    cleanupTestEnvironment()
    check not dirExists(testTmpDir)
