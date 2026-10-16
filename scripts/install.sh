#!/usr/bin/env bash
# /Users/eek/Development/vine/scripts/install.sh
# Universal installer for Vine: Sub-Second Rift Workspaces & Zero-Mirage Weaving Engine.
set -euo pipefail

REPO="axiomantic/vine"
INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
mkdir -p "$INSTALL_DIR"

detect_platform() {
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch="x64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) echo "Error: Unsupported architecture: $arch" >&2; exit 1 ;;
  esac
  echo "${os}-${arch}"
}

install_rules() {
  local target_content
  target_content='# Vine Workspace & Strand Coordination Guide

Vine manages zero-cost Rift copy-on-write workspaces (**Strands**), polyglot build cache normalizers, and the Two-Key integration gate for parallel agent development.

## 1. Invariants & Strand Identity
* **No Workspace-Scoped Identity Files**:
  Agent identity is strictly decoupled from directory paths. Never create or read `.rhizo.agent` or `.vine.agent` in any project or strand directory.
* **Zero Dirty Commits**:
  All strand state, lockfiles, temporary buffers, and manifests must be ignored in `~/.gitignore_global` or `.git/info/exclude`. Never stage or commit coordination metadata (`.vine.json`, `workspaces/`).
* **Compaction Recovery**:
  Whenever starting a session or recovering from context compaction, inspect active strands before editing canonical files:
  ```bash
  vine list 2>/dev/null || rift list 2>/dev/null || ls -la ~/Development/workspaces/ 2>/dev/null || true
  ```
  If an assigned task has an active `.vine.json`, re-anchor to that directory instead of touching the canonical repository root.

---

## 2. When to Spin a Strand vs. Working in Trunk
* **Spin an Isolated Strand when**:
  - The repository contains Git submodules (e.g., PebbleOS).
  - The task requires complex, multi-file refactoring or high risk of breaking `main`.
  - Parallel subagents or assistants are operating simultaneously on different tasks.
* **Work Directly in Trunk when**:
  - The task is a trivial 1-file documentation fix, typo correction, or minor configuration tweak.

---

## 3. Strand Provisioning Protocol

### Step 1: Directory Setup
```bash
STRAND_DIR="$HOME/Development/workspaces/<project>/<task-slug>/<repo>"
mkdir -p "$(dirname "$STRAND_DIR")"
```

### Step 2: Submodule Pre-Flight Check & Workspace Creation
1. Check for uninitialized submodules before cloning.
2. Repositories with submodules: `rift create --into "$(dirname "$STRAND_DIR")" --name "<repo>"`.
3. Repositories without submodules: `git worktree add "$STRAND_DIR" -b "<branch>"`.
4. Stat cache warmup: `git -C "$STRAND_DIR" update-index --refresh >/dev/null 2>&1 || true`.

### Step 3: Reflink & Cache Vendoring Fast-Path
Clone pre-built dependency caches from canonical repository:
```bash
CANONICAL_REPO="$HOME/Development/<project>"
VENDORED_DIRS=("deps" "nimbledeps" "vendor" "node_modules" ".zig-cache")
for vdir in "${VENDORED_DIRS[@]}"; do
  if [ -d "$CANONICAL_REPO/$vdir" ] && [ ! -d "$STRAND_DIR/$vdir" ]; then
    cp -c -R "$CANONICAL_REPO/$vdir" "$STRAND_DIR/$vdir" 2>/dev/null || cp -a --reflink=auto "$CANONICAL_REPO/$vdir" "$STRAND_DIR/$vdir" 2>/dev/null || cp -R "$CANONICAL_REPO/$vdir" "$STRAND_DIR/$vdir"
  fi
done
```

### Step 4: Turn-End Two-Key Gate
Never declare a task complete without passing both keys:
1. **Key 1 (In-Memory Conflict Gate)**: `git merge-tree --write-tree "$BASE_BRANCH" HEAD` (exit 0).
2. **Key 2 (Semantic Compiler Gate)**: Execute live test command inside strand.
3. **Weave**: Fast-forward merge into canonical trunk (`git merge --ff-only <branch>`) and prune strand.'

  # Claude Code
  if [ -d "$HOME/.claude/rules" ]; then
    echo "$target_content" > "$HOME/.claude/rules/vine.md"
    echo "Installed Vine rule to ~/.claude/rules/vine.md"
  fi

  # OpenCode
  if [ -d "$HOME/.config/opencode/instructions" ]; then
    echo "$target_content" > "$HOME/.config/opencode/instructions/vine.md"
    echo "Installed Vine instruction to ~/.config/opencode/instructions/vine.md"
  fi

  # Antigravity
  if [ -d "$HOME/.gemini/antigravity/rules" ]; then
    echo "$target_content" > "$HOME/.gemini/antigravity/rules/vine.md"
    echo "Installed Vine rule to ~/.gemini/antigravity/rules/vine.md"
  fi
}

main() {
  echo "Installing Vine..."
  local platform
  platform="$(detect_platform)"

  # If running inside Vine repo, build from source
  if [ -f "src/vine.nim" ]; then
    nim c -d:release -o:"$INSTALL_DIR/vine" src/vine.nim
    echo "Built and installed Vine to $INSTALL_DIR/vine"
  else
    echo "Downloading release for $platform..."
    local url="https://github.com/${REPO}/releases/latest/download/vine-${platform}.tar.gz"
    curl -fsSL "$url" | tar -xz -C "$INSTALL_DIR" vine
  fi

  install_rules

  echo ""
  echo "Vine installation complete!"
  echo "Run 'vine --version' or 'vine new <task-id>' to get started."
}

main "$@"
