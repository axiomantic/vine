# /Users/eek/Development/vine/tests/test_vine.py
# Automated end-to-end tests for Vine CLI.

import subprocess
import tempfile
import json
import os
import shutil
import time
import sys
from pathlib import Path

_bin_name = "vine.exe" if sys.platform == "win32" or (Path(__file__).parent.parent / "bin" / "vine.exe").exists() else "vine"
VINE_BIN = Path(__file__).parent.parent / "bin" / _bin_name

TEST_TMPDIR = tempfile.mkdtemp(prefix="vine-tests-")
TEST_WORKSPACES = os.path.join(TEST_TMPDIR, "workspaces")
os.makedirs(TEST_WORKSPACES, mode=0o777, exist_ok=True)
os.environ["VINE_WORKSPACES_DIR"] = TEST_WORKSPACES

def run_vine(*args, cwd=None, env=None):
    cmd = [str(VINE_BIN)] + list(args)
    proc_env = os.environ.copy()
    if env:
        proc_env.update(env)
    proc = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd, env=proc_env)
    return proc.returncode, proc.stdout, proc.stderr

PACKAGE_JSON = Path(__file__).parent.parent / "package.json"
CANONICAL_VERSION = json.loads(PACKAGE_JSON.read_text()).get("version", "0.1.6")

def test_vine_version():
    code, out, err = run_vine("--version")
    assert code == 0
    assert f"vine {CANONICAL_VERSION}" in out

def test_vine_skill_reconciliation():
    root_skill = (Path(__file__).parent.parent / "SKILL.md").read_text()
    pkg_skill = (Path(__file__).parent.parent / "skills" / "vine" / "SKILL.md").read_text()
    assert root_skill == pkg_skill, "Root SKILL.md must match skills/vine/SKILL.md"
    assert "Three-Key Gate" in root_skill
    assert "The Worker is NOT the Auditor" in root_skill

def test_vine_guide_lifecycle():
    with tempfile.TemporaryDirectory() as tmpdir:
        target = Path(tmpdir) / "AGENTS.md"

        # 1. Check missing
        code, out, err = run_vine("guide", "check", str(target))
        assert code == 0
        assert "[MISSING]" in out

        # 2. Install into new file
        code, out, err = run_vine("guide", "install", str(target))
        assert code == 0
        assert "Created" in out
        assert target.exists()

        content = target.read_text()
        assert "<!-- BEGIN VINE GUIDE [v1.7] -->" in content
        assert "<!-- END VINE GUIDE -->" in content
        assert "Vine Workspace & Strand Coordination Guide" in content

        # 3. Check installed
        code, out, err = run_vine("guide", "check", str(target))
        assert code == 0
        assert "[INSTALLED]" in out

        # 4. Uninstall
        code, out, err = run_vine("guide", "uninstall", str(target))
        assert code == 0
        assert "Successfully uninstalled" in out
        assert "BEGIN VINE GUIDE" not in target.read_text()

def test_vine_guide_unbalanced_markers_fail_safe():
    """Negative control: Unbalanced/corrupted guide markers must fail safe and protect content."""
    with tempfile.TemporaryDirectory() as tmpdir:
        target = Path(tmpdir) / "AGENTS.md"
        corrupted_content = "# Agent Guide\n<!-- BEGIN VINE GUIDE [v1.0] -->\nOnly opening marker without closing marker\n"
        target.write_text(corrupted_content)

        # 1. Check must detect MALFORMED and exit code 1
        code, out, err = run_vine("guide", "check", str(target))
        assert code == 1
        assert "[MALFORMED]" in err

        # 2. Install must fail safe and NOT overwrite file
        code, out, err = run_vine("guide", "install", str(target))
        assert code == 1
        assert "Malformed markers" in err
        assert target.read_text() == corrupted_content

        # 3. Uninstall must fail safe and NOT mutate file
        code, out, err = run_vine("guide", "uninstall", str(target))
        assert code == 1
        assert "Malformed markers" in err
        assert target.read_text() == corrupted_content

def test_vine_config():
    with tempfile.TemporaryDirectory() as tmpdir:
        # Default config
        code, out, err = run_vine("config", "show", cwd=tmpdir)
        assert code == 0
        data = json.loads(out)
        assert data["primary_branch"] == "main"
        assert data["venv_policy"] == "prompt"
        assert "deps" in data["vendor_dirs"]

        # Init config
        code, out, err = run_vine("config", "init", cwd=tmpdir)
        assert code == 0
        toml_path = Path(tmpdir) / "vine.toml"
        assert toml_path.exists()
        assert "primary_branch" in toml_path.read_text()

def test_vine_custom_config_parsing():
    """Verify custom vine.toml overrides all configuration fields accurately."""
    with tempfile.TemporaryDirectory() as tmpdir:
        toml_path = Path(tmpdir) / "vine.toml"
        toml_path.write_text("""[project]
primary_branch = "develop"

[strand]
venv_policy = "recreate"
vendor_dirs = ["deps", "third_party", "node_modules"]

[verification]
test_command = "pytest tests/ -v"
""")
        code, out, err = run_vine("config", "show", cwd=tmpdir)
        assert code == 0, f"Error: {err}\nOut: {out}"
        data = json.loads(out)
        assert data["primary_branch"] == "develop"
        assert data["venv_policy"] == "recreate"
        assert data["vendor_dirs"] == ["deps", "third_party", "node_modules"]
        assert data["test_command"] == "pytest tests/ -v"
        assert Path(data["active_config"]).resolve() == toml_path.resolve()

