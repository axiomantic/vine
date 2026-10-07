# /Users/eek/Development/vine/src/strand.nim
# Strand (workspace) provisioning, listing, and lifecycle management for Braid.

import std/[os, osproc, strutils, json, times, tables, sets, algorithm]
import config

type
  StrandManifest* = object
    taskId*: string
    project*: string
    strandPath*: string
    branch*: string
    baseBranch*: string
    baseCommit*: string
    status*: string
    createdAt*: string
    tool*: string

proc getRepoRoot*(path: string = getCurrentDir()): string =
  var cur = path
  while cur.len > 0 and cur != "/":
    if dirExists(cur / ".git") or fileExists(cur / ".git"):
      return cur
    let parent = cur.parentDir()
    if parent == cur: break
    cur = parent
  return path

proc hasSubmodules*(repoDir: string): bool =
  let gitmodules = repoDir / ".gitmodules"
  if not fileExists(gitmodules): return false
  let (outp, code) = execCmdEx("git -C " & quoteShell(repoDir) & " submodule status")
  return code == 0 and outp.strip().len > 0

proc isSubmodulesUninitialized*(repoDir: string): bool =
  let (outp, code) = execCmdEx("git -C " & quoteShell(repoDir) & " submodule status")
  if code != 0: return false
  for line in outp.splitLines():
    if line.strip().startsWith("-"): return true
  return false

proc getHeadCommit*(repoDir: string): string =
  let (outp, code) = execCmdEx("git -C " & quoteShell(repoDir) & " rev-parse HEAD")
  if code == 0: return outp.strip()
  return ""

proc isVenvRelocatable*(venvDir: string): bool =
  let cfg = venvDir / "pyvenv.cfg"
  if not fileExists(cfg): return false
  for line in readFile(cfg).splitLines():
    let s = line.strip().toLowerAscii
    if s.startsWith("relocatable") and s.contains("true"):
      return true
  return false

