# /Users/eek/Development/vine/src/gate.nim
# The Two-Key Integration Gate for Braid (Zero Green Mirage).

import std/[os, osproc, strutils, json, times]
import config, strand, crypto, process, notify, redis_client
export notify

const
  ExitGateSuccess* = 0
  ExitGateConflict* = 1
  ExitGateFailure* = 2
  ExitGateTwoPointViolation* = 3
  ExitGateTimeout* = 4
  ExitGateChangelogViolation* = 5
  ExitGateAuditViolation* = 6
  ExitGateDefeatDeviceViolation* = 7

const ChangelogFilenames* = [
  "CHANGELOG.md", "changelog.md",
  "CHANGES.md", "changes.md",
  "HISTORY.md", "history.md",
  "NEWS.md", "news.md"
]

proc findChangelogFile*(dir: string): string =
  for fn in ChangelogFilenames:
    if fileExists(dir / fn):
      return fn
  return ""

proc hasUnreleasedSection*(content: string): bool =
  for line in content.splitLines():
    let t = line.strip()
    if t.startsWith("## "):
      var heading = t[3..^1].strip().toLowerAscii
      if heading.startsWith("[") and heading.find(']') > 0:
        heading = heading[1 ..< heading.find(']')].strip()
      if heading == "unreleased" or heading.startsWith("unreleased"):
        return true
  return false

proc ensureUnreleasedSection*(content: string): string =
  if hasUnreleasedSection(content):
    return content

  var lines = content.splitLines()
  var insertIdx = -1

  for i, line in lines:
    let t = line.strip()
    if t.startsWith("## "):
      let lower = t.toLowerAscii
      if not lower.contains("changelog") and not lower.contains("table of contents"):
        insertIdx = i
        break

  if insertIdx >= 0:
    lines = lines[0 ..< insertIdx] & @["## [Unreleased]", "", "### Added", ""] & lines[insertIdx .. ^1]
  else:
    if lines.len > 0 and lines[^1].strip().len > 0:
      lines.add("")
    lines.add("## [Unreleased]")
    lines.add("")
    lines.add("### Added")
    lines.add("")

  return lines.join("\n")

proc addChangelogEntry*(content: string, entry: string, section: string = "Added"): string =
  let ensured = ensureUnreleasedSection(content)
  var lines = ensured.splitLines()

  var unreleasedIdx = -1
  var nextReleaseIdx = lines.len

  for i, line in lines:
    let t = line.strip()
    if t.startsWith("## "):
      var heading = t[3..^1].strip().toLowerAscii
      if heading.startsWith("[") and heading.find(']') > 0:
        heading = heading[1 ..< heading.find(']')].strip()
      if heading == "unreleased" or heading.startsWith("unreleased"):
        unreleasedIdx = i
      elif unreleasedIdx >= 0:
        nextReleaseIdx = i
        break

  if unreleasedIdx < 0:
    return content & "\n\n## [Unreleased]\n\n### " & section & "\n- " & entry & "\n"

  let effSection = if section.strip().len > 0: section.strip() else: "Added"
  let targetSecHeader = "### " & effSection

  var secIdx = -1
  for i in (unreleasedIdx + 1) ..< nextReleaseIdx:
    let t = lines[i].strip()
    if t.startsWith("### "):
      let secName = t[4..^1].strip().toLowerAscii
      if secName == effSection.toLowerAscii or secName == ("[" & effSection.toLowerAscii & "]"):
        secIdx = i
        break

  let entryLine = "- " & entry.strip()

  if secIdx >= 0:
    var insertAt = secIdx + 1
    while insertAt < nextReleaseIdx:
      let t = lines[insertAt].strip()
      if t.startsWith("- ") or t.startsWith("* "):
        inc insertAt
      elif t.len == 0 and insertAt + 1 < nextReleaseIdx and (lines[insertAt + 1].strip().startsWith("- ") or lines[insertAt + 1].strip().startsWith("* ")):
        inc insertAt
      else:
        break
    lines.insert(entryLine, insertAt)
  else:
    var insertAt = unreleasedIdx + 1
    while insertAt < nextReleaseIdx and lines[insertAt].strip().len == 0:
      inc insertAt
    lines = lines[0 ..< insertAt] & @[targetSecHeader, entryLine, ""] & lines[insertAt .. ^1]

  return lines.join("\n")

