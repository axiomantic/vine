# /Users/eek/Development/vine/src/gate.nim
# The Two-Key Integration Gate for Braid (Zero Green Mirage).

import std/[os, osproc, strutils, json, times]
import config, strand, crypto, process

const
  ExitGateSuccess* = 0
  ExitGateConflict* = 1
  ExitGateFailure* = 2
  ExitGateTwoPointViolation* = 3
  ExitGateTimeout* = 4
  ExitGateChangelogViolation* = 5

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
  autoEnsureUnreleased: bool = false
): tuple[output: JsonNode, exitCode: int] =
  var strandDir = if strandDirParam.len > 0: strandDirParam.normalizedPath else: getCurrentDir()
  var manifestPath = strandDir / ".vine.json"
  var manifest: JsonNode = nil

  if fileExists(manifestPath):
    try: manifest = parseJson(readFile(manifestPath))
    except CatchableError: discard

  # Auto-resolve from strand registry if manifest not found in current directory
  if manifest == nil and branchParam.len > 0:
    let found = findStrandManifest(branchParam, getCurrentDir())
    if found != nil and found.hasKey("strand_path") and dirExists(found["strand_path"].getStr):
      manifest = found
      strandDir = manifest["strand_path"].getStr.normalizedPath
      manifestPath = strandDir / ".vine.json"

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

  # Track gate evaluation in manifest if present
  if manifest != nil:
    manifest["status"] = %"GATE_EVALUATING"
    manifest["lifecycle_state"] = %"GATE_EVALUATING"
    try: writeFile(manifestPath, pretty(manifest))
    except CatchableError: discard

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

    if manifest != nil:
      manifest["status"] = %"CONFLICTED"
      manifest["lifecycle_state"] = %"CONFLICTED"
      try: writeFile(manifestPath, pretty(manifest))
      except CatchableError: discard

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
        if normPath in [".vine.json", ".envrc", ".gitignore", "vine.toml", "README.md", "LICENSE"] or
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
        if manifest != nil:
          manifest["status"] = %"GATE_FAILED"
          manifest["lifecycle_state"] = %"GATE_FAILED"
          try: writeFile(manifestPath, pretty(manifest))
          except CatchableError: discard
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
          if manifest != nil:
            manifest["status"] = %"GATE_FAILED"
            manifest["lifecycle_state"] = %"GATE_FAILED"
            try: writeFile(manifestPath, pretty(manifest))
            except CatchableError: discard
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
            if manifest != nil:
              manifest["status"] = %"GATE_FAILED"
              manifest["lifecycle_state"] = %"GATE_FAILED"
              try: writeFile(manifestPath, pretty(manifest))
              except CatchableError: discard
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
                if manifest != nil:
                  manifest["status"] = %"GATE_FAILED"
                  manifest["lifecycle_state"] = %"GATE_FAILED"
                  try: writeFile(manifestPath, pretty(manifest))
                  except CatchableError: discard
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

        if manifest != nil:
          manifest["status"] = %"GATE_TIMEOUT"
          manifest["lifecycle_state"] = %"GATE_TIMEOUT"
          manifest["timed_out_command"] = %testCmd
          manifest["timeout_elapsed_sec"] = %elapsedSec
          try: writeFile(manifestPath, pretty(manifest))
          except CatchableError: discard

        return (res, EXIT_GATE_TIMEOUT)

      if tCode != 0:
        res["status"] = %"semantic_failure"
        res["clean"] = %false
        res["key2_semantic"] = %"FAIL"
        res["compiler_output"] = %tOut.strip()

        if manifest != nil:
          manifest["status"] = %"GATE_FAILED"
          manifest["lifecycle_state"] = %"GATE_FAILED"
          try: writeFile(manifestPath, pretty(manifest))
          except CatchableError: discard

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

      if manifest != nil:
        manifest["status"] = %"GATE_FAILED"
        manifest["lifecycle_state"] = %"GATE_FAILED"
        try: writeFile(manifestPath, pretty(manifest))
        except CatchableError: discard

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
      if manifest != nil:
        manifest["status"] = %"GATE_FAILED"
        manifest["lifecycle_state"] = %"GATE_FAILED"
        try: writeFile(manifestPath, pretty(manifest))
        except CatchableError: discard
      return (res, 2)

  # Both Keys and Two-Point Diff Passed!
  let testOutputHash = sha256(testOutput)
  let gateToken = computeGateToken(treeSha, testOutputHash)

  res["status"] = %"green"
  res["clean"] = %true
  res["merge_tree_sha"] = %treeSha
  res["test_output_hash"] = %testOutputHash
  res["gate_token"] = %gateToken

  # Update .vine.json if present
  if manifest != nil:
    if testCmdParam.len > 0:
      manifest["test_command"] = %testCmdParam
    manifest["status"] = %"READY_FOR_WEAVE"
    manifest["lifecycle_state"] = %"GATE_PASSED"
    manifest["merge_tree_sha"] = %treeSha
    manifest["test_output_hash"] = %testOutputHash
    manifest["gate_token"] = %gateToken
    manifest["verified_at"] = %now().utc().format("yyyy-MM-dd'T'HH:mm:ss'Z'")
    try: writeFile(manifestPath, pretty(manifest))
    except CatchableError: discard
  return (res, 0)