proc doStrandNew*(
  taskId: string,
  repoDirParam: string = "",
  branchParam: string = "",
  baseRef: string = "HEAD",
  forceRift: bool = false,
  forceWorktree: bool = false,
  parentBranch: string = ""
): tuple[manifest: JsonNode, exitCode: int] =
  let repoDir = if repoDirParam.len > 0: repoDirParam.normalizedPath else: getRepoRoot()
  let projectName = repoDir.splitPath.tail
  let cfg = loadVineConfig(repoDir / "vine.toml")

  let branch = if branchParam.len > 0: branchParam else: "strand/" & taskId
  let effectiveParent = if parentBranch.len > 0: parentBranch
                        elif baseRef != "HEAD": baseRef
                        else: cfg.primaryBranch
  let baseBranch = effectiveParent

  let workspacesBase = getWorkspacesBaseDir() / projectName / taskId
  let strandDir = workspacesBase / projectName

  if dirExists(strandDir):
    var errObj = newJObject()
    errObj["status"] = %"error"
    errObj["message"] = %("Strand directory already exists at: " & strandDir)
    return (errObj, 1)

  createDir(workspacesBase)

  # Check uninitialized submodules
  if hasSubmodules(repoDir) and isSubmodulesUninitialized(repoDir):
    stderr.writeLine("WARNING: Canonical repository has uninitialized submodules. Initializing first...")
    discard execCmdEx("git -C " & quoteShell(repoDir) & " submodule update --init --recursive")

  # Decision: Rift vs Git Worktree
  let useRift = if forceWorktree: false elif forceRift: true else: hasSubmodules(repoDir)
  var toolUsed = "git-worktree"

  if useRift:
    toolUsed = "rift"
    let riftCmd = "rift create --into " & quoteShell(workspacesBase) & " --name " & quoteShell(projectName)
    let (rout, rcode) = execCmdEx(riftCmd)
    if rcode != 0:
      var errObj = newJObject()
      errObj["status"] = %"error"
      errObj["message"] = %("Rift creation failed: " & rout)
      return (errObj, rcode)
    # Check out branch inside rift clone
    discard execCmdEx("git -C " & quoteShell(strandDir) & " checkout -q -b " & quoteShell(branch) & " " & quoteShell(effectiveParent))
  else:
    toolUsed = "git-worktree"
    let wtBase = effectiveParent
    let wtCmd = "git -C " & quoteShell(repoDir) & " worktree add " & quoteShell(strandDir) & " -b " & quoteShell(branch) & " " & quoteShell(wtBase)
    let (wout, wcode) = execCmdEx(wtCmd)
    if wcode != 0:
      var errObj = newJObject()
      errObj["status"] = %"error"
      errObj["message"] = %("git worktree add failed: " & wout)
      return (errObj, wcode)

  # Stat Cache Warmup
  discard execCmdEx("git -C " & quoteShell(strandDir) & " update-index --refresh")

  # APFS CoW Vendoring Fast-Path
  for vdir in cfg.vendorDirs:
    let srcV = repoDir / vdir
    let dstV = strandDir / vdir
    if dirExists(srcV) and not dirExists(dstV):
      try:
        when defined(macosx):
          discard execCmdEx("cp -c -R " & quoteShell(srcV) & " " & quoteShell(dstV))
        else:
          discard execCmdEx("cp -a --reflink=auto " & quoteShell(srcV) & " " & quoteShell(dstV))
      except CatchableError:
        discard

  # Python Virtual Environment Policy
  let parentVenv = repoDir / ".venv"
  let strandVenv = strandDir / ".venv"
  if dirExists(parentVenv) and not dirExists(strandVenv):
    if isVenvRelocatable(parentVenv):
      try:
        when defined(macosx):
          discard execCmdEx("cp -c -R " & quoteShell(parentVenv) & " " & quoteShell(strandVenv))
        else:
          discard execCmdEx("cp -a --reflink=auto " & quoteShell(parentVenv) & " " & quoteShell(strandVenv))
      except CatchableError:
        discard
    elif cfg.venvPolicy == "recreate":
      if findExe("uv").len > 0:
        try:
          discard execCmdEx("UV_VENV_RELOCATABLE=1 uv venv " & quoteShell(strandVenv))
        except CatchableError:
          discard

  # Non-Destructive .envrc Setup
  let envrcPath = strandDir / ".envrc"
  var envrcLines: seq[string] = @[]
  if fileExists(repoDir / ".envrc"):
    envrcLines.add("[ -f " & quoteShell(repoDir / ".envrc") & " ] && source_env " & quoteShell(repoDir / ".envrc"))
  envrcLines.add("export PROJECT_ROOT=\"$(git rev-parse --show-toplevel 2>/dev/null || pwd)\"")
  envrcLines.add("export CACHE_ROOT=\"${XDG_CACHE_HOME:-$HOME/.cache}/dev-workspaces/$(basename \"$PROJECT_ROOT\")\"")
  envrcLines.add("mkdir -p \"$CACHE_ROOT\"")
  envrcLines.add("if command -v ccache >/dev/null 2>&1; then")
  envrcLines.add("    export CCACHE_BASEDIR=\"$(dirname \"$PROJECT_ROOT\")\"")
  envrcLines.add("    export CCACHE_NOHASHDIR=1")
  envrcLines.add("fi")
  envrcLines.add("[ -f \"$PROJECT_ROOT/Cargo.toml\" ] && export CARGO_TARGET_DIR=\"$CACHE_ROOT/cargo-target\"")
  envrcLines.add("export UV_LINK_MODE=\"clone\"")
  envrcLines.add("export NIMCACHE=\"$CACHE_ROOT/nimcache\"")
  writeFile(envrcPath, envrcLines.join("\n") & "\n")
  if findExe("direnv").len > 0:
    try:
      discard execCmdEx("direnv allow " & quoteShell(strandDir))
    except CatchableError:
      discard

  # Initialize .vine.json Manifest
  let (bcOut, bcCode) = execCmdEx("git -C " & quoteShell(repoDir) & " rev-parse " & quoteShell(baseBranch))
  let baseCommit = if bcCode == 0 and bcOut.strip().len > 0: bcOut.strip() else: getHeadCommit(repoDir)
  let (mbOut, mbCode) = execCmdEx("git -C " & quoteShell(repoDir) & " merge-base " & quoteShell(baseBranch) & " " & quoteShell(cfg.primaryBranch))
  let intendedMergeBase = if mbCode == 0 and mbOut.strip().len > 0: mbOut.strip() else: baseCommit
  let manifest = %*{
    "task_id": taskId,
    "project": projectName,
    "canonical_repo": repoDir,
    "strand_path": strandDir,
    "branch": branch,
    "base_branch": baseBranch,
    "parent_branch": baseBranch,
    "base_commit": baseCommit,
    "intended_merge_base": intendedMergeBase,
    "status": "PROVISIONED",
    "lifecycle_state": "PROVISIONED",
    "created_at": now().utc().format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
    "tool": toolUsed
  }
  writeFile(strandDir / ".vine.json", pretty(manifest))
  
  var res = newJObject()
  res["status"] = %"created"
  res["task_id"] = %taskId
  res["project"] = %projectName
  res["strand_path"] = %strandDir
  res["branch"] = %branch
  res["parent_branch"] = %baseBranch
  res["base_branch"] = %baseBranch
  res["base_commit"] = %baseCommit
  res["intended_merge_base"] = %intendedMergeBase
  res["tool"] = %toolUsed
  return (res, 0)

