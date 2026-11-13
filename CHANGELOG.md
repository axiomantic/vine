# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- **Clear UX Message on Already-Ratified and Already-Woven Strands (`src/gate.nim`, `src/vine.nim`)**:
  - `vine audit approve` and `vine audit reject` now perform an early state check before ticket and gate token validation.
  - If a strand is already in `["AUDIT_RATIFIED", "RATIFIED"]`, exits with code 0 returning `status: "already_ratified"` and `Already ratified by <auditor> at <ratified_at>; nothing to do.` instead of failing with `Strand has not passed Keys 1 & 2`.
  - If a strand is already in `["WOVEN", "MERGED", "WEAVED", "CLOSED"]`, exits with code 0 returning `status: "already_woven"` and `Already woven into trunk by <woven_by> at <woven_at>; nothing to do.` instead of failing.
  - Added timestamp formatting helper `formatAuditEpochOrStr` converting epoch timestamps to human-readable UTC string format (`yyyy-MM-dd HH:mm:ss 'UTC'`).

### Changed
- **Release Version Bump (`vine.nimble`, `package.json`, `src/vine.nim`)**:
  - Bumped version from 0.2.20 to 0.2.21.

## [0.2.21] - 2026-11-12

### Fixed
- **Per-Auditor Delivery Ticket Verification (`scripts/strand.lua`, `src/redis_client.nim`, `src/gate.nim`)**:
  - Added support for per-auditor audit ticket hashes (`audit_ticket_hash:<auditor_lower>`) alongside scalar `audit_ticket_hash`.
  - When `vine submit` multicasts `STRAND_SUBMITTED` across multiple listeners or auditors on `@<project>`, `vine audit approve`, `vine audit reject`, and Lua/Redis verification accept `--ticket <hex>` matching either `audit_ticket_hash:<auditor_lower>` or `audit_ticket_hash`.
  - Updated `set_audit_ticket` in Lua and Redis client to accept optional `auditor_name` parameter and set `audit_ticket_hash:<auditor_lower>`.
- **Gate & Weave State Preservation (`src/gate.nim`, `src/weave.nim`, `scripts/strand.lua`, `src/redis_client.nim`)**:
  - Fixed `recordGateFailure` in `src/gate.nim` to preserve resting state if prior state was in `["SUBMITTED", "READY_FOR_AUDIT", "RATIFIED", "AUDIT_RATIFIED"]` instead of downgrading to `IN_PROGRESS` on gate test failures.
  - Fixed `doBraidGate` in `src/gate.nim` when run without `--submit` so strands in `SUBMITTED` or `READY_FOR_AUDIT` state maintain `SUBMITTED` status instead of downgrading to `GATE_PASSED`.
  - Added working `test_command` persistence to Redis extra attributes in `doBraidGate` and `submitStrandRedis` so subsequent `vine gate` or `vine weave` invocations reuse the working command.
  - Added `testCmdParam` support to `doBraidWeave` and `--test-command` CLI flag parsing in `vine weave`.
  - In `doBraidWeave`, when `--allow-unaudited` is used on a strand that already passed Keys 1 & 2 (`GATE_PASSED`, `SUBMITTED`, `RATIFIED`) with matching `merge_tree_sha`, skip re-running `doBraidGate`.
  - In `scripts/strand.lua` and `src/redis_client.nim`, updated `weave` to allow weaving when `allow_unaudited` is true and strand state is `GATE_PASSED` or `SUBMITTED`.
- **CMake & Nimble Test Detection Ordering (`src/gate.nim`)**:
  - In `detectTestCommand`, reordered `.nimble` detection before unconfigured CMake so ESP-IDF + Nim hybrid repositories (such as `remocha`) run `nimble test` instead of attempting unconfigured CMake `ctest`.
  - CMake `ctest --test-dir build --output-on-failure` is only returned if `build/CTestTestfile.cmake` or `build/CMakeCache.txt` exists.
- **Ephemeral Tool Artifact Filtering in Git Status Checks (`src/gate.nim`, `src/strand.nim`)**:
  - Updated porcelain status checks in `doStrandAudit approve` and `doStrandStatus` to ignore untracked (`?? `) ephemeral lock and backup files (`.kicad_prl`, `-bak`, `.lck`, `.lock`, `.tmp`, `.swp`, `~`, `.DS_Store`) left behind by external test tools (such as `kicad-cli`).

## [0.2.20] - 2026-11-11

### Added
- **Strict Fail-Fast Author & Auditor Identity Resolution (`src/strand.nim`, `src/gate.nim`, `src/weave.nim`, `src/redis_client.nim`)**:
  - Purged silent OS `$USER`/`$USERNAME` fallback across all subcommands (`vine submit`, `vine audit approve`, `vine audit reject`, `vine weave`).
  - Added multi-tier resolution: explicit flag (`--author`, `--agent`, `--worker`, `--agent-id`, `--id`) -> `RHIZO_AGENT_ID` / `RHIZO_AGENT_NAME` -> `rhizo:sessions` reverse-lookup for current coding harness session IDs (`ANTIGRAVITY_CONVERSATION_ID`, `OPENCODE_SESSION_ID`, `PI_SESSION_ID`, `CLAUDE_CONVERSATION_ID`, `CODEX_SESSION_ID`, `RHIZO_SESSION_ID`) -> git config / manifest.
  - If unresolved, fails fast with exit code 1 and actionable usage guidance.