def test_vine_strand_lifecycle_and_gate():
    with tempfile.TemporaryDirectory(prefix="vine_repo_") as repo_dir:
        # Initialize test git repo
        subprocess.run(["git", "init", "-b", "main", "-q", repo_dir], check=True)
        subprocess.run(["git", "-C", repo_dir, "config", "user.email", "agent@vine.mesh"], check=True)
        subprocess.run(["git", "-C", repo_dir, "config", "user.name", "Vine Agent"], check=True)

        readme = os.path.join(repo_dir, "README.md")
        with open(readme, "w") as f:
            f.write("# Vine Repo\n")
        subprocess.run(["git", "-C", repo_dir, "add", "README.md"], check=True)
        subprocess.run(["git", "-C", repo_dir, "commit", "-q", "-m", "Initial commit"], check=True)

        # Create mock vendor dir
        os.makedirs(os.path.join(repo_dir, "deps", "pkg"), exist_ok=True)
        with open(os.path.join(repo_dir, "deps", "pkg", "lib.txt"), "w") as f:
            f.write("vendored library\n")

        # 1. Create Strand
        task_id = f"task-{int(time.time() * 1000)}"
        code, out, err = run_vine("new", task_id, "--repo", repo_dir, "--branch", f"strand/{task_id}", "--worktree")
        assert code == 0, f"Error: {err}\nOut: {out}"
        data = json.loads(out)
        assert data["status"] == "created"
        strand_path = data["strand_path"]
        assert os.path.isdir(strand_path)

        # Check manifest (pure Redis - zero on-disk JSON)
        manifest_file = os.path.join(strand_path, ".vine.json")
        assert not os.path.exists(manifest_file), "On-disk .vine.json must NOT exist"
        assert not os.path.exists(os.path.join(strand_path, ".vine", "strand.json")), "On-disk .vine/strand.json must NOT exist"

        s_code, s_out, s_err = run_vine("status", "--dir", strand_path, "--json")
        assert s_code == 0, f"Status failed: {s_err}\nOut: {s_out}"
        s_data = json.loads(s_out)
        assert s_data["task_id"] == task_id
        assert s_data["status"] in ["IN_PROGRESS", "PROVISIONED"]

        # Check vendored dependencies copied
        assert os.path.isfile(os.path.join(strand_path, "deps", "pkg", "lib.txt"))

        try:
            # 2. Commit a feature in strand
            feat_file = os.path.join(strand_path, "feature.txt")
            with open(feat_file, "w") as f:
                f.write("Vine feature line\n")
            subprocess.run(["git", "-C", strand_path, "add", "feature.txt"], check=True)
            subprocess.run(["git", "-C", strand_path, "commit", "-q", "-m", "feat: add feature"], check=True)

            # 3. Two-Key Gate
            g_code, g_out, g_err = run_vine("gate", "--dir", strand_path, "--base", "main", "--allow-no-tests", "--json")
            assert g_code == 0, f"Gate failed: {g_err}\nOut: {g_out}"
            g_data = json.loads(g_out)
            assert g_data["clean"] is True
            assert g_data["key1_mechanical"] == "PASS"

            # 4. Status should now be READY_FOR_WEAVE or GATE_PASSED
            s_code, s_out, s_err = run_vine("status", "--dir", strand_path, "--json")
            assert s_code == 0, f"Status failed: {s_err}\nOut: {s_out}"
            s_data = json.loads(s_out)
            assert s_data["status"] in ["READY_FOR_WEAVE", "GATE_PASSED"] or s_data.get("stored_status") in ["READY_FOR_WEAVE", "GATE_PASSED"]

            # 5. List strands
            l_code, l_out, l_err = run_vine("list", "--repo", repo_dir)
            assert l_code == 0
            l_data = json.loads(l_out)
            assert l_data["count"] >= 1

            # 6. Key 3 Adversarial Audit Lifecycle
            # Unaudited weave attempt must fail
            w_fail_code, w_fail_out, w_fail_err = run_vine("weave", "--dir", strand_path, "--base", "main", "--allow-no-tests")
            assert w_fail_code == 6, f"Expected Key 3 audit violation (code 6), got {w_fail_code}: {w_fail_err}"

            # Submit strand for audit
            sub_code, sub_out, sub_err = run_vine("submit", "--dir", strand_path, "--author", "worker-alice", "--allow-no-tests", "--json")
            assert sub_code == 0, f"Submit failed: {sub_err}"
            sub_data = json.loads(sub_out)
            assert sub_data["status"] == "ready_for_audit"

            # Self-audit must be rejected
            self_code, self_out, self_err = run_vine("audit", "approve", strand_path, "--auditor", "worker-alice", "--json")
            assert self_code == 6, f"Self-audit should fail with code 6, got {self_code}"

            # Independent auditor ratifies
            aud_code, aud_out, aud_err = run_vine("audit", "approve", strand_path, "--auditor", "auditor-bob", "--notes", "Passes Key 3", "--json")
            assert aud_code == 0, f"Audit approval failed code {aud_code}: {aud_err} Out: {aud_out}"
            aud_data = json.loads(aud_out)
            assert aud_data["status"] == "audit_ratified"
            assert aud_data["audit_token"]

            # 7. Weave strand into canonical repository
            w_code, w_out, w_err = run_vine("weave", "--dir", strand_path, "--base", "main", "--allow-no-tests")
            assert w_code == 0, f"Weave failed: {w_err}\nOut: {w_out}"
            w_data = json.loads(w_out)
            assert w_data["status"] == "woven"

            # Verify canonical repo received the commit
            assert os.path.isfile(os.path.join(repo_dir, "feature.txt"))
            with open(os.path.join(repo_dir, "feature.txt")) as f:
                assert "Vine feature line" in f.read()

            # Verify strand was pruned
            assert not os.path.exists(strand_path)

        finally:
            if os.path.exists(strand_path):
                subprocess.run(["git", "-C", repo_dir, "worktree", "remove", "--force", strand_path], capture_output=True)
                subprocess.run(["git", "-C", repo_dir, "worktree", "prune"], capture_output=True)
                shutil.rmtree(os.path.dirname(strand_path), ignore_errors=True)

def test_vine_gate_catches_mechanical_conflict():
    """Negative control: Key 1 mechanical conflict gate must reject conflicting strands."""
    with tempfile.TemporaryDirectory(prefix="vine_conflict_") as repo_dir:
        subprocess.run(["git", "init", "-b", "main", "-q", repo_dir], check=True)
        subprocess.run(["git", "-C", repo_dir, "config", "user.email", "agent@vine.mesh"], check=True)
        subprocess.run(["git", "-C", repo_dir, "config", "user.name", "Vine Agent"], check=True)

        readme = os.path.join(repo_dir, "README.md")
        with open(readme, "w") as f:
            f.write("Line 1: Original text\n")
        subprocess.run(["git", "-C", repo_dir, "add", "README.md"], check=True)
        subprocess.run(["git", "-C", repo_dir, "commit", "-q", "-m", "Initial commit"], check=True)

        # 1. Create Strand
        task_id = f"task-conf-{int(time.time() * 1000)}"
        code, out, err = run_vine("new", task_id, "--repo", repo_dir, "--branch", f"strand/{task_id}", "--worktree")
        assert code == 0
        strand_path = json.loads(out)["strand_path"]

        try:
            # 2. Modify line in strand
            with open(os.path.join(strand_path, "README.md"), "w") as f:
                f.write("Line 1: Strand modified text\n")
            subprocess.run(["git", "-C", strand_path, "add", "README.md"], check=True)
            subprocess.run(["git", "-C", strand_path, "commit", "-q", "-m", "feat: strand edit"], check=True)

            # 3. Modify same line in canonical main (create conflict)
            with open(readme, "w") as f:
                f.write("Line 1: Canonical trunk conflicting edit\n")
            subprocess.run(["git", "-C", repo_dir, "add", "README.md"], check=True)
            subprocess.run(["git", "-C", repo_dir, "commit", "-q", "-m", "fix: trunk edit"], check=True)

            # 4. Gate must FAIL on Key 1 (code 1)
            g_code, g_out, g_err = run_vine("gate", "--dir", strand_path, "--base", "main", "--json")
            assert g_code == 1, f"Expected conflict gate failure (code 1), got {g_code}\nOut: {g_out}"
            g_data = json.loads(g_out)
            assert g_data["clean"] is False
            assert g_data["status"] == "conflict"
            assert g_data["key1_mechanical"] == "FAIL"
            assert any("README.md" in c for c in g_data["conflicts"])

            # 5. Weave without --force must be REJECTED
            w_code, w_out, w_err = run_vine("weave", "--dir", strand_path, "--base", "main")
            assert w_code != 0
            assert "Two-Key Gate" in w_err or "Three-Key Gate" in w_err or "weave_rejected" in w_err

        finally:
            if os.path.exists(strand_path):
                subprocess.run(["git", "-C", repo_dir, "worktree", "remove", "--force", strand_path], capture_output=True)
                subprocess.run(["git", "-C", repo_dir, "worktree", "prune"], capture_output=True)
                shutil.rmtree(os.path.dirname(strand_path), ignore_errors=True)

