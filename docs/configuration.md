# Vine Configuration & Workspace Manifest Reference

Vine provides isolated copy-on-write workspaces (**Strands**), polyglot build-cache normalizers, and the Two-Key integration gate for parallel multi-agent development.

This document details all configuration options, environment variables, the `vine.toml` file schema, and the `.vine.json` runtime manifest specification.

---

## 1. Environment Variables Reference

All Vine-controlled environment variables use the canonical `VINE_` prefix.

| Variable | Fallback Alias | Type | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `VINE_WORKSPACES_DIR` | `VINE_WORKSPACES` | Path | `~/Development/workspaces` | Base directory where Rift copy-on-write strands and git worktrees are provisioned. |
| `VINE_PROJECTS_DIR` | `VINE_DEV_DIR` | Path | `~/Development` | Base directory where canonical git repositories reside. |
| `VINE_CONFIG` | — | Path | *Auto-discovered* | Explicit path to project `vine.toml` configuration file. |
| `VINE_PRIMARY_BRANCH` | — | String | `main` | Default target branch for gate verification and fast-forward trunk merges. Overrides `vine.toml`. |
| `VINE_TEST_COMMAND` | — | String | *Auto-detected* | Semantic test/compiler command executed during Key 2 gate checks. Overrides `vine.toml` and CLI flags. |
| `VINE_VENV_POLICY` | — | Enum | `prompt` | Policy for isolated Python virtual environments inside strands (`prompt`, `auto_yes`, `auto_no`). |

---

## 2. Configuration File (`vine.toml`)

Vine discovers configuration by walking up from the current working directory to the nearest `vine.toml` or `.vine.toml` file.

### Complete Example

```toml
# vine.toml - Project Workspace & Verification Configuration

[project]
# Primary integration branch in canonical repository (e.g. main, trunk, develop)
primary_branch = "main"

[strand]
# Virtual environment copy policy: "prompt", "auto_yes", "auto_no"
venv_policy = "prompt"

# Directories containing large dependencies that should be shared or symlinked
vendor_dirs = ["deps", "vendor", "node_modules", ".zig-cache", "nimbledeps"]

[verification]
# Semantic gate command: live test runner or compiler check
# If omitted, Vine automatically detects ctest, cargo test, pytest, nimble test, or npm test.
test_command = "pytest -v tests/"
```

### Scaffolding Configuration

To generate a starter configuration file in the current directory:
```bash
vine config init
```

To display active configuration values:
```bash
vine config show
```

---

## 3. Runtime Manifest Specification (`.vine.json`)

Every strand created by `vine new <task_id>` contains a `.vine.json` metadata manifest in its root directory. This manifest tracks the strand's complete lineage, parent branch, merge base, and lifecycle verification status.

### JSON Schema

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "VineStrandManifest",
  "type": "object",
  "required": [
    "task_id",
    "project",
    "strand_path",
    "branch",
    "base_branch",
    "base_commit",
    "status",
    "created_at",
    "tool"
  ],
  "properties": {
    "task_id": {
      "type": "string",
      "description": "Unique task or issue identifier (e.g. task-4102)"
    },
    "project": {
      "type": "string",
      "description": "Canonical project name"
    },
    "canonical_repo": {
      "type": "string",
      "description": "Absolute filesystem path to the canonical git repository"
    },
    "strand_path": {
      "type": "string",
      "description": "Absolute filesystem path to the isolated strand workspace"
    },
    "branch": {
      "type": "string",
      "description": "Git branch name provisioned for this strand (e.g. strand/task-4102)"
    },
    "base_branch": {
      "type": "string",
      "description": "Target trunk branch for merge verification (e.g. main)"
    },
    "base_commit": {
      "type": "string",
      "description": "Initial 40-character commit SHA at strand creation time"
    },
    "intended_merge_base": {
      "type": "string",
      "description": "Computed merge-base SHA against canonical parent branch"
    },
    "status": {
      "type": "string",
      "enum": [
        "PROVISIONED",
        "IN_PROGRESS",
        "GATE_EVALUATING",
        "CONFLICTED",
        "GATE_FAILED",
        "GATE_PASSED",
        "READY_FOR_WEAVE",
        "WEAVED"
      ],
      "description": "Lifecycle and gate verification state"
    },
    "created_at": {
      "type": "integer",
      "description": "Epoch timestamp when strand was created"
    },
    "tool": {
      "type": "string",
      "enum": ["rift", "git-worktree"],
      "description": "Underlying workspace engine used"
    },
    "gate_results": {
      "type": "object",
      "properties": {
        "clean": { "type": "boolean" },
        "key1_mechanical": { "type": "string", "enum": ["PASS", "FAIL", "SKIPPED"] },
        "key2_semantic": { "type": "string", "enum": ["PASS", "FAIL", "SKIPPED"] },
        "test_command": { "type": "string" },
        "conflicts": { "type": "array", "items": { "type": "string" } },
        "compiler_output": { "type": "string" }
      }
    }
  }
}
```

### Lifecycle States

| State | Meaning |
| :--- | :--- |
| `PROVISIONED` | Workspace created, clean working tree, 0 commits ahead of trunk. |
| `IN_PROGRESS` | Active work underway (uncommitted edits or commits ahead of trunk). |
| `GATE_EVALUATING` | Two-Key Gate verification currently running. |
| `CONFLICTED` | Key 1 mechanical pre-check detected merge conflicts against trunk. |
| `GATE_FAILED` | Key 2 semantic test/compiler suite failed (non-zero exit code). |
| `GATE_PASSED` / `READY_FOR_WEAVE` | Both Key 1 and Key 2 passed 100% green. Ready for `vine weave`. |
| `WEAVED` | Changes fast-forward merged into canonical trunk; workspace pruned. |

---

## 4. The Two-Key Gate Protocol

Before any strand can be woven into canonical trunk, it must pass `vine gate`:

1. **Key 1 (Mechanical Mergeability)**:
   Executes an in-memory merge pre-check (`git merge-tree --write-tree`) against the target branch. Verifies that the branch can merge cleanly without textual conflicts.
2. **Key 2 (Semantic Compilation & Tests)**:
   Executes the configured `test_command` inside the strand directory. Textual mergeability does not imply compilation correctness; Key 2 guarantees the code compiles and tests pass.

```bash
# Run gate verification:
vine gate

# Output as structured JSON:
vine gate --json
```

Once both keys pass:
```bash
vine weave
```
