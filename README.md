# Vine

**Zero-Cost Rift Copy-on-Write Workspaces & Zero-Mirage Git Weaving for Autonomous AI Agents**

Vine provides zero-drag workspace virtualization, polyglot build-cache normalization, and mechanical + semantic verification gates for parallel AI coding agents.

## Core Concepts

- **Strands**: Instantaneous Rift copy-on-write workspace clones (`vine new <task_id>`). Uses `rift` for zero-cost snapshot cloning (in ~9s with 0 extra disk blocks) and `git worktree` for monolithic fallback (in ~280ms).
- **Universal CoW Vendoring**: Clones dependency caches (`deps`, `node_modules`, `vendor`) in <80ms without physical disk duplication.
- **Polyglot Build Cache Layer**: Auto-activates non-destructive `.envrc` normalizing `ccache`, `sccache`, `uv` clone mode, and `nimcache`.
- **The Two-Key Gate**: Ensures zero "Green Mirage" by requiring both Key 1 (in-memory mechanical `git merge-tree` exit 0) and Key 2 (live compiler & test suite exit 0).
- **Weaving**: Fast-forwards verified strands back into the canonical trunk (`vine weave`).

## Standalone Yet Designed for the Axiomantic Triad

Vine is completely standalone and can be used on its own for zero-cost Rift copy-on-write workspace cloning, `.envrc` build-cache normalization, and Two-Key gate verification on any git repository.