- **Role Name as Identity Rejection (`ERR_ROLE_AS_ID`) (`src/strand.nim`, `src/gate.nim`, `src/vine.nim`, `skills/vine/SKILL.md`)**:
  - Added strict mechanical rejection when generic role titles (`implementer`, `auditor`, `architect`, `orchestrator`, `worker`, `builder`, `reviewer`, `lead`, `agent`, `default`, `eek`) or compound titles ending with `-implementer`, `-architect`, `-orchestrator` are passed as `--author` or `--auditor`.
  - Exits code 1 with `ERR_ROLE_AS_ID` guidance instructing the agent to pass their sovereign unique codename allocated via `rhizo name` (e.g. `rhizo-sequoia`), unless explicitly bypassed via `--allow-role-id` or `VINE_ALLOW_ROLE_IDS=1`.
  - Updated CLI usage strings, examples, and skill documents from role titles to `<agent_id>` with unique codename examples.
- **Canonical Root Subcommand Execution (`src/weave.nim`, `src/gate.nim`, `src/strand.nim`, `src/vine.nim`)**:
  - `vine weave <task_id>`, `vine gate <task_id>`, and `vine submit <task_id>` can now be executed directly from canonical repository root without `cd`-ing into the strand directory, resolving the strand path via `findStrandManifest(task_id)`.
  - When invoked from canonical root without `<task_id>`, fails fast with exit code 1, displaying active strands (`vine list`) and command-specific usage.
- **Intuitive Flag Synonyms & Strict Unknown Option Rejection (`src/vine.nim`, `src/update.nim`)**:
  - Added synonyms across all subcommands: `<task_id>` positionally and via `--task <id>`, `--task-id <id>`, `--strand <id>`; `--base` / `-b`; `--dir` / `-d`; `--commit` / `--message` / `-m`; `--listen` / `-l`; `--evidence` / `--notes`; `--reason` / `--notes` / `--findings`.
  - Replaced silent `else: discard` in option parsing loops with strict unknown-flag rejection (`elif a.startsWith("-"):`) that outputs valid flags and exits with code 2 across all subcommands.
- **Auditor Merge-Clerk Decoupling: Retiring `--weave` on `audit approve` (`src/vine.nim`, `src/gate.nim`)**:
  - Retired `--weave` on `vine audit approve`: auditors only ratify Key 3; the Lead Orchestrator executes `vine weave`.
  - Passing `--weave` to `vine audit approve` fails fast with exit code 2 and explicit decoupling guidance.

## [0.2.19] - 2026-11-11

### Added
- **Evidence-Bound Audit Approval (`--evidence <text>`) (`src/vine.nim`, `src/gate.nim`, `src/guide.nim`, `skills/vine/SKILL.md`)**:
  - `vine audit approve` strictly enforces substantive verification evidence via `--evidence <text>` (or `--notes <text>` when `>= 20` characters).
  - `--evidence` must be at least 20 characters and must cite at least one changed file basename from the strand diff (`git diff --name-only <base>...HEAD`, excluding `CHANGELOG.md`).
  - Generic boilerplate (e.g. `"LGTM"`, `"Five pillars verified"`) fails with `ExitGateAuditViolation` (code 6).
  - `--force` is strictly prohibited from bypassing the evidence requirement.
  - Stamped `evidence` and `notes` into Redis strand state and manifest.
  - Updated audit approval command recommendations across CLI hints and documentation to recommend `vine audit approve <task_id> --auditor <name> --ticket <hex> --evidence "Verified <file>:<symbol> and test <test_file>"`, clarifying that the Auditor ratifies Key 3 while the Orchestrator executes `vine weave`.
- **Pre-Plan Contract Skeleton Mode (`--skeleton`) (`src/vine.nim`, `src/gate.nim`, `src/redis_client.nim`, `scripts/strand.lua`, `src/strand.nim`)**:
  - Added `--skeleton` flag to `vine gate` and `vine submit` for pre-plan contract skeleton strands (`strand/task-<slug>-skeleton` branching from `epic/<slug>` parent branches).
  - Skips Two-Point Diff application consumer requirement for interface stubs, allowing shared types/headers/stubs in `src/` to be submitted without application callers yet (while still rejecting 100% test strands).
  - Permits `UNIMPLEMENTED_CONTRACT` test failures during Key 2 test runner execution when `--skeleton` is active.
  - Stamps `is_skeleton = true` in Redis strand state (`strand:<id>` and `vine:strand:<id>`).
  - Exposed in `vine status` and `vine list --json`.
- **Key 3 Audit Hardening: Mandatory `vine audit inspect` Diff Review (`src/vine.nim`, `src/gate.nim`, `src/redis_client.nim`, `scripts/strand.lua`)**:
  - Added `vine audit inspect [<task_id>] [--json]` subcommand: displays the full production diff against base commit (filtering out lockfiles and artifacts) into the auditor's context window.
  - Stamps `inspected_tree_sha` and `inspected_at` in Redis strand state upon inspection.
  - Enforces that `vine audit approve` strictly requires `inspected_tree_sha == merge_tree_sha`, mechanically preventing approval without prior diff inspection (`ExitGateAuditViolation = 6`).
  - Clears `inspected_tree_sha` upon any new `vine submit` or tree change, enforcing re-inspection.
- **Strict Ticket Enforcement on `vine audit approve` (`src/gate.nim`, `scripts/strand.lua`, `src/redis_client.nim`)**:
  - Removed `--force` ticket bypass from `vine audit approve`: if `audit_ticket_hash` is recorded on the strand, an authentic `--ticket <hex>` is strictly required, preventing unratified approvals even with `--force`.