proc doStrandList*(repoDirParam: string = "", includeAll: bool = false): JsonNode =
  let repoDir = if repoDirParam.len > 0: repoDirParam.normalizedPath else: getRepoRoot()
  let projectName = repoDir.splitPath.tail
  let workspacesBase = getWorkspacesBaseDir()

  var strands = newJArray()

  if dirExists(workspacesBase):
    for kind, projectDir in walkDir(workspacesBase):
      if kind == pcDir:
        let curProj = projectDir.splitPath.tail
        if not includeAll and curProj != projectName: continue
        for subKind, taskDir in walkDir(projectDir):
          if subKind == pcDir:
            for itemKind, leafDir in walkDir(taskDir):
              if itemKind == pcDir:
                let manifestPath = leafDir / ".vine.json"
                if fileExists(manifestPath):
                  try:
                    let j = parseJson(readFile(manifestPath))
                    strands.add(j)
                  except CatchableError: discard

  var res = newJObject()
  res["project"] = %projectName
  res["count"] = %(strands.len)
  res["strands"] = strands
  return res

proc doStrandPrune*(repoDirParam: string = "", maxAgeHours: float = 24.0, dryRun: bool = true): JsonNode =
  let listData = doStrandList(repoDirParam, includeAll = false)
  var pruned = newJArray()
  let nowEpoch = getTime().toUnix().float

  for item in listData["strands"]:
    let path = item{"strand_path"}.getStr("")
    let status = item{"status"}.getStr("")
    let createdAt = item{"created_at"}.getStr("")
    let canonRepo = item{"canonical_repo"}.getStr("")
    var ageHours = 0.0

    try:
      let dt = parse(createdAt, "yyyy-MM-dd'T'HH:mm:ss'Z'", utc())
      ageHours = (nowEpoch - dt.toTime().toUnix().float) / 3600.0
    except CatchableError: discard

    let shouldPrune = (status in ["WEAVED", "MERGED", "CLOSED"]) or (ageHours >= maxAgeHours)
    if shouldPrune and dirExists(path):
      if not dryRun:
        if canonRepo.len > 0 and dirExists(canonRepo):
          discard execCmdEx("git -C " & quoteShell(canonRepo) & " worktree remove --force " & quoteShell(path))
          discard execCmdEx("git -C " & quoteShell(canonRepo) & " worktree prune")
        else:
          discard execCmdEx("git worktree remove --force " & quoteShell(path))
        if dirExists(path):
          try: removeDir(path)
          except CatchableError: discard
        if dirExists(path.parentDir()):
          try: removeDir(path.parentDir())
          except CatchableError: discard
      var prunedItem = newJObject()
      prunedItem["strand_path"] = %path
      prunedItem["age_hours"] = %ageHours
      prunedItem["reason"] = if status in ["WEAVED", "MERGED", "CLOSED"]: %status else: %"expired"
      pruned.add(prunedItem)

  var res = newJObject()
  res["dry_run"] = %dryRun
  res["pruned_count"] = %(pruned.len)
  res["pruned"] = pruned
  return res