> [!NOTE]
> ### Quick Note: Using Garden as your High-Level Swarm Wrapper
> **Looking for the high-level multi-agent conductor? Use [Garden](https://github.com/axiomantic/garden).**  
> While `vine` provides isolated branch workspaces (strands) and the Two-Key Gate, **Garden** is the high-level umbrella framework. Simply start a session in your favorite coding harness (Antigravity, Claude Code, OpenCode) and type `"garden: I want to build [feature]"`. Garden conducts an intake interview, generates clean 10-backtick prompt cards for your terminal tabs, and coordinates all workers over Rhizo and Vine!

However, Vine is designed from the ground up to pair seamlessly with **Rhizo** and **Garden**:
- [**Rhizo**](https://github.com/axiomantic/rhizo) (Transport & Concurrency): Inter-agent messaging bus, monotonic fencing locks, and task queues over Redis.
- **Vine** (Workspaces & Verification): Zero-cost Rift copy-on-write strands, polyglot build-cache normalization, and the Two-Key integration gate (`git merge-tree` mechanical + compiler/test suite semantic checks).
- [**Garden**](https://github.com/axiomantic/garden) (Swarm Methodology & High-Level Wrapper): Conversational project intake interview, prompt-bootstrapped worker fleets (10-backtick cards), 3-stage empirical dialectical pump (research, architecture, audit), and master ceremonial implementation planning.

## Installation

### 1. For AI Coding Assistants (Recommended)

Install the skills globally (`-g`) across all your coding assistants (Claude Code, Antigravity, Cursor, Codex, OpenCode, etc.):

```bash
# Recommended: Install the complete multi-agent triad globally
npx skills add -g axiomantic/rhizo
npx skills add -g axiomantic/vine
npx skills add -g axiomantic/garden
```

*(Each skill automatically self-bootstraps its native CLI binary if it is not already installed on your system).*

To install only Vine:
```bash
npx skills add -g axiomantic/vine
```

### 2. Standalone CLI Installation

Install the compiled CLI tools directly onto your `$PATH`:

```bash
# Install all three tools:
npm install -g @axiomantic/rhizo @axiomantic/vine @axiomantic/garden rift-snapshot

# Or install Vine alone:
npm install -g @axiomantic/vine rift-snapshot
```

> [!TIP]
> **Zero-Install Run via NPX**: In restricted or containerized environments where global installation is unavailable, you can run any command directly without installing:
> ```bash
> npx -y @axiomantic/vine <command>
> ```

### 3. Repository Coordination Guide

Install the Vine strand coordination protocol directly into any project's `AGENTS.md`:
```bash
vine guide install
```

## Quickstart

```bash
# Spin up an isolated strand for a task
vine new task-1049 --repo ~/Development/PebbleOS --branch feat/display-driver

# Inspect dynamic strand lifecycle and commit delta
vine status --json

# Forecast cross-strand file footprint overlap before conflicts happen
vine collisions

# Reconcile upstream canonical trunk changes into strand
vine sync

# Verify mechanical and semantic correctness inside the strand
vine gate

# Weave clean strand into canonical trunk
vine weave

# Prune completed or merged strands
vine prune --apply
```

## CLI Reference

| Command | Arguments | Description |
| :--- | :--- | :--- |
| `vine new <task_id>` | `[--repo <dir>] [--branch <name>] [--parent <branch>] [--worktree]` | Provision an isolated Rift CoW strand or git worktree. |
| `vine list` | `[--repo <dir>] [--all] [--json]` | List active strands, branches, and status across projects. |
| `vine status` | `[<strand>] [--dir <path>] [--json]` | Inspect deep lifecycle state (`PROVISIONED`, `IN_PROGRESS`, `GATE_PASSED`, etc.) and commits ahead/behind. |
| `vine collisions` | `[--repo <dir>] [--json]` | Forecast file-footprint overlaps across concurrent worker strands. |
| `vine sync` | `[--dir <path>] [--base <branch>]` | Fast-forward or merge upstream trunk changes cleanly into strand. |
| `vine gate` | `[--dir <path>] [--base <branch>] [--skip-tests] [-- <command...>]` | Run Two-Key Gate: Key 1 mechanical pre-check and Key 2 semantic test suite (`-- <cmd...>` or `--test-command <cmd>`). |
| `vine weave` | `[--dir <path>] [--base <branch>] [--force]` | Fast-forward merge verified strand into canonical trunk and prune. |
| `vine prune` | `[--repo <dir>] [--apply]` | Remove inactive or completed strands (dry-run by default). |
| `vine config <init\|show>`| `[--json]` | Scaffold or display project `vine.toml` configuration. |
| `vine guide <install\|check\|uninstall>` | `[path]` | Install or manage Vine Coordination Guide in `AGENTS.md`. |

## Configuration & Environment Variables

> [!TIP]
> For the complete specification of `vine.toml`, `.vine.json` runtime state schemas, and environment variables, see the [Vine Configuration & Manifest Reference](docs/configuration.md).

Vine provides zero-config defaults that can be customized via `vine.toml` or environment variables:

| Variable | Default | Description |
| :--- | :--- | :--- |
| `VINE_WORKSPACES_DIR` | `~/Development/workspaces` | Base directory where isolated strands are provisioned. |
| `VINE_PROJECTS_DIR` | `~/Development` | Base directory where canonical repositories reside. |
| `VINE_CONFIG` | *Auto-discovered* | Explicit path to project `vine.toml`. |
| `VINE_PRIMARY_BRANCH` | `main` | Default target branch for gate checks and merges. |
| `VINE_TEST_COMMAND` | *Auto-detected* | Custom test/compiler runner for Key 2 semantic gate check. |
| `VINE_VENV_POLICY` | `prompt` | Virtual environment copy policy (`prompt`, `auto_yes`, `auto_no`). |

### Example `vine.toml`

```toml
[project]
primary_branch = "main"

[strand]
venv_policy = "prompt"
vendor_dirs = ["deps", "node_modules", "vendor", ".zig-cache"]

[verification]
test_command = "pytest -v tests/"
```

## Multi-Agent Triad Workflow

When orchestrating teams of multiple AI assistants operating simultaneously across strands, pair Vine with [**Rhizo**](https://github.com/axiomantic/rhizo) and [**Garden**](https://github.com/axiomantic/garden):

- **Distributed Mutexes & Fencing**: Use `rhizo lock file:<path> --fencing` to prevent concurrent collisions on non-mergeable schema files or migrations.
- **Synchronized Task Queues**: Agents claim work via `rhizo claim queue:<project>:tasks --lease 1800` and report status back over the Redis bus.
- **Full Ceremony Conduct**: Use `garden` to direct persona deliberations, generate 10-backtick worker prompt cards, and drive implementation plans.
- **Zero Dirty Commits**: Rhizo, Vine, and Garden enforce complete decoupling of agent identity from directory paths.

## Repository Guide Integration

Install the Vine guide into any repository's `AGENTS.md`:

```bash
# Defaults to AGENTS.md in the current working directory:
vine guide install

# Or specify a custom target path:
vine guide install /path/to/AGENTS.md
```
