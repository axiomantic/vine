# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
- **Sub-Second APFS Copy-on-Write Strands**: High-performance isolated branch workspaces (`braid new <task-id>`) created via native macOS APFS CoW cloning (`clonefile` / `cp -c -R`) and git worktrees in <80ms with 0 initial disk block consumption.
- **Universal Dependency Cache Normalizer**: Zero-cost APFS cloning of pre-built dependency trees (`deps`, `nimbledeps`, `vendor`, `node_modules`, `.zig-cache`) directly from the canonical repository into newly spun strands in <80ms.
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
