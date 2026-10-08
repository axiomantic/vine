# Contributing to Vine

We welcome contributions to Vine! Vine provides zero-cost Rift copy-on-write workspace isolation (**Strands**), polyglot build cache normalization, and the Two-Key integration gate for parallel AI coding agents.

---

## Development Prerequisites

- **Operating System**: macOS (Apple Silicon or Intel) or Linux with copy-on-write filesystem support (APFS, Btrfs, XFS reflink). Windows is supported via native `git worktree` fallback.
- **Nim Compiler**: Pinned to **2.2+** (managed via [`mise`](https://mise.jdx.dev) via `.tool-versions` or `choosenim`).
- **Git**: **2.38+** (required for `git merge-tree --write-tree` mechanical conflict verification).
- **Python**: **3.10+** (Python 3.12 recommended for pytest integration suites and Tripwire verification).
- **Node.js**: For `@axiomantic/vine` npm multi-architecture packaging.
- **Rift**: [`rift-snapshot`](https://www.npmjs.com/package/rift-snapshot) (`npm install -g rift-snapshot`) for zero-cost copy-on-write cloning of repositories with git submodules (e.g. PebbleOS).

---

## Quick Build & Test

```bash
# 1. Clone repository
git clone https://github.com/axiomantic/vine.git
cd vine

# 2. Build native Nim binary
nimble build -d:release -y

# Verify binary
./bin/vine --version

# 3. Run test suites
uv run pytest tests/
```

---

## Architectural Guidelines

### 1. The Two-Key Gate Invariant (Zero Green Mirage)
Every strand must satisfy both keys before being woven into the canonical trunk (`vine weave`):
- **Key 1 (Mechanical Mergeability)**:
  `git merge-tree --write-tree <base_branch> HEAD` must exit 0 in memory with no conflict markers.
- **Key 2 (Semantic Verification)**:
  The project's actual build and test suite (`test_command` defined in `vine.toml` or auto-detected) must compile and pass with exit 0 inside the strand.
*Never bypass either key. Mechanical mergeability does not imply compilation correctness, and compilation in an out-of-date branch does not guarantee mergeability.*

### 2. Zero Dirty Commits & Workspace Decoupling
- Agent identity and strand manifests (`.vine.json`, `workspaces/`) must never be committed to canonical repository history.
- Ensure coordination artifacts are ignored via `~/.gitignore_global` or `.git/info/exclude`.

### 3. Non-Destructive Polyglot Cache Layer
Vine automatically generates `.envrc` files for newly spun strands to normalize build caches across Strands without cross-polluting parent repositories:
- C/C++: `CCACHE_BASEDIR` and `CCACHE_NOHASHDIR=1`
- Rust: `CARGO_TARGET_DIR` pointing to shared cache root
- Python: `UV_LINK_MODE=clone`
- Nim: `NIMCACHE` pointing to shared cache root

---

## Pull Request Process

1. Fork the repo and create a topic branch from `main`.
2. Ensure all unit and integration tests pass: `uv run pytest tests/`.
3. If modifying core logic in `src/vine.nim` or `src/guide.nim`, rebuild the release binary (`nimble build -d:release -y`).
4. Ensure `vine gate` passes cleanly before submitting.
5. Submit a Pull Request describing your changes, motivation, and test evidence.
