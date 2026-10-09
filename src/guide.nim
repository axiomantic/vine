# /Users/eek/Development/vine/src/guide.nim
# Manages installable/uninstallable demarcated documentation blocks in AGENTS.md
# for the Vine workspace virtualization and strand weaving engine.

import std/[os, strutils]

const
  GuideVersion* = "v1.2"
  BeginMarker* = "<!-- BEGIN VINE GUIDE [" & GuideVersion & "] -->"
  EndMarker* = "<!-- END VINE GUIDE -->"
  MarkerPrefix* = "<!-- BEGIN VINE GUIDE"

const CanonicalGuideContent* = """
<!-- BEGIN VINE GUIDE [v1.2] -->
<!-- DO NOT EDIT DIRECTLY: Managed by `vine guide install` -->

## Vine Workspace & Strand Coordination Guide

Vine manages zero-cost APFS copy-on-write workspaces (**Strands**), polyglot build cache normalizers, and the Two-Key integration gate for parallel agent development.

### 0. Self-Bootstrapping Prerequisite
This project requires `rhizo` and `vine`. If `command -v rhizo` or `command -v vine` fails, install them via npm:
```bash
npm install -g @axiomantic/rhizo @axiomantic/vine
```

### 1. Invariants & Strand Identity
* **Sovereign Worker Allocation**:
  Workspaces (Strands) are allocated strictly 1:1 to sovereign, dedicated worker sessions. Never assign harness-internal subagents to strand directories to prevent git index contention and lifecycle premature termination.
* **No Workspace-Scoped Identity Files**:
  Agent identity is strictly decoupled from directory paths. Never create or read `.rhizo.agent` or `.vine.agent` in any project or strand directory.
* **Zero Dirty Commits**:
  All strand state, lockfiles, temporary buffers, and manifests must be ignored in `~/.gitignore_global` or `.git/info/exclude`. Never stage or commit coordination metadata (`.vine.json`, `workspaces/`).
* **Post-Compaction Ceremony Restoration**:
  Whenever context compaction occurs in a session that used Vine (or Rhizo/Garden), the compaction summary MUST include the mandatory directive commanding the resurrected agent to re-read `vine` (and `rhizo`/`garden` if active) and inspect active strands before touching canonical trunk files. This directive must remain intact across all future compactions.
* **Compaction Recovery**:
  Whenever starting a session or recovering from context compaction, inspect active strands before editing canonical files:
  ```bash
  vine list 2>/dev/null || rift list 2>/dev/null || ls -la ~/Development/workspaces/ 2>/dev/null || true
  ```
  If an assigned task has an active `.vine.json`, re-anchor to that directory instead of touching the canonical repository root.

---

### 2. When to Spin a Strand vs. Working in Trunk
* **Spin an Isolated Strand when**:
  - The repository contains Git submodules (e.g., PebbleOS).
  - The task requires complex, multi-file refactoring or high risk of breaking `main`.
  - Parallel workers or assistants are operating simultaneously on different tasks.
* **Work Directly in Trunk when**:
  - The task is a trivial 1-file documentation fix, typo correction, or minor configuration tweak.

---

### 3. Strand Provisioning Protocol

#### Step 1: Directory Setup
All strands live outside canonical repositories to prevent recursive indexing and IDE thrashing:
```bash
STRAND_DIR="$HOME/Development/workspaces/<project>/<task-slug>/<repo>"
mkdir -p "$(dirname "$STRAND_DIR")"
```

#### Step 2: Submodule Pre-Flight Check & Workspace Creation
1. **Check for Uninitialized Submodules**:
   ```bash
   if git submodule status 2>/dev/null | grep -q '^-'; then
     echo "WARNING: Canonical repository has uninitialized submodules. Initialize first before cloning!"
   fi
   ```
2. **Clone Workspace via APFS Copy-on-Write**:
   - **Repositories with Submodules (e.g. PebbleOS)**:
     Use `rift` (native APFS CoW cloning of working tree + `.git/modules` in ~9s with 0 extra blocks):
     ```bash
     rift create --into "$(dirname "$STRAND_DIR")" --name "<repo>"
     ```
   - **Monolithic Repositories without Submodules (e.g. rhizo, redis)**:
     Use native Git worktree:
     ```bash
     git worktree add "$STRAND_DIR" -b "<branch>"
     ```
3. **Stat Cache Warmup**:
   Silences APFS inode change time (`ctime`) differences in <15ms:
   ```bash
   git -C "$STRAND_DIR" update-index --refresh >/dev/null 2>&1 || true
   ```

#### Step 3: The Universal APFS CoW Vendoring Fast-Path
Clone pre-built dependency caches from the canonical repository in <80ms without consuming physical disk space:
```bash
CANONICAL_REPO="$HOME/Development/<project>"
VENDORED_DIRS=("deps" "nimbledeps" "vendor" "node_modules" ".zig-cache")

for vdir in "${VENDORED_DIRS[@]}"; do
  if [ -d "$CANONICAL_REPO/$vdir" ] && [ ! -d "$STRAND_DIR/$vdir" ]; then
    cp -c -R "$CANONICAL_REPO/$vdir" "$STRAND_DIR/$vdir"
  fi
done
```

#### Step 4: Python Virtual Environment (`.venv`) Policy
1. Inspect `$CANONICAL_REPO/.venv/pyvenv.cfg`.
2. **If `relocatable = true`**: Safe to APFS clone:
   ```bash
   cp -c -R "$CANONICAL_REPO/.venv" "$STRAND_DIR/.venv"
   ```
3. **If NOT relocatable**: **Do not blind-copy** (prevents mutating parent environment via absolute shebangs).
   - Check `vine.toml` for `venv_policy`:
     - If `recreate`: Run `UV_VENV_RELOCATABLE=1 uv venv "$STRAND_DIR/.venv"` (~12ms).
     - If `prompt` (default): Ask user whether to recreate or skip.

#### Step 5: Non-Destructive Polyglot `.envrc` Setup
Place this `.envrc` in `$STRAND_DIR` and run `direnv allow "$STRAND_DIR"`:
```bash
# Source parent repository .envrc if present (non-destructive chaining)
[ -f "$HOME/Development/<project>/.envrc" ] && source_env "$HOME/Development/<project>/.envrc"

export PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
export CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/dev-workspaces/$(basename "$PROJECT_ROOT")"
mkdir -p "$CACHE_ROOT"

# C / C++ Ccache normalization across Strands
if command -v ccache >/dev/null 2>&1; then
    export CCACHE_BASEDIR="$(dirname "$PROJECT_ROOT")"
    export CCACHE_NOHASHDIR=1
fi

# Rust Target / Sccache
[ -f "$PROJECT_ROOT/Cargo.toml" ] && export CARGO_TARGET_DIR="$CACHE_ROOT/cargo-target"

# Python uv clone mode
export UV_LINK_MODE="clone"

# Nim Nimcache
export NIMCACHE="$CACHE_ROOT/nimcache"
```

#### Step 6: Initialize Strand Manifest (`.vine.json`)
```json
{
  "task_id": "<task-id>",
  "project": "<project>",
  "strand_path": "<strand-dir>",
  "branch": "<branch>",
  "base_branch": "<base-branch>",
  "base_commit": "<base-commit-sha>",
  "status": "IN_PROGRESS",
  "created_at": "2026-09-26T12:00:00Z"
}
```

---

### 4. Turn-End & Weaving Protocol (The Two-Key Rule)

Never declare a task complete or attempt to weave without passing both keys:

#### Key 1: In-Memory Conflict Gate
```bash
BASE_BRANCH="${BASE_BRANCH:-main}"
git merge-tree --write-tree "$BASE_BRANCH" HEAD
```
- **Exit 0**: Clean mechanical merge.
- **Exit 1**: Conflicts detected. Resolve conflicts *inside the Strand* before touching canonical trunk.

#### Key 2: Live Compiler & Test Suite Gate (Zero Green Mirage)
Execute the project's actual build and test suite inside the Strand:
```bash
# Inferred or from vine.toml [verification] test_command:
$BUILD_AND_TEST_COMMAND
```
*Never bypass this gate. `git merge-tree` only verifies text mergeability, not compilation or semantic correctness.*

#### Step 3: Weave into Canonical Trunk
Once Key 1 and Key 2 pass 100% green:
```bash
cd "$CANONICAL_REPO"
# Fetch branch directly from isolated Strand
git fetch "$STRAND_DIR" <branch>:<branch>
# Fast-forward merge
git merge --ff-only <branch>
```

#### Step 4: Prune & Cleanup
```bash
rm -rf "$STRAND_DIR"
command -v rift >/dev/null 2>&1 && rift prune >/dev/null 2>&1 || true
```
<!-- END VINE GUIDE -->"""

