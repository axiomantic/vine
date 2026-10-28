# /Users/eek/Development/vine/src/redis_client.nim
# Pure Redis Strand State Client & RESP Protocol Implementation for Vine.
# Invariants:
# 1. Zero external Nimble dependencies (uses std/net & std/nativesockets).
# 2. Embeds scripts/strand.lua at compile time via staticRead.
# 3. Transparently supports compound reverse-path keys (machine_id:path -> task_id).
# 4. Provides hermetic offline fallback for test environments without live Redis.

import std/[net, nativesockets, os, strutils, json, times, tables, uri, options]

const strandLuaScript* = staticRead("../scripts/strand.lua")

type
  RedisConfig* = object
    host*: string
    port*: Port
    password*: string
    db*: int
    prefix*: string
    timeoutMs*: int

var gRedisAvailable*: Option[bool] = none(bool)
var gFallbackStrands*: Table[string, JsonNode] = initTable[string, JsonNode]()
var gFallbackByPath*: Table[string, string] = initTable[string, string]()

proc getMachineId*(): string =
  let v = getEnv("VINE_MACHINE_ID", "").strip()
  if v.len > 0: return v
  let r = getEnv("RHIZO_MACHINE_ID", "").strip()
  if r.len > 0: return r
  let rh = getEnv("RHIZO_HOSTNAME", "").strip()
  if rh.len > 0: return rh
  let h = getEnv("HOSTNAME", "").strip()
  if h.len > 0: return h
  try:
    let nh = getHostName().strip()
    if nh.len > 0: return nh
  except CatchableError: discard
  return "localhost"

proc getRedisPrefix*(): string =
  let vp = getEnv("VINE_REDIS_PREFIX", "").strip()
  if vp.len > 0:
    return if vp.endsWith(":"): vp else: vp & ":"
  let rp = getEnv("RHIZO_REDIS_PREFIX", "").strip()
  if rp.len > 0:
    return if rp.endsWith(":"): rp else: rp & ":"
  return "vine:"

proc loadRedisConfig*(): RedisConfig =
  var rawUrl = getEnv("VINE_REDIS_URL", "").strip()
  if rawUrl.len == 0:
    rawUrl = getEnv("RHIZO_REDIS_URL", "").strip()
  if rawUrl.len == 0:
    rawUrl = getEnv("REDIS_URL", "").strip()
  if rawUrl.len == 0:
    rawUrl = "redis://127.0.0.1:6379/0"

  var cfg = RedisConfig(
    host: "127.0.0.1",
    port: Port(6379),
    password: "",
    db: 0,
    prefix: getRedisPrefix(),
    timeoutMs: 3000
  )

  try:
    if rawUrl.startsWith("redis://") or rawUrl.startsWith("valkey://"):
      let u = parseUri(rawUrl)
      if u.hostname.len > 0: cfg.host = u.hostname
      if u.port.len > 0:
        try: cfg.port = Port(parseInt(u.port))
        except ValueError: discard
      if u.password.len > 0: cfg.password = u.password
      if u.path.len > 1 and u.path.startsWith("/"):
        try: cfg.db = parseInt(u.path[1..^1])
        except ValueError: discard
    elif rawUrl.contains(":"):
      let parts = rawUrl.split(':')
      cfg.host = parts[0]
      try: cfg.port = Port(parseInt(parts[1]))
      except ValueError: discard
    elif rawUrl.len > 0:
      cfg.host = rawUrl
  except CatchableError:
    discard

  return cfg

proc formatRespCommand*(args: openArray[string]): string =
  var b = "*" & $args.len & "\r\n"
  for a in args:
    b.add("$" & $a.len & "\r\n" & a & "\r\n")
  return b

proc readRespResponse*(sock: Socket): JsonNode =
  var line = ""
  sock.readLine(line)
  if line.len == 0:
    return nil
  let prefix = line[0]
  let rest = line[1..^1]

  case prefix
  of '+': # Simple string
    return %rest
  of '-': # Error
    var errObj = newJObject()
    errObj["error"] = %rest
    return errObj
  of ':': # Integer
    try: return %(parseInt(rest))
    except ValueError: return %rest
  of '$': # Bulk string
    let length = parseInt(rest)
    if length < 0:
      return newJNull()
    var payload = newString(length)
    var readTotal = 0
    while readTotal < length:
      let chunk = sock.recv(length - readTotal)
      if chunk.len == 0: break
      for i in 0 ..< chunk.len:
        payload[readTotal + i] = chunk[i]
      readTotal += chunk.len
    var trailing = ""
    sock.readLine(trailing) # Consume trailing CRLF
    # Attempt parsing as JSON if string starts with { or [
    let trimmed = payload.strip()
    if (trimmed.startsWith("{") and trimmed.endsWith("}")) or
       (trimmed.startsWith("[") and trimmed.endsWith("]")):
      try: return parseJson(trimmed)
      except CatchableError: discard
    return %payload
  of '*': # Array
    let count = parseInt(rest)
    if count < 0:
      return newJNull()
    var arr = newJArray()
    for _ in 0 ..< count:
      arr.add(sock.readRespResponse())
    return arr
  else:
    return %line

