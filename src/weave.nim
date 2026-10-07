# /Users/eek/Development/vine/src/weave.nim
# Weaves verified strands back into the canonical repository trunk.

import std/[os, osproc, strutils, json]
import gate
import config

proc doBraidWeave*(
  branchParam: string = "",
  baseRefParam: string = "",
  strandDirParam: string = "",
  force: bool = false
): tuple[output: JsonNode, exitCode: int] =
  let strandDir = if strandDirParam.len > 0: strandDirParam.normalizedPath else: getCurrentDir()
  let manifestPath = strandDir / ".vine.json"
  var manifest: JsonNode = nil

  if fileExists(manifestPath):
    try: manifest = parseJson(readFile(manifestPath))
    except CatchableError: discard

  # Step 1: Run Gate check if not already verified green
  if not force:
    let effectiveBase = if baseRefParam.len > 0: baseRefParam
                        elif manifest != nil and manifest.hasKey("base_branch"): manifest["base_branch"].getStr()
                        else: "main"
    let (gateRes, gateCode) = doBraidGate(branchParam, effectiveBase, strandDir)
    if gateCode != 0:
      var errObj = newJObject()
      errObj["status"] = %"weave_rejected"
      errObj["message"] = %"Strand did not pass the Two-Key Gate. Resolve conflicts or compiler failures first."
      errObj["gate_results"] = gateRes
      return (errObj, 1)

  let branch = if branchParam.len > 0: branchParam
               elif manifest != nil and manifest.hasKey("branch"): manifest["branch"].getStr()
               else:
                 let (outp, code) = execCmdEx("git -C " & quoteShell(strandDir) & " rev-parse --abbrev-ref HEAD")
                 if code == 0: outp.strip() else: "HEAD"

  let baseBranch = if baseRefParam.len > 0: baseRefParam
                   elif manifest != nil and manifest.hasKey("base_branch"): manifest["base_branch"].getStr()
                   else: "main"

  let projectName = if manifest != nil and manifest.hasKey("project"): manifest["project"].getStr()
                    else: strandDir.splitPath.tail

  let home = getHomeDir()
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

  # Step 2: Fetch branch directly if it's an isolated clone (rift)
  let isWorktree = (manifest != nil and manifest.hasKey("tool") and manifest["tool"].getStr() == "git-worktree") or
                   (execCmdEx("git -C " & quoteShell(canonicalRepo) & " worktree list").output.contains(strandDir))
  if not isWorktree:
    let fetchCmd = "git -C " & quoteShell(canonicalRepo) & " fetch " & quoteShell(strandDir) & " " & quoteShell(branch & ":" & branch)
    let (fOut, fCode) = execCmdEx(fetchCmd)
    if fCode != 0:
      var errObj = newJObject()
      errObj["status"] = %"fetch_failed"
      errObj["message"] = %("git fetch from strand failed: " & fOut)
      return (errObj, fCode)

  # Step 3: Fast-forward merge into base branch in canonical repo
  let checkoutCmd = "git -C " & quoteShell(canonicalRepo) & " checkout " & quoteShell(baseBranch)
  discard execCmdEx(checkoutCmd)

  let mergeCmd = "git -C " & quoteShell(canonicalRepo) & " merge --ff-only " & quoteShell(branch)
  let (mOut, mCode) = execCmdEx(mergeCmd)
  if mCode != 0:
    var errObj = newJObject()
    errObj["status"] = %"fast_forward_failed"
    errObj["message"] = %("git merge --ff-only failed: " & mOut.strip() & ". Canonical trunk has diverged. Run 'vine sync' inside the strand first.")
    return (errObj, mCode)

  # Step 4: Prune strand directory
  try: setCurrentDir(canonicalRepo)
  except CatchableError: discard

  if isWorktree:
    discard execCmdEx("git -C " & quoteShell(canonicalRepo) & " worktree remove --force " & quoteShell(strandDir))
    discard execCmdEx("git -C " & quoteShell(canonicalRepo) & " worktree prune")
  else:
    try:
      if dirExists(strandDir): removeDir(strandDir)
    except CatchableError: discard

  try:
    let parent = strandDir.parentDir()
    let wsBase = getWorkspacesBaseDir()
    if dirExists(parent) and parent != home and parent != devBase and parent != wsBase:
      removeDir(parent)
  except CatchableError: discard

  var res = newJObject()
  res["status"] = %"woven"
  res["branch"] = %branch
  res["base_branch"] = %baseBranch
  res["canonical_repo"] = %canonicalRepo
  return (res, 0)
