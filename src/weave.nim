# /Users/eek/Development/vine/src/weave.nim
# Weaves verified strands back into the canonical repository trunk.

import std/[os, osproc, strutils, json, times]
import gate, crypto
import config, strand, notify, redis_client

proc doBraidWeave*(
  branchParam: string = "",
  baseRefParam: string = "",
  strandDirParam: string = "",
  force: bool = false,
  allowNoTests: bool = false,
  allowNoChangelog: bool = false,
  allowUnaudited: bool = false,
  noNotify: bool = false
): tuple[output: JsonNode, exitCode: int] =
  var strandDir = if strandDirParam.len > 0: strandDirParam.normalizedPath else: getCurrentDir()
  var manifest = findStrandManifest(if strandDirParam.len > 0: strandDirParam else: branchParam)
  if manifest == nil and strandDirParam.len == 0:
    manifest = findStrandManifest(strandDir)
  if manifest != nil and manifest.hasKey("strand_path") and dirExists(manifest["strand_path"].getStr):
    strandDir = manifest["strand_path"].getStr.normalizedPath

  let tid = if manifest != nil: manifest.getOrDefault("id").getStr(manifest.getOrDefault("task_id").getStr("")) else: ""

  # Step 1: Run Gate check if not already verified green
  let isAlreadyRatified = manifest != nil and (
    manifest.getOrDefault("status").getStr("") in ["AUDIT_RATIFIED", "RATIFIED"] or
    manifest.getOrDefault("lifecycle_state").getStr("") in ["AUDIT_RATIFIED", "RATIFIED"] or
    manifest.getOrDefault("state").getStr("") in ["AUDIT_RATIFIED", "RATIFIED"]
  )
  if not force and not isAlreadyRatified:
    let effectiveBase = if baseRefParam.len > 0: baseRefParam
                        elif manifest != nil and manifest.hasKey("base_branch"): manifest["base_branch"].getStr()
                        else: "main"
    let (gateRes, gateCode) = doBraidGate(branchParam, effectiveBase, strandDir, allowNoTests = allowNoTests, allowNoChangelog = allowNoChangelog)
    if gateCode != 0:
      var errObj = newJObject()
      errObj["status"] = %"weave_rejected"
      errObj["message"] = %"Strand did not pass Key 1 or Key 2 of the Three-Key Gate. Resolve conflicts or compiler failures first."
      errObj["gate_results"] = gateRes
      return (errObj, gateCode)

  # Reload manifest from Redis in case doBraidGate updated it
  if tid.len > 0:
    let updated = getStrandRedis(tid)
    if updated != nil and updated.kind == JObject:
      manifest = updated

  # Step 2: Enforce Key 3 (Pre-Weave Adversarial Audit)
  if not force and not allowUnaudited:
    if manifest == nil:
      var errObj = newJObject()
      errObj["status"] = %"audit_violation"
      errObj["message"] = %"Key 3 Audit Violation: No strand metadata found. Strand must be audited and ratified by an independent auditor. Pass --allow-unaudited to bypass."
      return (errObj, ExitGateAuditViolation)

    let st = manifest.getOrDefault("status").getStr("")
    let ls = manifest.getOrDefault("lifecycle_state").getStr("")
    let state = manifest.getOrDefault("state").getStr("")
    if st notin ["AUDIT_RATIFIED", "RATIFIED"] and ls notin ["AUDIT_RATIFIED", "RATIFIED"] and state notin ["AUDIT_RATIFIED", "RATIFIED"]:
      var errObj = newJObject()
      errObj["status"] = %"audit_violation"
      errObj["message"] = %("Key 3 Audit Violation: Strand status is '" & st & "', but requires 'AUDIT_RATIFIED' before trunk weaving. Pass --allow-unaudited to bypass.")
      return (errObj, ExitGateAuditViolation)

    let author = if manifest.hasKey("author"): manifest["author"].getStr()
                 elif manifest.hasKey("worker_name"): manifest["worker_name"].getStr()
                 else: ""
    let auditor = manifest.getOrDefault("auditor").getStr("")
    if auditor.len == 0:
      var errObj = newJObject()
      errObj["status"] = %"audit_violation"
      errObj["message"] = %"Key 3 Audit Violation: Manifest indicates AUDIT_RATIFIED but missing auditor identifier."
      return (errObj, ExitGateAuditViolation)

    if author.len > 0 and auditor.toLowerAscii == author.toLowerAscii:
      var errObj = newJObject()
      errObj["status"] = %"audit_violation"
      errObj["message"] = %("Key 3 Audit Violation: Self-audit detected. Worker '" & author & "' cannot audit their own strand. Key 3 requires an independent Adversarial Auditor created by the Orchestrator.")
      return (errObj, ExitGateAuditViolation)

    let recordedTreeSha = manifest.getOrDefault("merge_tree_sha").getStr("")
    let gateToken = manifest.getOrDefault("gate_token").getStr("")
    let recordedAuditToken = manifest.getOrDefault("audit_token").getStr("")
    let expectedAuditToken = computeAuditToken(gateToken, recordedTreeSha, auditor)

    if recordedAuditToken.len == 0 or recordedAuditToken != expectedAuditToken:
      var errObj = newJObject()
      errObj["status"] = %"audit_violation"
      errObj["message"] = %"Key 3 Audit Violation: Audit token mismatch or tampering detected. Re-audit the strand."
      return (errObj, ExitGateAuditViolation)

  let branch = if branchParam.len > 0 and execCmdEx("git -C " & quoteShell(strandDir) & " rev-parse --verify " & quoteShell(branchParam)).exitCode == 0:
                 branchParam
               elif manifest != nil and manifest.hasKey("branch"):
                 manifest["branch"].getStr()
               elif branchParam.len > 0:
                 branchParam
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
                      elif dirExists(getCurrentDir() / ".git"):
                        getCurrentDir()
                      else:
                        ""

  if canonicalRepo.len == 0 or not dirExists(canonicalRepo):
    var errObj = newJObject()
    errObj["status"] = %"error"
    errObj["message"] = %("Canonical repository not found for project: " & projectName)
    return (errObj, 1)

  # Dual-Mode Transport: Co-located vs Remote Strand
  let strandMachineId = if manifest != nil and manifest.hasKey("machine_id"): manifest["machine_id"].getStr("") else: ""
  let localMachineId = getMachineId()
  let isColocated = (strandMachineId.len == 0 or strandMachineId == localMachineId)

  # Step 2: Fetch branch
  if not isColocated:
    # Remote strand: fetch branch commits from remote git origin before evaluating merge
    let fetchRemoteCmd = "git -C " & quoteShell(canonicalRepo) & " fetch origin " & quoteShell(branch & ":" & branch)
    let (frOut, frCode) = execCmdEx(fetchRemoteCmd)
    if frCode != 0:
      var errObj = newJObject()
      errObj["status"] = %"fetch_failed"
      errObj["message"] = %("git fetch origin from remote strand failed: " & frOut)
      return (errObj, frCode)
  else:
    # Co-located strand: fetch branch directly if it's an isolated clone (rift)
    let isWorktree = (manifest != nil and manifest.hasKey("tool") and manifest["tool"].getStr() == "git-worktree") or
                     (execCmdEx("git -C " & quoteShell(canonicalRepo) & " worktree list").output.contains(strandDir))
    if not isWorktree and dirExists(strandDir):
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

  # Step 4: Prune strand directory (only if co-located)
  try: setCurrentDir(canonicalRepo)
  except CatchableError: discard

  if isColocated:
    let isWorktree = (manifest != nil and manifest.hasKey("tool") and manifest["tool"].getStr() == "git-worktree") or
                     (execCmdEx("git -C " & quoteShell(canonicalRepo) & " worktree list").output.contains(strandDir))
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

  # Step 5: Update Redis Strand State to WOVEN (Atomically updates state and removes strands:by_path)
  let (headShaOut, _) = execCmdEx("git -C " & quoteShell(canonicalRepo) & " rev-parse HEAD")
  let headSha = headShaOut.strip()
  let byAgent = getEnv("RHIZO_AGENT_NAME", getEnv("USER", "orchestrator"))
  if tid.len > 0:
    discard weaveStrandRedis(tid, headSha, byAgent)

  # Step 5: Auto-harvest matching Garden task seed if .garden exists in canonicalRepo
  let gSeeds = canonicalRepo / ".garden" / "seeds"
  if dirExists(gSeeds):
    let taskId = if manifest != nil and manifest.hasKey("task_id"): manifest["task_id"].getStr("") else: ""
    let candidates = [taskId, branch, "seed-" & taskId, "seed-" & branch]
    for c in candidates:
      if c.len > 0 and fileExists(gSeeds / (c & ".toml")):
        try:
          var sLines = readFile(gSeeds / (c & ".toml")).splitLines()
          var updated: seq[string] = @[]
          let nowIso = now().utc().format("yyyy-MM-dd'T'HH:mm:ss'Z'")
          var replacedStatus = false
          var replacedUpdated = false
          for sl in sLines:
            let trimmed = sl.strip()
            if not replacedStatus and trimmed.startsWith("status") and trimmed.len > 6 and trimmed[6..^1].strip().startsWith("="):
              updated.add("status = \"WOVEN\"")
              replacedStatus = true
            elif not replacedUpdated and trimmed.startsWith("updated_at") and trimmed.len > 10 and trimmed[10..^1].strip().startsWith("="):
              updated.add("updated_at = \"" & nowIso & "\"")
              replacedUpdated = true
            else:
              updated.add(sl)
          if not replacedStatus:
            updated.add("status = \"WOVEN\"")
          if not replacedUpdated:
            updated.add("updated_at = \"" & nowIso & "\"")
          writeFile(gSeeds / (c & ".toml"), updated.join("\n"))
          discard execCmdEx("garden roadmap --sync --project-dir " & quoteShell(canonicalRepo))
        except CatchableError:
          discard
        break

  var res = newJObject()
  res["status"] = %"woven"
  res["branch"] = %branch
  res["base_branch"] = %baseBranch
  res["canonical_repo"] = %canonicalRepo

  let notifyRes = notifyStrandEvent(manifest, "STRAND_WOVEN", res, noNotify)
  if notifyRes != nil:
    res["notification"] = notifyRes

  return (res, 0)