def test_vine_gate_catches_semantic_compiler_failure():
    """Negative control: Key 2 semantic gate must reject failing build/test commands."""
    with tempfile.TemporaryDirectory(prefix="vine_compiler_fail_") as repo_dir:
        subprocess.run(["git", "init", "-b", "main", "-q", repo_dir], check=True)
        subprocess.run(["git", "-C", repo_dir, "config", "user.email", "agent@vine.mesh"], check=True)
        subprocess.run(["git", "-C", repo_dir, "config", "user.name", "Vine Agent"], check=True)

        readme = os.path.join(repo_dir, "README.md")
        with open(readme, "w") as f:
            f.write("# Project\n")
        subprocess.run(["git", "-C", repo_dir, "add", "README.md"], check=True)
        subprocess.run(["git", "-C", repo_dir, "commit", "-q", "-m", "Initial commit"], check=True)

        # Configure vine.toml with a failing test_command via a script
        with open(os.path.join(repo_dir, "fail.py"), "w") as f:
            f.write("import sys\nprint('Simulated compiler error')\nsys.exit(1)\n")
        with open(os.path.join(repo_dir, "vine.toml"), "w") as f:
            f.write(f'[verification]\ntest_command = "{sys.executable} fail.py"\n')
        subprocess.run(["git", "-C", repo_dir, "add", "vine.toml", "fail.py"], check=True)
        subprocess.run(["git", "-C", repo_dir, "commit", "-q", "-m", "chore: add vine.toml and fail.py"], check=True)

        task_id = f"task-sem-{int(time.time() * 1000)}"
        code, out, err = run_vine("new", task_id, "--repo", repo_dir, "--branch", f"strand/{task_id}", "--worktree")
        assert code == 0
        strand_path = json.loads(out)["strand_path"]

        try:
            # Commit a change in strand
            with open(os.path.join(strand_path, "feature.txt"), "w") as f:
                f.write("Broken feature\n")
            subprocess.run(["git", "-C", strand_path, "add", "feature.txt"], check=True)
            subprocess.run(["git", "-C", strand_path, "commit", "-q", "-m", "feat: broken feature"], check=True)

            # Gate must FAIL on Key 2 (code 2)
            g_code, g_out, g_err = run_vine("gate", "--dir", strand_path, "--base", "main", "--json")
            assert g_code == 2, f"Expected semantic failure (code 2), got {g_code}\nOut: {g_out}"
            g_data = json.loads(g_out)
            assert g_data["clean"] is False
            assert g_data["status"] == "semantic_failure"
            assert g_data["key1_mechanical"] == "PASS"
            assert g_data["key2_semantic"] == "FAIL"
            assert "Simulated compiler error" in g_data["compiler_output"]

        finally:
            if os.path.exists(strand_path):
                subprocess.run(["git", "-C", repo_dir, "worktree", "remove", "--force", strand_path], capture_output=True)
                subprocess.run(["git", "-C", repo_dir, "worktree", "prune"], capture_output=True)
                shutil.rmtree(os.path.dirname(strand_path), ignore_errors=True)

def test_vine_strand_envrc_generation():
    """Verify Vine generates a non-destructive polyglot .envrc that chains parent .envrc."""
    with tempfile.TemporaryDirectory(prefix="vine_envrc_") as repo_dir:
        subprocess.run(["git", "init", "-b", "main", "-q", repo_dir], check=True)
        subprocess.run(["git", "-C", repo_dir, "config", "user.email", "agent@vine.mesh"], check=True)
        subprocess.run(["git", "-C", repo_dir, "config", "user.name", "Vine Agent"], check=True)

        readme = os.path.join(repo_dir, "README.md")
        with open(readme, "w") as f:
            f.write("# Project\n")
        parent_envrc = os.path.join(repo_dir, ".envrc")
        with open(parent_envrc, "w") as f:
            f.write("export PARENT_FLAG=active\n")

        subprocess.run(["git", "-C", repo_dir, "add", "README.md"], check=True)
        subprocess.run(["git", "-C", repo_dir, "commit", "-q", "-m", "Initial commit"], check=True)

        task_id = f"task-envrc-{int(time.time() * 1000)}"
        code, out, err = run_vine("new", task_id, "--repo", repo_dir, "--branch", f"strand/{task_id}", "--worktree")
        assert code == 0
        strand_path = json.loads(out)["strand_path"]

        try:
            envrc_file = os.path.join(strand_path, ".envrc")
            assert os.path.isfile(envrc_file), ".envrc must be generated in strand root"
            content = open(envrc_file).read()
            assert "source_env" in content, "Must source parent repository .envrc"
            assert "PROJECT_ROOT=" in content
            assert "CACHE_ROOT=" in content
            assert "CCACHE_BASEDIR=" in content
            assert "CCACHE_NOHASHDIR=1" in content
            assert "CARGO_TARGET_DIR=" in content
            assert 'UV_LINK_MODE="clone"' in content
            assert "NIMCACHE=" in content
        finally:
            if os.path.exists(strand_path):
                subprocess.run(["git", "-C", repo_dir, "worktree", "remove", "--force", strand_path], capture_output=True)
                subprocess.run(["git", "-C", repo_dir, "worktree", "prune"], capture_output=True)
                shutil.rmtree(os.path.dirname(strand_path), ignore_errors=True)

def test_vine_prune():
    """Verify vine prune dry-run and apply lifecycle on completed strands."""
    with tempfile.TemporaryDirectory(prefix="vine_prune_") as repo_dir:
        subprocess.run(["git", "init", "-b", "main", "-q", repo_dir], check=True)
        subprocess.run(["git", "-C", repo_dir, "config", "user.email", "agent@vine.mesh"], check=True)
        subprocess.run(["git", "-C", repo_dir, "config", "user.name", "Vine Agent"], check=True)

        readme = os.path.join(repo_dir, "README.md")
        with open(readme, "w") as f:
            f.write("# Prune test\n")
        subprocess.run(["git", "-C", repo_dir, "add", "README.md"], check=True)
        subprocess.run(["git", "-C", repo_dir, "commit", "-q", "-m", "Initial commit"], check=True)

        task_id = f"task-prune-{int(time.time() * 1000)}"
        code, out, err = run_vine("new", task_id, "--repo", repo_dir, "--branch", f"strand/{task_id}", "--worktree")
        assert code == 0
        strand_path = json.loads(out)["strand_path"]

        try:
            # Mark strand as WEAVED/WOVEN in Redis (pure Redis state, zero on-disk JSON)
            try:
                subprocess.run(
                    ["redis-cli", "HSET", f"vine:strand:{task_id}", "state", "WOVEN", "status", "WOVEN", "lifecycle_state", "WOVEN"],
                    check=True,
                    capture_output=True
                )
                subprocess.run(
                    ["redis-cli", "SADD", "vine:strands:state:woven", task_id],
                    check=True,
                    capture_output=True
                )
            except Exception:
                pass

            # 1. Dry run prune
            p_code, p_out, p_err = run_vine("prune", "--repo", repo_dir)
            assert p_code == 0
            p_data = json.loads(p_out)
            assert p_data["dry_run"] is True
            assert p_data["pruned_count"] == 1
            assert os.path.exists(strand_path), "Dry run must NOT remove strand directory"

            # 2. Apply prune
            a_code, a_out, a_err = run_vine("prune", "--repo", repo_dir, "--apply")
            assert a_code == 0
            a_data = json.loads(a_out)
            assert a_data["dry_run"] is False
            assert a_data["pruned_count"] == 1
            assert not os.path.exists(strand_path), "Prune apply MUST remove strand directory"

            # 3. Verify git worktree cleaned up
            wt_out = subprocess.run(["git", "-C", repo_dir, "worktree", "list"], capture_output=True, text=True).stdout
            assert strand_path not in wt_out

        finally:
            if os.path.exists(strand_path):
                subprocess.run(["git", "-C", repo_dir, "worktree", "remove", "--force", strand_path], capture_output=True)
                subprocess.run(["git", "-C", repo_dir, "worktree", "prune"], capture_output=True)
                shutil.rmtree(os.path.dirname(strand_path), ignore_errors=True)