proc doChangelogOperation*(
  dir: string = "",
  entry: string = "",
  section: string = "Added",
  ensureUnreleased: bool = false,
  checkOnly: bool = false,
  baseRefParam: string = ""
): tuple[output: string, exitCode: int] =
  let targetDir = if dir.len > 0: dir.normalizedPath else: getCurrentDir()
  var changelogFile = findChangelogFile(targetDir)

  if checkOnly:
    if changelogFile.len == 0:
      return ("No changelog file detected in project.", 0)
    let fullPath = targetDir / changelogFile
    let content = try: readFile(fullPath) except CatchableError as e: return ("Error reading " & fullPath & ": " & e.msg, 1)
    if not hasUnreleasedSection(content):
      return ("Violation: " & changelogFile & " is missing '## [Unreleased]' section.", ExitGateChangelogViolation)
    let baseRef = if baseRefParam.len > 0: baseRefParam else: "HEAD"
    let diffCmd = "git -C " & quoteShell(targetDir) & " diff --name-only " & quoteShell(baseRef)
    let (dOut, dCode) = execCmdEx(diffCmd)
    if dCode == 0:
      for line in dOut.splitLines():
        let norm = line.strip().replace('\\', '/').toLowerAscii
        if norm == changelogFile.toLowerAscii or norm.endsWith("/" & changelogFile.toLowerAscii):
          return ("Clean: " & changelogFile & " is modified in diff against " & baseRef, 0)
    return ("Violation: " & changelogFile & " is NOT modified in diff against " & baseRef, ExitGateChangelogViolation)

  if changelogFile.len == 0:
    if entry.len > 0 or ensureUnreleased:
      changelogFile = "CHANGELOG.md"
      let initialContent = "# Changelog\n\nAll notable changes to this project will be documented in this file.\n\n## [Unreleased]\n\n### " & section & "\n\n"
      writeFile(targetDir / changelogFile, initialContent)
      if entry.len > 0:
        let updated = addChangelogEntry(initialContent, entry, section)
        writeFile(targetDir / changelogFile, updated)
        return ("[CHANGELOG] Created CHANGELOG.md and added entry to '## [Unreleased]' (### " & section & ").", 0)
      else:
        return ("[CHANGELOG] Created CHANGELOG.md with '## [Unreleased]' section.", 0)
    else:
      return ("No changelog file found in repository.", 1)

  let fullPath = targetDir / changelogFile
  let content = try: readFile(fullPath) except CatchableError as e: return ("Error reading " & fullPath & ": " & e.msg, 1)

  if ensureUnreleased and entry.len == 0:
    if hasUnreleasedSection(content):
      return ("[CHANGELOG] '## [Unreleased]' section already exists in " & changelogFile, 0)
    let updated = ensureUnreleasedSection(content)
    try: writeFile(fullPath, updated)
    except CatchableError as e: return ("Error writing " & fullPath & ": " & e.msg, 1)
    return ("[CHANGELOG] Created '## [Unreleased]' section in " & changelogFile, 0)

  if entry.len > 0:
    let updated = addChangelogEntry(content, entry, section)
    try: writeFile(fullPath, updated)
    except CatchableError as e: return ("Error writing " & fullPath & ": " & e.msg, 1)
    return ("[CHANGELOG] Added entry to '## [Unreleased]' (### " & section & ") in " & changelogFile, 0)

  return ("Usage: vine changelog <entry> [--section <Added|Changed|Fixed|Removed>] [--ensure-unreleased] [--check]", 1)

proc detectTestCommand*(dir: string): string =
  if fileExists(dir / "Cargo.toml"): return "cargo test"
  if fileExists(dir / "wscript"): return "./waf build"
  if fileExists(dir / "pyproject.toml"): return "uv run pytest"
  if fileExists(dir / "package.json"):
    if fileExists(dir / "pnpm-lock.yaml"): return "pnpm test"
    return "npm test"
  if fileExists(dir / "build" / "CTestTestfile.cmake"):
    return "ctest --test-dir build --output-on-failure"
  if fileExists(dir / "CMakePresets.json") or fileExists(dir / "CMakeLists.txt"):
    return "ctest --test-dir build --output-on-failure"
  for kind, p in walkDir(dir):
    if kind == pcFile and p.endsWith(".nimble"): return "nimble test"
  return ""

type
  DefeatDeviceFinding* = object
    path*: string
    lineNum*: int
    line*: string
    reason*: string

proc scanForDefeatDevices*(strandDir: string, diffBase: string, branch: string = "HEAD"): seq[DefeatDeviceFinding] =
  result = @[]
  var cmd = "git -C " & quoteShell(strandDir) & " diff -U0 " & quoteShell(diffBase) & "..." & quoteShell(branch)
  if diffBase == branch or diffBase == "HEAD":
    cmd = "git -C " & quoteShell(strandDir) & " diff -U0 HEAD"
  let (dOut, dCode) = try: execCmdEx(cmd) except CatchableError: ("", 1)
  if dCode != 0 or dOut.strip().len == 0:
    return

  var curFile = ""
  var curLineNum = 0

  for rawLine in dOut.splitLines():
    if rawLine.startsWith("diff --git "):
      curFile = ""
      curLineNum = 0
      continue
    elif rawLine.startsWith("+++ b/"):
      curFile = rawLine[6..^1].strip().replace('\\', '/')
      continue
    elif rawLine.startsWith("@@ "):
      let plusIdx = rawLine.find('+')
      if plusIdx > 0:
        let rest = rawLine[plusIdx + 1 .. ^1]
        let spaceIdx = rest.find(' ')
        let chunk = if spaceIdx > 0: rest[0 ..< spaceIdx] else: rest
        let commaIdx = chunk.find(',')
        let startLineStr = if commaIdx > 0: chunk[0 ..< commaIdx] else: chunk
        try: curLineNum = parseInt(startLineStr)
        except CatchableError: curLineNum = 0
      continue

    if curFile.len == 0: continue
    let norm = curFile.toLowerAscii
    if not (norm.startsWith("src/") or norm.startsWith("bin/") or norm.startsWith("lib/") or norm.startsWith("app/")):
      continue
    if norm.startsWith("tests/") or norm.startsWith("test/") or
       norm.contains("/test/") or norm.contains("/tests/") or
       norm.contains("/fixtures/") or norm.contains("/fixture/") or
       norm.endsWith(".md") or norm.endsWith(".json") or norm.endsWith(".toml") or
       norm.endsWith(".yaml") or norm.endsWith(".yml"):
      continue

    if rawLine.startsWith("+") and not rawLine.startsWith("+++"):
      let addedLine = rawLine[1..^1]
      let trimmed = addedLine.strip()
      let lower = trimmed.toLowerAscii

      if trimmed.len == 0 or trimmed.startsWith("#") or trimmed.startsWith("//") or
         trimmed.startsWith("/*") or trimmed.startsWith("*"):
        inc curLineNum
        continue

      var isInterceptor = false
      var reason = ""

      let hasQueryVar = lower.contains(" in q") or lower.contains(" in query") or
                        lower.contains(" in prompt") or lower.contains(" in user_query") or
                        lower.contains(" in userquery") or lower.contains(" in input_query") or
                        lower.contains("q.contains(") or lower.contains("query.contains(") or
                        lower.contains("prompt.contains(") or lower.contains("input.contains(")

      let hasBenchmarkKeywords = lower.contains("flight game") or lower.contains("nim_3d_flight_game") or
                                 lower.contains("webworker") or lower.contains("benchmark_query")

      let hasTheatricalMocks = lower.contains("epistemicquestions") or lower.contains("mockquestionnaire") or
                               lower.contains("isdeepprojectcreationquery")

      if hasTheatricalMocks:
        isInterceptor = true
        reason = "Theatrical mock questionnaire or hardcoded project query interceptor detected"
      elif hasQueryVar and (hasBenchmarkKeywords or (lower.count(" or ") >= 1 and (lower.contains("\"") or lower.contains("'")))):
        isInterceptor = true
        reason = "Prompt keyword interceptor detected matching user query variables ('in q', 'query.contains', etc.) with domain/benchmark branches"
      elif hasBenchmarkKeywords and (lower.contains("proc ") or lower.contains("def ") or lower.contains("fn ") or lower.contains("function ")):
        isInterceptor = true
        reason = "Hardcoded benchmark keyword routing procedure detected in application code"

      if isInterceptor:
        result.add(DefeatDeviceFinding(
          path: curFile,
          lineNum: curLineNum,
          line: trimmed,
          reason: reason
        ))

      inc curLineNum

