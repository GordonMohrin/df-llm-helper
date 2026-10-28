"""BUG-152 (live test i1, 2026-10-28): `dfllm doctor` said "a session started in a parent folder never reads it" while the
session had started in the repo, whose own .claude/settings.json had lost the hook block. The text now tells the three
inactive cases apart: the repo itself, a parent folder of the repo, any other folder."""
import json
from pathlib import Path

from dfpilot import doctor

HOOK = {"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [
    {"type": "command", "command": 'cd "${CLAUDE_PROJECT_DIR:-.}" && python -m dfpilot.hook'}]}]}}


def _repo(base: Path, settings) -> Path:
    d = base / "dfpilot-public"
    (d / ".claude").mkdir(parents=True)
    (d / "dfpilot").mkdir()
    (d / "dfpilot" / "hook.py").write_text("", encoding="utf-8")
    (d / ".claude" / "settings.json").write_text(json.dumps(settings), encoding="utf-8")
    return d


def test_the_repo_without_its_hook_block_says_so(tmp_path):
    repo = _repo(tmp_path, {})
    state, text = doctor.hook_check({"CLAUDE_PROJECT_DIR": str(repo)}, cwd=repo, home=tmp_path / "home", repo=repo)
    assert state == "inactive"
    assert "the repo's own .claude/settings.json" in text and "no dfllm PreToolUse hook" in text
    assert "parent folder" not in text and "git checkout .claude/settings.json" in text


def test_a_parent_folder_keeps_the_parent_advice(tmp_path):
    parent = tmp_path / "projects"
    repo = _repo(parent, HOOK)
    state, text = doctor.hook_check({"CLAUDE_PROJECT_DIR": str(parent)}, cwd=repo, home=tmp_path / "home", repo=repo)
    assert state == "inactive" and "a session started in a parent folder never reads it" in text
    assert str(parent) in text and "Start Claude Code inside the repo folder" in text


def test_another_folder_gets_neutral_advice(tmp_path):
    repo = _repo(tmp_path / "a", HOOK)
    other = tmp_path / "b"
    (other / ".claude").mkdir(parents=True)
    state, text = doctor.hook_check({"CLAUDE_PROJECT_DIR": str(other)}, cwd=other, home=tmp_path / "home", repo=repo)
    assert state == "inactive" and "parent folder" not in text
    assert str(other) in text and str(repo) in text and "Start Claude Code inside the repo folder" in text
    assert doctor.hook_check({"CLAUDE_PROJECT_DIR": str(repo)}, cwd=repo, home=tmp_path / "home", repo=repo)[0] == "active"
