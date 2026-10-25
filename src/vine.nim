# /Users/eek/Development/vine/src/vine.nim
# Vine — Sub-Second Rift Workspaces & Zero-Mirage Git Weaving Engine.

import std/[os, strutils, json, sequtils]
import strand, gate, weave, guide, config, update, notify

const Version = "0.2.14"

proc printHelp() =
  echo "Vine v" & Version & " — Sub-Second Rift Workspaces & Zero-Mirage Git Weaving"
  echo ""
  echo "Usage:"
  echo "  vine new <task_id> [--repo <path>] [--branch <name>] [--base <ref>] [--parent <ref>] [--rift] [--worktree]"
  echo "  vine list [--repo <path>] [--all]"
  echo "  vine status [task_id|path] [--dir <path>] [--json]"
  echo "  vine collisions [--repo <path>] [--json]"
  echo "  vine gate [branch] [--base <ref>] [--dir <path>] [--submit] [--author <name>] [--timeout <sec>] [--skip-tests] [--allow-no-tests] [--allow-test-only] [--allow-no-changelog] [--allow-defeat-devices] [--ensure-unreleased] [--test-command <cmd>] [--json] [-- <command...>]"
  echo "  vine submit [task_id|path] [--dir <path>] [--author <name>] [--commit <msg>] [--listen] [--timeout <sec>] [--allow-no-tests] [--allow-test-only] [--allow-no-changelog] [--allow-defeat-devices] [--test-command <cmd>] [--no-notify] [--json]"
  echo "  vine audit <approve|reject|status> [task_id|path] [--auditor <name>] [--reason <text>] [--notes <text>] [--findings <file>] [--dir <path>] [--no-notify] [--json]"
  echo "  vine sync [--dir <path>] [--base <ref>] [--rebase]"
  echo "  vine weave [branch] [--base <ref>] [--dir <path>] [--force] [--allow-no-tests] [--allow-no-changelog] [--allow-unaudited] [--no-notify]"
  echo "  vine changelog [entry] [--dir <path>] [--section <sec>] [--ensure-unreleased] [--check]"
  echo "  vine prune [--repo <path>] [--max-age <hours>] [--apply]"
  echo "  vine update [--check] [--apply] [--skip <pkg@ver>] [--disable] [--enable] [--json]"
  echo "  vine guide <install|uninstall|check> [path]"
  echo "  vine config <init|show> [path]"
  echo ""
  echo "Global Options:"
  echo "  --version, -v    Print version"
  echo "  --help, -h       Print help"