proc doStrandSync*(
  strandDirParam: string = "",
  baseRefParam: string = "",
  useRebase: bool = false
): tuple[output: JsonNode, exitCode: int] =
  let strandDir = if strandDirParam.len > 0: strandDirParam.normalizedPath else: getCurrentDir()
  let manifestPath = strandDir / ".vine.json"
  var manifest: JsonNode = nil

  if fileExists(manifestPath):
    try: manifest = parseJson(readFile(manifestPath))
    except CatchableError: discard

  # Check working tree cleanliness (tracked changes or staged files, ignoring untracked metadata)
  let (_, dirtyCode) = execCmdEx("git -C " & quoteShell(strandDir) & " diff-index --quiet HEAD --")
  if dirtyCode != 0:
    var errObj = newJObject()
    errObj["status"] = %"dirty_working_tree"
    errObj["message"] = %"Working tree has uncommitted changes. Commit or stash them before syncing."
    return (errObj, 1)

  let branch = if manifest != nil and manifest.hasKey("branch"): manifest["branch"].getStr()
               else:
                 let (outp, code) = execCmdEx("git -C " & quoteShell(strandDir) & " rev-parse --abbrev-ref HEAD")
                 if code == 0: outp.strip() else: "HEAD"

  let baseBranch = if baseRefParam.len > 0: baseRefParam
                   elif manifest != nil and manifest.hasKey("base_branch"): manifest["base_branch"].getStr()
                   else: "main"

  let projectName = if manifest != nil and manifest.hasKey("project"): manifest["project"].getStr()
                    else: strandDir.splitPath.tail

  let devBase = getProjectsBaseDir()
  let canonicalRepo = if manifest != nil and manifest.hasKey("canonical_repo") and dirExists(manifest["canonical_repo"].getStr()):
                        manifest["canonical_repo"].getStr()
                      elif dirExists(devBase / projectName):
                        devBase / projectName
                      else:
                        ""

  if canonicalRepo.len == 0 or not dirExists(canonicalRepo):
    var errObj = newJObject()
    errObj["status"] = %"error"
    errObj["message"] = %("Canonical repository not found for project: " & projectName)
    return (errObj, 1)

  let isWorktree = (manifest != nil and manifest.hasKey("tool") and manifest["tool"].getStr() == "git-worktree") or
                   (execCmdEx("git -C " & quoteShell(canonicalRepo) & " worktree list").output.contains(strandDir))

  # If not a worktree (e.g. rift clone), fetch baseBranch from canonical repo into strand
  if not isWorktree:
    let fetchCmd = "git -C " & quoteShell(strandDir) & " fetch " & quoteShell(canonicalRepo) & " " & quoteShell(baseBranch & ":" & baseBranch)
    let (fOut, fCode) = execCmdEx(fetchCmd)
    if fCode != 0:
      var errObj = newJObject()
      errObj["status"] = %"fetch_failed"
      errObj["message"] = %("git fetch from canonical repo failed: " & fOut)
      return (errObj, fCode)

  # Check canonical repo HEAD of baseBranch
  let (baseCommitOut, baseCommitCode) = execCmdEx("git -C " & quoteShell(canonicalRepo) & " rev-parse " & quoteShell(baseBranch))
  let canonicalBaseCommit = if baseCommitCode == 0: baseCommitOut.strip() else: ""

  # Rebase or merge baseBranch into current branch
  let syncCmd = if useRebase:
                  "git -C " & quoteShell(strandDir) & " rebase " & quoteShell(baseBranch)
                else:
                  "git -C " & quoteShell(strandDir) & " merge --no-edit " & quoteShell(baseBranch)
  let (sOut, sCode) = execCmdEx(syncCmd)
  if sCode != 0:
    var errObj = newJObject()
    errObj["status"] = %"conflict"
    errObj["message"] = %("Sync failed due to conflicts with " & baseBranch & ": " & sOut)
    return (errObj, sCode)

  # Update manifest if present
  if manifest != nil:
    if canonicalBaseCommit.len > 0:
      manifest["base_commit"] = %canonicalBaseCommit
    manifest["status"] = %"SYNCED"
    manifest["synced_at"] = %now().utc().format("yyyy-MM-dd'T'HH:mm:ss'Z'")
    writeFile(manifestPath, pretty(manifest))

  var res = newJObject()
  res["status"] = %"synced"
  res["branch"] = %branch
  res["base_branch"] = %baseBranch
  res["base_commit"] = %canonicalBaseCommit
  res["strand_path"] = %strandDir
  res["mode"] = if useRebase: %"rebase" else: %"merge"
  return (res, 0)

