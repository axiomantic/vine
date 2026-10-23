# src/notify.nim
# Vine Strand Lifecycle Notifications with Orchestrator Awareness and Project Multicast Fallback.

import std/[os, osproc, strutils, json]

proc isRhizoAvailable*(): bool =
  findExe("rhizo").len > 0

proc isNotificationsDisabled*(noNotify: bool = false): bool =
  if noNotify: return true
  let envVal = getEnv("VINE_NO_NOTIFY", "").strip().toLowerAscii
  return envVal in ["1", "true", "yes", "on"]

proc isOrchestratorActive*(orchestrator: string): bool =
  if orchestrator.len == 0 or not isRhizoAvailable(): return false

  # First try exact codename query via rhizo who <orchestrator> --json
  let (outp, code) = execCmdEx("rhizo who " & quoteShell(orchestrator) & " --json")
  if code == 0 and outp.strip().len > 0:
    try:
      let node = parseJson(outp)
      if node.kind == JArray and node.len > 0:
        for item in node:
          let ag = item.getOrDefault("agent").getStr("")
          let aliasOf = item.getOrDefault("alias_of").getStr("")
          if ag.toLowerAscii == orchestrator.toLowerAscii or
             (aliasOf.len > 0 and aliasOf.toLowerAscii == orchestrator.toLowerAscii):
            let status = item.getOrDefault("status").getStr("").toUpperAscii
            let listener = item.getOrDefault("listener").getStr("").toUpperAscii
            if status in ["ACTIVE", "BUSY"] or listener in ["LISTENING", "DETACHED"]:
              return true
      elif node.kind == JObject:
        let ag = node.getOrDefault("agent").getStr("")
        let aliasOf = node.getOrDefault("alias_of").getStr("")
        if ag.toLowerAscii == orchestrator.toLowerAscii or
           (aliasOf.len > 0 and aliasOf.toLowerAscii == orchestrator.toLowerAscii):
          let status = node.getOrDefault("status").getStr("").toUpperAscii
          let listener = node.getOrDefault("listener").getStr("").toUpperAscii
          if status in ["ACTIVE", "BUSY"] or listener in ["LISTENING", "DETACHED"]:
            return true
    except CatchableError:
      discard

  # Fallback to rhizo who --all --json in case exact query didn't match or failed
  let (allOut, allCode) = execCmdEx("rhizo who --all --json")
  if allCode == 0 and allOut.strip().len > 0:
    try:
      let roster = parseJson(allOut)
      if roster.kind == JArray:
        for entry in roster:
          let agentName = entry.getOrDefault("agent").getStr("")
          let aliasOf = entry.getOrDefault("alias_of").getStr("")
          if agentName.toLowerAscii == orchestrator.toLowerAscii or
             (aliasOf.len > 0 and aliasOf.toLowerAscii == orchestrator.toLowerAscii):
            let status = entry.getOrDefault("status").getStr("").toUpperAscii
            let listener = entry.getOrDefault("listener").getStr("").toUpperAscii
            if status in ["ACTIVE", "BUSY"] or listener in ["LISTENING", "DETACHED"]:
              return true
    except CatchableError:
      discard

  return false

proc sendRhizoDirect*(target: string, subject: string, bodyJson: string, project: string = "", sender: string = ""): bool =
  if not isRhizoAvailable() or target.len == 0: return false
  let effSender = if sender.len > 0: sender
                  elif getEnv("RHIZO_AGENT_NAME").len > 0: getEnv("RHIZO_AGENT_NAME")
                  else: "system:vine"
  var cmd = "RHIZO_AGENT_NAME=" & quoteShell(effSender) & " rhizo "
  if project.len > 0:
    cmd &= "--project " & quoteShell(project) & " "
  cmd &= "send --to " & quoteShell(target) & " --subject " & quoteShell(subject) & " --body " & quoteShell(bodyJson) & " --skip-gate"
  let (_, code) = execCmdEx(cmd)
  return code == 0