### Changed
- **Purge Brittle Static Regex Whack-a-Mole from Defeat Device Scanner (`src/gate.nim`, `src/guide.nim`)**:
  - Removed brittle, overfitted string checks (`hasMockFallback` / `MockFallback` and `hasAblationToggle` / `if not ablation_applied:`) from `scanForDefeatDevices`.
  - Removed scanner self-exemption hacks for `src/gate.nim` and `src/guide.nim`.
  - Preserved structural prompt-interceptor detection (`in q`, `in query`, `q.contains`, etc.) and `UNIMPLEMENTED_CONTRACT` test checks.

## [0.2.18] - 2026-11-09

### Added
- **Delivery Ticket Verification (`--ticket <hex>`) & Bypass (`--force`) in `vine audit` (`src/vine.nim`, `src/gate.nim`, `src/redis_client.nim`, `scripts/strand.lua`, `tests/test_vine.py`)**:
  - Implemented delivery ticket verification in `vine audit approve|reject`: validates `--ticket <hex>` against `audit_ticket_hash` recorded on the strand in Redis (`ExitGateAuditViolation = 6` on mismatch or missing ticket).
  - Added atomic `set_audit_ticket` Lua action in `scripts/strand.lua` and `setAuditTicketRedis` in `src/redis_client.nim` with offline fallback.
  - Clears `audit_ticket_hash` to `""` upon successful ratification, rejection, or strand re-submission.
  - Added `--force` flag to `vine audit approve|reject` to allow manual operator bypass of ticket checks when required.
  - Preserved backward compatibility: strands without `audit_ticket_hash` allow unticketed approvals/rejections as before.
- **Atomic `vine audit approve --weave` & `vine audit --listen` (`src/vine.nim`, `src/gate.nim`)**:
  - Added `--weave` flag to `vine audit approve`: automatically invokes fast-forward trunk merge via `doBraidWeave` immediately upon successful ratification and attaches the weave result to the audit response.
  - Added `--listen` flag to `vine audit approve|reject`: re-arms foreground listener (`runRhizoListen`) for the auditor session after completing audit operations.
- **Auto-Complete Rhizo Task on `vine weave` (`src/weave.nim`)**:
  - Integrated automatic `rhizo task complete <task_id> --gate-token <gate_token>` execution upon successful trunk weave when `rhizo` CLI is available.

### Fixed
- **Prevent `GATE_FAILED` as Permanent Resting State (`src/gate.nim`, `src/strand.nim`, `tests/test_vine.py`)**:
  - When `doBraidGate` fails (due to semantic test failures, defeat devices, changelog violations, or two-point diff defects), the strand state is preserved as `IN_PROGRESS` (or `PROVISIONED`) and the failure is recorded in `last_gate_error`, preventing workspaces from being permanently locked in `GATE_FAILED`.
  - Updated `doStrandStatus` to expose `last_gate_error` in JSON and status outputs.
- **Canonical Trunk Protection in `vine submit` & Complete `.vine.json` Purge (`src/gate.nim`, `src/strand.nim`, `src/guide.nim`, `SKILL.md`, `README.md`)**:
  - Protected canonical repository root against direct `vine submit` execution: if run on canonical trunk (`main`/`master` without active strand manifest), checks whether author has a single active strand in Redis to auto-resolve; otherwise fails fast with code 1 (`"Error: Cannot run vine submit directly on canonical trunk. cd into your strand or pass <task_id>."`).
  - Purged all remaining `.vine.json` legacy on-disk scanners from `doStrandList` and `findStrandManifest` in favor of pure Redis state and `.git/config` `vine.taskId`.
  - Updated documentation, guides, and skills to completely eliminate `.vine.json` references.
- **Prevent `.envrc` Self-Recursion & Preserve Tracked `.envrc` (`src/strand.nim`, `src/guide.nim`, `AGENTS.md`, `tests/test_vine.py`)**:
  - Guarded parent `.envrc` sourcing in synthesized strand `.envrc` files with an inode equality check (`[ ! "$PWD/.envrc" -ef <repoDir>/.envrc ]`), preventing infinite direnv recursion loops if `.envrc` is woven into canonical repository root.
  - Checked whether `.envrc` is already tracked in git in `repoDir` (`git ls-files --error-unmatch .envrc`); if tracked, `vine new` preserves the tracked `.envrc` verbatim and does not overwrite it with the synthesized wrapper.
  - Added strand-local `.envrc` to `info/exclude` in non-tracked repositories so `git add -A` inside strands never stages or commits synthesized `.envrc` files into the project repository.
  - Added automated test cases `test_vine_strand_envrc_generation` and `test_vine_strand_tracked_envrc_preservation` in `tests/test_vine.py`.

## [0.2.17] - 2026-10-29

### Fixed
- **Subcommand `--help` Interception & Accidental Workspace Guard (`src/vine.nim`, `src/strand.nim`, `tests/test_vine.py`)**:
  - Added `hasHelpFlag` and `printSubcommandHelp` to intercept `--help` and `-h` across all subcommands (`new`, `gate`, `submit`, `audit`, `sync`, `weave`, etc.) early with exit code 0.
  - Hardened `doStrandNew` and `main()` argument parsing to strictly reject task IDs starting with `-`, preventing flags from being captured as positional task IDs and creating accidental workspaces or branches (e.g. `strand/--help`).
  - Added automated test `test_vine_subcommand_help_and_flag_guards` covering subcommand help outputs and flag rejection.
- **Canonical Path Resolution for Symlinks and Windows Drive Letters (`src/config.nim`, `src/strand.nim`)**:
  - Exported `canonicalizePath(p: string)` via `expandFilename(p).normalizedPath` in `src/config.nim`.
  - Canonicalized `strand_path` in `doStrandNew` before persisting to Redis and returning in JSON result.
  - Enhanced `findStrandManifest` to index and match against canonical realpaths in addition to raw normalized paths.