type GuideStatus* = enum
  gsNotFound,
  gsInstalled,
  gsMalformed,
  gsFileMissing

proc checkGuide*(targetPath: string): GuideStatus =
  if not fileExists(targetPath):
    return gsFileMissing

  let content = readFile(targetPath)
  let hasBegin = content.contains(MarkerPrefix)
  let hasEnd = content.contains(EndMarker)

  if hasBegin and hasEnd:
    return gsInstalled
  elif hasBegin xor hasEnd:
    return gsMalformed
  else:
    return gsNotFound

proc installGuide*(targetPath: string): tuple[success: bool, message: string] =
  let status = checkGuide(targetPath)

  if status == gsMalformed:
    return (false, "Error: Malformed markers detected in " & targetPath & " (one marker found without matching pair). Aborting to prevent data loss.")

  let pid = getCurrentProcessId()
  let tmpPath = targetPath & ".tmp." & $pid

  try:
    if status == gsFileMissing:
      createDir(targetPath.splitPath.head)
      let initialContent = "# AGENTS.md — Vine Workspace & Strand Guide\n\n" & CanonicalGuideContent & "\n"
      writeFile(tmpPath, initialContent)
      moveFile(tmpPath, targetPath)
      return (true, "Created " & targetPath & " and installed Vine Guide [" & GuideVersion & "].")

    let content = readFile(targetPath)

    if status == gsInstalled:
      # In-place update between markers
      let lines = content.splitLines()
      var newLines: seq[string] = @[]
      var inBlock = false
      var replaced = false

      for line in lines:
        if line.contains(MarkerPrefix):
          inBlock = true
          if not replaced:
            newLines.add(CanonicalGuideContent)
            replaced = true
          continue
        elif inBlock and line.contains(EndMarker):
          inBlock = false
          continue

        if not inBlock:
          newLines.add(line)

      writeFile(tmpPath, newLines.join("\n") & "\n")
      moveFile(tmpPath, targetPath)
      return (true, "Updated Vine Guide to [" & GuideVersion & "] in " & targetPath & ".")

    else: # gsNotFound
      var updated = content.strip(trailing = true)
      if updated.len > 0:
        updated.add("\n\n")
      updated.add(CanonicalGuideContent & "\n")

      writeFile(tmpPath, updated)
      moveFile(tmpPath, targetPath)
      return (true, "Appended Vine Guide [" & GuideVersion & "] to " & targetPath & ".")

  except Exception as e:
    if fileExists(tmpPath):
      try: removeFile(tmpPath)
      except CatchableError: discard
    return (false, "Error installing guide: " & e.msg)