proc sendRhizoMulticast*(project: string, subject: string, bodyJson: string, sender: string = ""): bool =
  if not isRhizoAvailable(): return false
  let targetTag = if project.len > 0: project else: "vine"
  let effSender = if sender.len > 0: sender
                  elif getEnv("RHIZO_AGENT_NAME").len > 0: getEnv("RHIZO_AGENT_NAME")
                  else: "system:vine"
  var cmd = "RHIZO_AGENT_NAME=" & quoteShell(effSender) & " rhizo "
  if project.len > 0:
    cmd &= "--project " & quoteShell(project) & " "
  cmd &= "broadcast --tags " & quoteShell(targetTag) & " --subject " & quoteShell(subject) & " --body " & quoteShell(bodyJson)
  let (_, code) = execCmdEx(cmd)
  return code == 0

proc notifyStrandEvent*(
  manifest: JsonNode,
  event: string,
  details: JsonNode = nil,
  noNotify: bool = false
): JsonNode =
  var res = newJObject()
  res["event"] = %event
  res["dispatched"] = %false

  if isNotificationsDisabled(noNotify):
    res["status"] = %"skipped_disabled"
    return res

  if not isRhizoAvailable():
    res["status"] = %"skipped_rhizo_unavailable"
    return res

  try:
    let taskId = if manifest != nil and manifest.hasKey("task_id"): manifest["task_id"].getStr("")
                 elif details != nil and details.hasKey("task_id"): details["task_id"].getStr("")
                 else: "unknown-task"

    var project = if manifest != nil and manifest.hasKey("project"): manifest["project"].getStr("")
                  elif details != nil and details.hasKey("project"): details["project"].getStr("")
                  else: ""
    if project.len == 0:
      project = "vine"

    let strandPath = if manifest != nil and manifest.hasKey("strand_path"): manifest["strand_path"].getStr("")
                     elif details != nil and details.hasKey("strand_path"): details["strand_path"].getStr("")
                     else: ""

    let branch = if manifest != nil and manifest.hasKey("branch"): manifest["branch"].getStr("")
                 elif details != nil and details.hasKey("branch"): details["branch"].getStr("")
                 else: ""

    let baseBranch = if manifest != nil and manifest.hasKey("base_branch"): manifest["base_branch"].getStr("main")
                     elif details != nil and details.hasKey("base_branch"): details["base_branch"].getStr("main")
                     else: "main"

    var author = if manifest != nil and manifest.hasKey("author"): manifest["author"].getStr("")
                 elif manifest != nil and manifest.hasKey("worker"): manifest["worker"].getStr("")
                 elif manifest != nil and manifest.hasKey("worker_name"): manifest["worker_name"].getStr("")
                 elif details != nil and details.hasKey("author"): details["author"].getStr("")
                 else: ""

    var auditor = if manifest != nil and manifest.hasKey("auditor"): manifest["auditor"].getStr("")
                  elif details != nil and details.hasKey("auditor"): details["auditor"].getStr("")
                  else: ""

    var orchestrator = if manifest != nil and manifest.hasKey("orchestrator"): manifest["orchestrator"].getStr("")
                       elif manifest != nil and manifest.hasKey("orch_name"): manifest["orch_name"].getStr("")
                       elif details != nil and details.hasKey("orchestrator"): details["orchestrator"].getStr("")
                       else: ""

    let gateToken = if manifest != nil and manifest.hasKey("gate_token"): manifest["gate_token"].getStr("")
                    elif details != nil and details.hasKey("gate_token"): details["gate_token"].getStr("")
                    else: ""

    let mergeTreeSha = if manifest != nil and manifest.hasKey("merge_tree_sha"): manifest["merge_tree_sha"].getStr("")
                       elif details != nil and details.hasKey("merge_tree_sha"): details["merge_tree_sha"].getStr("")
                       else: ""

    let auditToken = if manifest != nil and manifest.hasKey("audit_token"): manifest["audit_token"].getStr("")
                     elif details != nil and details.hasKey("audit_token"): details["audit_token"].getStr("")
                     else: ""

    var subject = ""
    var payload = newJObject()
    payload["event"] = %event
    payload["task_id"] = %taskId
    payload["project"] = %project
    if strandPath.len > 0: payload["strand_path"] = %strandPath
    if branch.len > 0: payload["branch"] = %branch
    if baseBranch.len > 0: payload["base_branch"] = %baseBranch
    if author.len > 0: payload["author"] = %author

    case event
    of "STRAND_SUBMITTED":
      subject = "STRAND_SUBMITTED: " & taskId & " (Keys 1 & 2 Passed)"
      payload["status"] = %"READY_FOR_AUDIT"
      if orchestrator.len > 0: payload["orchestrator"] = %orchestrator
      if gateToken.len > 0: payload["gate_token"] = %gateToken
      if mergeTreeSha.len > 0: payload["merge_tree_sha"] = %mergeTreeSha

    of "AUDIT_RATIFIED":
      subject = "AUDIT_RATIFIED: " & taskId & " (Key 3 Gate Passed)"
      payload["status"] = %"AUDIT_RATIFIED"
      if auditor.len > 0: payload["auditor"] = %auditor
      if auditToken.len > 0: payload["audit_token"] = %auditToken
      if gateToken.len > 0: payload["gate_token"] = %gateToken
      if mergeTreeSha.len > 0: payload["merge_tree_sha"] = %mergeTreeSha

    of "AUDIT_REJECTED":
      subject = "AUDIT_REJECTED: " & taskId & " (Rework Required)"
      payload["status"] = %"AUDIT_REJECTED"
      if auditor.len > 0: payload["auditor"] = %auditor
      let reason = if details != nil and details.hasKey("rejection_reason"): details["rejection_reason"].getStr("")
                   elif manifest != nil and manifest.hasKey("rejection_reason"): manifest["rejection_reason"].getStr("")
                   else: "Defects detected during adversarial review."
      payload["reason"] = %reason
      let findings = if details != nil and details.hasKey("findings"): details["findings"].getStr("")
                     elif manifest != nil and manifest.hasKey("findings"): manifest["findings"].getStr("")
                     else: ""
      if findings.len > 0: payload["findings"] = %findings

    of "STRAND_WOVEN":
      subject = "STRAND_WOVEN: " & taskId & " (Trunk Integration Complete)"
      payload["status"] = %"WOVEN"
      let canonicalRepo = if details != nil and details.hasKey("canonical_repo"): details["canonical_repo"].getStr("")
                          elif manifest != nil and manifest.hasKey("canonical_repo"): manifest["canonical_repo"].getStr("")
                          else: ""
      if canonicalRepo.len > 0: payload["canonical_repo"] = %canonicalRepo
      if auditor.len > 0: payload["auditor"] = %auditor

    else:
      subject = "STRAND_EVENT: " & taskId & " (" & event & ")"
      payload["status"] = %(if manifest != nil and manifest.hasKey("status"): manifest["status"].getStr("") else: event)

    let sender = if author.len > 0: author
                 elif auditor.len > 0: auditor
                 elif getEnv("RHIZO_AGENT_NAME").len > 0: getEnv("RHIZO_AGENT_NAME")
                 else: "system:vine"

    let bodyJson = $payload
    var primaryRouted = false
    var primaryMode = ""
    var primaryTarget = ""

    # Primary routing: Orchestrator Awareness with Multicast Fallback
    if orchestrator.len > 0 and isOrchestratorActive(orchestrator):
      primaryRouted = sendRhizoDirect(orchestrator, subject, bodyJson, project, sender)
      primaryMode = "orchestrator_direct"
      primaryTarget = orchestrator
    else:
      primaryRouted = sendRhizoMulticast(project, subject, bodyJson, sender)
      primaryMode = "multicast_fallback"
      primaryTarget = "@" & project

    res["dispatched"] = %primaryRouted
    res["primary_mode"] = %primaryMode
    res["primary_target"] = %primaryTarget
    res["subject"] = %subject

    # Secondary Direct Notifications
    var secondaries: seq[string] = @[]
    case event
    of "AUDIT_RATIFIED", "AUDIT_REJECTED":
      if author.len > 0 and author.toLowerAscii != auditor.toLowerAscii and author.toLowerAscii != orchestrator.toLowerAscii:
        let auditSender = if auditor.len > 0: auditor else: sender
        if sendRhizoDirect(author, subject, bodyJson, project, auditSender):
          secondaries.add(author)

    of "STRAND_WOVEN":
      if author.len > 0 and author.toLowerAscii != orchestrator.toLowerAscii:
        if sendRhizoDirect(author, subject, bodyJson, project, sender):
          secondaries.add(author)
      if auditor.len > 0 and auditor.toLowerAscii != author.toLowerAscii and auditor.toLowerAscii != orchestrator.toLowerAscii:
        if sendRhizoDirect(auditor, subject, bodyJson, project, sender):
          secondaries.add(auditor)

    res["secondary_targets"] = %secondaries
    return res

  except CatchableError as e:
    res["error"] = %e.msg
    return res