### Documentation
- **Skill Reconciliation (`SKILL.md`)**:
  - Reconciled root `SKILL.md` with `skills/vine/SKILL.md` to ensure identical Three-Key Gate, Rift copy-on-write workspace, and turn-end audit instructions across global and repository skill definitions.

## [0.2.16] - 2026-10-28

### Fixed
- **Empty Strands Array Encoding in `vine list` (`scripts/strand.lua`, `src/strand.nim`)**:
  - Fixed an `AssertionDefect` crash (`node.kind == JArray`) in `vine list` when no strands exist. Updated `scripts/strand.lua` to explicitly return `{"status":"OK","count":0,"strands":[]}` instead of letting `cjson.encode` encode an empty table as `{}`.
  - Hardened `src/strand.nim` parser to safely handle both `JArray` and `JObject` responses from Redis.

### Documentation
- **Multi-Agent Guide Harmonization (`AGENTS.md`)**:
  - Updated embedded Rhizo guide to `v2.0` and Garden guide to `v2.7` with the Project-Scoped Fleet Mandate and Anti-Hijacking Invariant.

## [0.2.15] - 2026-10-25

### Added
- **Atomic `vine submit --listen` & `vine submit --commit <msg>` (`src/vine.nim`, `src/gate.nim`, `src/notify.nim`)**:
  - Added CLI flag `--listen` (`-l`) to `vine submit`, executing `rhizo listen <author>` in the foreground immediately after verifying Keys 1 & 2 (merge-tree, tests, changelog) and recording `READY_FOR_AUDIT` in Redis.
  - Added CLI flag `--commit <msg>` to `vine submit`, automatically staging (`git add -A`) and committing dirty working tree changes before running Three-Key gate validation.
  - Prevents the ceremony pause and race condition where workers would re-arm their listener prematurely before submitting or leave uncommitted changes unverified.
  - Added `runRhizoListen` helper in `src/notify.nim` and integrated with project routing.
- **Zero-Disk Redis Strands & Distributed Transport (`scripts/strand.lua`, `src/redis_client.nim`, `src/strand.nim`, `src/gate.nim`, `src/weave.nim`)**:
  - Implemented pure Redis strand state management using atomic Lua engine (`scripts/strand.lua`) and standalone high-performance RESP client (`src/redis_client.nim`).
  - Added reverse path compound indexing (`vine:strands:by_path`: `<machine_id>:<normalized_absolute_path>` -> `<task_id>` and `<normalized_absolute_path>` -> `<task_id>`), eliminating filesystem scanning and enabling O(1) strand resolution.
  - Implemented 5-tier cascading strand resolver in `findStrandManifest` (explicit arg/ID -> branch convention `strand/<id>` -> isolated git worktree config `vine.taskId` -> reverse path index -> search).
  - Dual-mode strand transport: co-located strands (`strand.machine_id == local_machine_id`) execute local merge-tree and worktree pruning, while remote strands (`strand.machine_id != local_machine_id`) fetch branch commits from remote git origin (`git fetch origin <branch>:<branch>`) before evaluating the Three-Key gate and executing fast-forward weave.
  - Ghost strand auto-pruning: automatically cleans up orphaned/stale Redis strand records when local workspace directories or canonical repositories are deleted externally.

### Removed
- **Eradication of On-Disk JSON Coordination Files**:
  - Completely eliminated all file read and write callsites for `.vine.json`, `.vine/strand.json`, and metadata lockfiles across `src/strand.nim`, `src/gate.nim`, `src/weave.nim`, and CLI commands.
  - Zero coordination JSON manifests are created, read, or staged in git workspaces.
  - Inverted test assertions to mechanically verify the complete absence of on-disk coordination manifests.

## [0.2.14] - 2026-10-24

### Added
- **Dynamic Leader Discovery & Orchestrator Purge (`src/notify.nim`, `src/strand.nim`, `src/vine.nim`, `tests/test_notify.nim`)**:
  - Eliminated legacy hardcoded `<project>-orchestrator` fallbacks and purged `aliasOf` crutches across strand creation and notification routing.
  - Implemented 3-step dynamic leader discovery hierarchy in `notifyStrandEvent`:
    1. **Direct Origin**: Routes directly to `manifest["orchestrator"]` or `manifest["created_by"]` if present and active.
    2. **Elected Leader**: Queries `rhizo leader status orchestrator:<project>` for active leader lease if direct origin is absent or inactive.
    3. **Multicast Fallback**: Broadcasts to `@<project>` when both direct origin and elected leader are absent.
  - Added support for `--orchestrator`, `--created-by`, and `--from` flags in `vine strand new` and `vine new`, recording both `orchestrator` and `created_by` in `.vine.json` and `.vine/strand.json`.
  - Fixed CLI parsing in `src/vine.nim` for `vine strand new <task_id>` subcommand invocation.
  - Added negative controls and dynamic leader discovery tests in `tests/test_notify.nim`.
- **Strand Lifecycle Notifications with Orchestrator Awareness & Multicast Fallback (`src/notify.nim`, `src/gate.nim`, `src/weave.nim`, `src/vine.nim`, `tests/test_notify.nim`)**:
  - Implemented `src/notify.nim` provider module dispatching real-time notifications over Rhizo Redis bus during strand lifecycle milestones: `STRAND_SUBMITTED`, `AUDIT_RATIFIED`, `AUDIT_REJECTED`, and `STRAND_WOVEN`.
  - Added dynamic orchestrator awareness (`isOrchestratorActive`): verifies orchestrator liveness via `rhizo who` before routing directly to the conductor.
  - Added automatic swarm multicast fallback (`rhizo broadcast --tags <project>`) when an orchestrator is unset, inactive, or unreachable, ensuring peer-to-peer swarms maintain continuous situational awareness.
  - Added secondary direct notifications to strand authors on audit approvals/rejections and to authors/auditors on trunk weave.
  - Added `--no-notify` CLI flag and `VINE_NO_NOTIFY` environment variable for automated testing and quiet execution.
  - Comprehensive unit and integration test suite in `tests/test_notify.nim`.