proc doStrandStatus*(strandDirOrId: string = ""): tuple[status: JsonNode, exitCode: int] =
  var strandDir = ""
  var manifest: JsonNode = nil

  if strandDirOrId.len > 0:
    if dirExists(strandDirOrId):
      strandDir = strandDirOrId.normalizedPath
    else:
      let allStrands = doStrandList("", includeAll = true)
      for s in allStrands{"strands"}:
        if s{"task_id"}.getStr == strandDirOrId or s{"branch"}.getStr == strandDirOrId or s{"strand_path"}.getStr.contains(strandDirOrId):
          strandDir = s{"strand_path"}.getStr
          break
      if strandDir.len == 0:
        var errObj = newJObject()
        errObj["status"] = %"error"
        errObj["message"] = %("Strand not found for identifier: " & strandDirOrId)
        return (errObj, 1)
  else:
    strandDir = getCurrentDir()

  let manifestPath = strandDir / ".vine.json"
  if fileExists(manifestPath):
    try: manifest = parseJson(readFile(manifestPath))
    except CatchableError: discard

  let taskId = if manifest != nil and manifest.hasKey("task_id"): manifest["task_id"].getStr else: strandDir.splitPath.tail
  let project = if manifest != nil and manifest.hasKey("project"): manifest["project"].getStr else: ""
  let strandBranch = if manifest != nil and manifest.hasKey("branch"): manifest["branch"].getStr
                     else:
                       let (bOut, bCode) = execCmdEx("git -C " & quoteShell(strandDir) & " rev-parse --abbrev-ref HEAD")
                       if bCode == 0: bOut.strip() else: "HEAD"
  let baseBranch = if manifest != nil and manifest.hasKey("base_branch"): manifest["base_branch"].getStr else: "main"
  let parentBranch = if manifest != nil and manifest.hasKey("parent_branch"): manifest["parent_branch"].getStr else: baseBranch
  let baseCommit = if manifest != nil and manifest.hasKey("base_commit"): manifest["base_commit"].getStr else: ""
  let intendedMergeBase = if manifest != nil and manifest.hasKey("intended_merge_base"): manifest["intended_merge_base"].getStr else: baseCommit
  let storedStatus = if manifest != nil and manifest.hasKey("status"): manifest["status"].getStr else: "IN_PROGRESS"
  let tool = if manifest != nil and manifest.hasKey("tool"): manifest["tool"].getStr else: "git-worktree"

  var commitsAhead = 0
  var commitsBehind = 0
  let (aheadOut, aheadCode) = execCmdEx("git -C " & quoteShell(strandDir) & " rev-list --count " & quoteShell(parentBranch) & ".." & quoteShell(strandBranch))
  if aheadCode == 0:
    try: commitsAhead = parseInt(aheadOut.strip())
    except CatchableError: discard

  let (behindOut, behindCode) = execCmdEx("git -C " & quoteShell(strandDir) & " rev-list --count " & quoteShell(strandBranch) & ".." & quoteShell(parentBranch))
  if behindCode == 0:
    try: commitsBehind = parseInt(behindOut.strip())
    except CatchableError: discard

  var dirtyFiles = newJArray()
  let (stOut, stCode) = execCmdEx("git -C " & quoteShell(strandDir) & " status --porcelain")
  if stCode == 0:
    for line in stOut.splitLines():
      if line.len >= 3:
        let filePath = line[3..^1].strip()
        if filePath in [".vine.json", ".envrc", ".venv", ".git"] or filePath.startsWith(".vine."):
          continue
        dirtyFiles.add(%line.strip())

  var lifecycleState = "IN_PROGRESS"
  if storedStatus in ["MERGED", "WEAVED", "CLOSED"]:
    lifecycleState = "MERGED"
  elif storedStatus == "ABANDONED":
    lifecycleState = "ABANDONED"
  elif storedStatus == "GATE_EVALUATING":
    lifecycleState = "GATE_EVALUATING"
  elif storedStatus == "CONFLICTED":
    lifecycleState = "CONFLICTED"
  elif storedStatus == "GATE_FAILED":
    lifecycleState = "GATE_FAILED"
  elif storedStatus in ["READY_FOR_WEAVE", "GATE_PASSED"]:
    if dirtyFiles.len > 0:
      lifecycleState = "IN_PROGRESS"
    else:
      lifecycleState = "GATE_PASSED"
  elif storedStatus == "PROVISIONED" and commitsAhead == 0 and dirtyFiles.len == 0:
    lifecycleState = "PROVISIONED"
  else:
    lifecycleState = "IN_PROGRESS"

  var res = newJObject()
  res["task_id"] = %taskId
  res["project"] = %project
  res["strand_path"] = %strandDir
  res["branch"] = %strandBranch
  res["parent_branch"] = %parentBranch
  res["base_branch"] = %baseBranch
  res["base_commit"] = %baseCommit
  res["intended_merge_base"] = %intendedMergeBase
  res["lifecycle_state"] = %lifecycleState
  res["status"] = %lifecycleState
  res["stored_status"] = %storedStatus
  res["commits_ahead"] = %commitsAhead
  res["commits_behind"] = %commitsBehind
  res["dirty_count"] = %(dirtyFiles.len)
  res["dirty_files"] = dirtyFiles
  res["tool"] = %tool

  return (res, 0)

