# /Users/eek/Development/vine/src/vine.nim
# Vine — Sub-Second Rift Workspaces & Zero-Mirage Git Weaving Engine.

import std/[os, strutils, json, sequtils]
import strand, gate, weave, guide, config, update, notify, crypto, redis_client

const Version = "0.2.21"

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
  echo "  vine audit <approve|reject|status|set-ticket> [task_id|path] [--auditor <name>] [--ticket <hex>] [--force] [--listen] [--weave] [--reason <text>] [--notes <text>] [--findings <file>] [--dir <path>] [--no-notify] [--json]"
  echo "  vine sync [--dir <path>] [--base <ref>] [--rebase]"
  echo "  vine weave [branch] [--base <ref>] [--dir <path>] [--force] [--allow-no-tests] [--allow-no-changelog] [--allow-unaudited] [--test-command <cmd>] [--no-notify]"
  echo "  vine changelog [entry] [--dir <path>] [--section <sec>] [--ensure-unreleased] [--check]"
  echo "  vine prune [--repo <path>] [--max-age <hours>] [--apply]"
  echo "  vine update [--check] [--apply] [--skip <pkg@ver>] [--disable] [--enable] [--json]"
  echo "  vine guide <install|uninstall|check> [path]"
  echo "  vine config <init|show> [path]"
  echo ""
  echo "Global Options:"
  echo "  --version, -v    Print version"
  echo "  --help, -h       Print help"

proc hasHelpFlag*(args: seq[string]): bool =
  for a in args:
    if a == "--":
      return false
    if a in ["--help", "-h", "help"]:
      return true
  return false