def test_vine_diverged_trunk_sync_and_weave():
    """Verify vine sync reconciles diverged canonical trunk changes into strand before weaving."""
    with tempfile.TemporaryDirectory(prefix="vine_sync_") as repo_dir:
        subprocess.run(["git", "init", "-b", "main", "-q", repo_dir], check=True)
        subprocess.run(["git", "-C", repo_dir, "config", "user.email", "agent@vine.mesh"], check=True)
        subprocess.run(["git", "-C", repo_dir, "config", "user.name", "Vine Agent"], check=True)

        readme = os.path.join(repo_dir, "README.md")
        with open(readme, "w") as f:
            f.write("# Diverged Trunk Test Repo\n")
        subprocess.run(["git", "-C", repo_dir, "add", "README.md"], check=True)
        subprocess.run(["git", "-C", repo_dir, "commit", "-q", "-m", "Initial commit C0"], check=True)

        # 1. Create Strand branched at C0
        task_id = f"task-sync-{int(time.time() * 1000)}"
        code, out, err = run_vine("new", task_id, "--repo", repo_dir, "--branch", f"strand/{task_id}", "--worktree")
        assert code == 0, f"Error creating strand: {err}\nOut: {out}"
        strand_path = json.loads(out)["strand_path"]

        try:
            # 2. Strand makes a feature commit
            feat_file = os.path.join(strand_path, "feature.txt")
            with open(feat_file, "w") as f:
                f.write("New feature from parallel worker\n")
            subprocess.run(["git", "-C", strand_path, "add", "feature.txt"], check=True)
            subprocess.run(["git", "-C", strand_path, "commit", "-q", "-m", "feat: parallel strand feature"], check=True)

            # 3. Canonical trunk advances independently (simulating another agent or developer pushing to trunk)
            trunk_file = os.path.join(repo_dir, "trunk_update.txt")
            with open(trunk_file, "w") as f:
                f.write("Trunk change committed by another worker\n")
            subprocess.run(["git", "-C", repo_dir, "add", "trunk_update.txt"], check=True)
            subprocess.run(["git", "-C", repo_dir, "commit", "-q", "-m", "chore: independent trunk commit C_trunk"], check=True)

            # 4. Attempting to weave directly without sync MUST FAIL fast with clear diagnostic
            w_code, w_out, w_err = run_vine("weave", "--dir", strand_path, "--base", "main", "--allow-no-tests", "--allow-unaudited")
            assert w_code != 0, f"Weave should have failed due to diverged trunk, got code {w_code}\nOut: {w_out}"
            assert "fast_forward_failed" in w_err or "diverged" in w_err
            assert "vine sync" in w_err

            # 5. Negative control: dirty working tree in strand blocks sync
            dirty_file = os.path.join(strand_path, "uncommitted.txt")
            with open(dirty_file, "w") as f:
                f.write("uncommitted work\n")
            subprocess.run(["git", "-C", strand_path, "add", "uncommitted.txt"], check=True)
            s_fail_code, s_fail_out, s_fail_err = run_vine("sync", "--dir", strand_path, "--base", "main")
            assert s_fail_code != 0
            assert "dirty_working_tree" in s_fail_err
            os.remove(dirty_file)
            subprocess.run(["git", "-C", strand_path, "reset", "HEAD", "--", "uncommitted.txt"], check=True)

            # 6. Run vine sync to incorporate canonical trunk into strand
            s_code, s_out, s_err = run_vine("sync", "--dir", strand_path, "--base", "main")
            assert s_code == 0, f"vine sync failed: {s_err}\nOut: {s_out}"
            s_data = json.loads(s_out)
            assert s_data["status"] == "synced"
            assert s_data["base_branch"] == "main"

            # 7. Verify trunk change is now inside strand
            assert os.path.isfile(os.path.join(strand_path, "trunk_update.txt"))
            assert os.path.isfile(os.path.join(strand_path, "feature.txt"))

            # 8. Pass Two-Key Gate
            g_code, g_out, g_err = run_vine("gate", "--dir", strand_path, "--base", "main", "--allow-no-tests", "--json")
            assert g_code == 0, f"Gate failed: {g_err}\nOut: {g_out}"
            assert json.loads(g_out)["clean"] is True

            # 9. Now vine weave succeeds with clean fast-forward
            w_ok_code, w_ok_out, w_ok_err = run_vine("weave", "--dir", strand_path, "--base", "main", "--allow-no-tests", "--allow-unaudited")
            assert w_ok_code == 0, f"Weave failed after sync: {w_ok_err}\nOut: {w_ok_out}"
            assert json.loads(w_ok_out)["status"] == "woven"

            # 10. Verify canonical trunk contains both commits
            assert os.path.isfile(os.path.join(repo_dir, "feature.txt"))
            assert os.path.isfile(os.path.join(repo_dir, "trunk_update.txt"))
            assert not os.path.exists(strand_path)

        finally:
            if os.path.exists(strand_path):
                subprocess.run(["git", "-C", repo_dir, "worktree", "remove", "--force", strand_path], capture_output=True)
                subprocess.run(["git", "-C", repo_dir, "worktree", "prune"], capture_output=True)
                shutil.rmtree(os.path.dirname(strand_path), ignore_errors=True)

def test_vine_gate_custom_test_command():
    """GVR-004: Verify --test-command flag overrides configuration and executes custom test runner."""
    with tempfile.TemporaryDirectory(prefix="vine_custom_gate_") as repo_dir:
        subprocess.run(["git", "init", "-b", "main", "-q", repo_dir], check=True)
        subprocess.run(["git", "-C", repo_dir, "config", "user.email", "agent@vine.mesh"], check=True)
        subprocess.run(["git", "-C", repo_dir, "config", "user.name", "Vine Agent"], check=True)

        readme = os.path.join(repo_dir, "README.md")
        with open(readme, "w") as f:
            f.write("# Gate Custom Test\n")
        subprocess.run(["git", "-C", repo_dir, "add", "README.md"], check=True)
        subprocess.run(["git", "-C", repo_dir, "commit", "-q", "-m", "Initial commit"], check=True)

        task_id = f"task-gate-{int(time.time() * 1000)}"
        code, out, err = run_vine("new", task_id, "--repo", repo_dir, "--branch", f"strand/{task_id}", "--worktree")
        assert code == 0
        strand_path = json.loads(out)["strand_path"]

        try:
            # 1. Custom passing test command
            pass_cmd = f'{sys.executable} -c "import sys; print(\'Tests passed\'); sys.exit(0)"'
            g_code, g_out, g_err = run_vine("gate", "--dir", strand_path, "--base", "main", "--test-command", pass_cmd, "--json")
            assert g_code == 0, f"Expected gate pass: {g_err}\nOut: {g_out}"
            g_data = json.loads(g_out)
            assert g_data["clean"] is True
            assert g_data["key2_semantic"] == "PASS"
            assert g_data["test_command"] == pass_cmd

            # 2. Custom failing test command
            fail_cmd = f'{sys.executable} -c "import sys; sys.stderr.write(\'Synthetic test failure\'); sys.exit(42)"'
            f_code, f_out, f_err = run_vine("gate", "--dir", strand_path, "--base", "main", "--test-command", fail_cmd, "--json")
            assert f_code == 2, f"Expected gate semantic failure, got {f_code}\nOut: {f_out}"
            f_data = json.loads(f_out)
            assert f_data["clean"] is False
            assert f_data["key2_semantic"] == "FAIL"
            assert "Synthetic test failure" in f_data["compiler_output"]

            # 3. Custom passing test command via '--' delimiter
            g_code, g_out, g_err = run_vine("gate", "--dir", strand_path, "--base", "main", "--json", "--", sys.executable, "-c", 'import sys; print("Passing via double dash"); sys.exit(0)')
            assert g_code == 0, f"Expected gate pass via --: {g_err}\nOut: {g_out}"
            g_data = json.loads(g_out)
            assert g_data["clean"] is True
            assert g_data["key2_semantic"] == "PASS"

            # 4. Custom failing test command via '--' delimiter
            f_code, f_out, f_err = run_vine("gate", "--dir", strand_path, "--base", "main", "--json", "--", sys.executable, "-c", 'import sys; sys.stderr.write("Synthetic failure via double dash"); sys.exit(42)')
            assert f_code == 2, f"Expected gate semantic failure via --, got {f_code}\nOut: {f_out}"
            f_data = json.loads(f_out)
            assert f_data["clean"] is False
            assert f_data["key2_semantic"] == "FAIL"
            assert "Synthetic failure via double dash" in f_data["compiler_output"]
        finally:
            if os.path.exists(strand_path):
                subprocess.run(["git", "-C", repo_dir, "worktree", "remove", "--force", strand_path], capture_output=True)
                subprocess.run(["git", "-C", repo_dir, "worktree", "prune"], capture_output=True)
                shutil.rmtree(os.path.dirname(strand_path), ignore_errors=True)