proc doBraidGate*(
  branchParam: string = "",
  baseRefParam: string = "HEAD",
  strandDirParam: string = "",
  skipTests: bool = false,
  testCmdParam: string = "",
  allowNoTests: bool = false,
  allowTestOnly: bool = false,
  timeoutSecParam: float = 0.0,
  allowNoChangelog: bool = false,
  autoEnsureUnreleased: bool = false,
  submit: bool = false,
  authorParam: string = "",
  allowDefeatDevices: bool = false
): tuple[output: JsonNode, exitCode: int] =
  var strandDir = if strandDirParam.len > 0: strandDirParam.normalizedPath else: getCurrentDir()
  var manifest = findStrandManifest(if strandDirParam.len > 0: strandDirParam else: branchParam)
  if manifest == nil and strandDirParam.len == 0:
    manifest = findStrandManifest(strandDir)
  if manifest != nil and manifest.hasKey("strand_path") and dirExists(manifest["strand_path"].getStr):
    strandDir = manifest["strand_path"].getStr.normalizedPath

  let branch = if branchParam.len > 0 and execCmdEx("git -C " & quoteShell(strandDir) & " rev-parse --verify " & quoteShell(branchParam)).exitCode == 0:
                 branchParam
               elif manifest != nil and manifest.hasKey("branch"):
                 manifest["branch"].getStr()
               elif branchParam.len > 0:
                 branchParam
               else:
                 let (outp, code) = execCmdEx("git -C " & quoteShell(strandDir) & " rev-parse --abbrev-ref HEAD")
                 if code == 0: outp.strip() else: "HEAD"

  let baseRef = if baseRefParam.len > 0 and baseRefParam != "HEAD": baseRefParam
                elif manifest != nil and manifest.hasKey("base_branch"): manifest["base_branch"].getStr()
                else: "HEAD"

  let cfg = loadVineConfig(findVineConfigPath(strandDir))

  var effectiveTimeout = 180.0
  let envTimeout = getEnv("VINE_GATE_TIMEOUT", "")
  if envTimeout.len > 0:
    try: effectiveTimeout = parseFloat(envTimeout)
    except CatchableError: discard
  if cfg.gateTimeout > 0.0:
    effectiveTimeout = cfg.gateTimeout
  if timeoutSecParam > 0.0:
    effectiveTimeout = timeoutSecParam
  let prevStatus = if manifest != nil and manifest.hasKey("status"): manifest["status"].getStr() else: ""

  # Track gate evaluation in Redis
  let strandTaskId = if manifest != nil and manifest.hasKey("task_id"): manifest["task_id"].getStr("")
                     elif manifest != nil and manifest.hasKey("id"): manifest["id"].getStr("")
                     else: ""
  if strandTaskId.len > 0:
    discard updateGateRedis(strandTaskId, "GATE_EVALUATING")

  var res = newJObject()
  res["branch"] = %branch
  res["base_ref"] = %baseRef
  res["strand_path"] = %strandDir

  # --- KEY 1: In-Memory Mechanical Conflict Gate ---
  let t0 = getTime().toUnixFloat()
  let cmd = "git -C " & quoteShell(strandDir) & " merge-tree --write-tree " & quoteShell(baseRef) & " " & quoteShell(branch)
  let (mtOut, mtCode) = try:
    execCmdEx(cmd)
  except CatchableError as e:
    (e.msg, 1)
  let latencyMs = (getTime().toUnixFloat() - t0) * 1000.0
  res["mechanical_gate_ms"] = %latencyMs

  if mtCode != 0:
    res["status"] = %"conflict"
    res["clean"] = %false
    res["key1_mechanical"] = %"FAIL"
    var conflictLines = newJArray()
    for line in mtOut.splitLines():
      let t = line.strip()
      if t.len > 0: conflictLines.add(%t)
    res["conflicts"] = conflictLines

    if strandTaskId.len > 0:
      discard updateGateRedis(strandTaskId, "CONFLICTED")

    return (res, 1)

  let treeSha = mtOut.strip().splitLines()[0]
  res["key1_mechanical"] = %"PASS"
  res["merge_tree_sha"] = %treeSha

  # --- TWO-POINT DIFF & CONSUMER CALL-SITE VERIFICATION ---
  if not allowTestOnly:
    let diffBase = if baseRef.len > 0 and baseRef != "HEAD": baseRef
                   elif manifest != nil and manifest.hasKey("base_branch"): manifest["base_branch"].getStr()
                   elif manifest != nil and manifest.hasKey("base_commit"): manifest["base_commit"].getStr()
                   else: "main"
    let diffCmd = "git -C " & quoteShell(strandDir) & " diff --name-status " & quoteShell(diffBase) & "..." & quoteShell(branch)
    let (dOut, dCode) = execCmdEx(diffCmd)
    if dCode == 0 and dOut.strip().len > 0:
      var diffFiles: seq[string] = @[]
      var rawDiffFiles: seq[string] = @[]
      var diffStatuses: seq[tuple[status: char, path: string]] = @[]
      var appFilesChanged = 0
      var testFilesChanged = 0
      var newCapabilities: seq[string] = @[]

      for line in dOut.splitLines():
        let trimmed = line.strip()
        if trimmed.len < 2: continue
        let parts = trimmed.split('\t')
        if parts.len < 2: continue
        let statusCode = parts[0][0]
        let filePath = parts[1].strip()
        let normPath = filePath.replace('\\', '/')
        rawDiffFiles.add(normPath)

        # Ignore coordination metadata & root non-source files
        if normPath in [".envrc", ".gitignore", "vine.toml", "README.md", "LICENSE"] or
           normPath.startsWith(".git") or normPath.startsWith(".rhizo"):
          continue

        diffFiles.add(normPath)
        diffStatuses.add((statusCode, normPath))

        if normPath.startsWith("tests/") or normPath.startsWith("test/"):
          inc testFilesChanged
        elif normPath.startsWith("src/") or normPath.startsWith("bin/") or
             normPath.startsWith("lib/") or normPath.startsWith("app/"):
          inc appFilesChanged
          if statusCode == 'A':
            newCapabilities.add(normPath)

      # Invariant 1: Reject strands where 100% of changes are in tests/
      if diffFiles.len > 0 and testFilesChanged == diffFiles.len:
        res["status"] = %"two_point_diff_failed"
        res["clean"] = %false
        res["two_point_diff"] = %"FAIL"
        res["two_point_diff_error"] = %"Two-Point Diff Violation: 100% of changes are in tests/. Deliverable must include production capability in application source files (src/, bin/, etc.)."
        if strandTaskId.len > 0:
          discard updateGateRedis(strandTaskId, "GATE_FAILED")
        return (res, 3)

      # Invariant 2: Newly introduced capabilities must have a consumer call-site in application source files
      for newCap in newCapabilities:
        let capName = newCap.splitPath.tail.changeFileExt("") # e.g. "auth" from "src/auth.nim"
        if capName.len < 2: continue
        var hasConsumer = false

        # Check other changed application source files in diff
        for (st, path) in diffStatuses:
          if (path.startsWith("src/") or path.startsWith("bin/") or path.startsWith("lib/") or path.startsWith("app/")) and path != newCap:
            let fullPath = strandDir / path
            if fileExists(fullPath):
              try:
                if readFile(fullPath).contains(capName):
                  hasConsumer = true
                  break
              except CatchableError: discard

        # If not in diff, search existing source files in application directories
        if not hasConsumer:
          for appSub in ["src", "bin", "lib", "app"]:
            let appDir = strandDir / appSub
            if dirExists(appDir):
              for p in walkDirRec(appDir):
                if p.normalizedPath != (strandDir / newCap).normalizedPath:
                  try:
                    if readFile(p).contains(capName):
                      hasConsumer = true
                      break
                  except CatchableError: discard
              if hasConsumer: break

        if not hasConsumer:
          res["status"] = %"two_point_diff_failed"
          res["clean"] = %false
          res["two_point_diff"] = %"FAIL"
          res["two_point_diff_error"] = %("Two-Point Diff Violation: Newly introduced capability '" & newCap &
            "' lacks a consumer call-site in application source files (src/, bin/, etc.). Shelfware without production caller is prohibited.")
          if strandTaskId.len > 0:
            discard updateGateRedis(strandTaskId, "GATE_FAILED")
          return (res, 3)

      res["two_point_diff"] = %"PASS"

      # --- CHANGELOG GATE (Unreleased Section Verification) ---
      let changelogFile = findChangelogFile(strandDir)
      let effectiveAllowNoChangelog = allowNoChangelog or cfg.allowNoChangelog

      if changelogFile.len > 0:
        res["changelog_file"] = %changelogFile
        var changelogChanged = false
        for p in rawDiffFiles:
          let low = p.toLowerAscii
          if low == changelogFile.toLowerAscii or low.endsWith("/" & changelogFile.toLowerAscii):
            changelogChanged = true
            break

        if not effectiveAllowNoChangelog:
          if not changelogChanged:
            res["status"] = %"changelog_violation"
            res["clean"] = %false
            res["changelog_gate"] = %"FAIL"
            res["changelog_error"] = %("Changelog Gate Violation: Repository contains '" & changelogFile &
              "', but this strand diff does not include a changelog update. Record your deliverable under the '## [Unreleased]' section (or run 'vine changelog \"<entry>\"' or pass --allow-no-changelog).")
            if strandTaskId.len > 0:
              discard updateGateRedis(strandTaskId, "GATE_FAILED")
            return (res, ExitGateChangelogViolation)

          let changelogFullPath = strandDir / changelogFile
          if fileExists(changelogFullPath):
            let clContent = readFile(changelogFullPath)
            if not hasUnreleasedSection(clContent):
              if autoEnsureUnreleased:
                let updated = ensureUnreleasedSection(clContent)
                writeFile(changelogFullPath, updated)
                res["changelog_gate"] = %"PASS (auto-ensured unreleased section)"
              else:
                res["status"] = %"changelog_violation"
                res["clean"] = %false
                res["changelog_gate"] = %"FAIL"
                res["changelog_error"] = %("Changelog Gate Violation: '" & changelogFile &
                  "' is modified in strand, but is missing an '## [Unreleased]' section. Add or run 'vine changelog --ensure-unreleased'.")
                if strandTaskId.len > 0:
                  discard updateGateRedis(strandTaskId, "GATE_FAILED")
                return (res, ExitGateChangelogViolation)
            else:
              res["changelog_gate"] = %"PASS"
        else:
          res["changelog_gate"] = %"SKIPPED (allow-no-changelog)"
      else:
        res["changelog_gate"] = %"SKIPPED (no changelog in repository)"
    else:
      res["two_point_diff"] = %"PASS"
      res["changelog_gate"] = %"SKIPPED (no changes in diff)"
  else:
    res["two_point_diff"] = %"SKIPPED (allow-test-only)"
    res["changelog_gate"] = %"SKIPPED (allow-test-only)"

  # --- ANTI-DEFEAT-DEVICE SCAN (Volkswagen Defeat Device & Benchmark Interceptor Detection) ---
  let effAllowDefeat = allowDefeatDevices or cfg.allowDefeatDevices
  if not effAllowDefeat:
    let diffBase = if baseRef.len > 0 and baseRef != "HEAD": baseRef
                   elif manifest != nil and manifest.hasKey("base_branch"): manifest["base_branch"].getStr()
                   elif manifest != nil and manifest.hasKey("base_commit"): manifest["base_commit"].getStr()
                   else: "main"
    let defeatFindings = scanForDefeatDevices(strandDir, diffBase, branch)
    if defeatFindings.len > 0:
      res["status"] = %"defeat_device_detected"
      res["clean"] = %false
      res["defeat_device_gate"] = %"FAIL"
      var fArr = newJArray()
      for f in defeatFindings:
        var fObj = newJObject()
        fObj["file"] = %f.path
        fObj["line_number"] = %f.lineNum
        fObj["line"] = %f.line
        fObj["reason"] = %f.reason
        fArr.add(fObj)
      res["defeat_devices"] = fArr
      res["defeat_device_error"] = %(
        "Volkswagen Defeat Device Violation: Prompt/query keyword interceptor detected in application code (" &
        defeatFindings[0].path & ":" & $defeatFindings[0].lineNum & "). " &
        "Deliverables that bypass genuine execution pipelines or emit static mock questionnaires to fake benchmark compliance are strictly prohibited. Pass --allow-defeat-devices to bypass."
      )
      if strandTaskId.len > 0:
        discard updateGateRedis(strandTaskId, "GATE_FAILED")
      return (res, ExitGateDefeatDeviceViolation)
    else:
      res["defeat_device_gate"] = %"PASS"
  else:
    res["defeat_device_gate"] = %"SKIPPED (allow-defeat-devices)"

  # --- KEY 2: Live Compiler & Test Suite Gate (Anti-Green Mirage) ---
  var testOutput = ""
  if not skipTests:
    let manifestTestCmd = if manifest != nil and manifest.hasKey("test_command"): manifest["test_command"].getStr() else: ""
    let testCmd = if testCmdParam.len > 0: testCmdParam
                  elif manifestTestCmd.len > 0: manifestTestCmd
                  elif cfg.testCommand.len > 0: cfg.testCommand
                  else: detectTestCommand(strandDir)
    if testCmd.len > 0:
      res["test_command"] = %testCmd
      let (tOut, tCode, timedOut, elapsedSec) = try:
        execCmdExWithTimeout(testCmd, timeoutSec = effectiveTimeout, workingDir = strandDir)
      except CatchableError as e:
        (e.msg, 1, false, 0.0)
      testOutput = tOut
      let testDurationMs = elapsedSec * 1000.0
      res["test_duration_ms"] = %testDurationMs

      if timedOut:
        let forensicEnvelope =
          "================================================================================\n" &
          "🚨 [GATE TIMEOUT] Semantic Test Suite Frozen\n" &
          "================================================================================\n" &
          "Command      : " & testCmd & "\n" &
          "Elapsed Time : " & formatFloat(elapsedSec, ffDecimal, 2) & "s (timeout threshold: " & formatFloat(effectiveTimeout, ffDecimal, 1) & "s)\n" &
          "--------------------------------------------------------------------------------\n" &
          "CAPTURED OUTPUT UP TO FREEZE POINT:\n" &
          (if tOut.strip().len > 0: tOut.strip() else: "(no output captured before freeze)") & "\n" &
          "--------------------------------------------------------------------------------\n" &
          "[GATE TIMEOUT] Semantic test suite frozen. Do NOT bypass or skip tests. Investigate deadlocks, port collisions, unhandled socket hangs, or infinite loops.\n" &
          "================================================================================"

        res["status"] = %"gate_timeout"
        res["clean"] = %false
        res["key2_semantic"] = %"TIMEOUT"
        res["timeout_sec"] = %effectiveTimeout
        res["elapsed_sec"] = %elapsedSec
        res["compiler_output"] = %forensicEnvelope
        res["forensic_envelope"] = %forensicEnvelope

        if strandTaskId.len > 0:
          var extraObj = newJObject()
          extraObj["timed_out_command"] = %testCmd
          extraObj["timeout_elapsed_sec"] = %elapsedSec
          discard updateGateRedis(strandTaskId, "GATE_TIMEOUT", extraJson = $extraObj)

        return (res, EXIT_GATE_TIMEOUT)

      if tCode != 0:
        res["status"] = %"semantic_failure"
        res["clean"] = %false
        res["key2_semantic"] = %"FAIL"
        res["compiler_output"] = %tOut.strip()

        if strandTaskId.len > 0:
          discard updateGateRedis(strandTaskId, "GATE_FAILED")

        return (res, 2)
      res["key2_semantic"] = %"PASS"
    elif allowNoTests:
      res["key2_semantic"] = %"SKIPPED (no test runner detected; allowed via --allow-no-tests)"
      testOutput = "NO_TESTS_ALLOWED"
    else:
      res["status"] = %"semantic_failure"
      res["clean"] = %false
      res["key2_semantic"] = %"FAIL (no test runner detected)"
      res["compiler_output"] = %"Zero tests executed: no test runner detected in strand. To prevent Green Mirage, pass --allow-no-tests if this repository does not have tests."

      if strandTaskId.len > 0:
        discard updateGateRedis(strandTaskId, "GATE_FAILED")

      return (res, 2)
  else:
    if allowNoTests:
      res["key2_semantic"] = %"SKIPPED (requested)"
      testOutput = "TESTS_SKIPPED"
    else:
      res["status"] = %"semantic_failure"
      res["clean"] = %false
      res["key2_semantic"] = %"FAIL (tests skipped without --allow-no-tests)"
      res["compiler_output"] = %"Zero tests executed: --skip-tests was provided without --allow-no-tests. Gate failed to prevent Green Mirage."
      if strandTaskId.len > 0:
        discard updateGateRedis(strandTaskId, "GATE_FAILED")
      return (res, 2)

  # Both Keys and Two-Point Diff Passed!
  let testOutputHash = sha256(testOutput)
  let gateToken = computeGateToken(treeSha, testOutputHash)

  res["status"] = %"green"
  res["clean"] = %true
  res["merge_tree_sha"] = %treeSha
  res["test_output_hash"] = %testOutputHash
  res["gate_token"] = %gateToken

  # Update strand state in Redis (Zero On-Disk JSON)
  if strandTaskId.len > 0:
    if submit:
      var effAuthor = authorParam
      if effAuthor.len == 0:
        if manifest != nil and manifest.hasKey("author"): effAuthor = manifest["author"].getStr()
        elif manifest != nil and manifest.hasKey("worker_name"): effAuthor = manifest["worker_name"].getStr()
        elif getEnv("RHIZO_AGENT_NAME").len > 0: effAuthor = getEnv("RHIZO_AGENT_NAME")
        else: effAuthor = getEnv("USER", "worker")
      discard submitStrandRedis(strandTaskId, gateToken, effAuthor, effAuthor, treeSha)
      res["status"] = %"ready_for_audit"
      res["author"] = %effAuthor
    elif prevStatus == "AUDIT_RATIFIED" or prevStatus == "RATIFIED":
      discard updateGateRedis(strandTaskId, "RATIFIED", gateToken, treeSha, testOutputHash)
    else:
      discard updateGateRedis(strandTaskId, "GATE_PASSED", gateToken, treeSha, testOutputHash)
  elif submit:
    var effAuthor = authorParam
    if effAuthor.len == 0:
      if getEnv("RHIZO_AGENT_NAME").len > 0: effAuthor = getEnv("RHIZO_AGENT_NAME")
      else: effAuthor = getEnv("USER", "worker")
    res["status"] = %"ready_for_audit"
    res["author"] = %effAuthor

  return (res, 0)