proc executeRawRedis*(args: openArray[string]): JsonNode =
  let cfg = loadRedisConfig()
  var sock = newSocket()
  try:
    sock.connect(cfg.host, cfg.port, cfg.timeoutMs)
    try: sock.setSockOpt(OptNoDelay, true)
    except CatchableError: discard
    if cfg.password.len > 0:
      sock.send(formatRespCommand(["AUTH", cfg.password]))
      discard sock.readRespResponse()
    if cfg.db > 0:
      sock.send(formatRespCommand(["SELECT", $cfg.db]))
      discard sock.readRespResponse()

    sock.send(formatRespCommand(args))
    let resp = sock.readRespResponse()
    sock.close()
    return resp
  except CatchableError:
    try: sock.close()
    except CatchableError: discard
    return nil

proc isRedisAvailable*(): bool =
  if gRedisAvailable.isSome:
    return gRedisAvailable.get()
  let res = executeRawRedis(["PING"])
  let avail = (res != nil and (res.kind == JString and res.getStr() == "PONG"))
  gRedisAvailable = some(avail)
  return avail

proc evalStrandLua*(action: string, args: openArray[string]): JsonNode =
  if isRedisAvailable():
    let cfg = loadRedisConfig()
    var cmdArgs: seq[string] = @["EVAL", strandLuaScript, "0", cfg.prefix, action]
    for a in args:
      cmdArgs.add(a)
    let resp = executeRawRedis(cmdArgs)
    if resp != nil:
      if resp.kind == JObject and resp.hasKey("error"):
        return resp
      elif resp.kind == JString:
        try: return parseJson(resp.getStr())
        except CatchableError: return resp
      return resp

  # --- HERMETIC OFFLINE FALLBACK ---
  let nowEpoch = getTime().toUnix()
  case action.toLowerAscii
  of "create":
    let strandId = if args.len > 0: args[0].toLowerAscii else: ""
    let project = if args.len > 1: args[1] else: ""
    let strandPath = if args.len > 2: args[2] else: ""
    let branch = if args.len > 3: args[3] else: ""
    let baseBranch = if args.len > 4: args[4] else: "main"
    let baseCommit = if args.len > 5: args[5] else: ""
    let author = if args.len > 6: args[6] else: ""
    let authorPubkey = if args.len > 7: args[7] else: author
    let orchestrator = if args.len > 8: args[8] else: ""
    let canonicalRepo = if args.len > 9: args[9] else: ""
    let machineId = if args.len > 10: args[10] else: getMachineId()
    let tool = if args.len > 11: args[11] else: "git-worktree"
    let parentBranch = if args.len > 12: args[12] else: baseBranch
    let intendedMergeBase = if args.len > 13: args[13] else: baseCommit
    let createdBy = if args.len > 14: args[14] else: orchestrator

    var s = %*{
      "id": strandId,
      "task_id": strandId,
      "project": project,
      "strand_path": strandPath,
      "branch": branch,
      "base_branch": baseBranch,
      "parent_branch": parentBranch,
      "base_commit": baseCommit,
      "intended_merge_base": intendedMergeBase,
      "author": author,
      "author_pubkey": authorPubkey,
      "worker": author,
      "orchestrator": orchestrator,
      "created_by": createdBy,
      "canonical_repo": canonicalRepo,
      "machine_id": machineId,
      "tool": tool,
      "state": "PROVISIONED",
      "status": "PROVISIONED",
      "lifecycle_state": "PROVISIONED",
      "created_at": nowEpoch,
      "submitted_at": 0,
      "ratified_at": 0,
      "rejected_at": 0,
      "woven_at": 0,
      "gate_token": "",
      "audit_token": "",
      "auditor": "",
      "auditor_pubkey": "",
      "rejection_reason": "",
      "notes": ""
    }
    gFallbackStrands[strandId] = s
    if strandPath.len > 0:
      if machineId.len > 0:
        gFallbackByPath[machineId & ":" & strandPath] = strandId
      gFallbackByPath[strandPath] = strandId
    var res = copy(s)
    res["status"] = %"OK"
    return res

  of "submit":
    let strandId = if args.len > 0: args[0].toLowerAscii else: ""
    let gateToken = if args.len > 1: args[1] else: ""
    let author = if args.len > 2: args[2] else: ""
    let authorPubkey = if args.len > 3: args[3] else: ""
    let mergeTreeSha = if args.len > 4: args[4] else: ""
    let headCommit = if args.len > 5: args[5] else: mergeTreeSha

    if not gFallbackStrands.hasKey(strandId):
      var err = newJObject(); err["error"] = %("Strand '" & strandId & "' does not exist"); return err
    var s = gFallbackStrands[strandId]
    s["gate_token"] = %gateToken
    s["state"] = %"SUBMITTED"
    s["status"] = %"READY_FOR_AUDIT"
    s["lifecycle_state"] = %"SUBMITTED"
    s["submitted_at"] = %(nowEpoch)
    if author.len > 0: s["author"] = %author
    if authorPubkey.len > 0: s["author_pubkey"] = %authorPubkey
    if mergeTreeSha.len > 0: s["merge_tree_sha"] = %mergeTreeSha
    if headCommit.len > 0: s["head_commit"] = %headCommit
    gFallbackStrands[strandId] = s
    var res = newJObject()
    res["status"] = %"OK"
    res["id"] = %strandId
    res["state"] = %"SUBMITTED"
    res["gate_token"] = %gateToken
    res["author"] = s["author"]
    return res

  of "ratify":
    let strandId = if args.len > 0: args[0].toLowerAscii else: ""
    let auditorPubkey = if args.len > 1: args[1] else: ""
    let auditorName = if args.len > 2: args[2] else: auditorPubkey
    let auditToken = if args.len > 3: args[3] else: ""
    let notes = if args.len > 4: args[4] else: ""

    if not gFallbackStrands.hasKey(strandId):
      var err = newJObject(); err["error"] = %("Strand '" & strandId & "' does not exist"); return err
    var s = gFallbackStrands[strandId]
    let author = s.getOrDefault("author").getStr("")
    let authorPub = s.getOrDefault("author_pubkey").getStr("")
    if (author.len > 0 and author.toLowerAscii == auditorName.toLowerAscii) or
       (authorPub.len > 0 and authorPub.toLowerAscii == auditorPubkey.toLowerAscii):
      var err = newJObject(); err["error"] = %"Independent auditor required: self-ratification prohibited"; return err
    s["state"] = %"RATIFIED"
    s["status"] = %"AUDIT_RATIFIED"
    s["lifecycle_state"] = %"RATIFIED"
    s["ratified_at"] = %(nowEpoch)
    s["auditor"] = %auditorName
    s["auditor_pubkey"] = %auditorPubkey
    s["audit_token"] = %auditToken
    s["notes"] = %notes
    gFallbackStrands[strandId] = s
    var res = newJObject()
    res["status"] = %"OK"
    res["id"] = %strandId
    res["state"] = %"RATIFIED"
    res["auditor"] = %auditorName
    res["audit_token"] = %auditToken
    return res

  of "reject":
    let strandId = if args.len > 0: args[0].toLowerAscii else: ""
    let auditorPubkey = if args.len > 1: args[1] else: ""
    let auditorName = if args.len > 2: args[2] else: auditorPubkey
    let reason = if args.len > 3: args[3] else: ""
    let notes = if args.len > 4: args[4] else: ""

    if not gFallbackStrands.hasKey(strandId):
      var err = newJObject(); err["error"] = %("Strand '" & strandId & "' does not exist"); return err
    var s = gFallbackStrands[strandId]
    s["state"] = %"REJECTED"
    s["status"] = %"AUDIT_REJECTED"
    s["lifecycle_state"] = %"REJECTED"
    s["rejected_at"] = %(nowEpoch)
    s["auditor"] = %auditorName
    s["auditor_pubkey"] = %auditorPubkey
    s["rejection_reason"] = %reason
    s["notes"] = %notes
    gFallbackStrands[strandId] = s
    var res = newJObject()
    res["status"] = %"OK"
    res["id"] = %strandId
    res["state"] = %"REJECTED"
    res["rejection_reason"] = %reason
    return res

  of "weave":
    let strandId = if args.len > 0: args[0].toLowerAscii else: ""
    let mergeCommit = if args.len > 1: args[1] else: ""
    let byAgent = if args.len > 2: args[2] else: ""

    if not gFallbackStrands.hasKey(strandId):
      var err = newJObject(); err["error"] = %("Strand '" & strandId & "' does not exist"); return err
    var s = gFallbackStrands[strandId]
    let st = s.getOrDefault("state").getStr("")
    if st != "RATIFIED":
      var err = newJObject(); err["error"] = %("Cannot weave unratified strand '" & strandId & "'"); return err
    s["state"] = %"WOVEN"
    s["status"] = %"WOVEN"
    s["lifecycle_state"] = %"WOVEN"
    s["woven_at"] = %(nowEpoch)
    s["merge_commit"] = %mergeCommit
    s["woven_by"] = %byAgent
    gFallbackStrands[strandId] = s
    let p = s.getOrDefault("strand_path").getStr("")
    let m = s.getOrDefault("machine_id").getStr("")
    if p.len > 0:
      if m.len > 0: gFallbackByPath.del(m & ":" & p)
      gFallbackByPath.del(p)
    var res = newJObject()
    res["status"] = %"OK"
    res["id"] = %strandId
    res["state"] = %"WOVEN"
    res["merge_commit"] = %mergeCommit
    return res

  of "update_gate":
    let strandId = if args.len > 0: args[0].toLowerAscii else: ""
    let newState = if args.len > 1: args[1] else: "GATE_PASSED"
    let gateToken = if args.len > 2: args[2] else: ""
    let mergeTreeSha = if args.len > 3: args[3] else: ""
    let testOutputHash = if args.len > 4: args[4] else: ""

    if not gFallbackStrands.hasKey(strandId):
      var err = newJObject(); err["error"] = %("Strand '" & strandId & "' does not exist"); return err
    var s = gFallbackStrands[strandId]
    let statusVal = if newState == "GATE_PASSED": "READY_FOR_WEAVE" else: newState
    s["state"] = %newState
    s["status"] = %statusVal
    s["lifecycle_state"] = %newState
    s["gate_token"] = %gateToken
    s["merge_tree_sha"] = %mergeTreeSha
    s["test_output_hash"] = %testOutputHash
    s["verified_at"] = %(nowEpoch)

    let extraJson = if args.len > 5: args[5] else: ""
    if extraJson.len > 0:
      try:
        let ej = parseJson(extraJson)
        if ej.kind == JObject:
          for k, v in ej:
            s[k] = v
      except CatchableError: discard

    gFallbackStrands[strandId] = s
    var res = newJObject()
    res["status"] = %"OK"
    res["id"] = %strandId
    res["state"] = %newState
    res["gate_token"] = %gateToken
    res["merge_tree_sha"] = %mergeTreeSha
    return res

  of "get":
    let query = if args.len > 0: args[0].toLowerAscii else: ""
    var targetId = query
    if not gFallbackStrands.hasKey(targetId) and gFallbackByPath.hasKey(args[0]):
      targetId = gFallbackByPath[args[0]].toLowerAscii
    if not gFallbackStrands.hasKey(targetId):
      var err = newJObject(); err["error"] = %("Strand '" & query & "' does not exist"); return err
    var res = newJObject()
    res["status"] = %"OK"
    res["strand"] = gFallbackStrands[targetId]
    return res

  of "resolve_path":
    let p = if args.len > 0: args[0] else: ""
    let m = if args.len > 1: args[1] else: ""
    var targetId = ""
    if m.len > 0 and gFallbackByPath.hasKey(m & ":" & p):
      targetId = gFallbackByPath[m & ":" & p]
    elif gFallbackByPath.hasKey(p):
      targetId = gFallbackByPath[p]
    if targetId.len == 0 or not gFallbackStrands.hasKey(targetId):
      var res = newJObject(); res["status"] = %"NOT_FOUND"; return res
    var res = newJObject()
    res["status"] = %"OK"
    res["id"] = %targetId
    res["strand"] = gFallbackStrands[targetId]
    return res

  of "list":
    let stateFilter = if args.len > 0: args[0].toLowerAscii else: ""
    let projectFilter = if args.len > 1: args[1].toLowerAscii else: ""
    var arr = newJArray()
    for sid, s in gFallbackStrands:
      let st = s.getOrDefault("state").getStr("").toLowerAscii
      let pr = s.getOrDefault("project").getStr("").toLowerAscii
      if (stateFilter.len == 0 or stateFilter == "*" or st == stateFilter) and
         (projectFilter.len == 0 or projectFilter == "*" or pr == projectFilter):
        arr.add(s)
    var res = newJObject()
    res["status"] = %"OK"
    res["count"] = %(arr.len)
    res["strands"] = arr
    return res

  of "prune", "delete":
    let strandId = if args.len > 0: args[0].toLowerAscii else: ""
    if gFallbackStrands.hasKey(strandId):
      let s = gFallbackStrands[strandId]
      let p = s.getOrDefault("strand_path").getStr("")
      let m = s.getOrDefault("machine_id").getStr("")
      if p.len > 0:
        if m.len > 0: gFallbackByPath.del(m & ":" & p)
        gFallbackByPath.del(p)
      gFallbackStrands.del(strandId)
    var res = newJObject()
    res["status"] = %"OK"
    res["action"] = %"pruned"
    res["id"] = %strandId
    return res

  else:
    var err = newJObject()
    err["error"] = %("Unknown action: " & action)
    return err