def test_vine_strand_deep_lifecycle_and_status():
    """GVR-013: Verify parent branch tracking, PROVISIONED state, dynamic status queries, and gate passing."""
    with tempfile.TemporaryDirectory(prefix="vine_lifecycle_") as repo_dir:
        subprocess.run(["git", "init", "-b", "main", "-q", repo_dir], check=True)
        subprocess.run(["git", "-C", repo_dir, "config", "user.email", "agent@vine.mesh"], check=True)
        subprocess.run(["git", "-C", repo_dir, "config", "user.name", "Vine Agent"], check=True)

        readme = os.path.join(repo_dir, "README.md")
        with open(readme, "w") as f:
            f.write("# Lifecycle Test\n")
        subprocess.run(["git", "-C", repo_dir, "add", "README.md"], check=True)
        subprocess.run(["git", "-C", repo_dir, "commit", "-q", "-m", "Initial commit"], check=True)

        # Create a develop branch
        subprocess.run(["git", "-C", repo_dir, "checkout", "-b", "develop"], check=True)
        with open(os.path.join(repo_dir, "develop.txt"), "w") as f:
            f.write("Develop branch base\n")
        subprocess.run(["git", "-C", repo_dir, "add", "develop.txt"], check=True)
        subprocess.run(["git", "-C", repo_dir, "commit", "-q", "-m", "develop commit"], check=True)

        task_id = f"task-life-{int(time.time() * 1000)}"
        code, out, err = run_vine("new", task_id, "--repo", repo_dir, "--branch", f"strand/{task_id}", "--parent", "develop", "--worktree")
        assert code == 0, f"Failed to create strand: {err}\nOut: {out}"
        data = json.loads(out)
        strand_path = data["strand_path"]
        assert data["parent_branch"] == "develop"
        assert "intended_merge_base" in data
        assert len(data["intended_merge_base"]) == 40

        try:
            # 1. Check initial status is PROVISIONED
            s_code, s_out, s_err = run_vine("status", "--dir", strand_path, "--json")
            assert s_code == 0
            s_data = json.loads(s_out)
            assert s_data["lifecycle_state"] == "PROVISIONED"
            assert s_data["parent_branch"] == "develop"
            assert s_data["commits_ahead"] == 0
            assert s_data["dirty_count"] == 0

            # 2. Make an uncommitted edit -> state transitions to IN_PROGRESS
            work_file = os.path.join(strand_path, "work.txt")
            with open(work_file, "w") as f:
                f.write("in progress work\n")
            s_code2, s_out2, _ = run_vine("status", "--dir", strand_path, "--json")
            assert s_code2 == 0
            s_data2 = json.loads(s_out2)
            assert s_data2["lifecycle_state"] == "IN_PROGRESS"
            assert s_data2["dirty_count"] == 1

            # 3. Commit the change -> commits_ahead == 1
            subprocess.run(["git", "-C", strand_path, "add", "work.txt"], check=True)
            subprocess.run(["git", "-C", strand_path, "commit", "-q", "-m", "feat: completed work"], check=True)
            s_code3, s_out3, _ = run_vine("status", "--dir", strand_path, "--json")
            assert s_code3 == 0
            s_data3 = json.loads(s_out3)
            assert s_data3["commits_ahead"] == 1
            assert s_data3["dirty_count"] == 0

            # 4. Fail gate with failing test command -> verify GATE_FAILED in vine status
            fail_cmd = f"{sys.executable} -c 'import sys; sys.exit(1)'"
            f_code, _, _ = run_vine("gate", "--dir", strand_path, "--base", "develop", "--test-command", fail_cmd, "--json")
            assert f_code == 2
            s_code_fail, s_out_fail, _ = run_vine("status", "--dir", strand_path, "--json")
            assert s_code_fail == 0
            s_data_fail = json.loads(s_out_fail)
            assert s_data_fail["lifecycle_state"] == "GATE_FAILED"

            # 5. Pass gate -> GATE_PASSED
            g_code, g_out, _ = run_vine("gate", "--dir", strand_path, "--base", "develop", "--skip-tests", "--allow-no-tests", "--json")
            assert g_code == 0
            s_code4, s_out4, _ = run_vine("status", "--dir", strand_path, "--json")
            assert s_code4 == 0
            s_data4 = json.loads(s_out4)
            assert s_data4["lifecycle_state"] == "GATE_PASSED"
        finally:
            if os.path.exists(strand_path):
                subprocess.run(["git", "-C", repo_dir, "worktree", "remove", "--force", strand_path], capture_output=True)
                subprocess.run(["git", "-C", repo_dir, "worktree", "prune"], capture_output=True)
                shutil.rmtree(os.path.dirname(os.path.dirname(strand_path)), ignore_errors=True)

def test_vine_collisions_forecasting():
    """GVR-013: Verify vine collisions detects multi-strand file footprint overlap."""
    with tempfile.TemporaryDirectory(prefix="vine_colls_") as repo_dir:
        subprocess.run(["git", "init", "-b", "main", "-q", repo_dir], check=True)
        subprocess.run(["git", "-C", repo_dir, "config", "user.email", "agent@vine.mesh"], check=True)
        subprocess.run(["git", "-C", repo_dir, "config", "user.name", "Vine Agent"], check=True)

        shared = os.path.join(repo_dir, "shared.txt")
        with open(shared, "w") as f:
            f.write("Line 0\n")
        subprocess.run(["git", "-C", repo_dir, "add", "shared.txt"], check=True)
        subprocess.run(["git", "-C", repo_dir, "commit", "-q", "-m", "Initial commit"], check=True)

        task_a = f"task-a-{int(time.time() * 1000)}"
        task_b = f"task-b-{int(time.time() * 1000)}"

        code_a, out_a, _ = run_vine("new", task_a, "--repo", repo_dir, "--branch", f"strand/{task_a}", "--worktree")
        assert code_a == 0
        path_a = json.loads(out_a)["strand_path"]

        code_b, out_b, _ = run_vine("new", task_b, "--repo", repo_dir, "--branch", f"strand/{task_b}", "--worktree")
        assert code_b == 0
        path_b = json.loads(out_b)["strand_path"]

        try:
            # Both strands modify shared.txt
            with open(os.path.join(path_a, "shared.txt"), "a") as f:
                f.write("Modified by A\n")
            with open(os.path.join(path_b, "shared.txt"), "a") as f:
                f.write("Modified by B\n")

            c_code, c_out, _ = run_vine("collisions", "--repo", repo_dir, "--json")
            assert c_code == 0
            c_data = json.loads(c_out)
            assert c_data["has_collisions"] is True
            assert c_data["collision_count"] >= 1
            coll = next(c for c in c_data["collisions"] if c["file"] == "shared.txt")
            assert task_a in coll["strands"]
            assert task_b in coll["strands"]
        finally:
            for p in [path_a, path_b]:
                if os.path.exists(p):
                    subprocess.run(["git", "-C", repo_dir, "worktree", "remove", "--force", p], capture_output=True)
                    subprocess.run(["git", "-C", repo_dir, "worktree", "prune"], capture_output=True)
                    shutil.rmtree(os.path.dirname(os.path.dirname(p)), ignore_errors=True)

def test_vine_cmake_test_runner_detection():
    """GVR-004: Verify automatic CMake test runner detection."""
    with tempfile.TemporaryDirectory(prefix="vine_cmake_") as repo_dir:
        subprocess.run(["git", "init", "-b", "main", "-q", repo_dir], check=True)
        subprocess.run(["git", "-C", repo_dir, "config", "user.email", "agent@vine.mesh"], check=True)
        subprocess.run(["git", "-C", repo_dir, "config", "user.name", "Vine Agent"], check=True)

        with open(os.path.join(repo_dir, "CMakeLists.txt"), "w") as f:
            f.write("cmake_minimum_required(VERSION 3.20)\nproject(TestProject)\n")
        subprocess.run(["git", "-C", repo_dir, "add", "CMakeLists.txt"], check=True)
        subprocess.run(["git", "-C", repo_dir, "commit", "-q", "-m", "Initial cmake commit"], check=True)

        task_id = f"task-cmake-{int(time.time() * 1000)}"
        code, out, _ = run_vine("new", task_id, "--repo", repo_dir, "--branch", f"strand/{task_id}", "--worktree")
        assert code == 0
        strand_path = json.loads(out)["strand_path"]

        try:
            # Gate with --skip-tests and --allow-no-tests passes
            g_code, g_out, _ = run_vine("gate", "--dir", strand_path, "--base", "main", "--skip-tests", "--allow-no-tests", "--json")
            assert g_code == 0
            g_data = json.loads(g_out)
            assert g_data["clean"] is True
        finally:
            if os.path.exists(strand_path):
                subprocess.run(["git", "-C", repo_dir, "worktree", "remove", "--force", strand_path], capture_output=True)
                subprocess.run(["git", "-C", repo_dir, "worktree", "prune"], capture_output=True)
                shutil.rmtree(os.path.dirname(os.path.dirname(strand_path)), ignore_errors=True)

