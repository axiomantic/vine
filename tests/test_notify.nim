# tests/test_notify.nim
# Unit and integration test suite for Vine strand lifecycle notifications,
# dynamic leader discovery, orchestrator awareness, and project multicast fallback.

import std/[os, osproc, strutils, json, unittest]
import tripwire
import tripwire/plugins/osproc as nfos
import notify, gate, weave, config, strand

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
  discard execCmdEx("git -C " & quoteShell(repo) & " config user.email agent@vine.mesh")
  discard execCmdEx("git -C " & quoteShell(repo) & " config user.name 'Vine Agent'")
  writeFile(repo / "README.md", "# Test Repo\n")
  discard execCmdEx("git -C " & quoteShell(repo) & " add README.md")
  discard execCmdEx("git -C " & quoteShell(repo) & " commit -q -m 'Initial commit'")
  return repo

suite "Vine Strand Lifecycle Notifications & Multicast Suite":

  teardown:
    try: setCurrentDir(initialWorkingDir)
    except CatchableError: discard

  test "isNotificationsDisabled detects CLI flag and environment variable":
    delEnv("VINE_NO_NOTIFY")
    check isNotificationsDisabled(false) == false
    check isNotificationsDisabled(true) == true

    putEnv("VINE_NO_NOTIFY", "1")
    check isNotificationsDisabled(false) == true
    check isNotificationsDisabled(true) == true

    putEnv("VINE_NO_NOTIFY", "true")
    check isNotificationsDisabled(false) == true

    delEnv("VINE_NO_NOTIFY")
    check isNotificationsDisabled(false) == false

  test "notifyStrandEvent respects notification suppression":
    let manifest = %*{
      "task_id": "task-test-suppress",
      "project": "vine",
      "orchestrator": "rhizo-test-orch"
    }

    # Case 1: noNotify param = true
    let res1 = notifyStrandEvent(manifest, "STRAND_SUBMITTED", noNotify = true)
    check res1["dispatched"].getBool() == false
    check res1["status"].getStr() == "skipped_disabled"

    # Case 2: VINE_NO_NOTIFY env var
    putEnv("VINE_NO_NOTIFY", "1")
    let res2 = notifyStrandEvent(manifest, "STRAND_SUBMITTED", noNotify = false)
    check res2["dispatched"].getBool() == false
    check res2["status"].getStr() == "skipped_disabled"
    delEnv("VINE_NO_NOTIFY")

  test "isAgentActive and isOrchestratorActive report agent cluster status without alias crutches":
    sandbox:
      allow(nfos.osprocPluginInstance)

      check isAgentActive("") == false
      check isAgentActive("non-existent-agent-xyz-99999") == false
      check isOrchestratorActive("") == false
      check isOrchestratorActive("non-existent-agent-xyz-99999") == false

  test "queryElectedLeader returns active leader or empty string when vacant":
    sandbox:
      allow(nfos.osprocPluginInstance)

      check queryElectedLeader("") == ""
      check queryElectedLeader("nonexistent-project-xyz-99999") == ""
      if isRhizoAvailable():
        let dummyLeader = "test-query-leader-" & $getCurrentProcessId()
        discard execCmdEx("rhizo status idle 'Testing' " & quoteShell(dummyLeader))
        discard execCmdEx("rhizo leader acquire orchestrator:vine-test-query --agent " & quoteShell(dummyLeader) & " --lease 30")
        defer:
          discard execCmdEx("rhizo leader resign orchestrator:vine-test-query --agent " & quoteShell(dummyLeader))
          discard execCmdEx("rhizo close " & quoteShell(dummyLeader))

        let leader = queryElectedLeader("vine-test-query")
        check leader == dummyLeader
        check isAgentActive(leader) == true

  test "notifyStrandEvent routes to elected_leader when direct origin is absent but leader exists":
    sandbox:
      allow(nfos.osprocPluginInstance)

      if isRhizoAvailable():
        let dummyLeader = "test-elected-orch-" & $getCurrentProcessId()
        discard execCmdEx("rhizo status idle 'Testing' " & quoteShell(dummyLeader))
        discard execCmdEx("rhizo leader acquire orchestrator:vine-test-elected --agent " & quoteShell(dummyLeader) & " --lease 30")
        defer:
          discard execCmdEx("rhizo leader resign orchestrator:vine-test-elected --agent " & quoteShell(dummyLeader))
          discard execCmdEx("rhizo close " & quoteShell(dummyLeader))

        let manifest = %*{
          "task_id": "task-test-leader-route",
          "project": "vine-test-elected",
          "orchestrator": "",
          "created_by": "",
          "author": "worker-dynamic-test",
          "branch": "strand/task-test-leader-route"
        }
        let res = notifyStrandEvent(manifest, "STRAND_SUBMITTED", noNotify = false)
        check res["dispatched"].getBool() == true
        check res["primary_mode"].getStr() == "elected_leader"
        check res["primary_target"].getStr() == dummyLeader

  test "notifyStrandEvent routes to created_by when orchestrator is empty":
    sandbox:
      allow(nfos.osprocPluginInstance)

      if isRhizoAvailable():
        let dummyCreator = "test-creator-" & $getCurrentProcessId()
        discard execCmdEx("rhizo status idle 'Testing' " & quoteShell(dummyCreator))
        defer:
          discard execCmdEx("rhizo close " & quoteShell(dummyCreator))

        let manifest = %*{
          "task_id": "task-test-created-by",
          "project": "vine-test-creator",
          "orchestrator": "",
          "created_by": dummyCreator,
          "author": "worker-other",
          "branch": "strand/task-test-created-by"
        }
        let res = notifyStrandEvent(manifest, "STRAND_SUBMITTED", noNotify = false)
        check res["dispatched"].getBool() == true
        check res["primary_mode"].getStr() == "orchestrator_direct"
        check res["primary_target"].getStr() == dummyCreator

  test "notifyStrandEvent falls back to project multicast when orchestrator and elected leader are absent":
    sandbox:
      allow(nfos.osprocPluginInstance)

      let manifestNoOrch = %*{
        "task_id": "task-test-multicast",
        "project": "vine-test-sandbox-vacant",
        "orchestrator": "non-existent-orch-xyz-12345",
        "author": "worker-2",
        "branch": "strand/task-test-multicast"
      }

      let res = notifyStrandEvent(manifestNoOrch, "STRAND_SUBMITTED", noNotify = false)
      if isRhizoAvailable():
        check res["dispatched"].getBool() == true
        check res["primary_mode"].getStr() == "multicast_fallback"
        check res["primary_target"].getStr() == "@vine-test-sandbox-vacant"
        check res["subject"].getStr().contains("STRAND_SUBMITTED: task-test-multicast")

  test "negative control: zero hardcoded <project>-orchestrator fallback":
    sandbox:
      allow(nfos.osprocPluginInstance)

      let manifestNoOrch = %*{
        "task_id": "task-test-negative-control",
        "project": "vacantsandbox99",
        "orchestrator": "",
        "created_by": "",
        "author": "worker-test",
        "branch": "strand/task-test-negative-control"
      }

      let res = notifyStrandEvent(manifestNoOrch, "STRAND_SUBMITTED", noNotify = false)
      if isRhizoAvailable():
        check res["primary_mode"].getStr() == "multicast_fallback"
        check res["primary_target"].getStr() == "@vacantsandbox99"
        check res["primary_target"].getStr() != "vacantsandbox99-orchestrator"

  test "AUDIT_RATIFIED and AUDIT_REJECTED trigger secondary notifications to author":
    sandbox:
      allow(nfos.osprocPluginInstance)

      let manifestAudit = %*{
        "task_id": "task-test-audit-events",
        "project": "vine-test-sandbox",
        "orchestrator": "non-existent-orch",
        "author": "worker-author-offline-sandbox",
        "auditor": "rhizo-auditor-offline-sandbox"
      }

      # AUDIT_RATIFIED
      let resRatified = notifyStrandEvent(manifestAudit, "AUDIT_RATIFIED", noNotify = false)
      if isRhizoAvailable():
        check resRatified["dispatched"].getBool() == true
        check resRatified["subject"].getStr().contains("AUDIT_RATIFIED")
        check resRatified.hasKey("secondary_targets")

      # AUDIT_REJECTED
      let details = %*{"rejection_reason": "Missing negative controls in tests"}
      let resRejected = notifyStrandEvent(manifestAudit, "AUDIT_REJECTED", details, noNotify = false)
      if isRhizoAvailable():
        check resRejected["dispatched"].getBool() == true
        check resRejected["subject"].getStr().contains("AUDIT_REJECTED")
        check resRejected.hasKey("secondary_targets")

  test "STRAND_WOVEN triggers secondary notifications to author and auditor":
    sandbox:
      allow(nfos.osprocPluginInstance)

      let manifestWoven = %*{
        "task_id": "task-test-woven",
        "project": "vine-test-sandbox",
        "orchestrator": "non-existent-orch",
        "author": "worker-author-offline-sandbox",
        "auditor": "rhizo-auditor-offline-sandbox",
        "canonical_repo": "/Users/eek/Development/vine"
      }

      let resWoven = notifyStrandEvent(manifestWoven, "STRAND_WOVEN", noNotify = false)
      if isRhizoAvailable():
        check resWoven["dispatched"].getBool() == true
        check resWoven["subject"].getStr().contains("STRAND_WOVEN")
        check resWoven.hasKey("secondary_targets")

  test "doStrandNew records created_by and eliminates hardcoded project-orchestrator":
    sandbox:
      allow(nfos.osprocPluginInstance)

      let repo = createTestGitRepo("vine_strand_orch_test")
      defer:
        try: setCurrentDir(initialWorkingDir)
        except CatchableError: discard
        removeDir(repo)

      # 1. doStrandNew with explicit createdByParam
      let (sRes1, sCode1) = doStrandNew(
        taskId = "task-orch-explicit",
        repoDirParam = repo,
        branchParam = "strand/task-orch-explicit",
        forceWorktree = true,
        createdByParam = "orch-tester-1",
        orchestratorParam = ""
      )
      check sCode1 == 0
      check sRes1["created_by"].getStr() == "orch-tester-1"
      check sRes1["orchestrator"].getStr() == "orch-tester-1"
      let strandPath1 = sRes1["strand_path"].getStr()
      defer:
        discard execCmdEx("git -C " & quoteShell(repo) & " worktree remove --force " & quoteShell(strandPath1))
        discard execCmdEx("git -C " & quoteShell(repo) & " worktree prune")
        removeDir(strandPath1.parentDir())

      let strandDotJson1 = parseFile(strandPath1 / ".vine" / "strand.json")
      check strandDotJson1["created_by"].getStr() == "orch-tester-1"

      # 2. doStrandNew with NO created_by and NO orchestrator
      let (sRes2, sCode2) = doStrandNew(
        taskId = "task-orch-empty",
        repoDirParam = repo,
        branchParam = "strand/task-orch-empty",
        forceWorktree = true,
        createdByParam = "",
        orchestratorParam = ""
      )
      check sCode2 == 0
      check sRes2["created_by"].getStr() == ""
      check sRes2["orchestrator"].getStr() == ""
      let strandPath2 = sRes2["strand_path"].getStr()
      defer:
        discard execCmdEx("git -C " & quoteShell(repo) & " worktree remove --force " & quoteShell(strandPath2))
        discard execCmdEx("git -C " & quoteShell(repo) & " worktree prune")
        removeDir(strandPath2.parentDir())

      let strandDotJson2 = parseFile(strandPath2 / ".vine" / "strand.json")
      check strandDotJson2["created_by"].getStr() == ""
      check strandDotJson2["orchestrator"].getStr() == ""
      let manifest2 = parseFile(strandPath2 / ".vine.json")
      check manifest2["created_by"].getStr() == ""
      check manifest2["orchestrator"].getStr() == ""
      # Negative control: assert it does NOT contain the old pattern "<repoName>-orchestrator"
      let repoBase = repo.splitPath.tail
      check manifest2["orchestrator"].getStr() != (repoBase & "-orchestrator")