proc printSubcommandHelp*(subcmd: string, args: seq[string] = @[]): bool =
  let cmd = subcmd.toLowerAscii
  case cmd
  of "new", "create", "strand":
    if args.len > 0 and args[0].toLowerAscii in ["new", "create"]:
      echo "Usage: vine strand new <task_id> [--repo <path>] [--branch <name>] [--base <ref>] [--parent <ref>] [--rift] [--worktree] [--worker <agent_id>] [--orchestrator <name>] [--created-by <name>]"
    else:
      echo "Usage: vine new <task_id> [--repo <path>] [--branch <name>] [--base <ref>] [--parent <ref>] [--rift] [--worktree] [--worker <agent_id>] [--orchestrator <name>] [--created-by <name>]"
    echo ""
    echo "Options:"
    echo "  --task, --name        Task ID identifier"
    echo "  --repo, -r <path>     Path to canonical repository"
    echo "  --branch, -b <name>   Branch name for strand"
    echo "  --base <ref>          Base Git reference (default: HEAD)"
    echo "  --parent, --from <ref> Explicit parent branch"
    echo "  --worker, --author, --agent-id <id> Unique worker agent ID (e.g. rhizo-sequoia from 'rhizo name', not a role name)"
    echo "  --orchestrator <name> Orchestrator agent name"
    echo "  --created-by <name>   Creator agent name"
    echo "  --rift                Force Rift copy-on-write cloning"
    echo "  --worktree            Force standard Git worktree creation"
    return true
  of "list", "ls":
    echo "Usage: vine list [--repo <path>] [--all]"
    echo ""
    echo "Options:"
    echo "  --repo, -r <path>     Target repository directory"
    echo "  --all, -a             Include inactive/pruned workspaces"
    echo "  --json                Output strand list as JSON"
    return true
  of "status":
    echo "Usage: vine status [task_id|path] [--task <id>] [--dir <path>] [--json]"
    echo ""
    echo "Options:"
    echo "  --task, --task-id     Target task ID"
    echo "  --dir, -d <path>      Path to strand directory"
    echo "  --json                Output status as JSON"
    return true
  of "collisions", "conflicts":
    echo "Usage: vine collisions [--repo <path>] [--json]"
    echo ""
    echo "Options:"
    echo "  --repo, -r <path>     Target repository directory"
    echo "  --json                Output collisions as JSON"
    return true
  of "gate", "check":
    echo "Usage: vine gate [task_id|branch] [--base <ref>] [--dir <path>] [--submit] [--author <agent_id>] [--timeout <sec>] [--skip-tests] [--allow-no-tests] [--allow-test-only] [--allow-no-changelog] [--allow-defeat-devices] [--allow-role-id] [--skeleton] [--ensure-unreleased] [--test-command <cmd>] [--json] [-- <command...>]"
    echo ""
    echo "Options:"
    echo "  --task, --task-id     Target task ID"
    echo "  --base, -b <ref>      Base reference to compare against (default: HEAD)"
    echo "  --dir, -d <path>      Path to strand directory"
    echo "  --submit              Submit strand for Key 3 audit upon passing Keys 1 & 2"
    echo "  --author, --agent-id <id> Unique author agent ID (e.g. rhizo-sequoia; not a role name)"
    echo "  --timeout, -t <sec>   Semantic test execution timeout"
    echo "  --skip-tests          Skip semantic test suite"
    echo "  --allow-no-tests      Allow passing gate without tests"
    echo "  --allow-test-only     Allow test-only changes"
    echo "  --allow-no-changelog  Bypass mandatory changelog update check"
    echo "  --allow-defeat-devices Bypass defeat device detection"
    echo "  --allow-role-id       Allow generic role titles as agent ID"
    echo "  --skeleton            Pre-plan contract skeleton mode (allows UNIMPLEMENTED_CONTRACT stubs)"
    echo "  --ensure-unreleased   Automatically ensure Unreleased section in changelog"
    echo "  --test-command <cmd>  Explicit command to execute tests"
    echo "  --json                Output gate results as JSON"
    return true
  of "submit":
    echo "Usage: vine submit [task_id|path] [--dir <path>] [--author <agent_id>] [--commit <msg>] [--listen] [--timeout <sec>] [--allow-no-tests] [--allow-test-only] [--allow-no-changelog] [--allow-defeat-devices] [--allow-role-id] [--skeleton] [--test-command <cmd>] [--no-notify] [--json]"
    echo ""
    echo "Options:"
    echo "  --task, --task-id     Target task ID (can be run from canonical repo root)"
    echo "  --dir, -d <path>      Path to strand directory"
    echo "  --author, --agent-id <id> Unique agent ID (e.g. rhizo-sequoia from 'rhizo name'; never a role title like implementer)"
    echo "  --commit, -m <msg>    Commit message for dirty changes"
    echo "  --listen, -l          Arm single-shot rhizo listener after submission"
    echo "  --timeout, -t <sec>   Test timeout in seconds"
    echo "  --allow-no-tests      Allow passing without test runner"
    echo "  --allow-test-only     Allow test-only changes"
    echo "  --allow-no-changelog  Bypass mandatory changelog update check"
    echo "  --allow-defeat-devices Bypass defeat device detection"
    echo "  --allow-role-id       Allow generic role titles as agent ID"
    echo "  --skeleton            Pre-plan contract skeleton mode (allows UNIMPLEMENTED_CONTRACT stubs)"
    echo "  --no-notify           Silence Redis notifications"
    echo "  --json                Output submission result as JSON"
    return true
  of "audit":
    echo "Usage: vine audit <approve|reject|inspect|status> [task_id|path] [--auditor <agent_id>] [--ticket <hex>] [--evidence <text>] [--notes <text>] [--reason <text>] [--findings <file>] [--dir <path>] [--allow-role-id] [--no-notify] [--json]"
    echo ""
    echo "Options:"
    echo "  --task, --task-id     Target task ID"
    echo "  --auditor, --agent-id <id> Unique auditor agent ID (e.g. rhizo-kestrel from 'rhizo name'; never a role title like auditor)"
    echo "  --ticket, --token <h> Delivery ticket hex from rhizo listen delivery (strictly required for approve)"
    echo "  --evidence <text>     Substantive verification evidence citing changed files and symbols (strictly required for approve)"
    echo "  --notes <text>        Approval or review notes (alias for --evidence)"
    echo "  --reason <text>       Rejection reason (strictly required for reject)"
    echo "  --allow-role-id       Allow generic role titles as auditor ID"
    echo "  --force               Bypass delivery ticket verification (reject only; banned on approve)"
    echo "  --listen, -l          Arm single-shot rhizo listener after audit completion"
    echo "  --findings <file>     Path to audit findings file"
    echo "  --dir, -d <path>      Path to strand directory"
    echo "  --no-notify           Silence Redis notifications"
    echo "  --json                Output audit result as JSON"
    echo "  Note: --weave is obsolete and rejected (Auditor Merge-Clerk Decoupling; Orchestrator runs vine weave)"
    return true
  of "sync":
    echo "Usage: vine sync [--dir <path>] [--base <ref>] [--rebase]"
    echo ""
    echo "Options:"
    echo "  --dir, -d <path>      Path to strand directory"
    echo "  --base, -b <ref>      Base reference (default: HEAD)"
    echo "  --rebase              Rebase on top of base reference"
    return true
  of "weave":
    echo "Usage: vine weave [task_id|branch] [--base <ref>] [--dir <path>] [--force] [--allow-no-tests] [--allow-no-changelog] [--allow-unaudited] [--no-notify] [--json]"
    echo ""
    echo "Options:"
    echo "  --task, --task-id     Target task ID (can be run from canonical repo root)"
    echo "  --base, -b <ref>      Target base branch (default: main/master)"
    echo "  --dir, -d <path>      Path to strand directory"
    echo "  --force, -f           Force weave even if checks fail"
    echo "  --allow-unaudited, -u Bypass Key 3 audit approval requirement"
    echo "  --allow-no-tests      Allow passing gate without tests"
    echo "  --allow-no-changelog  Bypass mandatory changelog update check"
    echo "  --no-notify           Silence Redis notifications"
    echo "  --json                Output weave result as JSON"
    return true
  of "changelog":
    echo "Usage: vine changelog [entry] [--dir <path>] [--section <sec>] [--ensure-unreleased] [--check]"
    echo ""
    echo "Options:"
    echo "  --dir, -d <path>      Path to project or strand directory"
    echo "  --repo, -r <path>     Path to project repository"
    echo "  --section, -s <sec>   Target section (e.g. Added, Fixed, Changed)"
    echo "  --base, -b <ref>      Base git reference"
    echo "  --ensure-unreleased   Ensure Unreleased header exists"
    echo "  --check               Verify changelog has entries under Unreleased"
    return true
  of "prune":
    echo "Usage: vine prune [--repo <path>] [--max-age <hours>] [--apply]"
    echo ""
    echo "Options:"
    echo "  --repo <path>         Target repository directory"
    echo "  --max-age <hours>     Maximum workspace age before pruning (default: 48)"
    echo "  --apply               Apply pruning actions (default is dry-run)"
    return true
  of "update":
    echo "Usage: vine update [--check] [--apply] [--skip <pkg@ver>] [--disable] [--enable] [--json]"
    echo ""
    echo "Options:"
    echo "  --check, -c           Force a fresh check for updates"
    echo "  --apply, -a           Install latest triad packages via npm"
    echo "  --skip <pkg@ver>      Skip notification for specific version"
    echo "  --disable, -d         Disable update notifications"
    echo "  --enable, -e          Enable update notifications"
    echo "  --json                Output status as JSON"
    return true
  of "guide":
    echo "Usage: vine guide <install|uninstall|check> [path]"
    return true
  of "config":
    echo "Usage: vine config <init|show> [path]"
    return true
  else:
    return false