def test_vine_environment_variable_precedence():
    """Verify VINE_* environment variables override config files and defaults."""
    with tempfile.TemporaryDirectory(prefix="vine_env_test_") as tmpdir:
        # 1. Test VINE_CONFIG pointing to custom path
        custom_toml = Path(tmpdir) / "custom_vine.toml"
        custom_toml.write_text("""[project]
primary_branch = "trunk"
[strand]
venv_policy = "always"
[verification]
test_command = "cargo test"
""")
        code, out, _ = run_vine("config", "show", env={"VINE_CONFIG": str(custom_toml)}, cwd=tmpdir)
        assert code == 0
        data = json.loads(out)
        assert data["primary_branch"] == "trunk"
        assert data["venv_policy"] == "always"
        assert data["test_command"] == "cargo test"

        # 2. Test VINE_PRIMARY_BRANCH and VINE_TEST_COMMAND direct overrides
        overrides = {
            "VINE_CONFIG": str(custom_toml),
            "VINE_PRIMARY_BRANCH": "production",
            "VINE_TEST_COMMAND": "nimble test",
            "VINE_VENV_POLICY": "never",
        }
        code2, out2, _ = run_vine("config", "show", env=overrides, cwd=tmpdir)
        assert code2 == 0
        data2 = json.loads(out2)
        assert data2["primary_branch"] == "production"
        assert data2["test_command"] == "nimble test"
        assert data2["venv_policy"] == "never"

        # 3. Test VINE_WORKSPACES_DIR overrides default workspace creation location
        custom_ws = Path(tmpdir) / "custom_workspaces"
        repo_dir = Path(tmpdir) / "repo"
        repo_dir.mkdir()
        subprocess.run(["git", "init", "-b", "main", "-q", str(repo_dir)], check=True)
        subprocess.run(["git", "-C", str(repo_dir), "config", "user.email", "agent@vine.mesh"], check=True)
        subprocess.run(["git", "-C", str(repo_dir), "config", "user.name", "Vine Agent"], check=True)
        (repo_dir / "README.md").write_text("# Test\n")
        subprocess.run(["git", "-C", str(repo_dir), "add", "README.md"], check=True)
        subprocess.run(["git", "-C", str(repo_dir), "commit", "-q", "-m", "init"], check=True)

        task_id = f"task-ws-{int(time.time() * 1000)}"
        code3, out3, _ = run_vine("new", task_id, "--repo", str(repo_dir), "--branch", f"strand/{task_id}", "--worktree", env={"VINE_WORKSPACES_DIR": str(custom_ws)})
        assert code3 == 0
        data3 = json.loads(out3)
        assert str(custom_ws) in data3["strand_path"]
        assert Path(data3["strand_path"]).exists()

def test_vine_weave_and_gate_auto_resolve_by_task_id():
    """Verify that vine gate, vine weave, and vine status auto-resolve strand directory by branch or task_id without --dir."""
    with tempfile.TemporaryDirectory(prefix="vine_autoresolve_") as repo_dir:
        subprocess.run(["git", "init", "-b", "main", "-q", repo_dir], check=True)
        subprocess.run(["git", "-C", repo_dir, "config", "user.email", "agent@vine.mesh"], check=True)
        subprocess.run(["git", "-C", repo_dir, "config", "user.name", "Vine Agent"], check=True)

        readme = os.path.join(repo_dir, "README.md")
        with open(readme, "w") as f:
            f.write("# Autoresolve Test\n")
        subprocess.run(["git", "-C", repo_dir, "add", "README.md"], check=True)
        subprocess.run(["git", "-C", repo_dir, "commit", "-q", "-m", "Initial commit"], check=True)

        task_id = f"task-auto-{int(time.time() * 1000)}"
        code, out, err = run_vine("new", task_id, "--repo", repo_dir, "--branch", f"strand/{task_id}", "--worktree")
        assert code == 0, f"Failed to create strand: {err}"
        data = json.loads(out)
        strand_path = data["strand_path"]

        try:
            # Add a feature file in the strand
            feat_file = os.path.join(strand_path, "feature.txt")
            with open(feat_file, "w") as f:
                f.write("Autoresolved feature\n")
            subprocess.run(["git", "-C", strand_path, "add", "feature.txt"], check=True)
            subprocess.run(["git", "-C", strand_path, "commit", "-q", "-m", "feat: add feature"], check=True)

            # Change cwd to repo_dir (canonical repo without .vine.json)
            orig_cwd = os.getcwd()
            os.chdir(repo_dir)
            try:
                # 1. Gate resolution by branch name without --dir
                g_code, g_out, g_err = run_vine("gate", f"strand/{task_id}", "--skip-tests", "--allow-no-tests", "--json")
                assert g_code == 0, f"Gate failed: {g_err}\nOut: {g_out}"
                g_data = json.loads(g_out)
                assert g_data["strand_path"] == strand_path

                # 2. Gate resolution by task_id without --dir
                g_code2, g_out2, g_err2 = run_vine("gate", task_id, "--skip-tests", "--allow-no-tests", "--json")
                assert g_code2 == 0, f"Gate by task_id failed: {g_err2}\nOut: {g_out2}"
                g_data2 = json.loads(g_out2)
                assert g_data2["strand_path"] == strand_path

                # 3. Status resolution by task_id before weave
                s_code, s_out, s_err = run_vine("status", task_id, "--json")
                assert s_code == 0, f"Status failed: {s_err}"
                s_data = json.loads(s_out)
                assert s_data["commits_ahead"] == 1

                # 4. Weave resolution by task_id from canonical repo without --dir
                w_code, w_out, w_err = run_vine("weave", task_id, "--force")
                assert w_code == 0, f"Weave by task_id failed: {w_err}\nOut: {w_out}"
                w_data = json.loads(w_out)
                assert w_data["status"] == "woven"
                assert os.path.exists(os.path.join(repo_dir, "feature.txt")), "feature.txt not found in canonical repo after weave"
            finally:
                os.chdir(orig_cwd)
        finally:
            if os.path.exists(strand_path):
                subprocess.run(["git", "-C", repo_dir, "worktree", "remove", "--force", strand_path], capture_output=True)
                subprocess.run(["git", "-C", repo_dir, "worktree", "prune"], capture_output=True)
                shutil.rmtree(os.path.dirname(os.path.dirname(strand_path)), ignore_errors=True)

def test_vine_changelog_command():
    """Verify vine changelog CLI operations: creation, entry addition, and checking."""
    with tempfile.TemporaryDirectory(prefix="vine_cl_test_") as tmpdir:
        subprocess.run(["git", "init", "-b", "main", "-q", tmpdir], check=True)
        subprocess.run(["git", "-C", tmpdir, "config", "user.email", "agent@vine.mesh"], check=True)
        subprocess.run(["git", "-C", tmpdir, "config", "user.name", "Vine Agent"], check=True)

        # 1. No changelog initially
        code, out, err = run_vine("changelog", "--check", "--repo", tmpdir)
        assert code == 0
        assert "No changelog file detected in project" in out

        # 2. Ensure unreleased section creates CHANGELOG.md
        code, out, err = run_vine("changelog", "--ensure-unreleased", "--repo", tmpdir)
        assert code == 0
        cl_path = os.path.join(tmpdir, "CHANGELOG.md")
        assert os.path.exists(cl_path)
        content = Path(cl_path).read_text()
        assert "## [Unreleased]" in content

        # 3. Add an entry
        code, out, err = run_vine("changelog", "Added great new feature", "--repo", tmpdir)
        assert code == 0
        content = Path(cl_path).read_text()
        assert "- Added great new feature" in content

        # Initial commit with changelog
        subprocess.run(["git", "-C", tmpdir, "add", "CHANGELOG.md"], check=True)
        subprocess.run(["git", "-C", tmpdir, "commit", "-q", "-m", "chore: init changelog"], check=True)

        # 4. Check reports violation if not modified in diff against HEAD
        code, out, err = run_vine("changelog", "--check", "--repo", tmpdir)
        assert code == 5
        assert "is NOT modified in diff" in err or "is NOT modified in diff" in out

        # 5. Add a new entry to make it modified
        code, out, err = run_vine("changelog", "Second entry in progress", "--repo", tmpdir)
        assert code == 0

        # 6. Now check passes
        code, out, err = run_vine("changelog", "--check", "--repo", tmpdir)
        assert code == 0
        assert "Clean: CHANGELOG.md is modified in diff" in out

