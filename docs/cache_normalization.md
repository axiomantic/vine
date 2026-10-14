# Vine Polyglot Build Cache Normalization

> **Shared Zero-Cost Compilation Caches Across Isolated Strands**  
> *A technical reference for configuring non-destructive `.envrc` chaining, Ccache normalization, Cargo target sharing, uv clone links, and Nimcache unification.*

---

## 1. The Multi-Strand Cache Problem

When parallel AI agents spin up isolated strands, default compiler behaviors create severe performance degradation:
1. **Redundant Compilation**: Every strand recompiles dependencies from scratch, wasting CPU minutes.
2. **Path Hash Busting**: Absolute paths in debug info bust compiler cache hit rates (`ccache`, `sccache`).
3. **Disk Exhaustion**: Duplicating `target/` or `.venv/` across 10 parallel strands can consume tens of gigabytes of disk space.

Vine solves this through **Polyglot Build Cache Normalization** via non-destructive `.envrc` chaining.

---

## 2. Non-Destructive `.envrc` Template

When a strand is provisioned (`vine new`), Vine places this `.envrc` into `$STRAND_DIR`:

```bash
# 1. Non-destructive parent .envrc chaining
[ -f "$HOME/Development/<project>/.envrc" ] && source_env "$HOME/Development/<project>/.envrc"

# 2. Canonical project identifiers & shared cache root
export PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
export CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/dev-workspaces/$(basename "$PROJECT_ROOT")"
mkdir -p "$CACHE_ROOT"

# 3. C / C++ Ccache normalization across Strands
if command -v ccache >/dev/null 2>&1; then
    export CCACHE_BASEDIR="$(dirname "$PROJECT_ROOT")"
    export CCACHE_NOHASHDIR=1
fi

# 4. Rust Target & Sccache
[ -f "$PROJECT_ROOT/Cargo.toml" ] && export CARGO_TARGET_DIR="$CACHE_ROOT/cargo-target"

# 5. Python UV clone mode
export UV_LINK_MODE="clone"

# 6. Nim Nimcache
export NIMCACHE="$CACHE_ROOT/nimcache"
```

---

## 3. Polyglot Compiler Normalization Mechanics

### A. C / C++ (Ccache)
- `CCACHE_BASEDIR="$(dirname "$PROJECT_ROOT")"`: Rewrites absolute file paths in preprocessed source code to relative paths based on the strand parent directory. This allows cache entries generated in `strand-alpha` to produce 100% cache hits in `strand-beta`.
- `CCACHE_NOHASHDIR=1`: Prevents hashing of working directory paths into the cache key.

### B. Rust (Cargo & Sccache)
- `CARGO_TARGET_DIR="$CACHE_ROOT/cargo-target"`: Directs Cargo to place compiled dependency crates (`target/`) into a shared directory outside the strand. Intermediate `.rlib` dependencies compiled by one worker are immediately available to all other workers.

### C. Python (uv & Relocatable Venvs)
- `UV_LINK_MODE="clone"`: Directs `uv` to use native APFS copy-on-write clone links for Python packages, taking 0 extra disk blocks.
- **Relocatability Guard**: If `pyvenv.cfg` has `relocatable = true`, `.venv` is APFS cloned in $<50\text{ ms}$. If not relocatable, Vine executes `UV_VENV_RELOCATABLE=1 uv venv` (~12ms) to prevent shebang mutation of the parent repository.

### D. Nim (Nimcache)
- `NIMCACHE="$CACHE_ROOT/nimcache"`: Directs Nim's C code generation backend to emit `.c` and `.o` intermediate artifacts into a shared directory, achieving 10x faster subsequent compiles across strands.

---

## 4. Direnv Integration & Permissions

Vine automatically authorizes `.envrc` upon provisioning:
```bash
direnv allow "$STRAND_DIR" >/dev/null 2>&1 || true
```
This ensures that when an autonomous agent enters the strand (`cd $STRAND_DIR`), all cache normalizers are active in the subshell immediately.
