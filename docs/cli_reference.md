# Vine CLI Reference Manual

> **Complete Command-Line Interface Specification**  
> *A normative reference for all commands, subcommands, flags, exit codes, and JSON outputs supported by the Vine CLI.*

---

## 1. Global Options

All `vine` commands accept the following global flags:

| Flag | Default | Description |
| :--- | :--- | :--- |
| `-c, --config <path>` | `vine.toml` | Path to project configuration file. |
| `--json` | `false` | Emits output in machine-parseable JSON format. |
| `-v, --verbose` | `false` | Emits diagnostic logs to stderr. |

---

## 2. Command Catalog

### `vine new <task-id>`
Provisions an isolated APFS copy-on-write strand for a task.
```bash
vine new task-1049 [--repo <dir>] [--branch <name>] [--parent <branch>] [--worktree] [--clean]
```
- `--repo <dir>`: Target canonical git repository (defaults to current directory).
- `--branch <name>`: Branch to create and check out inside the strand (defaults to `feat/<task-id>`).
- `--parent <branch>`: Base branch to branch from (defaults to `main`).
- `--worktree`: Forces git worktree fallback instead of Rift CoW clone.
- `--clean`: Recreates strand directory if an orphaned strand exists.

### `vine status`
Inspects dynamic lifecycle state, commits ahead/behind canonical trunk, and modified files.
```bash
vine status [--json]
```
*Output includes:*
- Strand task ID and directory path.
- Commits ahead and behind parent branch.
- Gate status (`PROVISIONED`, `IN_PROGRESS`, `READY_FOR_WEAVE`, `CONFLICTED`, `GATE_FAILED`).
- List of modified files (ignoring metadata `.vine.json`, `.envrc`, `.venv`).

### `vine collisions`
Analyzes overlapping file modifications across all active strands to prevent merge collisions.
```bash
vine collisions [--json]
```
- Flags overlapping files between active parallel workers.
- Suggests distributed fencing locks (`rhizo lock <path>`).

### `vine gate`
Executes the Two-Key Gate verification protocol.
```bash
vine gate [--json] [--test-command <cmd>] [--skip-tests] [--parent <branch>]
```
- **Key 1**: Executes in-memory `git merge-tree --write-tree` check against base branch.
- **Key 2**: Executes live compiler and project test suite inside strand.
- Stamps cryptographic `gate_token` into `.vine.json` on exit 0.
- Exits 0 on pass, 1 on conflict, 2 on test failure.

### `vine weave`
Fast-forward merges a gate-verified strand directly into the canonical trunk.
```bash
vine weave [--strand <dir>] [--branch <name>] [--target <repo>]
```
- Verifies that `.vine.json` contains a valid cryptographic `gate_token` matching current `HEAD`.
- Fetches branch from strand into canonical repo.
- Executes `git merge --ff-only <branch>`.
- Deletes strand directory upon successful weave.

### `vine list`
Lists all active strands across the system with their status and task bindings.
```bash
vine list [--json]
```

### `vine sync`
Synchronizes the strand with recent commits on the parent trunk.
```bash
vine sync [--parent <branch>]
```
- Performs fast-forward or rebase onto updated trunk.

### `vine prune`
Cleans up merged, abandoned, or orphaned workspace directories.
```bash
vine prune [--all] [--dry-run]
```
- Removes workspaces whose branches have been merged or deleted.
- Calls `rift prune` to free APFS snapshot metadata.

### `vine guide install`
Installs or updates the canonical `VINE GUIDE` block in the repository's `AGENTS.md`.
```bash
vine guide install [--file <path>]
```