proc doStrandCollisions*(repoDirParam: string = ""): JsonNode =
  let repoDir = if repoDirParam.len > 0: repoDirParam.normalizedPath else: getRepoRoot()
  let projectName = repoDir.splitPath.tail
  let listData = doStrandList(repoDir, includeAll = false)
  let activeStrands = listData{"strands"}

  var fileToTaskIds = initTable[string, seq[string]]()
  var strandFootprints = newJObject()

  for item in activeStrands:
    let status = item{"status"}.getStr("").toUpperAscii
    let lifecycleState = item{"lifecycle_state"}.getStr("").toUpperAscii
    if status in ["MERGED", "WEAVED", "CLOSED", "ABANDONED"] or
       lifecycleState in ["MERGED", "WEAVED", "CLOSED", "ABANDONED"]:
      continue

    let taskId = item{"task_id"}.getStr("")
    let sPath = item{"strand_path"}.getStr("")
    let branch = item{"branch"}.getStr("")
    let baseBranch = item{"base_branch"}.getStr("main")
    let baseCommit = item{"base_commit"}.getStr("")

    if not dirExists(sPath): continue

    var touchedFiles = initHashSet[string]()

    let diffRef = if baseBranch.len > 0: baseBranch else: baseCommit
    if diffRef.len > 0:
      let (dOut, dCode) = execCmdEx("git -C " & quoteShell(sPath) & " diff --name-only " & quoteShell(diffRef) & "..." & quoteShell(branch))
      if dCode == 0:
        for f in dOut.splitLines():
          let tf = f.strip()
          if tf.len > 0: touchedFiles.incl(tf)

    let (sOut, sCode) = execCmdEx("git -C " & quoteShell(sPath) & " diff --name-only HEAD")
    if sCode == 0:
      for f in sOut.splitLines():
        let tf = f.strip()
        if tf.len > 0: touchedFiles.incl(tf)

    let (uOut, uCode) = execCmdEx("git -C " & quoteShell(sPath) & " status --porcelain")
    if uCode == 0:
      for line in uOut.splitLines():
        if line.len >= 3:
          let f = line[3..^1].strip()
          if f.len > 0 and f notin [".vine.json", ".envrc", ".venv", ".git"] and not f.startsWith(".vine."):
            touchedFiles.incl(f)

    var sortedFiles: seq[string] = @[]
    for f in touchedFiles: sortedFiles.add(f)
    sortedFiles.sort()

    var fpArr = newJArray()
    for f in sortedFiles:
      fpArr.add(%f)
      if not fileToTaskIds.hasKey(f):
        fileToTaskIds[f] = @[]
      fileToTaskIds[f].add(taskId)
    strandFootprints[taskId] = fpArr

  var sortedCollisionFiles: seq[string] = @[]
  for f, tids in fileToTaskIds:
    if tids.len > 1:
      sortedCollisionFiles.add(f)
  sortedCollisionFiles.sort()

  var collisions = newJArray()
  for f in sortedCollisionFiles:
    let tids = fileToTaskIds[f]
    var cObj = newJObject()
    cObj["file"] = %f
    var strandsArr = newJArray()
    for tid in tids: strandsArr.add(%tid)
    cObj["strands"] = strandsArr
    cObj["count"] = %(tids.len)
    collisions.add(cObj)

  var res = newJObject()
  res["project"] = %projectName
  res["active_strands"] = %(activeStrands.len)
  res["has_collisions"] = %(collisions.len > 0)
  res["collision_count"] = %(collisions.len)
  res["collisions"] = collisions
  res["strand_footprints"] = strandFootprints
  return res