## [0.2.13] - 2026-10-22

### Added
- **Three-Key Integration Gate & Key 3 Adversarial Audit (`src/gate.nim`, `src/vine.nim`, `src/weave.nim`)**:
  - Upgraded Vine integration gate to the Three-Key Gate: Key 1 (mechanical merge-tree), Key 2 (semantic compiler/tests + changelog), and Key 3 (independent adversarial audit ratification).
  - Implemented `vine submit` command transitioning strands to `status: "READY_FOR_AUDIT"` after passing Keys 1 and 2.
  - Implemented `vine audit approve --auditor <name>` and `vine audit reject` commands with cryptographic HMAC `audit_token` stamping.
  - Enforced "The Worker is NOT the Auditor" invariant: self-auditing by strand author is rejected with exit code 6 (`ExitGateAuditViolation` / `GATE_AUDIT_VIOLATION`).
  - Added Key 3 ratification enforcement to `vine weave` blocking un-audited trunk merges unless `--allow-unaudited` is explicitly passed.
  - Added automated Garden task seed harvesting and roadmap sync in `vine weave` upon fast-forward merge into canonical trunk.
- **Anti-Defeat-Device Scan & Autonomous Audit Mandate (`src/gate.nim`, `src/config.nim`, `src/vine.nim`)**:
  - Implemented mechanical Volkswagen Defeat Device scanner (`scanForDefeatDevices`) in `vine gate` and `vine submit`, detecting prompt/query keyword interceptors (e.g. `if 'flight game' in q`) and theatrical mock questionnaires in application code outside test suites.
  - Rejects defeat devices with dedicated exit code `7` (`ExitGateDefeatDeviceViolation`). Added `--allow-defeat-devices` CLI flag and `allow_defeat_devices` config in `vine.toml` for explicit bypass.
  - Codified the Autonomous Intensive Audit Mandate: intensive Five-Pillar adversarial audits are Standard Operating Procedure (SOP), pre-authorized, and autonomous across the Triad without requiring operator input.

## [0.2.12] - 2026-10-18

### Added
- **Pre-Weave Changelog Gate (`src/gate.nim`, `src/config.nim`, `src/vine.nim`)**:
  - Gated changelog verification in `vine gate` (and `vine weave`): detects repository changelog files (`CHANGELOG.md`, `changelog.md`, `CHANGES.md`, etc.).
  - Enforces that any strand with changes must modify the changelog under the `## [Unreleased]` section (or equivalent).
  - Rejects missing changelog modifications with dedicated exit code `5` (`ExitGateChangelogViolation` / `GATE_CHANGELOG_VIOLATION`).
  - Added `--allow-no-changelog` CLI flag, `allow_no_changelog` config option in `vine.toml`, and `VINE_ALLOW_NO_CHANGELOG` environment variable to bypass checks when changes are internal or test-only.
  - Added `--ensure-unreleased` flag to `vine gate` to automatically scaffold `## [Unreleased]` if missing.
- **First-Class `vine changelog` Subcommand (`src/gate.nim`, `src/vine.nim`)**:
  - `vine changelog [entry]`: Appends bulleted changelog entries under target section (defaults to `## [Unreleased]`, configurable via `--section <name>`).
  - `--ensure-unreleased`: Scaffolds `## [Unreleased]` before the first version heading if not already present.
  - `--check`: Validates whether the changelog exists, has an unreleased section, and is modified in git diff.
- **Vine Guide v1.7 (`src/guide.nim`)**:
  - Codified the Pre-Weave Changelog Invariant in Section 1 and Section 4 of the canonical guide.
- **Tripwire-Supervised Test Suite (`tests/test_changelog_gate.nim`)**:
  - Comprehensive unit and integration test suite asserting `hasUnreleasedSection`, `ensureUnreleasedSection`, `addChangelogEntry`, `doChangelogOperation`, and `doBraidGate` exit code 5 enforcement and bypass invariants.

## [0.2.11] - 2026-10-17

### Added
- **Triad Update Checking Engine (`src/update.nim`, `src/vine.nim`)**:
  - Unified 24-hour update cadence checking for `garden`, `rhizo`, and `vine` cached in `~/.config/axiomantic/updates.json`.
  - Smart installation kind auto-detection (`dev_source` git checkout, `local_npm`, `homebrew`, `pnpm`, `yarn`, `bun`, `standalone_binary`, `global_npm`).
  - Automatic `<!-- TRIAD_UPDATE_RIDER -->` prompt riders attached to `vine status` during interactive use.
  - Full suppression in Autonomous Mode (`AUTONOMOUS_MODE=1` or `.autonomous`) and JSON mode (`--json`).
  - Added `vine update` subcommand supporting `--check`, `--apply`, `--skip <pkg@ver>`, `--disable`, `--enable`, and `--json`.
- **Three-Key Gate & Literal Fidelity Mandate (Vine Guide v1.6)**:
  - Formally codified the Three-Key Gate: Key 1 Mechanical, Key 2 Semantic Test Runner, Key 3 Adversarial Code Audit Pump.
  - Strict Literal Fidelity & Reference Parity Mandate rejecting "good enough for happy paths" approximations.
  - Structural Assertion Rigor rejecting loose partial assertions and enforcing complete object equality.