proc getMergeTreeSha*(strandDir: string, baseRef: string, branch: string = "HEAD"): string =
  let cmd = "git -C " & quoteShell(strandDir) & " merge-tree --write-tree " & quoteShell(baseRef) & " " & quoteShell(branch)
  let (mtOut, mtCode) = execCmdEx(cmd)
  if mtCode == 0 and mtOut.strip().len > 0:
    return mtOut.strip().splitLines()[0]
  return ""

proc gitAutoCommitIfDirty*(dir: string, msg: string): tuple[committed: bool, sha: string, error: string] =
  let (statusOut, statusCode, _, _) = execCmdExWithTimeout("git status --porcelain", 15.0, workingDir = dir)
  if statusCode == 0 and statusOut.strip().len > 0:
    let (addOut, addCode, _, _) = execCmdExWithTimeout("git add -A", 30.0, workingDir = dir)
    if addCode != 0:
      return (false, "", addOut)
    let (cOut, cCode, _, _) = execCmdExWithTimeout("git commit -m " & quoteShell(msg), 30.0, workingDir = dir)
    if cCode != 0:
      return (false, "", cOut)
    let (revOut, revCode, _, _) = execCmdExWithTimeout("git rev-parse --short HEAD", 15.0, workingDir = dir)
    if revCode != 0:
      return (false, "", revOut)
    return (true, revOut.strip(), "")
  return (false, "", "")