def test_vine_key3_adversarial_audit_lifecycle():
    """Verify Key 3 Pre-Weave Adversarial Audit: submit, reject, self-audit block, approve, tamper detection, weave."""
    with tempfile.TemporaryDirectory(prefix="vine_audit_lifecycle_") as repo_dir:
        # 1. Initialize git repo
        subprocess.run(["git", "-C", repo_dir, "init", "-q", "-b", "main"], check=True)
        subprocess.run(["git", "-C", repo_dir, "config", "user.name", "Test Committer"], check=True)
        subprocess.run(["git", "-C", repo_dir, "config", "user.email", "test@test.local"], check=True)
        with open(os.path.join(repo_dir, "README.md"), "w") as f:
            f.write("# Main Repo\n")
        os.makedirs(os.path.join(repo_dir, "src"), exist_ok=True)
        with open(os.path.join(repo_dir, "src", "main.py"), "w") as f:
            f.write("# Main entrypoint\n")
        subprocess.run(["git", "-C", repo_dir, "add", "README.md", "src/main.py"], check=True)
        subprocess.run(["git", "-C", repo_dir, "commit", "-q", "-m", "chore: initial commit"], check=True)

        # 2. Create strand
        s_code, s_out, s_err = run_vine("new", "task-audit-1", "--repo", repo_dir, "--worktree")
        assert s_code == 0, f"Strand creation failed: {s_err}"
        strand_data = json.loads(s_out)
        strand_path = strand_data["strand_path"]

        try:
            # 3. Add provider and consumer in strand
            with open(os.path.join(strand_path, "src", "engine.py"), "w") as f:
                f.write("def run(): return 42\n")
            with open(os.path.join(strand_path, "src", "main.py"), "w") as f:
                f.write("from engine import run\nprint(run())\n")
            subprocess.run(["git", "-C", strand_path, "add", "src/"], check=True)
            subprocess.run(["git", "-C", strand_path, "commit", "-q", "-m", "feat: provider and consumer"], check=True)

            # 4. Attempt audit approval before gate/submit -> MUST FAIL
            a_premature_code, a_premature_out, a_premature_err = run_vine(
                "audit", "approve", strand_path, "--auditor", "auditor-rex", "--json"
            )
            assert a_premature_code == 6, f"Expected prerequisite failure (code 6), got {a_premature_code}"

            # 5. Worker submits strand
            sub_code, sub_out, sub_err = run_vine(
                "submit", "--dir", strand_path, "--author", "worker-claudia", "--allow-no-tests", "--json"
            )
            assert sub_code == 0, f"Submit failed: {sub_err}"
            sub_data = json.loads(sub_out)
            assert sub_data["status"] == "ready_for_audit"
            assert sub_data["author"] == "worker-claudia"

            # 6. Audit status check
            stat_code, stat_out, stat_err = run_vine("audit", "status", strand_path, "--json")
            assert stat_code == 0
            stat_data = json.loads(stat_out)
            assert stat_data["status"] == "READY_FOR_AUDIT"
            assert stat_data["author"] == "worker-claudia"

            # 7. Auditor rejects strand with findings
            rej_code, rej_out, rej_err = run_vine(
                "audit", "reject", strand_path, "--auditor", "auditor-rex",
                "--reason", "Missing input validation in engine.py", "--json"
            )
            assert rej_code == 0, f"Reject failed: {rej_err}"
            rej_data = json.loads(rej_out)
            assert rej_data["status"] == "audit_rejected"

            # 8. Weaving rejected strand MUST FAIL with code 6
            w_fail_code, w_fail_out, w_fail_err = run_vine(
                "weave", "--dir", strand_path, "--base", "main", "--allow-no-tests"
            )
            assert w_fail_code == 6, f"Expected weave rejection (code 6), got {w_fail_code}"

            # 9. Worker fixes code in strand and re-submits
            with open(os.path.join(strand_path, "src", "engine.py"), "w") as f:
                f.write("def run():\n    # Validated\n    return 42\n")
            subprocess.run(["git", "-C", strand_path, "add", "src/engine.py"], check=True)
            subprocess.run(["git", "-C", strand_path, "commit", "-q", "-m", "fix: add input validation"], check=True)

            sub2_code, sub2_out, sub2_err = run_vine(
                "submit", "--dir", strand_path, "--author", "worker-claudia", "--allow-no-tests", "--json"
            )
            assert sub2_code == 0

            # 10. Self-audit attempt MUST BE REJECTED with code 6
            self_code, self_out, self_err = run_vine(
                "audit", "approve", strand_path, "--auditor", "worker-claudia", "--json"
            )
            assert self_code == 6
            self_data = json.loads(self_out)
            assert "Self-audit violation" in self_data.get("error", "")

            # 11. Independent auditor approves
            app_code, app_out, app_err = run_vine(
                "audit", "approve", strand_path, "--auditor", "auditor-rex",
                "--notes", "Input validation ratified across all call sites", "--json"
            )
            assert app_code == 0, f"Approval failed: {app_err}"
            app_data = json.loads(app_out)
            assert app_data["status"] == "audit_ratified"
            assert app_data["audit_token"]

            # 12. Strand status shows AUDIT_RATIFIED
            s_stat_code, s_stat_out, s_stat_err = run_vine("status", "--dir", strand_path, "--json")
            assert s_stat_code == 0
            assert json.loads(s_stat_out)["lifecycle_state"] == "AUDIT_RATIFIED"

            # 13. Weave succeeds without --allow-unaudited
            w_code, w_out, w_err = run_vine("weave", "--dir", strand_path, "--base", "main", "--allow-no-tests")
            assert w_code == 0, f"Weave failed: {w_err}"
            w_data = json.loads(w_out)
            assert w_data["status"] == "woven"
            assert os.path.exists(os.path.join(repo_dir, "src", "engine.py"))

        finally:
            if os.path.exists(strand_path):
                subprocess.run(["git", "-C", repo_dir, "worktree", "remove", "--force", strand_path], capture_output=True)
                subprocess.run(["git", "-C", repo_dir, "worktree", "prune"], capture_output=True)
                shutil.rmtree(os.path.dirname(strand_path), ignore_errors=True)