### Fixed
- **Cross-Platform Windows Process Supervision (`src/process.nim`)**:
  - Fixed Windows CI hang by adding `p.hasData()` and pipe draining in `execCmdExWithTimeout`.
  - Replaced POSIX `pgrep` with `taskkill /F /T /PID` on Windows in `killProcessTree`.
- **CLI & Test Suite Compatibility (`src/vine.nim`, `tests/test_vine.py`)**:
  - Added `--allow-no-tests` flag pass-through to `vine weave`.
  - Updated pytest assertions for Vine Guide v1.6 and anti-green-mirage gate requirements.

## [0.2.10] - 2026-10-17

### Added
- **Forensic Timeout Rail for Two-Key Gate (`src/process.nim`, `src/gate.nim`, `src/vine.nim`)**:
  - Replaced bare `execCmdEx` test execution with supervised `execCmdExWithTimeout` using process group supervision and recursive child process tree termination (`killProcessTree` via `pgrep -P` and `SIGKILL`).
  - Added configurable timeout thresholds: default 180s, overridable via `--timeout <sec>` CLI flag and `VINE_GATE_TIMEOUT` environment variable.
  - Added dedicated exit code `4` (`ExitGateTimeout` / `EXIT_GATE_TIMEOUT`) and strand manifest lifecycle state `GATE_TIMEOUT`.
  - Structured Forensic Crash Envelope: captures and dumps exact elapsed time, command that timed out, and all stdout/stderr captured up to the freeze point to pinpoint deadlocks, port collisions, or unhandled hangs.
  - Added Tripwire-verified test coverage in `tests/test_gate_advanced.nim` asserting that frozen commands terminate at timeout and update manifest state.

## [0.2.9] - 2026-10-14

### Added
- **Strand Directory & Manifest Auto-Resolution (`src/strand.nim`, `src/weave.nim`, `src/gate.nim`)**:
  - Added exported `findStrandManifest` to locate registered workspace strands by `task_id`, branch name, or directory path.
  - Updated `vine weave` and `vine gate` to automatically resolve target strand paths and manifest metadata when invoked from canonical trunk with a branch or `task_id` without requiring `--dir`.
  - Added automatic fallback to manifest branch name when `branchParam` matches a task identifier rather than a literal git branch.
  - Added comprehensive test coverage in `tests/test_vine.py` (`test_vine_weave_and_gate_auto_resolve_by_task_id`).

## [0.2.8] - 2026-10-14

### Added
- **Post-Push CI Verification Timer Guideline (`src/guide.nim`, `SKILL.md`, `skills/vine/SKILL.md`)**:
  - Embedded loose guidelines in the Two-Key Gate & Weaving protocol to schedule periodic CI status checks (default every 5m, max 12 checks / 1hr) after weaving and pushing to remote trunk.
- **Nomenclature Cleanup (`AGENTS.md`, `scripts/install.sh`)**:
  - Renamed remaining `Locutus` and `Braid` references across rule templates and install scripts to `Rhizo` and `Vine`.

## [0.2.7] - 2026-10-14

### Added
- **Closed-Circuit Two-Point Diff Mandate (Vine Guide v1.4)**:
  - Formally codified the requirement that every strand deliverable must contain both a Provider and an active Consumer call-site in live entrypoints, routers, CLI dispatchers, or UI. Hermetic modules tested solely by their own unit tests are strictly prohibited as incomplete shelfware.
- **Holistic Production Integration (Anti-Stub / Anti-Toy)**:
  - Deliverables must actually holistically integrate with real application state and production error paths rather than mock heuristics or dummy stubs.
- **Aggressive Replacement Purge (Zero Dead Code)**:
  - Obsolete code, deprecated functions, and vestigial fallbacks targeted for replacement MUST be deleted in the same strand diff.
- **Closed-Circuit Audit in Two-Key Gate**:
  - Embedded the Closed-Circuit audit step in the weaving protocol in `guide.nim` (`v1.4`), `SKILL.md`, and `skills/vine/SKILL.md`.

## [0.2.6] - 2026-10-13

### Added
- **Worker & Orchestrator Identity Attestation (`src/strand.nim`, `src/vine.nim`)**:
  - Added `--worker <agent>` and `--orchestrator <agent>` options (with automatic `RHIZO_AGENT_NAME` / `VINE_WORKER` environment detection) to `vine new`.
  - Automatically writes `.vine/strand.json` identity attestation metadata alongside `.vine.json` to bind each isolated strand to its owning sovereign worker and orchestrator.
- **Internal Metadata Filtering in Strand Status (`src/strand.nim`)**:
  - Updated `doStrandStatus` dirty-working-tree calculation to filter out `.vine/` and `.vine/strand.json` internal coordination files alongside `.vine.json`, `.envrc`, and `.venv`, preventing false-positive dirty strand states.
- **Comprehensive Dual-Onboarding Documentation Suite (`AGENTS.md`, `README.md`, `docs/`)**:
  - Authored `docs/strand_lifecycle.md` (Rift CoW vs. Git worktree provisioning, vendoring fast-path, `.venv` relocatability policy), `docs/two_key_gate.md` (Key 1 `git merge-tree --write-tree` mechanical check + Key 2 live compiler/test runner cascade), `docs/cache_normalization.md` (`.envrc` ccache, Cargo, Nimcache, and uv link-mode normalization across strands), and `docs/cli_reference.md` (complete CLI command & exit code reference).
  - Updated `AGENTS.md` and `README.md` with structured onboarding maps for both human developers and LLM agents.
- **Test Suite Expansion (`tests/test_vine.py`)**:
  - Added identity attestation and `.vine/strand.json` dirty-status filtering test coverage.