proc doStrandSubmit*(
  strandDirParam: string = "",
  authorParam: string = "",
  testCmdParam: string = "",
  allowNoTests: bool = false,
  allowTestOnly: bool = false,
  allowNoChangelog: bool = false,
  timeoutSec: float = 0.0,
  allowDefeatDevices: bool = false,
  noNotify: bool = false,
  commitMsg: string = "",
  listen: bool = false
): tuple[output: JsonNode, exitCode: int] =
  var strandDir = if strandDirParam.len > 0: strandDirParam.normalizedPath else: getCurrentDir()
  var manifest = findStrandManifest(if strandDirParam.len > 0: strandDirParam else: strandDir)
  if manifest != nil and manifest.hasKey("strand_path") and dirExists(manifest["strand_path"].getStr):
    strandDir = manifest["strand_path"].getStr.normalizedPath

  # Optional auto-commit if working directory is dirty before running gate validation
  var autoCommitted = false
  var autoCommitSha = ""
  if commitMsg.len > 0:
    let (committed, sha, err) = gitAutoCommitIfDirty(strandDir, commitMsg)
    if err.len > 0:
      var errRes = newJObject()
      errRes["status"] = %"error"
      errRes["error"] = %("Failed to auto-commit changes: " & err)
      return (errRes, ExitGateFailure)
    if committed:
      autoCommitted = true
      autoCommitSha = sha

  let effectiveBase = if manifest != nil and manifest.hasKey("base_branch"): manifest["base_branch"].getStr() else: "main"
  let effectiveBranch = if manifest != nil and manifest.hasKey("branch"): manifest["branch"].getStr() else: "HEAD"

  var effAuthor = authorParam
  if effAuthor.len == 0:
    if manifest != nil and manifest.hasKey("worker_name"):
      effAuthor = manifest["worker_name"].getStr()
    elif manifest != nil and manifest.hasKey("author"):
      effAuthor = manifest["author"].getStr()
    elif getEnv("RHIZO_AGENT_NAME").len > 0:
      effAuthor = getEnv("RHIZO_AGENT_NAME")
    else:
      effAuthor = getEnv("USER", "worker")

  let (gateRes, gateCode) = doBraidGate(
    branchParam = effectiveBranch,
    baseRefParam = effectiveBase,
    strandDirParam = strandDir,
    skipTests = false,
    testCmdParam = testCmdParam,
    allowNoTests = allowNoTests,
    allowTestOnly = allowTestOnly,
    timeoutSecParam = timeoutSec,
    allowNoChangelog = allowNoChangelog,
    submit = true,
    authorParam = effAuthor,
    allowDefeatDevices = allowDefeatDevices
  )

  if gateCode != 0:
    return (gateRes, gateCode)

  if manifest != nil and (manifest.hasKey("id") or manifest.hasKey("task_id")):
    let tid = manifest.getOrDefault("id").getStr(manifest.getOrDefault("task_id").getStr(""))
    let updated = getStrandRedis(tid)
    if updated != nil and updated.kind == JObject:
      manifest = updated

  let effProject = if manifest != nil and manifest.hasKey("project") and manifest["project"].getStr.len > 0:
                     manifest["project"].getStr
                   else:
                     "vine"

  var res = newJObject()
  res["status"] = %"ready_for_audit"
  res["task_id"] = if manifest != nil and manifest.hasKey("task_id"): manifest["task_id"] else: %strandDir.splitPath.tail
  res["author"] = %effAuthor
  res["project"] = %effProject
  res["strand_path"] = %strandDir
  res["merge_tree_sha"] = gateRes.getOrDefault("merge_tree_sha")
  res["gate_token"] = gateRes.getOrDefault("gate_token")
  res["message"] = %"Strand passed Keys 1 & 2 and is submitted for independent Key 3 Adversarial Audit."
  if autoCommitted:
    res["auto_committed"] = %true
    if autoCommitSha.len > 0:
      res["commit"] = %autoCommitSha

  let notifyRes = notifyStrandEvent(manifest, "STRAND_SUBMITTED", res, noNotify)
  if notifyRes != nil:
    res["notification"] = notifyRes

  if listen:
    let lCode = runRhizoListen(effAuthor, effProject)
    res["listen_exit_code"] = %lCode
    return (res, lCode)

  return (res, 0)