proc main() =
  let args = commandLineParams()
  if args.len == 0 or args[0] in ["--help", "-h", "help"]:
    printHelp()
    quit(0)

  if args[0] in ["--version", "-v", "version"]:
    echo "vine " & Version
    quit(0)

  let cmd = args[0].toLowerAscii
  case cmd
  of "new", "create", "strand":
    var taskId = ""
    var repoDir = ""
    var branch = ""
    var baseRef = "HEAD"
    var parentBranch = ""
    var workerName = ""
    var orchName = ""
    var createdBy = ""
    var forceRift = false
    var forceWorktree = false
    var i = 1

    if cmd == "strand" and args.len >= 2 and args[1].toLowerAscii in ["new", "create"]:
      if args.len < 3:
        stderr.writeLine("Usage: vine strand new <task_id> [--repo <path>] [--branch <name>] [--base <ref>] [--parent <ref>] [--rift] [--worktree] [--orchestrator <name>] [--created-by <name>]")
        quit(1)
      taskId = args[2]
      i = 3
    else:
      if args.len < 2:
        stderr.writeLine("Usage: vine new <task_id> [--repo <path>] [--branch <name>] [--base <ref>] [--parent <ref>] [--rift] [--worktree] [--orchestrator <name>] [--created-by <name>]")
        quit(1)
      taskId = args[1]
      i = 2

    while i < args.len:
      let a = args[i]
      if a == "--repo" and i + 1 < args.len:
        repoDir = args[i+1]; inc i
      elif a.startsWith("--repo="): repoDir = a[7..^1]
      elif a == "--branch" and i + 1 < args.len:
        branch = args[i+1]; inc i
      elif a.startsWith("--branch="): branch = a[9..^1]
      elif a == "--base" and i + 1 < args.len:
        baseRef = args[i+1]; inc i
      elif a.startsWith("--base="): baseRef = a[7..^1]
      elif a == "--parent" and i + 1 < args.len:
        parentBranch = args[i+1]; inc i
      elif a.startsWith("--parent="): parentBranch = a[9..^1]
      elif a == "--worker" and i + 1 < args.len:
        workerName = args[i+1]; inc i
      elif a.startsWith("--worker="): workerName = a[9..^1]
      elif a == "--orchestrator" and i + 1 < args.len:
        orchName = args[i+1]; inc i
      elif a.startsWith("--orchestrator="): orchName = a[15..^1]
      elif (a in ["--created-by", "--from"]) and i + 1 < args.len:
        createdBy = args[i+1]; inc i
      elif a.startsWith("--created-by="): createdBy = a[13..^1]
      elif a.startsWith("--from="): createdBy = a[7..^1]
      elif a == "--rift": forceRift = true
      elif a == "--worktree": forceWorktree = true
      inc i
    let (res, code) = doStrandNew(taskId, repoDir, branch, baseRef, forceRift, forceWorktree, parentBranch, workerName, orchName, createdBy)
    if code != 0:
      stderr.writeLine(pretty(res))
      quit(code)
    echo pretty(res)

  of "list", "ls":
    var repoDir = ""
    var includeAll = false
    var i = 1
    while i < args.len:
      let a = args[i]
      if a in ["--all", "-a"]: includeAll = true
      elif a == "--repo" and i + 1 < args.len:
        repoDir = args[i+1]; inc i
      inc i
    let res = doStrandList(repoDir, includeAll)
    echo pretty(res)

  of "status":
    var strandIdent = ""
    var jsonOut = false
    var i = 1
    while i < args.len:
      let a = args[i]
      if a == "--json": jsonOut = true
      elif a == "--dir" and i + 1 < args.len:
        strandIdent = args[i+1]; inc i
      elif a.startsWith("--dir="): strandIdent = a[6..^1]
      elif not a.startsWith("-") and strandIdent.len == 0:
        strandIdent = a
      inc i
    let (res, code) = doStrandStatus(strandIdent)
    if jsonOut:
      echo pretty(res)
    else:
      if code == 0:
        echo "Strand Status: " & res{"task_id"}.getStr("")
        echo "  Project       : " & res{"project"}.getStr("")
        echo "  Branch        : " & res{"branch"}.getStr("") & " (parent: " & res{"parent_branch"}.getStr("") & ")"
        echo "  Lifecycle     : [" & res{"lifecycle_state"}.getStr("") & "]"
        echo "  Commits Ahead : " & $res{"commits_ahead"}.getInt(0)
        echo "  Commits Behind: " & $res{"commits_behind"}.getInt(0)
        echo "  Dirty Files   : " & $res{"dirty_count"}.getInt(0)
        echo "  Strand Path   : " & res{"strand_path"}.getStr("")
        let rider = getUpdatePromptRider(Version, "vine")
        if rider.len > 0:
          echo ""
          echo rider
      else:
        stderr.writeLine(pretty(res))
    quit(code)

  of "collisions", "conflicts":
    var repoDir = ""
    var jsonOut = false
    var i = 1
    while i < args.len:
      let a = args[i]
      if a == "--json": jsonOut = true
      elif a == "--repo" and i + 1 < args.len:
        repoDir = args[i+1]; inc i
      elif a.startsWith("--repo="): repoDir = a[7..^1]
      inc i
    let res = doStrandCollisions(repoDir)
    if jsonOut:
      echo pretty(res)
    else:
      let cCount = res{"collision_count"}.getInt(0)
      let sCount = res{"active_strands"}.getInt(0)
      if cCount > 0:
        echo "[COLLISION WARNING] " & $cCount & " potential file collision(s) detected across " & $sCount & " active strands:"
        for c in res{"collisions"}:
          var sNames: seq[string] = @[]
          for s in c{"strands"}: sNames.add(s.getStr)
          echo "  " & c{"file"}.getStr & " -> " & sNames.join(", ")
      else:
        echo "[CLEAN] No file collisions detected across " & $sCount & " active strand(s)."
    quit(0)

  of "gate", "check":
    var branch = ""
    var baseRef = "HEAD"
    var strandDir = ""
    var skipTests = false
    var allowNoTests = false
    var allowTestOnly = false
    var allowNoChangelog = false
    var autoEnsureUnreleased = false
    var allowDefeatDevices = false
    var submit = false
    var author = ""
    var timeoutSec = 0.0
    var testCmd = ""
    var jsonOut = false
    var i = 1
    while i < args.len:
      let a = args[i]
      if a == "--":
        if i + 1 < args.len:
          testCmd = args[i+1..^1].map(quoteShell).join(" ")
        break
      elif a == "--base" and i + 1 < args.len:
        baseRef = args[i+1]; inc i
      elif a.startsWith("--base="): baseRef = a[7..^1]
      elif a == "--dir" and i + 1 < args.len:
        strandDir = args[i+1]; inc i
      elif a.startsWith("--dir="): strandDir = a[6..^1]
      elif a == "--test-command" and i + 1 < args.len:
        testCmd = args[i+1]; inc i
      elif a.startsWith("--test-command="): testCmd = a[15..^1]
      elif a == "--author" and i + 1 < args.len:
        author = args[i+1]; inc i
      elif a.startsWith("--author="): author = a[9..^1]
      elif (a == "--timeout" or a == "-t") and i + 1 < args.len:
        try: timeoutSec = parseFloat(args[i+1])
        except CatchableError: discard
        inc i
      elif a.startsWith("--timeout="):
        try: timeoutSec = parseFloat(a[10..^1])
        except CatchableError: discard
      elif a == "--skip-tests": skipTests = true
      elif a == "--allow-no-tests": allowNoTests = true
      elif a == "--allow-test-only": allowTestOnly = true
      elif a == "--allow-no-changelog": allowNoChangelog = true
      elif a == "--allow-defeat-devices": allowDefeatDevices = true
      elif a == "--ensure-unreleased": autoEnsureUnreleased = true
      elif a == "--submit": submit = true
      elif a == "--json": jsonOut = true
      elif not a.startsWith("-") and branch.len == 0:
        branch = a
      inc i
    let (res, code) = doBraidGate(branch, baseRef, strandDir, skipTests, testCmd, allowNoTests, allowTestOnly, timeoutSec, allowNoChangelog, autoEnsureUnreleased, submit, author, allowDefeatDevices)
    if jsonOut:
      echo pretty(res)
    else:
      if code == 0:
        if submit or (res.hasKey("status") and res["status"].getStr() == "ready_for_audit"):
          echo "[GREEN] Keys 1 & 2 Passed — Strand Submitted for Key 3 Adversarial Audit!"
        else:
          echo "[GREEN] Three-Key Gate: Keys 1 & 2 Passed (Ready for Audit)!"
        echo "  Mechanical: Clean (tree: " & res{"merge_tree_sha"}.getStr("") & " in " & $res{"mechanical_gate_ms"}.getFloat() & " ms)"
        if res.hasKey("test_command"):
          echo "  Semantic  : 100% Green (" & res{"test_command"}.getStr() & " in " & $res{"test_duration_ms"}.getFloat() & " ms)"
        if res.hasKey("changelog_gate"):
          echo "  Changelog : " & res{"changelog_gate"}.getStr()
        if res.hasKey("defeat_device_gate"):
          echo "  Defeat-Dev: " & res{"defeat_device_gate"}.getStr()
        if res.hasKey("gate_token"):
          echo "  Gate Token: " & res{"gate_token"}.getStr()
        if res.hasKey("author"):
          echo "  Author    : " & res{"author"}.getStr()
      elif code == 1:
        stderr.writeLine("[CONFLICT] Key 1 Mechanical Gate Failed:")
        for c in res{"conflicts"}: stderr.writeLine("  " & c.getStr())
      elif code == 2:
        stderr.writeLine("[FAILURE] Key 2 Semantic Compiler Gate Failed:")
        stderr.writeLine(res{"compiler_output"}.getStr())
      elif code == 3:
        stderr.writeLine("[VIOLATION] Two-Point Diff Verification Failed:")
        stderr.writeLine(res{"two_point_diff_error"}.getStr())
      elif code == 4:
        stderr.writeLine(res{"forensic_envelope"}.getStr(res{"compiler_output"}.getStr()))
      elif code == 5:
        stderr.writeLine("[VIOLATION] Changelog Gate Verification Failed:")
        stderr.writeLine(res{"changelog_error"}.getStr())
      elif code == 7:
        stderr.writeLine("[VIOLATION] Defeat Device Scan Failed:")
        stderr.writeLine(res{"defeat_device_error"}.getStr())
        if res.hasKey("defeat_devices"):
          for d in res{"defeat_devices"}:
            stderr.writeLine("  " & d{"file"}.getStr() & ":" & $d{"line_number"}.getInt() & " -> " & d{"line"}.getStr())
    quit(code)

  of "submit":
    var strandDir = ""
    var author = ""
    var commitMsg = ""
    var listen = false
    var allowNoTests = false
    var allowTestOnly = false
    var allowNoChangelog = false
    var allowDefeatDevices = false
    var noNotify = false
    var timeoutSec = 0.0
    var testCmd = ""
    var jsonOut = false
    var i = 1
    while i < args.len:
      let a = args[i]
      if a == "--dir" and i + 1 < args.len:
        strandDir = args[i+1]; inc i
      elif a.startsWith("--dir="): strandDir = a[6..^1]
      elif a == "--author" and i + 1 < args.len:
        author = args[i+1]; inc i
      elif a.startsWith("--author="): author = a[9..^1]
      elif a == "--commit" and i + 1 < args.len:
        commitMsg = args[i+1]; inc i
      elif a.startsWith("--commit="): commitMsg = a[9..^1]
      elif a == "--listen" or a == "-l": listen = true
      elif a == "--test-command" and i + 1 < args.len:
        testCmd = args[i+1]; inc i
      elif a.startsWith("--test-command="): testCmd = a[15..^1]
      elif (a == "--timeout" or a == "-t") and i + 1 < args.len:
        try: timeoutSec = parseFloat(args[i+1])
        except CatchableError: discard
        inc i
      elif a.startsWith("--timeout="):
        try: timeoutSec = parseFloat(a[10..^1])
        except CatchableError: discard
      elif a == "--allow-no-tests": allowNoTests = true
      elif a == "--allow-test-only": allowTestOnly = true
      elif a == "--allow-no-changelog": allowNoChangelog = true
      elif a == "--allow-defeat-devices": allowDefeatDevices = true
      elif a == "--no-notify": noNotify = true
      elif a == "--json": jsonOut = true
      elif not a.startsWith("-") and strandDir.len == 0:
        strandDir = a
      inc i
    let (res, code) = doStrandSubmit(
      strandDirParam = strandDir,
      authorParam = author,
      testCmdParam = testCmd,
      allowNoTests = allowNoTests,
      allowTestOnly = allowTestOnly,
      allowNoChangelog = allowNoChangelog,
      timeoutSec = timeoutSec,
      allowDefeatDevices = allowDefeatDevices,
      noNotify = noNotify,
      commitMsg = commitMsg,
      listen = false
    )
    if jsonOut:
      echo pretty(res)
    else:
      if code == 0:
        echo "[SUBMITTED] Strand successfully submitted for Key 3 Adversarial Audit!"
        echo "  Task ID   : " & res{"task_id"}.getStr("")
        echo "  Author    : " & res{"author"}.getStr("")
        echo "  Gate Token: " & res{"gate_token"}.getStr("")
        echo "  Path      : " & res{"strand_path"}.getStr("")
        if res.hasKey("commit"):
          echo "  Committed : " & res{"commit"}.getStr("")
        if res.hasKey("notification") and res["notification"].hasKey("primary_mode"):
          let nm = res["notification"]
          echo "  Notified  : " & nm{"primary_mode"}.getStr("") & " (" & nm{"primary_target"}.getStr("") & ")"
      else:
        if res.hasKey("compiler_output"):
          stderr.writeLine("[FAILURE] Gate tests failed during submission:\n" & res{"compiler_output"}.getStr())
        elif res.hasKey("defeat_device_error"):
          stderr.writeLine("[VIOLATION] " & res{"defeat_device_error"}.getStr())
        elif res.hasKey("changelog_error"):
          stderr.writeLine("[VIOLATION] " & res{"changelog_error"}.getStr())
        elif res.hasKey("two_point_diff_error"):
          stderr.writeLine("[VIOLATION] " & res{"two_point_diff_error"}.getStr())
        elif res.hasKey("error"):
          stderr.writeLine("[ERROR] " & res{"error"}.getStr())
        else:
          stderr.writeLine(pretty(res))
    if code != 0:
      quit(code)

    if listen:
      let effAuthor = res{"author"}.getStr(author)
      let project = res{"project"}.getStr("vine")
      let listenCode = runRhizoListen(effAuthor, project)
      quit(listenCode)

    quit(0)

  of "audit":
    if args.len < 2:
      stderr.writeLine("Usage: vine audit <approve|reject|status> [task_id|path] [--auditor <name>] [--reason <text>] [--notes <text>] [--findings <file>] [--dir <path>] [--json]")
      quit(1)
    let subaction = args[1].toLowerAscii
    var strandDir = ""
    var auditor = ""
    var reason = ""
    var notes = ""
    var findingsFile = ""
    var noNotify = false
    var jsonOut = false
    var i = 2
    while i < args.len:
      let a = args[i]
      if a == "--dir" and i + 1 < args.len:
        strandDir = args[i+1]; inc i
      elif a.startsWith("--dir="): strandDir = a[6..^1]
      elif a == "--auditor" and i + 1 < args.len:
        auditor = args[i+1]; inc i
      elif a.startsWith("--auditor="): auditor = a[10..^1]
      elif a == "--reason" and i + 1 < args.len:
        reason = args[i+1]; inc i
      elif a.startsWith("--reason="): reason = a[9..^1]
      elif a == "--notes" and i + 1 < args.len:
        notes = args[i+1]; inc i
      elif a.startsWith("--notes="): notes = a[8..^1]
      elif a == "--findings" and i + 1 < args.len:
        findingsFile = args[i+1]; inc i
      elif a.startsWith("--findings="): findingsFile = a[11..^1]
      elif a == "--no-notify": noNotify = true
      elif a == "--json": jsonOut = true
      elif not a.startsWith("-") and strandDir.len == 0:
        strandDir = a
      inc i
    let (res, code) = doStrandAudit(subaction, strandDir, auditor, reason, findingsFile, notes, noNotify)
    if jsonOut:
      echo pretty(res)
    else:
      if code == 0:
        if subaction in ["approve", "ratify"]:
          echo "[RATIFIED] Key 3 Pre-Weave Adversarial Audit Passed!"
          echo "  Task ID    : " & res{"task_id"}.getStr("")
          echo "  Author     : " & res{"author"}.getStr("")
          echo "  Auditor    : " & res{"auditor"}.getStr("")
          echo "  Audit Token: " & res{"audit_token"}.getStr("")
          if res.hasKey("notification") and res["notification"].hasKey("primary_mode"):
            let nm = res["notification"]
            echo "  Notified   : " & nm{"primary_mode"}.getStr("") & " (" & nm{"primary_target"}.getStr("") & ")"
        elif subaction == "reject":
          echo "[REJECTED] Strand rejected during Key 3 Adversarial Audit!"
          echo "  Task ID    : " & res{"task_id"}.getStr("")
          echo "  Auditor    : " & res{"auditor"}.getStr("")
          echo "  Reason     : " & res{"rejection_reason"}.getStr("")
          if res.hasKey("notification") and res["notification"].hasKey("primary_mode"):
            let nm = res["notification"]
            echo "  Notified   : " & nm{"primary_mode"}.getStr("") & " (" & nm{"primary_target"}.getStr("") & ")"
        else: # status
          echo "Strand Audit Status:"
          echo "  Task ID     : " & res{"task_id"}.getStr("")
          echo "  Status      : " & res{"status"}.getStr("")
          echo "  Lifecycle   : " & res{"lifecycle_state"}.getStr("")
          echo "  Author      : " & res{"author"}.getStr("")
          echo "  Auditor     : " & res{"auditor"}.getStr("")
          echo "  Audit Token : " & res{"audit_token"}.getStr("")
          if res.hasKey("rejection_reason"):
            echo "  Rejection   : " & res{"rejection_reason"}.getStr("")
      else:
        if res.hasKey("error"):
          stderr.writeLine("[ERROR] " & res["error"].getStr())
        else:
          stderr.writeLine(pretty(res))
    quit(code)

  of "sync", "rebase":
    var strandDir = ""
    var baseRef = ""
    var useRebase = (cmd == "rebase")
    var i = 1
    while i < args.len:
      let a = args[i]
      if a == "--dir" and i + 1 < args.len:
        strandDir = args[i+1]; inc i
      elif a.startsWith("--dir="): strandDir = a[6..^1]
      elif a == "--base" and i + 1 < args.len:
        baseRef = args[i+1]; inc i
      elif a.startsWith("--base="): baseRef = a[7..^1]
      elif a == "--rebase": useRebase = true
      elif not a.startsWith("-") and strandDir.len == 0:
        strandDir = a
      inc i
    let (res, code) = doStrandSync(strandDir, baseRef, useRebase)
    if code != 0:
      stderr.writeLine(pretty(res))
      quit(code)
    echo pretty(res)

  of "weave", "join", "merge":
    var branch = ""
    var baseRef = ""
    var strandDir = ""
    var force = false
    var allowNoTests = false
    var allowNoChangelog = false
    var allowUnaudited = false
    var noNotify = false
    var i = 1
    while i < args.len:
      let a = args[i]
      if a == "--base" and i + 1 < args.len:
        baseRef = args[i+1]; inc i
      elif a.startsWith("--base="): baseRef = a[7..^1]
      elif a == "--dir" and i + 1 < args.len:
        strandDir = args[i+1]; inc i
      elif a.startsWith("--dir="): strandDir = a[6..^1]
      elif a == "--force": force = true
      elif a == "--allow-no-tests": allowNoTests = true
      elif a == "--allow-no-changelog": allowNoChangelog = true
      elif a in ["--allow-unaudited", "-u"]: allowUnaudited = true
      elif a == "--no-notify": noNotify = true
      elif not a.startsWith("-") and branch.len == 0:
        branch = a
      inc i
    let (res, code) = doBraidWeave(branch, baseRef, strandDir, force, allowNoTests, allowNoChangelog, allowUnaudited, noNotify)
    if code != 0:
      if res.hasKey("message"):
        stderr.writeLine("[REJECTED] " & res["message"].getStr())
      else:
        stderr.writeLine(pretty(res))
      quit(code)
    echo pretty(res)

  of "changelog", "news":
    var entry = ""
    var strandDir = ""
    var section = "Added"
    var ensureUnreleased = false
    var checkOnly = false
    var baseRef = ""
    var i = 1
    while i < args.len:
      let a = args[i]
      if a == "--ensure-unreleased": ensureUnreleased = true
      elif a == "--check": checkOnly = true
      elif (a == "--section" or a == "-s") and i + 1 < args.len:
        section = args[i+1]; inc i
      elif a.startsWith("--section="): section = a[10..^1]
      elif (a == "--dir" or a == "-d" or a == "--repo" or a == "-r") and i + 1 < args.len:
        strandDir = args[i+1]; inc i
      elif a.startsWith("--dir="): strandDir = a[6..^1]
      elif a.startsWith("--repo="): strandDir = a[7..^1]
      elif (a == "--base" or a == "-b") and i + 1 < args.len:
        baseRef = args[i+1]; inc i
      elif a.startsWith("--base="): baseRef = a[7..^1]
      elif not a.startsWith("-") and entry.len == 0:
        entry = a
      inc i
    let (msg, code) = doChangelogOperation(strandDir, entry, section, ensureUnreleased, checkOnly, baseRef)
    if code == 0:
      echo msg
    else:
      stderr.writeLine msg
    quit(code)

  of "prune", "sweep":
    var repoDir = ""
    var maxAge = 24.0
    var dryRun = true
    var i = 1
    while i < args.len:
      let a = args[i]
      if a == "--apply": dryRun = false
      elif a == "--repo" and i + 1 < args.len:
        repoDir = args[i+1]; inc i
      elif a == "--max-age" and i + 1 < args.len:
        try: maxAge = parseFloat(args[i+1])
        except ValueError: discard
        inc i
      inc i
    let res = doStrandPrune(repoDir, maxAge, dryRun)
    echo pretty(res)

  of "guide":
    if args.len < 2:
      stderr.writeLine("Usage: vine guide <install|uninstall|check> [path]")
      quit(1)
    let action = args[1].toLowerAscii
    let target = if args.len > 2: args[2] else: "AGENTS.md"
    case action
    of "install", "i", "add":
      let (ok, msg) = installGuide(target)
      if ok: echo msg else: (stderr.writeLine(msg); quit(1))
    of "uninstall", "u", "remove", "rm":
      let (ok, msg) = uninstallGuide(target)
      if ok: echo msg else: (stderr.writeLine(msg); quit(1))
    of "check", "status":
      let st = checkGuide(target)
      case st
      of gsInstalled: echo "[INSTALLED] Vine Guide is installed in: " & target
      of gsNotFound: echo "[NOT FOUND] Vine Guide not found in: " & target
      of gsMalformed: (stderr.writeLine("[MALFORMED] Unbalanced markers in: " & target); quit(1))
      of gsFileMissing: echo "[MISSING] Target file does not exist: " & target
    else:
      stderr.writeLine("Unknown guide action: " & action)
      quit(1)

  of "config":
    let sub = if args.len > 1: args[1] else: "show"
    if sub == "init":
      let target = getCurrentDir() / "vine.toml"
      if fileExists(target):
        echo "vine.toml already exists at: " & target
      else:
        writeFile(target, """# vine.toml — Vine Project Configuration
[project]
primary_branch = "main"

[strand]
# Policy when encountering a non-relocatable .venv ("prompt", "recreate", "skip")
venv_policy = "prompt"

# Vendored directories for the Rift / CoW fast-path
vendor_dirs = ["deps", "nimbledeps", "vendor", "node_modules", ".zig-cache"]

[verification]
# Command executed inside the strand during the Two-Key Gate
# test_command = "cargo test"
""")
        echo "Initialized: " & target
    else:
      let cfg = loadVineConfig()
      var j = newJObject()
      j["primary_branch"] = %cfg.primaryBranch
      j["venv_policy"] = %cfg.venvPolicy
      var vdirs = newJArray()
      for d in cfg.vendorDirs: vdirs.add(%d)
      j["vendor_dirs"] = vdirs
      j["test_command"] = %cfg.testCommand
      if cfg.activeConfigFile.len > 0:
        j["active_config"] = %cfg.activeConfigFile
      echo pretty(j)

  of "update":
    quit(doUpdateCommand(args[1..^1], Version, "vine"))

  else:
    stderr.writeLine("Unknown command: " & cmd)
    quit(1)

when isMainModule:
  main()