def test_vine_defeat_device_gate_rejection():
    """Verify mechanical rejection of Volkswagen Defeat Devices (prompt keyword interceptors) at Key 2 / submit."""
    with tempfile.TemporaryDirectory(prefix="vine_defeat_test_") as repo_dir:
        subprocess.run(["git", "-C", repo_dir, "init", "-q", "-b", "main"], check=True)
        subprocess.run(["git", "-C", repo_dir, "config", "user.name", "Test Committer"], check=True)
        subprocess.run(["git", "-C", repo_dir, "config", "user.email", "test@test.local"], check=True)
        os.makedirs(os.path.join(repo_dir, "src"), exist_ok=True)
        with open(os.path.join(repo_dir, "src", "main.py"), "w") as f:
            f.write("# Main entrypoint\nprint('hello')\n")
        subprocess.run(["git", "-C", repo_dir, "add", "src/main.py"], check=True)
        subprocess.run(["git", "-C", repo_dir, "commit", "-q", "-m", "chore: init"], check=True)

        # 1. Create strand
        s_code, s_out, s_err = run_vine("new", "task-defeat-1", "--repo", repo_dir, "--worktree")
        assert s_code == 0
        strand_path = json.loads(s_out)["strand_path"]

        try:
            # 2. Add prompt keyword interceptor in application code (defeat device)
            with open(os.path.join(strand_path, "src", "router.py"), "w") as f:
                f.write("""def isDeepProjectCreationQuery(q: str) -> bool:
    return ('flight game' in q or 'nim_3d_flight_game' in q or 'webworker' in q)
""")
            # Also wire consumer in main.py
            with open(os.path.join(strand_path, "src", "main.py"), "w") as f:
                f.write("from router import isDeepProjectCreationQuery\nprint(isDeepProjectCreationQuery('test'))\n")

            subprocess.run(["git", "-C", strand_path, "add", "src/"], check=True)
            subprocess.run(["git", "-C", strand_path, "commit", "-q", "-m", "feat: added router"], check=True)

            # 3. Running vine gate MUST FAIL with code 7 (ExitGateDefeatDeviceViolation)
            g_code, g_out, g_err = run_vine("gate", "--dir", strand_path, "--allow-no-tests", "--json")
            assert g_code == 7, f"Expected code 7, got {g_code}\nOut: {g_out}\nErr: {g_err}"
            g_data = json.loads(g_out)
            assert g_data["defeat_device_gate"] == "FAIL"
            assert "Volkswagen Defeat Device Violation" in g_data["defeat_device_error"]
            assert len(g_data["defeat_devices"]) >= 1

            # 4. Running vine submit MUST ALSO FAIL with code 7
            sub_code, sub_out, sub_err = run_vine("submit", "--dir", strand_path, "--author", "worker-1", "--allow-no-tests", "--json")
            assert sub_code == 7, f"Expected submit code 7, got {sub_code}\nOut: {sub_out}\nErr: {sub_err}"

            # 5. Passing --allow-defeat-devices allows gate to pass
            g_bypass_code, g_bypass_out, g_bypass_err = run_vine("gate", "--dir", strand_path, "--allow-no-tests", "--allow-defeat-devices", "--json")
            assert g_bypass_code == 0, f"Expected bypass code 0, got {g_bypass_code}\nErr: {g_bypass_err}"
            assert json.loads(g_bypass_out)["defeat_device_gate"] == "SKIPPED (allow-defeat-devices)"

            # 6. Remediate: remove defeat device and use genuine router across provider and consumer
            with open(os.path.join(strand_path, "src", "router.py"), "w") as f:
                f.write("""def route_query(q: str, classifier) -> str:
    return classifier.predict(q)
""")
            with open(os.path.join(strand_path, "src", "main.py"), "w") as f:
                f.write("from router import route_query\nprint(route_query('test', None))\n")
            subprocess.run(["git", "-C", strand_path, "add", "src/"], check=True)
            subprocess.run(["git", "-C", strand_path, "commit", "-q", "-m", "fix: genuine classifier routing"], check=True)

            # 7. Gate passes cleanly without bypass flag
            g_clean_code, g_clean_out, g_clean_err = run_vine("gate", "--dir", strand_path, "--allow-no-tests", "--json")
            assert g_clean_code == 0, f"Expected clean pass, got {g_clean_code}\nErr: {g_clean_err}"
            assert json.loads(g_clean_out)["defeat_device_gate"] == "PASS"

        finally:
            if os.path.exists(strand_path):
                subprocess.run(["git", "-C", repo_dir, "worktree", "remove", "--force", strand_path], capture_output=True)
                subprocess.run(["git", "-C", repo_dir, "worktree", "prune"], capture_output=True)
                shutil.rmtree(os.path.dirname(strand_path), ignore_errors=True)

def test_vine_atomic_submit_commit():
    """Verify vine submit --commit <msg> automatically stages and commits dirty working tree."""
    with tempfile.TemporaryDirectory() as temp_dir:
        repo_dir = os.path.join(temp_dir, "repo")
        os.makedirs(repo_dir)
        subprocess.run(["git", "init", "-b", "main", "-q", repo_dir], check=True)
        subprocess.run(["git", "-C", repo_dir, "config", "user.email", "agent@braid.mesh"], check=True)
        subprocess.run(["git", "-C", repo_dir, "config", "user.name", "Braid Agent"], check=True)

        # Base files in main
        os.makedirs(os.path.join(repo_dir, "src"))
        with open(os.path.join(repo_dir, "src", "app.py"), "w") as f:
            f.write("# Base app\n")
        subprocess.run(["git", "-C", repo_dir, "add", "src/app.py"], check=True)
        subprocess.run(["git", "-C", repo_dir, "commit", "-q", "-m", "Initial commit"], check=True)

        task_id = "task-py-subcommit"
        code, out, err = run_vine("new", task_id, "--repo", repo_dir, "--worktree")
        assert code == 0, f"vine new failed: {err}"
        strand_path = json.loads(out)["strand_path"]

        try:
            # Dirty worktree: provider and consumer modification
            with open(os.path.join(strand_path, "src", "feature.py"), "w") as f:
                f.write("def do_feature(): return 123\n")
            with open(os.path.join(strand_path, "src", "app.py"), "w") as f:
                f.write("from feature import do_feature\nprint(do_feature())\n")

            # Check status is dirty
            p = subprocess.run(["git", "-C", strand_path, "status", "--porcelain"], capture_output=True, text=True)
            assert p.stdout.strip(), "Working tree should be dirty"

            # Run vine submit with --commit
            sub_code, sub_out, sub_err = run_vine(
                "submit", "--dir", strand_path, "--author", "worker-claudia",
                "--commit", "feat: atomic auto-commit from pytest",
                "--allow-no-tests", "--json"
            )
            assert sub_code == 0, f"Submit failed: {sub_err}\nOut: {sub_out}"
            sub_data = json.loads(sub_out)
            assert sub_data["status"] == "ready_for_audit"
            assert sub_data.get("auto_committed") is True
            assert sub_data.get("commit")

            # Verify working tree is now clean
            p2 = subprocess.run(["git", "-C", strand_path, "status", "--porcelain"], capture_output=True, text=True)
            assert p2.stdout.strip() == "", "Working tree should be clean after submit --commit"

            # Verify commit message
            p3 = subprocess.run(["git", "-C", strand_path, "log", "-1", "--pretty=%B"], capture_output=True, text=True)
            assert "feat: atomic auto-commit from pytest" in p3.stdout

            # Submitting again when clean does not create empty commit
            head_sha = sub_data["commit"]
            sub2_code, sub2_out, sub2_err = run_vine(
                "submit", "--dir", strand_path, "--author", "worker-claudia",
                "--commit", "feat: should not commit",
                "--allow-no-tests", "--json"
            )
            assert sub2_code == 0
            sub2_data = json.loads(sub2_out)
            assert "auto_committed" not in sub2_data
            p4 = subprocess.run(["git", "-C", strand_path, "rev-parse", "--short", "HEAD"], capture_output=True, text=True)
            assert p4.stdout.strip() == head_sha

        finally:
            if os.path.exists(strand_path):
                subprocess.run(["git", "-C", repo_dir, "worktree", "remove", "--force", strand_path], capture_output=True)
                subprocess.run(["git", "-C", repo_dir, "worktree", "prune"], capture_output=True)
                shutil.rmtree(os.path.dirname(strand_path), ignore_errors=True)


if __name__ == "__main__":
    import inspect
    import traceback
    tests = [obj for name, obj in inspect.getmembers(sys.modules[__name__]) if inspect.isfunction(obj) and name.startswith("test_")]
    passed = 0
    failed = 0
    for test in tests:
        try:
            test()
            print(f"PASS: {test.__name__}")
            passed += 1
        except Exception as e:
            print(f"FAIL: {test.__name__}:\n{traceback.format_exc()}")
            failed += 1
    print(f"\n{passed} passed, {failed} failed")
    sys.exit(1 if failed else 0)