proc doStrandAudit*(
  action: string,
  strandDirParam: string = "",
  auditorParam: string = "",
  reasonParam: string = "",
  findingsFileParam: string = "",
  notesParam: string = "",
  noNotify: bool = false
): tuple[output: JsonNode, exitCode: int] =
  var strandDir = if strandDirParam.len > 0: strandDirParam.normalizedPath else: getCurrentDir()
  var manifest = findStrandManifest(if strandDirParam.len > 0: strandDirParam else: strandDir)
  if manifest != nil and manifest.hasKey("strand_path") and dirExists(manifest["strand_path"].getStr):
    strandDir = manifest["strand_path"].getStr.normalizedPath

  if manifest == nil:
    var errObj = newJObject()
    errObj["status"] = %"error"
    errObj["error"] = %("No strand found for: " & (if strandDirParam.len > 0: strandDirParam else: strandDir))
    return (errObj, 1)

  let normAction = action.toLowerAscii
  case normAction
  of "status":
    var res = newJObject()
    for key in ["task_id", "status", "lifecycle_state", "author", "auditor", "audit_token", "submitted_at", "audited_at", "rejected_at", "rejection_reason", "findings", "notes"]:
      if manifest.hasKey(key):
        res[key] = manifest[key]
      else:
        res[key] = %""
    return (res, 0)

  of "reject":
    var auditor = auditorParam
    if auditor.len == 0:
      if getEnv("RHIZO_AGENT_NAME").len > 0: auditor = getEnv("RHIZO_AGENT_NAME")
      else: auditor = getEnv("USER", "")
    if auditor.len == 0:
      var errObj = newJObject()
      errObj["status"] = %"error"
      errObj["error"] = %"Missing auditor: Specify --auditor <name> or set RHIZO_AGENT_NAME."
      return (errObj, 1)

    let author = if manifest.hasKey("author"): manifest["author"].getStr()
                 elif manifest.hasKey("worker_name"): manifest["worker_name"].getStr()
                 else: ""
    if author.len > 0 and auditor.toLowerAscii == author.toLowerAscii:
      var errObj = newJObject()
      errObj["status"] = %"audit_violation"
      errObj["error"] = %("Self-audit violation: Worker '" & author & "' cannot audit their own strand. Key 3 requires an independent Adversarial Auditor created by the Orchestrator.")
      return (errObj, ExitGateAuditViolation)

    var findings = ""
    if findingsFileParam.len > 0 and fileExists(findingsFileParam):
      try: findings = readFile(findingsFileParam)
      except CatchableError: discard

    let reason = if reasonParam.len > 0: reasonParam else: "Audit failed: defects detected during adversarial review."

    let tid = manifest.getOrDefault("id").getStr(manifest.getOrDefault("task_id").getStr(""))
    if tid.len > 0:
      let rejRes = rejectStrandRedis(tid, auditor, auditor, reason, findings)
      if rejRes != nil and rejRes.kind == JObject and rejRes.hasKey("error"):
        var errObj = newJObject()
        errObj["status"] = %"audit_violation"
        errObj["error"] = rejRes["error"]
        return (errObj, ExitGateAuditViolation)

    var res = newJObject()
    res["status"] = %"audit_rejected"
    res["task_id"] = %tid
    res["author"] = %author
    res["auditor"] = %auditor
    res["rejection_reason"] = %reason
    if findings.len > 0:
      res["findings"] = %findings
    res["message"] = %"Strand rejected by Adversarial Auditor. Worker must address findings and re-submit."
    let notifyRes = notifyStrandEvent(manifest, "AUDIT_REJECTED", res, noNotify)
    if notifyRes != nil:
      res["notification"] = notifyRes
    return (res, 0)

  of "approve", "ratify":
    var auditor = auditorParam
    if auditor.len == 0:
      if getEnv("RHIZO_AGENT_NAME").len > 0: auditor = getEnv("RHIZO_AGENT_NAME")
      else: auditor = getEnv("USER", "")
    if auditor.len == 0:
      var errObj = newJObject()
      errObj["status"] = %"error"
      errObj["error"] = %"Missing auditor: Specify --auditor <name> or set RHIZO_AGENT_NAME."
      return (errObj, 1)

    let author = if manifest.hasKey("author"): manifest["author"].getStr()
                 elif manifest.hasKey("worker_name"): manifest["worker_name"].getStr()
                 else: ""
    if author.len > 0 and auditor.toLowerAscii == author.toLowerAscii:
      var errObj = newJObject()
      errObj["status"] = %"audit_violation"
      errObj["error"] = %("Self-audit violation: Worker '" & author & "' cannot audit their own strand. Key 3 requires an independent Adversarial Auditor created by the Orchestrator.")
      return (errObj, ExitGateAuditViolation)

    let currentStatus = manifest.getOrDefault("status").getStr("")
    let currentLifecycle = manifest.getOrDefault("lifecycle_state").getStr("")
    let gateToken = manifest.getOrDefault("gate_token").getStr("")
    let recordedTreeSha = manifest.getOrDefault("merge_tree_sha").getStr("")

    if gateToken.len == 0 or recordedTreeSha.len == 0 or
       (currentStatus notin ["READY_FOR_AUDIT", "READY_FOR_WEAVE", "GATE_PASSED", "SUBMITTED"] and
        currentLifecycle notin ["READY_FOR_AUDIT", "READY_FOR_WEAVE", "GATE_PASSED", "SUBMITTED"]):
      var errObj = newJObject()
      errObj["status"] = %"audit_prerequisite_failed"
      errObj["error"] = %"Strand has not passed Keys 1 & 2. Run 'vine gate' or 'vine submit' before auditing."
      return (errObj, ExitGateAuditViolation)

    # Check uncommitted dirty files in strand
    let (sOut, sCode) = execCmdEx("git -C " & quoteShell(strandDir) & " status --porcelain")
    var hasDirty = false
    if sCode == 0 and sOut.strip().len > 0:
      for line in sOut.splitLines():
        let t = line.strip()
        if t.len >= 3:
          let f = t[3..^1].strip()
          let topDir = if f.contains('/'): f.split('/')[0] else: f
          if f in [".envrc", ".venv"] or topDir in ["deps", "nimbledeps", "vendor", "node_modules", ".zig-cache", ".venv"]:
            continue
          hasDirty = true
          break
    if hasDirty:
      var errObj = newJObject()
      errObj["status"] = %"audit_dirty_strand"
      errObj["error"] = %"Strand has uncommitted changes. All changes must be committed before auditing."
      return (errObj, ExitGateAuditViolation)

    # Verify merge tree sha matches current git tree
    let baseBranch = manifest.getOrDefault("base_branch").getStr("main")
    let currentTreeSha = getMergeTreeSha(strandDir, baseBranch)
    if currentTreeSha.len > 0 and currentTreeSha != recordedTreeSha:
      var errObj = newJObject()
      errObj["status"] = %"audit_tree_diverged"
      errObj["error"] = %"Strand git tree has diverged since gate verification. Re-run 'vine gate' or 'vine submit'."
      return (errObj, ExitGateAuditViolation)

    let auditCfg = loadVineConfig(findVineConfigPath(strandDir))
    if not auditCfg.allowDefeatDevices:
      let defeatFindings = scanForDefeatDevices(strandDir, baseBranch, "HEAD")
      if defeatFindings.len > 0:
        var errObj = newJObject()
        errObj["status"] = %"defeat_device_detected"
        errObj["error"] = %("Key 3 Audit Violation: Volkswagen Defeat Device detected in strand (" &
          defeatFindings[0].path & ":" & $defeatFindings[0].lineNum & "). Prompt keyword interceptors and theatrical mocks cannot be ratified.")
        return (errObj, ExitGateDefeatDeviceViolation)

    let effectiveTreeSha = if currentTreeSha.len > 0: currentTreeSha else: recordedTreeSha
    let auditToken = computeAuditToken(gateToken, effectiveTreeSha, auditor)

    let tid = manifest.getOrDefault("id").getStr(manifest.getOrDefault("task_id").getStr(""))
    if tid.len > 0:
      let rResp = ratifyStrandRedis(tid, auditor, auditor, auditToken, notesParam)
      if rResp != nil and rResp.kind == JObject and rResp.hasKey("error"):
        var errObj = newJObject()
        errObj["status"] = %"audit_violation"
        errObj["error"] = rResp["error"]
        return (errObj, ExitGateAuditViolation)

    var res = newJObject()
    res["status"] = %"audit_ratified"
    res["task_id"] = %tid
    res["author"] = %author
    res["auditor"] = %auditor
    res["audit_token"] = %auditToken
    res["merge_tree_sha"] = %effectiveTreeSha
    res["gate_token"] = %gateToken
    res["message"] = %"Key 3 Pre-Weave Adversarial Audit ratified. Strand is cleared for trunk weaving."
    let notifyRes = notifyStrandEvent(manifest, "AUDIT_RATIFIED", res, noNotify)
    if notifyRes != nil:
      res["notification"] = notifyRes
    return (res, 0)
  else:
    var errObj = newJObject()
    errObj["status"] = %"error"
    errObj["error"] = %("Unknown audit action: " & action & ". Expected 'approve', 'reject', or 'status'.")
    return (errObj, 1)