## [0.2.5] - 2026-10-10

### Added
- **POSIX Double-Dash End-of-Options Custom Runner Pattern (`vine gate -- <command...>`)**:
  - Added support for `-- <command...>` in `vine gate` (and `vine check`) to cleanly specify custom compiler and test runner commands without nested quotation or escaping.
  - Automatically joins and shell-quotes trailing `argv` parameters, eliminating JSON string escaping errors in autonomous agent harnesses.
  - Retained `--test-command <cmd>` as a backwards-compatible option.
  - Added test coverage in `tests/test_vine.py` for passing and failing custom test suites invoked via `--`.

## [0.2.4] - 2026-10-09

### Added
- **Sovereign Worker Allocation Invariant (Vine Guide v1.2)**:
  - Formally established the Sovereign Worker Allocation Invariant: workspaces (Strands) are allocated strictly 1:1 to sovereign, dedicated worker sessions.
  - Prohibited assignment of ephemeral harness-internal subagents to strand directories to prevent git index lock contention and cache corruption.
  - Synchronized complete WISM state diagrams across `SKILL.md` and `skills/vine/SKILL.md`.
  - Bumped `GuideVersion` to `v1.2` and updated `tests/test_vine.py`.

## [0.2.3] - 2026-10-07

### Added
- **Unified Work Item State Machine (WISM) Integration (Module 18)**:
  - Embedded the full 10-state lifecycle specification and transition diagrams into `skills/vine/SKILL.md`.
  - Added Two-Key integration gate state transitions (`GATE_EVALUATING` $\rightarrow$ `READY_TO_WEAVE` / `GATE_PASSED`) and fast-forward trunk weaving mechanics.

## [0.2.2] - 2026-10-07

### Added
- **Post-Compaction Ceremony Restoration Invariant (GVR-010)**:
  - Mandated preservation of `SWARM_RUNTIME_STATE` and immediate re-reading of coordination skills (`vine`, `rhizo`, `garden`) upon agent resurrection following context compaction.
  - Mandated active strand inspection (`vine list`) before touching canonical trunk files.
- **Vine Coordination Guide v1.1**:
  - Upgraded canonical guide in `src/guide.nim` and `AGENTS.md` across repositories to formalize post-compaction ceremony recovery.

## [0.2.1] - 2026-10-06

### Added
- **Environment Variable Overrides & Precedence**:
  - Added support for `VINE_WORKSPACES_DIR` (and `VINE_WORKSPACES`) to customize the base directory where strands and worktrees are provisioned.
  - Added support for `VINE_PROJECTS_DIR` (and `VINE_DEV_DIR`) to locate canonical parent repositories.
  - Added `VINE_CONFIG`, `VINE_PRIMARY_BRANCH`, `VINE_TEST_COMMAND`, and `VINE_VENV_POLICY` environment variable overrides with highest priority over `vine.toml`.
- **Comprehensive Configuration & Manifest Documentation**:
  - Authored `docs/configuration.md`: Comprehensive reference table for all `VINE_*` environment variables, `vine.toml` keys (`primary_branch`, `venv_policy`, `vendor_dirs`, `test_command`), and `.vine.json` runtime manifest specification.
- **Enhanced Test Coverage**:
  - Added `test_vine_environment_variable_precedence` in `tests/test_vine.py` covering config overrides, custom paths, and workspace base directory relocation.

## [0.2.0] - 2026-10-06

### Added
- **Strand Parent Branching & Lifecycle State Machine (`vine new --parent`, `vine status`)**:
  - Added `--parent <branch>` support to `vine new` for stacked and nested branch virtualization, anchoring `intended_merge_base` and `base_commit` against primary trunk.
  - Implemented `vine status` to inspect commits ahead/behind, metadata filtering, and real-time lifecycle states (`PROVISIONED`, `IN_PROGRESS`, `GATE_EVALUATING`, `CONFLICTED`, `GATE_FAILED`, `GATE_PASSED`, `MERGED`, `ABANDONED`).
- **Multi-Strand Collision Forecasting (`vine collisions`)**:
  - Implemented `vine collisions` to scan active workspaces and forecast overlapping file modifications before merge/weaving, filtering out stale, merged, and closed strands with deterministic alphabetical sorting.
- **Enhanced Test Runner Discovery & Custom Test Commands (`vine gate`)**:
  - Added CMake test runner detection (`CMakePresets.json` / `CMakeLists.txt` -> `ctest --test-dir build --output-on-failure`).
  - Added `--test-command <cmd>` CLI flag to `vine gate` with manifest persistence in `.vine.json` so subsequent `vine weave` invocations inherit custom runners.
- **Mac App Sandbox / AMFI Hardening**:
  - Added ad-hoc macOS codesigning post-build hooks in `vine.nimble`.

### Fixed
- **Rift Mode Start-Point**: Fixed Rift strand creation ignoring `--parent` / `baseBranch` by explicitly passing the designated parent branch to `git checkout -b <branch> <parent>`.
- **Porcelain Metadata Filtering**: Fixed porcelain status parsing index shift on unstaged files (`line[3..^1]`), preventing uncommitted `.vine.json` and `.envrc` from falsely marking strands dirty.
- **Gate Failure Reporting**: Correctly surfaced `GATE_FAILED` lifecycle state in `vine status` instead of falling back to `IN_PROGRESS`.
- **Manifest Persistence Error Handling**: Guarded manifest disk writes on gate pass against filesystem exceptions.

## [0.1.6] - 2026-09-30

### Fixed
- **Dynamic Version Assertion**: Aligned test suite version validation with `package.json` dynamically across release builds.