# --- PUBLIC HIGH-LEVEL HELPERS ---

proc createStrandRedis*(
  strandId: string,
  project: string,
  strandPath: string,
  branch: string,
  baseBranch: string,
  baseCommit: string,
  author: string,
  authorPubkey: string,
  orchestrator: string,
  canonicalRepo: string,
  machineId: string = "",
  tool: string = "git-worktree",
  parentBranch: string = "",
  intendedMergeBase: string = "",
  createdBy: string = ""
): JsonNode =
  let effMachine = if machineId.len > 0: machineId else: getMachineId()
  let effParent = if parentBranch.len > 0: parentBranch else: baseBranch
  let effMergeBase = if intendedMergeBase.len > 0: intendedMergeBase else: baseCommit
  let effCreatedBy = if createdBy.len > 0: createdBy else: orchestrator
  return evalStrandLua("create", [
    strandId, project, strandPath, branch, baseBranch, baseCommit,
    author, authorPubkey, orchestrator, canonicalRepo,
    effMachine, tool, effParent, effMergeBase, effCreatedBy
  ])

proc submitStrandRedis*(
  strandId: string,
  gateToken: string,
  author: string = "",
  authorPubkey: string = "",
  mergeTreeSha: string = "",
  headCommit: string = ""
): JsonNode =
  let effHead = if headCommit.len > 0: headCommit else: mergeTreeSha
  return evalStrandLua("submit", [strandId, gateToken, author, authorPubkey, mergeTreeSha, effHead])

