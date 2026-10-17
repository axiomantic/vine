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
  timeoutSecParam: float = 0.0
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

        # Ignore coordination metadata & root non-source files
        let normPath = filePath.replace('\\', '/')
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
    else:
      res["two_point_diff"] = %"PASS"
  else:
    res["two_point_diff"] = %"SKIPPED (allow-test-only)"

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