proc main() =
  gBraidWeaveProc = doBraidWeave
  let args = commandLineParams()
  if args.len == 0 or args[0] in ["--help", "-h", "help"]:
    if args.len > 1 and printSubcommandHelp(args[1], args[2..^1]):
      quit(0)
    printHelp()
    quit(0)

  if args[0] in ["--version", "-v", "version"]:
    echo "vine " & Version
    quit(0)

  let cmd = args[0].toLowerAscii
  if hasHelpFlag(args[1..^1]):
    if printSubcommandHelp(cmd, args[1..^1]):
      quit(0)
    printHelp()
    quit(0)

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

    if taskId.len == 0 or taskId.startsWith("-"):
      stderr.writeLine("Error: Invalid task ID: '" & taskId & "'. Task ID cannot be empty or start with '-'.")
      stderr.writeLine("Usage: vine new <task_id> [--repo <path>] [--branch <name>] [--base <ref>] [--parent <ref>] [--rift] [--worktree] [--orchestrator <name>] [--created-by <name>]")
      quit(1)

    while i < args.len:
      let a = args[i]
      if (a in ["--repo", "-r"]) and i + 1 < args.len:
        repoDir = args[i+1]; inc i
      elif a.startsWith("--repo="): repoDir = a[7..^1]
      elif (a in ["--branch", "-b"]) and i + 1 < args.len:
        branch = args[i+1]; inc i
      elif a.startsWith("--branch="): branch = a[9..^1]
      elif a == "--base" and i + 1 < args.len:
        baseRef = args[i+1]; inc i
      elif a.startsWith("--base="): baseRef = a[7..^1]
      elif (a in ["--parent", "--from"]) and i + 1 < args.len:
        parentBranch = args[i+1]; inc i
      elif a.startsWith("--parent="): parentBranch = a[9..^1]
      elif a.startsWith("--from="): parentBranch = a[7..^1]
      elif (a in ["--worker", "--author", "--agent", "--agent-id", "--id"]) and i + 1 < args.len:
        workerName = args[i+1]; inc i
      elif a.startsWith("--worker="): workerName = a[9..^1]
      elif a.startsWith("--author="): workerName = a[9..^1]
      elif a.startsWith("--agent="): workerName = a[8..^1]
      elif a.startsWith("--agent-id="): workerName = a[11..^1]
      elif a.startsWith("--id="): workerName = a[5..^1]
      elif a == "--orchestrator" and i + 1 < args.len:
        orchName = args[i+1]; inc i
      elif a.startsWith("--orchestrator="): orchName = a[15..^1]
      elif (a in ["--created-by"]) and i + 1 < args.len:
        createdBy = args[i+1]; inc i
      elif a.startsWith("--created-by="): createdBy = a[13..^1]
      elif (a in ["--task", "--task-id", "--name"]) and i + 1 < args.len:
        taskId = args[i+1]; inc i
      elif a.startsWith("--task="): taskId = a[7..^1]
      elif a.startsWith("--task-id="): taskId = a[10..^1]
      elif a.startsWith("--name="): taskId = a[7..^1]
      elif a == "--rift": forceRift = true
      elif a == "--worktree": forceWorktree = true
      elif a.startsWith("-"):
        stderr.writeLine("Error: Unknown option " & a & " for vine new")
        stderr.writeLine("Valid options: --task (--task-id, --name), --repo (-r), --branch (-b), --base, --parent (--from), --worker (--author, --agent, --agent-id, --id), --orchestrator, --created-by, --rift, --worktree")
        quit(2)
      inc i
    let (res, code) = doStrandNew(taskId, repoDir, branch, baseRef, forceRift, forceWorktree, parentBranch, workerName, orchName, createdBy)
    if code != 0:
      stderr.writeLine(pretty(res))
      quit(code)
    echo pretty(res)

  of "list", "ls":
    var repoDir = ""
    var includeAll = false
    var jsonOut = false
    var i = 1
    while i < args.len:
      let a = args[i]
      if a in ["--all", "-a"]: includeAll = true
      elif (a in ["--repo", "-r"]) and i + 1 < args.len:
        repoDir = args[i+1]; inc i
      elif a.startsWith("--repo="): repoDir = a[7..^1]
      elif a == "--json": jsonOut = true
      elif a.startsWith("-"):
        stderr.writeLine("Error: Unknown option " & a & " for vine list")
        stderr.writeLine("Valid options: --all (-a), --repo (-r), --json")
        quit(2)
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
      elif (a in ["--dir", "-d"]) and i + 1 < args.len:
        strandIdent = args[i+1]; inc i
      elif a.startsWith("--dir="): strandIdent = a[6..^1]
      elif (a in ["--task", "--task-id", "--strand"]) and i + 1 < args.len:
        strandIdent = args[i+1]; inc i
      elif a.startsWith("--task="): strandIdent = a[7..^1]
      elif a.startsWith("--task-id="): strandIdent = a[10..^1]
      elif a.startsWith("--strand="): strandIdent = a[9..^1]
      elif not a.startsWith("-") and strandIdent.len == 0:
        strandIdent = a
      elif a.startsWith("-"):
        stderr.writeLine("Error: Unknown option " & a & " for vine status")
        stderr.writeLine("Valid options: --task, --task-id, --strand, --dir (-d), --json")
        quit(2)
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
      elif (a in ["--repo", "-r"]) and i + 1 < args.len:
        repoDir = args[i+1]; inc i
      elif a.startsWith("--repo="): repoDir = a[7..^1]
      elif a.startsWith("-"):
        stderr.writeLine("Error: Unknown option " & a & " for vine collisions")
        stderr.writeLine("Valid options: --repo (-r), --json")
        quit(2)
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
    var target = ""
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
    var isSkeleton = false
    var allowRoleId = false
    var i = 1
    while i < args.len:
      let a = args[i]
      if a == "--":
        if i + 1 < args.len:
          testCmd = args[i+1..^1].map(quoteShell).join(" ")
        break
      elif (a in ["--base", "-b"]) and i + 1 < args.len:
        baseRef = args[i+1]; inc i
      elif a.startsWith("--base="): baseRef = a[7..^1]
      elif (a in ["--dir", "-d"]) and i + 1 < args.len:
        strandDir = args[i+1]; inc i
      elif a.startsWith("--dir="): strandDir = a[6..^1]
      elif (a in ["--task", "--task-id", "--strand"]) and i + 1 < args.len:
        target = args[i+1]; inc i
      elif a.startsWith("--task="): target = a[7..^1]
      elif a.startsWith("--task-id="): target = a[10..^1]
      elif a.startsWith("--strand="): target = a[9..^1]
      elif a == "--test-command" and i + 1 < args.len:
        testCmd = args[i+1]; inc i
      elif a.startsWith("--test-command="): testCmd = a[15..^1]
      elif (a in ["--author", "--agent", "--worker", "--agent-id", "--id"]) and i + 1 < args.len:
        author = args[i+1]; inc i
      elif a.startsWith("--author="): author = a[9..^1]
      elif a.startsWith("--agent="): author = a[8..^1]
      elif a.startsWith("--worker="): author = a[9..^1]
      elif a.startsWith("--agent-id="): author = a[11..^1]
      elif a.startsWith("--id="): author = a[5..^1]
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
      elif a == "--allow-role-id": allowRoleId = true
      elif a == "--ensure-unreleased": autoEnsureUnreleased = true
      elif a == "--skeleton": isSkeleton = true
      elif a == "--submit": submit = true
      elif a == "--json": jsonOut = true
      elif not a.startsWith("-") and target.len == 0:
        target = a
      elif a.startsWith("-"):
        stderr.writeLine("Error: Unknown option " & a & " for vine gate")
        stderr.writeLine("Valid options: --task, --task-id, --strand, --base (-b), --dir (-d), --test-command, --author (--agent, --worker, --agent-id, --id), --timeout (-t), --skip-tests, --allow-no-tests, --allow-test-only, --allow-no-changelog, --allow-defeat-devices, --allow-role-id, --ensure-unreleased, --skeleton, --submit, --json")
        quit(2)
      inc i
    let effectiveTarget = if target.len > 0: target else: branch
    let (res, code) = doBraidGate(effectiveTarget, baseRef, strandDir, skipTests, testCmd, allowNoTests, allowTestOnly, timeoutSec, allowNoChangelog, autoEnsureUnreleased, submit, author, allowDefeatDevices, isSkeleton = isSkeleton, allowRoleId = allowRoleId)
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
        if res.hasKey("is_skeleton") and res["is_skeleton"].getBool(false):
          echo "  Skeleton  : Contract Skeleton Mode (UNIMPLEMENTED_CONTRACT allowed)"
        if res.hasKey("changelog_gate"):
          echo "  Changelog : " & res{"changelog_gate"}.getStr()
        if res.hasKey("defeat_device_gate"):
          echo "  Defeat-Dev: " & res{"defeat_device_gate"}.getStr()
        if res.hasKey("gate_token"):
          echo "  Gate Token: " & res{"gate_token"}.getStr()
        if res.hasKey("author"):
          echo "  Author    : " & res{"author"}.getStr()
      elif code == 1:
        if res.hasKey("error"):
          let errMsg = res["error"].getStr()
          if errMsg.startsWith("Error:") or errMsg.startsWith("["):
            stderr.writeLine(errMsg)
          else:
            stderr.writeLine("[ERROR] " & errMsg)
        elif res.hasKey("conflicts"):
          stderr.writeLine("[CONFLICT] Key 1 Mechanical Gate Failed:")
          for c in res{"conflicts"}: stderr.writeLine("  " & c.getStr())
        else:
          stderr.writeLine(pretty(res))
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
    var target = ""
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
    var allowRoleId = false
    var isSkeleton = false
    var jsonOut = false
    var i = 1
    while i < args.len:
      let a = args[i]
      if a == "--":
        if i + 1 < args.len:
          testCmd = args[i+1..^1].map(quoteShell).join(" ")
        break
      elif (a in ["--dir", "-d"]) and i + 1 < args.len:
        strandDir = args[i+1]; inc i
      elif a.startsWith("--dir="): strandDir = a[6..^1]
      elif (a in ["--task", "--task-id", "--strand"]) and i + 1 < args.len:
        target = args[i+1]; inc i
      elif a.startsWith("--task="): target = a[7..^1]
      elif a.startsWith("--task-id="): target = a[10..^1]
      elif a.startsWith("--strand="): target = a[9..^1]
      elif (a in ["--author", "--agent", "--worker", "--agent-id", "--id"]) and i + 1 < args.len:
        author = args[i+1]; inc i
      elif a.startsWith("--author="): author = a[9..^1]
      elif a.startsWith("--agent="): author = a[8..^1]
      elif a.startsWith("--worker="): author = a[9..^1]
      elif a.startsWith("--agent-id="): author = a[11..^1]
      elif a.startsWith("--id="): author = a[5..^1]
      elif (a in ["--commit", "--message", "-m"]) and i + 1 < args.len:
        commitMsg = args[i+1]; inc i
      elif a.startsWith("--commit="): commitMsg = a[9..^1]
      elif a.startsWith("--message="): commitMsg = a[10..^1]
      elif a in ["--listen", "-l"]: listen = true
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
      elif a == "--allow-role-id": allowRoleId = true
      elif a == "--skeleton": isSkeleton = true
      elif a == "--no-notify": noNotify = true
      elif a == "--json": jsonOut = true
      elif not a.startsWith("-") and target.len == 0:
        target = a
      elif a.startsWith("-"):
        stderr.writeLine("Error: Unknown option " & a & " for vine submit")
        stderr.writeLine("Valid options: --task, --task-id, --strand, --author (--agent, --worker, --agent-id, --id), --commit (-m, --message), --dir (-d), --test-command, --timeout (-t), --listen (-l), --allow-no-tests, --allow-test-only, --allow-no-changelog, --allow-defeat-devices, --allow-role-id, --skeleton, --no-notify, --json")
        quit(2)
      inc i
    let effectiveTarget = if target.len > 0: target else: strandDir
    let (res, code) = doStrandSubmit(
      strandDirParam = effectiveTarget,
      authorParam = author,
      testCmdParam = testCmd,
      allowNoTests = allowNoTests,
      allowTestOnly = allowTestOnly,
      allowNoChangelog = allowNoChangelog,
      timeoutSec = timeoutSec,
      allowDefeatDevices = allowDefeatDevices,
      noNotify = noNotify,
      commitMsg = commitMsg,
      listen = false,
      isSkeleton = isSkeleton,
      allowRoleId = allowRoleId
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
        if res.hasKey("is_skeleton") and res["is_skeleton"].getBool(false):
          echo "  Skeleton  : Contract Skeleton Mode (UNIMPLEMENTED_CONTRACT allowed)"
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
          let errMsg = res{"error"}.getStr()
          if errMsg.startsWith("Error:") or errMsg.startsWith("["):
            stderr.writeLine(errMsg)
          else:
            stderr.writeLine("[ERROR] " & errMsg)
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
      stderr.writeLine("Usage: vine audit <approve|reject|inspect|status|set-ticket> [task_id|path] [--auditor <name>] [--ticket <hex>] [--force] [--listen] [--evidence <text>] [--reason <text>] [--notes <text>] [--findings <file>] [--dir <path>] [--json]")
      quit(1)
    let subaction = args[1].toLowerAscii
    if subaction == "set-ticket":
      if args.len < 4:
        stderr.writeLine("Usage: vine audit set-ticket <task_id|path> <ticket_hex> [--auditor <name>]")
        quit(1)
      let target = args[2]
      let rawTicket = args[3].strip()
      var auditor = ""
      var i = 4
      while i < args.len:
        let a = args[i]
        if (a in ["--auditor", "--agent", "--agent-id", "--id"]) and i + 1 < args.len:
          auditor = args[i+1]; inc i
        elif a.startsWith("--auditor="): auditor = a[10..^1]
        elif a.startsWith("--agent="): auditor = a[8..^1]
        elif a.startsWith("--agent-id="): auditor = a[11..^1]
        elif a.startsWith("--id="): auditor = a[5..^1]
        inc i
      var strand = findStrandManifest(target)
      let tid = if strand != nil: strand.getOrDefault("id").getStr(strand.getOrDefault("task_id").getStr(target)) else: target
      let ticketHash = if rawTicket.len == 64: rawTicket.toLowerAscii else: sha256(rawTicket.toLowerAscii)
      let sRes = setAuditTicketRedis(tid, ticketHash, auditor)
      echo pretty(sRes)
      quit(0)

    var strandDir = ""
    var target = ""
    var auditor = ""
    var reason = ""
    var notes = ""
    var evidence = ""
    var findingsFile = ""
    var ticket = ""
    var force = false
    var listen = false
    var weave = false
    var noNotify = false
    var allowRoleId = false
    var jsonOut = false
    var i = 2
    while i < args.len:
      let a = args[i]
      if (a in ["--dir", "-d"]) and i + 1 < args.len:
        strandDir = args[i+1]; inc i
      elif a.startsWith("--dir="): strandDir = a[6..^1]
      elif (a in ["--task", "--task-id", "--strand"]) and i + 1 < args.len:
        target = args[i+1]; inc i
      elif a.startsWith("--task="): target = a[7..^1]
      elif a.startsWith("--task-id="): target = a[10..^1]
      elif a.startsWith("--strand="): target = a[9..^1]
      elif (a in ["--auditor", "--agent", "--agent-id", "--id"]) and i + 1 < args.len:
        auditor = args[i+1]; inc i
      elif a.startsWith("--auditor="): auditor = a[10..^1]
      elif a.startsWith("--agent="): auditor = a[8..^1]
      elif a.startsWith("--agent-id="): auditor = a[11..^1]
      elif a.startsWith("--id="): auditor = a[5..^1]
      elif (a in ["--ticket", "--token"]) and i + 1 < args.len:
        ticket = args[i+1]; inc i
      elif a.startsWith("--ticket="): ticket = a[9..^1]
      elif a.startsWith("--token="): ticket = a[8..^1]
      elif a in ["--force", "-f"]: force = true
      elif a in ["--listen", "-l"]: listen = true
      elif a == "--allow-role-id": allowRoleId = true
      elif a == "--weave":
        if subaction in ["approve", "ratify"]:
          stderr.writeLine("Error: --weave is no longer supported on vine audit approve (Auditor Merge-Clerk Decoupling). Auditors only ratify Key 3; the Lead Orchestrator executes vine weave.")
          quit(2)
        weave = true
      elif (a in ["--reason", "--findings"]) and i + 1 < args.len:
        reason = args[i+1]; inc i
      elif a.startsWith("--reason="): reason = a[9..^1]
      elif a.startsWith("--findings="): reason = a[11..^1]
      elif (a in ["--evidence", "--notes"]) and i + 1 < args.len:
        evidence = args[i+1]; inc i
      elif a.startsWith("--evidence="): evidence = a[11..^1]
      elif a.startsWith("--notes="): evidence = a[8..^1]
      elif a == "--no-notify": noNotify = true
      elif a == "--json": jsonOut = true
      elif not a.startsWith("-"):
        if target.len == 0 and strandDir.len == 0:
          target = a
        elif subaction == "reject" and reason.len == 0:
          reason = a
        elif subaction in ["approve", "ratify"] and evidence.len == 0:
          evidence = a
        else:
          stderr.writeLine("Error: Unexpected argument '" & a & "' for vine audit " & subaction)
          quit(2)
      elif a.startsWith("-"):
        stderr.writeLine("Error: Unknown option " & a & " for vine audit " & subaction)
        if subaction in ["approve", "ratify"]:
          stderr.writeLine("Valid options: --task, --task-id, --strand, --auditor (--agent, --agent-id, --id), --ticket (--token), --evidence (--notes), --dir (-d), --listen (-l), --allow-role-id, --force (-f), --json")
        elif subaction == "reject":
          stderr.writeLine("Valid options: --task, --task-id, --strand, --auditor (--agent, --agent-id, --id), --ticket (--token), --reason (--notes, --findings), --dir (-d), --listen (-l), --allow-role-id, --force (-f), --json")
        else:
          stderr.writeLine("Valid options: --task, --task-id, --strand, --dir (-d), --json")
        quit(2)
      inc i

    let effectiveTarget = if target.len > 0: target else: strandDir
    let (res, code) = doStrandAudit(
      action = subaction,
      strandDirParam = effectiveTarget,
      auditorParam = auditor,
      reasonParam = reason,
      findingsFileParam = findingsFile,
      notesParam = notes,
      evidenceParam = evidence,
      noNotify = noNotify,
      ticketParam = ticket,
      forceParam = force,
      weaveParam = weave,
      listenParam = false,
      allowRoleId = allowRoleId
    )
    if jsonOut:
      echo pretty(res)
    else:
      if code == 0:
        if subaction == "inspect":
          let diffText = res.getOrDefault("diff").getStr("")
          if diffText.strip().len > 0:
            echo diffText
          else:
            echo "(no diff against base)"
          echo "================================================================================"
          echo "[INSPECTED] Strand diff inspected for Key 3 Adversarial Audit!"
          echo "  Task ID           : " & res{"task_id"}.getStr("")
          echo "  Inspected Tree SHA: " & res{"inspected_tree_sha"}.getStr("")
          echo "  Base Reference    : " & res{"base_ref"}.getStr("")
          echo "  Stamped in Redis  : Yes (ready for 'vine audit approve')"
          echo "================================================================================"
        elif subaction in ["approve", "ratify"]:
          if res.getOrDefault("status").getStr("") in ["already_ratified", "already_woven"]:
            echo res.getOrDefault("message").getStr("")
          else:
            echo "[RATIFIED] Key 3 Pre-Weave Adversarial Audit Passed!"
            echo "  Task ID    : " & res{"task_id"}.getStr("")
            echo "  Author     : " & res{"author"}.getStr("")
            echo "  Auditor    : " & res{"auditor"}.getStr("")
            echo "  Audit Token: " & res{"audit_token"}.getStr("")
            if res.hasKey("weave"):
              echo "  Trunk Weave: PASS (woven into trunk)"
            if res.hasKey("notification") and res["notification"].hasKey("primary_mode"):
              let nm = res["notification"]
              echo "  Notified   : " & nm{"primary_mode"}.getStr("") & " (" & nm{"primary_target"}.getStr("") & ")"
        elif subaction == "reject":
          if res.getOrDefault("status").getStr("") in ["already_ratified", "already_woven"]:
            echo res.getOrDefault("message").getStr("")
          else:
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
          let errMsg = res["error"].getStr()
          if errMsg.startsWith("Error:") or errMsg.startsWith("["):
            stderr.writeLine(errMsg)
          else:
            stderr.writeLine("[ERROR] " & errMsg)
        else:
          stderr.writeLine(pretty(res))
    if code != 0:
      quit(code)

    if listen:
      let effAuditor = res{"auditor"}.getStr(auditor)
      let project = res{"project"}.getStr("vine")
      let listenCode = runRhizoListen(effAuditor, project)
      quit(listenCode)

    quit(0)

  of "sync", "rebase":
    var strandDir = ""
    var target = ""
    var baseRef = ""
    var useRebase = (cmd == "rebase")
    var i = 1
    while i < args.len:
      let a = args[i]
      if (a in ["--dir", "-d"]) and i + 1 < args.len:
        strandDir = args[i+1]; inc i
      elif a.startsWith("--dir="): strandDir = a[6..^1]
      elif (a in ["--task", "--task-id", "--strand"]) and i + 1 < args.len:
        target = args[i+1]; inc i
      elif a.startsWith("--task="): target = a[7..^1]
      elif a.startsWith("--task-id="): target = a[10..^1]
      elif a.startsWith("--strand="): target = a[9..^1]
      elif (a in ["--base", "-b"]) and i + 1 < args.len:
        baseRef = args[i+1]; inc i
      elif a.startsWith("--base="): baseRef = a[7..^1]
      elif a == "--rebase": useRebase = true
      elif not a.startsWith("-") and target.len == 0 and strandDir.len == 0:
        target = a
      elif a.startsWith("-"):
        stderr.writeLine("Error: Unknown option " & a & " for vine " & cmd)
        stderr.writeLine("Valid options: --task, --task-id, --strand, --base (-b), --dir (-d), --rebase")
        quit(2)
      inc i
    let effectiveTarget = if target.len > 0: target else: strandDir
    let (res, code) = doStrandSync(effectiveTarget, baseRef, useRebase)
    if code != 0:
      stderr.writeLine(pretty(res))
      quit(code)
    echo pretty(res)

  of "weave", "join", "merge":
    var branch = ""
    var target = ""
    var baseRef = ""
    var strandDir = ""
    var force = false
    var allowNoTests = false
    var allowNoChangelog = false
    var allowUnaudited = false
    var testCmd = ""
    var noNotify = false
    var jsonOut = false
    var i = 1
    while i < args.len:
      let a = args[i]
      if (a in ["--base", "-b"]) and i + 1 < args.len:
        baseRef = args[i+1]; inc i
      elif a.startsWith("--base="): baseRef = a[7..^1]
      elif (a in ["--dir", "-d"]) and i + 1 < args.len:
        strandDir = args[i+1]; inc i
      elif a.startsWith("--dir="): strandDir = a[6..^1]
      elif (a in ["--task", "--task-id", "--strand"]) and i + 1 < args.len:
        target = args[i+1]; inc i
      elif a.startsWith("--task="): target = a[7..^1]
      elif a.startsWith("--task-id="): target = a[10..^1]
      elif a.startsWith("--strand="): target = a[9..^1]
      elif a in ["--force", "-f"]: force = true
      elif a == "--allow-no-tests": allowNoTests = true
      elif a == "--allow-no-changelog": allowNoChangelog = true
      elif a in ["--allow-unaudited", "-u"]: allowUnaudited = true
      elif a == "--test-command" and i + 1 < args.len:
        testCmd = args[i+1]; inc i
      elif a.startsWith("--test-command="): testCmd = a[15..^1]
      elif a == "--no-notify": noNotify = true
      elif a == "--json": jsonOut = true
      elif not a.startsWith("-") and target.len == 0 and branch.len == 0:
        target = a
      elif a.startsWith("-"):
        stderr.writeLine("Error: Unknown option " & a & " for vine weave")
        stderr.writeLine("Valid options: --task, --task-id, --strand, --base (-b), --dir (-d), --force (-f), --allow-unaudited (-u), --allow-no-tests, --allow-no-changelog, --test-command, --no-notify, --json")
        quit(2)
      inc i
    let effectiveTarget = if target.len > 0: target else: (if branch.len > 0: branch else: strandDir)
    let (res, code) = doBraidWeave(effectiveTarget, baseRef, strandDir, force, allowNoTests, allowNoChangelog, allowUnaudited, noNotify, testCmd)
    if code != 0:
      if res.hasKey("error"):
        let errMsg = res["error"].getStr()
        if errMsg.startsWith("Error:") or errMsg.startsWith("["):
          stderr.writeLine(errMsg)
        else:
          stderr.writeLine("[REJECTED] " & errMsg)
      elif res.hasKey("message"):
        let msg = res["message"].getStr()
        if msg.startsWith("Error:") or msg.startsWith("["):
          stderr.writeLine(msg)
        else:
          stderr.writeLine("[REJECTED] " & msg)
      else:
        stderr.writeLine(pretty(res))
      quit(code)
    if jsonOut:
      echo pretty(res)
    else:
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
      elif (a in ["--section", "-s"]) and i + 1 < args.len:
        section = args[i+1]; inc i
      elif a.startsWith("--section="): section = a[10..^1]
      elif (a in ["--dir", "-d", "--repo", "-r"]) and i + 1 < args.len:
        strandDir = args[i+1]; inc i
      elif a.startsWith("--dir="): strandDir = a[6..^1]
      elif a.startsWith("--repo="): strandDir = a[7..^1]
      elif (a in ["--base", "-b"]) and i + 1 < args.len:
        baseRef = args[i+1]; inc i
      elif a.startsWith("--base="): baseRef = a[7..^1]
      elif not a.startsWith("-") and entry.len == 0:
        entry = a
      elif a.startsWith("-"):
        stderr.writeLine("Error: Unknown option " & a & " for vine changelog")
        stderr.writeLine("Valid options: --section (-s), --dir (-d), --repo (-r), --base (-b), --ensure-unreleased, --check")
        quit(2)
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
      elif (a in ["--repo", "-r"]) and i + 1 < args.len:
        repoDir = args[i+1]; inc i
      elif a.startsWith("--repo="): repoDir = a[7..^1]
      elif a == "--max-age" and i + 1 < args.len:
        try: maxAge = parseFloat(args[i+1])
        except ValueError: discard
        inc i
      elif a.startsWith("--max-age="):
        try: maxAge = parseFloat(a[10..^1])
        except ValueError: discard
      elif a.startsWith("-"):
        stderr.writeLine("Error: Unknown option " & a & " for vine prune")
        stderr.writeLine("Valid options: --repo (-r), --max-age, --apply")
        quit(2)
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