proc ratifyStrandRedis*(
  strandId: string,
  auditorPubkey: string,
  auditorName: string,
  auditToken: string,
  notes: string = "",
  antiBlinkFloor: int = 0
): JsonNode =
  return evalStrandLua("ratify", [strandId, auditorPubkey, auditorName, auditToken, notes, $antiBlinkFloor])

proc rejectStrandRedis*(
  strandId: string,
  auditorPubkey: string,
  auditorName: string,
  reason: string,
  notes: string = ""
): JsonNode =
  return evalStrandLua("reject", [strandId, auditorPubkey, auditorName, reason, notes])

proc weaveStrandRedis*(
  strandId: string,
  mergeCommit: string,
  byAgent: string = ""
): JsonNode =
  return evalStrandLua("weave", [strandId, mergeCommit, byAgent])

proc updateGateRedis*(
  strandId: string,
  state: string,
  gateToken: string = "",
  mergeTreeSha: string = "",
  testOutputHash: string = "",
  extraJson: string = ""
): JsonNode =
  return evalStrandLua("update_gate", [strandId, state, gateToken, mergeTreeSha, testOutputHash, extraJson])

proc getStrandRedis*(idOrPath: string): JsonNode =
  let res = evalStrandLua("get", [idOrPath])
  if res != nil and res.kind == JObject and res.hasKey("strand"):
    return res["strand"]
  return res

proc listStrandsRedis*(stateFilter: string = "", projectFilter: string = ""): JsonNode =
  return evalStrandLua("list", [stateFilter, projectFilter])

proc resolveStrandByPathRedis*(path: string, machineId: string = ""): JsonNode =
  let effMachine = if machineId.len > 0: machineId else: getMachineId()
  let res = evalStrandLua("resolve_path", [path, effMachine])
  if res != nil and res.kind == JObject and res.hasKey("strand"):
    return res["strand"]
  return nil

proc pruneStrandRedis*(strandId: string): JsonNode =
  return evalStrandLua("prune", [strandId])