proc uninstallGuide*(targetPath: string): tuple[success: bool, message: string] =
  let status = checkGuide(targetPath)

  if status == gsFileMissing:
    return (false, "Error: Target file " & targetPath & " does not exist.")

  if status == gsMalformed:
    return (false, "Error: Malformed markers detected in " & targetPath & " (one marker found without matching pair). Aborting to prevent data loss.")

  if status == gsNotFound:
    return (true, "Notice: Vine Guide not found in " & targetPath & ". Nothing to uninstall.")

  let pid = getCurrentProcessId()
  let tmpPath = targetPath & ".tmp." & $pid

  try:
    let content = readFile(targetPath)
    let lines = content.splitLines()
    var newLines: seq[string] = @[]
    var inBlock = false

    for line in lines:
      if line.contains(MarkerPrefix):
        inBlock = true
        continue
      elif inBlock and line.contains(EndMarker):
        inBlock = false
        continue

      if not inBlock:
        newLines.add(line)

    var resultText = newLines.join("\n").strip(trailing = true)
    if resultText.len > 0:
      resultText.add("\n")

    writeFile(tmpPath, resultText)
    moveFile(tmpPath, targetPath)
    return (true, "Successfully uninstalled Vine Guide from " & targetPath & ".")

  except Exception as e:
    if fileExists(tmpPath):
      try: removeFile(tmpPath)
      except CatchableError: discard
    return (false, "Error uninstalling guide: " & e.msg)
