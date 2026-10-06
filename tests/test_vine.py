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

def run_vine(*args, cwd=None):
    cmd = [str(VINE_BIN)] + list(args)
    proc = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd)
    return proc.returncode, proc.stdout, proc.stderr

PACKAGE_JSON = Path(__file__).parent.parent / "package.json"
CANONICAL_VERSION = json.loads(PACKAGE_JSON.read_text()).get("version", "0.1.6")

def test_vine_version():
    code, out, err = run_vine("--version")
    assert code == 0
    assert f"vine {CANONICAL_VERSION}" in out

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
        assert "<!-- BEGIN VINE GUIDE [v1.0] -->" in content
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

        # Check manifest
        manifest_file = os.path.join(strand_path, ".vine.json")
        assert os.path.isfile(manifest_file)
        with open(manifest_file) as f:
            m = json.load(f)
        assert m["task_id"] == task_id
        assert m["status"] in ["IN_PROGRESS", "PROVISIONED"]

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
            g_code, g_out, g_err = run_vine("gate", "--dir", strand_path, "--base", "main", "--json")
            assert g_code == 0, f"Gate failed: {g_err}\nOut: {g_out}"
            g_data = json.loads(g_out)
            assert g_data["clean"] is True
            assert g_data["key1_mechanical"] == "PASS"

            # 4. Manifest should now be READY_FOR_WEAVE
            with open(manifest_file) as f:
                m_updated = json.load(f)
            assert m_updated["status"] == "READY_FOR_WEAVE"

            # 5. List strands
            l_code, l_out, l_err = run_vine("list", "--repo", repo_dir)
            assert l_code == 0
            l_data = json.loads(l_out)
            assert l_data["count"] >= 1

            # 6. Weave strand into canonical repository
            w_code, w_out, w_err = run_vine("weave", "--dir", strand_path, "--base", "main")
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
            assert "Two-Key Gate" in w_err or "weave_rejected" in w_err

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
            manifest_file = os.path.join(strand_path, ".vine.json")
            with open(manifest_file) as f:
                m = json.load(f)
            # Mark strand as WEAVED
            m["status"] = "WEAVED"
            with open(manifest_file, "w") as f:
                json.dump(m, f)

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
            w_code, w_out, w_err = run_vine("weave", "--dir", strand_path, "--base", "main")
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
            g_code, g_out, g_err = run_vine("gate", "--dir", strand_path, "--base", "main", "--json")
            assert g_code == 0, f"Gate failed: {g_err}\nOut: {g_out}"
            assert json.loads(g_out)["clean"] is True

            # 9. Now vine weave succeeds with clean fast-forward
            w_ok_code, w_ok_out, w_ok_err = run_vine("weave", "--dir", strand_path, "--base", "main")
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
            pass_cmd = f"{sys.executable} -c 'import sys; print(\"Tests passed\"); sys.exit(0)'"
            g_code, g_out, g_err = run_vine("gate", "--dir", strand_path, "--base", "main", "--test-command", pass_cmd, "--json")
            assert g_code == 0, f"Expected gate pass: {g_err}\nOut: {g_out}"
            g_data = json.loads(g_out)
            assert g_data["clean"] is True
            assert g_data["key2_semantic"] == "PASS"
            assert g_data["test_command"] == pass_cmd

            # 2. Custom failing test command
            fail_cmd = f"{sys.executable} -c 'import sys; sys.stderr.write(\"Synthetic test failure\"); sys.exit(42)'"
            f_code, f_out, f_err = run_vine("gate", "--dir", strand_path, "--base", "main", "--test-command", fail_cmd, "--json")
            assert f_code == 2, f"Expected gate semantic failure, got {f_code}\nOut: {f_out}"
            f_data = json.loads(f_out)
            assert f_data["clean"] is False
            assert f_data["key2_semantic"] == "FAIL"
            assert "Synthetic test failure" in f_data["compiler_output"]
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
            g_code, g_out, _ = run_vine("gate", "--dir", strand_path, "--base", "develop", "--skip-tests", "--json")
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
            # Gate without --skip-tests should detect ctest
            g_code, g_out, _ = run_vine("gate", "--dir", strand_path, "--base", "main", "--skip-tests", "--json")
            assert g_code == 0
            g_data = json.loads(g_out)
            assert g_data["clean"] is True
        finally:
            if os.path.exists(strand_path):
                subprocess.run(["git", "-C", repo_dir, "worktree", "remove", "--force", strand_path], capture_output=True)
                subprocess.run(["git", "-C", repo_dir, "worktree", "prune"], capture_output=True)
                shutil.rmtree(os.path.dirname(os.path.dirname(strand_path)), ignore_errors=True)



