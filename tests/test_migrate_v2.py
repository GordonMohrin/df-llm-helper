"""WP10 tools/migrate_v2.py on a fake DF tree in tmp (never the real install) with a fake process/task layer."""
import hashlib
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "tools"))
import migrate_v2 as mg  # noqa: E402


class FakeSys:
    def __init__(self):
        self.running = False
        self.procs = [{"pid": 101, "cmd": r'"C:\Python314\python.exe" -m df_llm_helper waechter --loop'},
                      {"pid": 102, "cmd": r"python C:\x\dwarf-fortress\tools\aufsicht\runde.py --follow --since 5"},
                      {"pid": 103, "cmd": r"python -m pytest tests"}]
        self.state = "Ready"
        self.action = {"Execute": '"C:\\Python314\\pythonw.exe"', "Arguments": '"C:\\x\\supervisor.py"',
                       "WorkingDirectory": None}
        self.calls = []

    def df_running(self):
        return self.running

    def processes(self):
        return [dict(p) for p in self.procs]

    def kill(self, pid):
        self.calls.append(("kill", pid))
        self.procs = [p for p in self.procs if p["pid"] != pid]
        return True, "SUCCESS"

    def task_state(self, name):
        return self.state

    def task_enable(self, name, on):
        self.calls.append(("task", on))
        self.state = "Ready" if on else "Disabled"
        return True, "SUCCESS"

    def task_action(self, name):
        return dict(self.action) if self.action else None

    def task_set_action(self, name, a):
        self.calls.append(("action", a["Arguments"]))
        self.action = dict(a)
        return True, ""


def put(p, data):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(data if isinstance(data, bytes) else data.encode("utf-8"))


@pytest.fixture
def X(tmp_path):
    df, ra, rb = tmp_path / "DF", tmp_path / "dfpilot-public", tmp_path / "dwarf-fortress"
    put(df / "dfhack-config" / "script-paths.txt",
        "# Add additional script search paths here\r\n# Paths preceded by \"+\" will be searched first\r\n"
        f"+{rb / 'lua'}\r\n")
    put(df / "dfhack-config" / "init" / "onMapLoad.init", "# v1\nclaude/tempo load\nclaude/wachen load\n")
    put(df / "hack" / "scripts" / "claude" / "util.lua", "-- v1")
    put(df / "hack" / "scripts" / "gui" / "other.lua", "-- keep")
    put(df / "df-llm-helper-runtime" / "tools" / "out" / "aufsicht.json", "{}")
    for p in mg.PLUGINS:
        put(df / "hack" / "plugins" / f"{p}.plug.dll", b"MZ" + p.encode())
    put(df / "hack" / "plugins" / "buildingplan.plug.dll", b"MZ")
    put(df / "prefs" / "init.txt", "[FPS_CAP:250]")
    lines = []
    sysf = FakeSys()
    ctx = mg.Ctx(df=df, repo_a=ra, repo_b=rb, sys=sysf, out=lines.append, clock=lambda: 1_791_600_000)
    ctx.lines = lines
    return ctx


def tree(df, skip_archive=False):
    return {str(p.relative_to(df)): hashlib.sha256(p.read_bytes()).hexdigest() for p in df.rglob("*")
            if p.is_file() and not (skip_archive and p.relative_to(df).parts[0] == "_archive-v1")}


def run(X, *args):
    X.lines.clear()
    return mg.main(list(args), ctx=X)


def text(X):
    return "\n".join(X.lines)


def test_dry_run_is_default_and_changes_nothing(X):
    before = tree(X.df)
    assert run(X) == 0
    out = text(X)
    assert tree(X.df) == before and X.sys.calls == [] and not X.archive.exists()
    for name in ("stop-v1-processes", "disable-task", "script-paths", "onmapload-init", "archive-claude-scripts",
                 "archive-v1-runtime"):
        assert f"] {name}: todo" in out, name
    assert "DRY RUN" in out and out.count("would apply") == 6
    assert "pid 101" in out and "pid 102" in out and "pid 103" not in out
    assert "repoint-task (--repoint-task)" in out and "plugin-confirm (--plugins)" in out


def test_apply_migrates_and_is_idempotent(X):
    before = tree(X.df)
    assert run(X, "--apply") == 0, text(X)
    df = X.df
    sp = (df / "dfhack-config" / "script-paths.txt").read_bytes().decode()
    assert f"+{X.repo_a / 'lua'}\r\n" in sp and str(X.repo_b) not in sp and sp.startswith("# Add additional")
    assert mg._commands((df / "dfhack-config" / "init" / "onMapLoad.init").read_text()) == ["dfllm boot"]
    assert (X.archive / "hack" / "scripts" / "claude" / "util.lua").read_text() == "-- v1"
    assert not (df / "hack" / "scripts" / "claude").exists()
    assert (df / "hack" / "scripts" / "gui" / "other.lua").exists()
    assert (X.archive / "df-llm-helper-runtime" / "tools" / "out" / "aufsicht.json").exists()
    assert not (df / "df-llm-helper-runtime").exists()
    assert all((df / "hack" / "plugins" / f"{p}.plug.dll").exists() for p in mg.PLUGINS)   # opt-in only
    prefs = str(Path("prefs") / "init.txt")
    assert tree(df)[prefs] == before[prefs]                                                 # prefs untouched
    assert ("kill", 101) in X.sys.calls and ("kill", 102) in X.sys.calls and ("kill", 103) not in X.sys.calls
    assert X.sys.state == "Disabled" and X.sys.action["Arguments"] == '"C:\\x\\supervisor.py"'
    j = json.loads(X.journal.read_text(encoding="utf-8"))
    assert [e["step"] for e in j["entries"]] == ["stop-v1-processes", "disable-task", "script-paths",
                                                 "onmapload-init", "archive-claude-scripts", "archive-v1-runtime"]
    after = tree(df)
    X.sys.calls.clear()
    assert run(X, "--apply") == 0
    assert tree(df) == after and X.sys.calls == [] and "applied" not in text(X)
    assert text(X).count(": done - ") == 6
    assert len(json.loads(X.journal.read_text(encoding="utf-8"))["entries"]) == 6