## [0.1.5] - 2026-09-30

### Changed
- **Rift Workspace Engine & Bootstrapping**: Standardized `rift-snapshot` as the primary copy-on-write workspace virtualization engine across guides and skills, with `--worktree` supported as a fallback.
- **Operational Invariants Formalization**: Embedded strict XML invariant tags (`<CRITICAL>`, `<INVARIANT>`, `<FORBIDDEN>`) into the coordination guide and skill documentation enforcing the Two-Key Gate before weaving, 1:1 task-to-strand isolation, and zero Git index contamination.
- **Git Hygiene**: Updated `.gitignore` to prevent nimble cache and test compilation artifacts from being tracked.
- **Version Alignment**: Synchronized `const Version = "0.1.5"` across `src/vine.nim`, `vine.nimble`, and `package.json`.

## [0.1.4] - 2026-09-29

### Added
- **Fat-Package Pre-Bundled Native Binaries**: Npm package now pre-bundles native compiled binaries for all 5 major platforms (`darwin-arm64`, `darwin-x64`, `linux-x64`, `linux-arm64`, `win32-x64.exe`) inside `bin/binaries/`.
- **Zero-Latency Offline Execution**: Invocations immediately execute the matching bundled native binary with zero network requests, zero `curl`/`powershell` execution, and complete air-gap/corporate-proxy support.
- **Supply-Chain Security Hardening**: Completely eliminated runtime unverified binary downloads, external shell executions, and supply-chain scanner red flags.

## [0.1.3] - 2026-09-29

### Added
- **Architecture-Aware Binary Bootstrapping**: `bin/run.js` verifies binary compatibility and automatically downloads pre-built binaries from GitHub Releases into `~/.cache/vine/bin/`.
- **SKILL.md Self-Bootstrapping Section 0**: Added clear instructions for agents encountering a missing `vine` CLI to run `npm install -g @axiomantic/vine`.

### Fixed
- **Release CI Multi-Platform Assets**: Automated building and publishing of `vine-linux-amd64.tar.gz`, `vine-darwin-arm64.tar.gz`, etc.
- **Pure Universal NPM Package**: Excluded host binaries from npm package.

### Added
- **Comprehensive Contribution Guide (`CONTRIBUTING.md`)**: Complete guide covering system prerequisites (`mise`, `nim 2.2+`, `git 2.38+`), local development setup, build pipeline, the Two-Key Gate verification protocol, and Tripwire test execution.
- **Tripwire Negative Control Verification Suite**: Added end-to-end sandbox tests verifying Key 1 mechanical conflict rejection, Key 2 semantic compiler failure enforcement, strand re-synchronization (`braid sync`), and worktree lifecycle pruning.

### Changed
- **Documentation & Coordination Alignment**:
  - Synchronized embedded coordination guide in `AGENTS.md` via `locu guide install` to incorporate the latest capability-based execution tree and token efficiency rules.
  - Harmonized naming across `README.md` to reference `Locu` as the primary CLI name.
  - Updated `README.md` repository guide section to document default target path behavior for `braid guide install`.

### Fixed
- **Weave Directory Lock & Base Ref Passing**: Switched process working directory back to canonical repository root prior to pruning strand worktrees in `braid weave` to prevent macOS directory-in-use deletion errors. Corrected parameter pass-through to ensure effective base ref is passed to the Two-Key integration gate.

## [0.1.0] - 2026-09-26

### Added
- **Sub-Second Rift Copy-on-Write Strands**: High-performance isolated branch workspaces (`braid new <task-id>`) created via native Rift CoW cloning and git worktrees in <80ms with 0 initial disk block consumption.
- **Universal Dependency Cache Normalizer**: Zero-cost Rift/reflink cloning of pre-built dependency trees (`deps`, `nimbledeps`, `vendor`, `node_modules`, `.zig-cache`) directly from the canonical repository into newly spun strands in <80ms.
- **Two-Key Integration Gate (`braid gate`)**: Anti-green-mirage verification requiring both keys before weaving into canonical trunk:
  - **Key 1 (Mechanical)**: In-memory conflict pre-check using `git merge-tree --write-tree` in ~30ms without touching the working tree.
  - **Key 2 (Semantic)**: Automated live compilation and test suite execution inside the strand (`test_command` via `braid.toml` or heuristic detection).
- **Automated Trunk Weaving (`braid weave`)**: Atomic, fast-forward merge from strand to canonical trunk with post-merge strand cleanup and prune.
- **Polyglot Build Cache Environment Normalizer (`.envrc`)**: Automatic generation of normalized caching environment variables for C/C++ (`CCACHE_BASEDIR`, `CCACHE_NOHASHDIR`), Rust (`CARGO_TARGET_DIR`), Nim (`NIMCACHE`), and Python `uv` (`UV_LINK_MODE=clone`).
- **Python Virtual Environment (`.venv`) Relocatability Policy**: Automatic inspection of `pyvenv.cfg` for relocatability, preventing parent environment mutation and enforcing safe recreation policies.
- **Strand Lifecycle Management & Registry**:
  - `braid list`: Discovers and displays active strands, status, branch tracking, and manifest metadata across the workspace.
  - `braid prune`: Automatically detects and cleans up strands whose branches have already merged or been deleted.
  - `braid guide install|check|uninstall`: Embeds the standard Braid Coordination Guide directly into repository `AGENTS.md` files.
- **NPM Multi-Architecture Packaging**: Published as `@axiomantic/braid` on npm with cross-platform native binary wrappers for macOS, Linux, and Windows.

[Unreleased]: https://github.com/axiomantic/braid/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/axiomantic/braid/releases/tag/v0.1.0