def test_revert_restores_the_install(X):
    before = tree(X.df)
    assert run(X, "--apply") == 0
    assert run(X, "--revert") == 0, text(X)
    assert tree(X.df, skip_archive=True) == before
    assert X.sys.state == "Ready"
    assert "manual" in text(X) and "waechter" in text(X)               # processes are not relaunched
    assert run(X, "--revert") == 0 and "nothing to revert" in text(X)
    assert run(X, "--apply") == 0 and X.sys.state == "Disabled"        # can migrate again


def test_revert_keeps_files_edited_after_migration(X):
    assert run(X, "--apply") == 0
    sp = X.df / "dfhack-config" / "script-paths.txt"
    sp.write_text("+C:\\mine\\lua\n")
    assert run(X, "--revert") == 1
    assert "conflict" in text(X) and sp.read_text() == "+C:\\mine\\lua\n"
    assert (X.df / "hack" / "scripts" / "claude" / "util.lua").exists()   # the other steps were reverted
    assert run(X, "--revert", "--force") == 0
    assert str(X.repo_b / "lua") in sp.read_text()


@pytest.mark.parametrize("running", [True, None])
def test_refuses_while_df_runs(X, running):
    X.sys.running = running
    before = tree(X.df)
    assert run(X, "--apply") == 2 and "REFUSED" in text(X)
    assert tree(X.df) == before and X.sys.calls == []
    assert run(X, "--apply", "--force") == 0


def test_task_disabled_before_stays_disabled(X):
    X.sys.state = "Disabled"
    assert run(X, "--apply") == 0 and "disable-task: done" in text(X)
    assert run(X, "--revert") == 0
    assert X.sys.state == "Disabled" and ("task", True) not in X.sys.calls


def test_missing_task_and_process_list_failure(X):
    X.sys.state, X.sys.action = None, None
    X.sys.processes = lambda: None
    assert run(X) == 1
    assert "disable-task: n/a" in text(X) and "stop-v1-processes: blocked" in text(X)


def test_move_conflict_is_blocked(X):
    put(X.archive / "hack" / "scripts" / "claude" / "old.lua", "x")
    assert run(X, "--apply") == 1
    assert "archive-claude-scripts: blocked" in text(X)
    assert (X.df / "hack" / "scripts" / "claude" / "util.lua").exists()


def test_optin_plugins_and_task_repoint(X):
    assert run(X, "--apply", "--plugins", "--repoint-task") == 0, text(X)
    for p in mg.PLUGINS:
        assert (X.df / "hack" / "plugins" / "_disabled" / f"{p}.plug.dll").exists()
        assert not (X.df / "hack" / "plugins" / f"{p}.plug.dll").exists()
    assert (X.df / "hack" / "plugins" / "buildingplan.plug.dll").exists()
    assert X.sys.action == {"Execute": "C:\\Python314\\pythonw.exe", "Arguments": mg.SUPERVISE_ARGS,
                            "WorkingDirectory": str(X.repo_a)}
    assert X.sys.state == "Disabled"
    assert run(X, "--revert") == 0
    assert all((X.df / "hack" / "plugins" / f"{p}.plug.dll").exists() for p in mg.PLUGINS)
    assert X.sys.action["Arguments"] == '"C:\\x\\supervisor.py"'


def test_script_paths_rewrite_rules(X):
    sp = mg.ScriptPaths()
    a, b = f"+{X.repo_a / 'lua'}", str(X.repo_b / "lua")
    assert sp.new_text(X, f"# c\n+{b}\n") == f"# c\n{a}\n"
    assert sp.new_text(X, f"{a}\n+{b}\n") == f"{a}\n"                         # both -> one repo A line
    assert sp.new_text(X, f"-\"{b.upper()}\\\"\n") == f"{a}\n"                # quotes, case, trailing slash
    assert sp.new_text(X, "+C:\\other\\lua\n") == f"+C:\\other\\lua\n{a}\n"   # other paths stay
    assert sp.new_text(X, f"{a}\n") == f"{a}\n"
    assert sp.new_text(X, "") == f"{a}\n"


def test_onmapload_with_dfllm_boot_is_done(X):
    put(X.df / "dfhack-config" / "init" / "onMapLoad.init", "# mine\n  dfllm boot  \n# more\n")
    st, _ = mg.OnMapLoad().check(X)
    assert st == "done"
    (X.df / "dfhack-config" / "init" / "onMapLoad.init").unlink()
    st, detail = mg.OnMapLoad().check(X)
    assert st == "todo" and "+dfllm boot" in detail
    assert run(X, "--apply") == 0
    assert mg._commands((X.df / "dfhack-config" / "init" / "onMapLoad.init").read_text()) == ["dfllm boot"]
    assert run(X, "--revert") == 0
    assert not (X.df / "dfhack-config" / "init" / "onMapLoad.init").exists()
