"""WP4: shell-boundary policy (lint.cmd) and the Claude Code PreToolUse hook (df_llm_helper.hook)."""
import io
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

from df_llm_helper import hook, lint

ROOT = Path(__file__).resolve().parent.parent
DFRUN = r'"E:\Program Files (x86)\Steam\steamapps\common\Dwarf Fortress\dfhack-run.exe"'

BLOCKED = [
    "dfhack-run lever pull --id 12 --instant",
    "dfhack-run claude/x",
    "dfhack-run claude/gefahr scan",
    "dfhack-run fastdwarf 1",
    f"{DFRUN} fastdwarf 1",
    f"& {DFRUN} :lua print(1)",                                  # PowerShell call operator
    'dfhack-run lua "df.global.pause_state = false"',
    "dfhack-run lua -f C:/x/y.lua",
    "dfhack-run reveal",
    "dfhack-run createitem BAR INORGANIC:IRON 5",
    "dfhack-run caravan extend",
    "dfhack-run digv",
    "dfhack-run control-panel enable fastdwarf",
    "dfhack-run enable fastdwarf",
    "dfhack-run devel/query --table df.global.world.units.active",
    "dfhack-run dfllm frobnicate",
    "dfhack-run timestream set fps 500",                         # a write without DFLLM_DEV
    "dfhack-run orders import library/basic",
    "dfhack-run dfllm selftest --exec probe.lua",                # dev only
    'cd "E:/Program Files (x86)/Steam/steamapps/common/Dwarf Fortress" && ./dfhack-run.exe reveal',
    "git status; dfhack-run teleport -x 1",
    'bash -c "dfhack-run createitem X"',
    "powershell -Command \"dfhack-run reveal\"",
    "cmd /c dfhack-run reveal",
    "python -c \"import subprocess; subprocess.run(['dfhack-run', 'fastdwarf', '1'])\"",
    f"Start-Process -FilePath {DFRUN} -ArgumentList 'lua','print(1)'",
    "$dfhackRun = 'x'; & $dfhackRun lua print(1)",
    "for i in 1 2; do dfhack-run reveal; done",
    # review WP4: wrappers, variables, substitutions and code strings (Git Bash / PowerShell habits)
    "timeout 30 dfhack-run fastdwarf 1",
    "winpty dfhack-run reveal",
    "nice dfhack-run reveal",
    "stdbuf -oL dfhack-run reveal",
    "xargs dfhack-run reveal",
    "ssh host dfhack-run reveal",
    'DFR="/e/x/dfhack-run.exe"; "$DFR" fastdwarf 1',
    "export DFR=/e/x/dfhack-run.exe; ${DFR} reveal",
    r'$exe = "E:\x\dfhack-run.exe"; & $exe fastdwarf 1',
    r'$env:DFR = "E:\x\dfhack-run.exe"; & $env:DFR reveal',
    r"set DFR=E:\x\dfhack-run.exe & %DFR% reveal",
    "x=`dfhack-run reveal`",
    "x=$(dfhack-run reveal)",
    'echo "$(dfhack-run reveal)"',
    "git log -1 --format=`dfhack-run reveal`",
    "python -c \"import os; os.system('dfhack-run fastdwarf 1')\"",
    "python -c \"import subprocess; subprocess.run('dfhack-run ' + c, shell=True)\"",
    "node -e \"require('child_process').execSync('dfhack-run reveal')\"",
    "perl -e 'system(\"dfhack-run reveal\")'",
    r'& ("E:\x\dfhack-run.exe") reveal',
    r"& (Join-Path $d 'dfhack-run.exe') reveal",
    "alias d=dfhack-run; d reveal",
    r"Set-Alias dfr E:\x\dfhack-run.exe; dfr reveal",
    'f() { dfhack-run "$@"; }; f reveal',
    "1..2 | % { dfhack-run reveal }",
    r"find . -name x -exec dfhack-run {} \;",
    "xargs -n1 dfhack-run < cmds.txt",
    "& $unknownVar reveal",
    "echo 'dfhack-run reveal' | bash",
    "cat <<'EOF' | bash\ndfhack-run reveal\nEOF",
    "bash <<'EOF'\ndfhack-run reveal\nEOF",
    "python - <<'EOF'\nimport os\nos.system('dfhack-run fastdwarf 1')\nEOF",
    "cat <<EOF\n$(dfhack-run reveal)\nEOF",
    "bash <<< 'dfhack-run reveal'",
    "dfhack-run dfllm status && sudo -u df dfhack-run reveal",
    'bash -c "dfhack-run dfllm status; dfhack-run reveal"',
    r'cmd /c "cd /d E:\DF && dfhack-run.exe reveal"',
    "Invoke-Expression 'dfhack-run reveal'",
    "./tools/run.sh dfhack-run reveal",
    'python -m pytest -k "dfhack-run fastdwarf"',               # fail closed: judged like a call
    "source <(echo dfhack-run reveal)",
    'eval "$(echo dfhack-run reveal)"',
    "eval dfhack-run reveal",
    'p=/e/x; "$p/dfhack-run.exe" reveal',
    "watch -n 5 dfhack-run reveal",
    'c="dfhack-run reveal"; $c',
    '$c = "dfhack-run reveal"; iex $c',
    r'$p = "E:\Program Files (x86)\Steam\dfhack-run.exe"; & $p reveal',
    "awk 'BEGIN{system(\"dfhack-run reveal\")}'",                # mention-only commands that run programs
    "sed 's/x/dfhack-run reveal/e' f",
    "git -c alias.x='!dfhack-run reveal' x",
    "rg --pre dfhack-run reveal .",
]
ALLOWED = [
    "dfhack-run dfllm status",
    "dfhack-run dfllm boot",
    "dfhack-run dfllm selftest --mock",
    f"& {DFRUN} dfllm status 2>&1 | Select-Object -Last 5",
    "dfhack-run load-save region1",
    "dfhack-run help lever",
    "dfhack-run ls",
    "dfhack-run",
    "git status",
    'grep -rn "dfhack-run fastdwarf" docs/',
    "echo 'dfhack-run reveal'",
    'git commit -m "dfhack-run lua x is now blocked"',
    "python -m df_llm_helper cmd drill '{}'",
    "dfllm status",
    "python -m pytest tests/test_hook.py -q",
    "source .venv/bin/activate",
    "$dfhackRun = 'C:/DF/dfhack-run.exe'; & $dfhackRun dfllm status",
    r"$dfr = 'E:\x\dfhack-run.exe'; $o = & $dfr dfllm status; $o",
    'DFR="/e/x/dfhack-run.exe"; "$DFR" dfllm status',
    "timeout 60 dfhack-run dfllm status",
    "x=$(dfhack-run dfllm status); echo $x",
    'rg -n "dfhack-run" lua/ | head -5',
    "timeout 5 grep dfhack-run notes.txt",
    'ls "E:/x/dfhack-run.exe"',
    r'Test-Path "E:\x\dfhack-run.exe"',
    '[ -f "$DF/dfhack-run.exe" ] && echo ok',
    "cat > notes.md <<'EOF'\nnever run dfhack-run reveal (it is blocked)\nEOF",
    # the Claude Code commit pattern; the message mentions blocked calls and has quotes and parens
    "git commit -m \"$(cat <<'EOF'\nhook: block `dfhack-run reveal` (it's armok); \"fastdwarf\" too\n\n"
    "Co-Authored-By: Claude <noreply@anthropic.com>\nEOF\n)\"",
    "git commit -m @'\nhook: dfhack-run reveal is blocked, don't use it\n'@",
    "python -m df_llm_helper follow",
    "ls dfhack-run-logs/ && cat dfhack-runner.txt",
    'python -m df_llm_helper lint --cmd "dfhack-run reveal"',  # the linter only judges its argument
    "n=$(grep -c dfhack-run log.txt)",
    "while true; do dfhack-run dfllm status; sleep 5; done",
    'c="dfhack-run dfllm status"; $c',
    r'$p = "E:\Program Files (x86)\Steam\dfhack-run.exe"; & $p dfllm status',
    "awk '/dfhack-run/ {print}' log.txt",
    "sed -n '/dfhack-run/p' f",
    "git grep dfhack-run",
]


@pytest.mark.parametrize("text", BLOCKED)
def test_blocked(text):
    ok, why = lint.cmd(text, dev=False, shell=True)
    assert not ok, why


@pytest.mark.parametrize("text", ALLOWED)
def test_allowed(text):
    ok, why = lint.cmd(text, dev=False, shell=True)
    assert ok, why


def test_reasons_name_the_rule():
    assert lint.cmd("$dfhackRun = 'x'; & $dfhackRun lua print(1)", shell=True)[1].startswith("inline lua")
    assert lint.cmd("dfhack-run control-panel enable fastdwarf", shell=True)[1] == "blocked: fastdwarf"
    assert "unparsable" in lint.cmd(f"Start-Process -FilePath {DFRUN} -ArgumentList 'lua'", shell=True)[1]


def test_dev_mode_allows_allowlisted_writes_only():
    assert lint.cmd("dfhack-run autochop target 40 14", dev=True)[0]
    assert lint.cmd("dfhack-run combine all -q", dev=True)[0]
    for text in ("dfhack-run fastdwarf 1", "dfhack-run lua print(1)", "dfhack-run claude/x",
                 "dfhack-run timestream set calendar 2", "dfhack-run lever pull --id 1"):
        assert not lint.cmd(text, dev=True)[0], text


@pytest.mark.parametrize("text", [
    "dfhack-run timestream set fps 500", "dfhack-run orders sort", "dfhack-run pop-control set max-pop 200",
    "dfhack-run quickfort run library/dreamfort.csv -n /dig", "dfhack-run overlay disable all",
    "dfhack-run control-panel disable timestream", "dfhack-run workorder {}",
])
def test_owned_actuators_stay_with_the_kernel_even_in_dev_mode(text):
    """DESIGN §3: one writer per actuator; the shell never competes with arbiter/readiness/runner/economy."""
    ok, why = lint.cmd(text, dev=True)
    assert not ok and "owned by act." in why, why


def test_selftest_exec_is_linted(tmp_path):
    good, bad = tmp_path / "good.lua", tmp_path / "bad.lua"
    good.write_text("local n = #df.global.world.items.all\nprint(n)\n", encoding="utf-8")
    bad.write_text("df.global.pause_state = false\n", encoding="utf-8")
    assert lint.cmd(f"dfhack-run dfllm selftest --exec {good}", dev=True)[0]
    assert lint.cmd("dfhack-run dfllm selftest --exec good.lua", dev=True, cwd=str(tmp_path))[0]
    ok, why = lint.cmd(f"dfhack-run dfllm selftest --exec {bad}", dev=True)
    assert not ok and "df-write" in why
    assert not lint.cmd(f"dfhack-run dfllm selftest --exec {tmp_path / 'none.lua'}", dev=True)[0]
    assert not lint.cmd(f"dfhack-run dfllm selftest --exec {good}", dev=False)[0]


def test_bare_dfhack_lines_for_the_cli():
    """`dfllm lint --cmd STR` judges a bare DFHack line; ordinary shell words stay allowed."""
    for text in ("lever pull --instant", "claude/x", "fastdwarf 1", "lua print(1)", "reveal"):
        assert not lint.cmd(text)[0], text
    for text in ("git status", "ls -la", "source x", "dfllm status", "python -m df_llm_helper status"):
        assert lint.cmd(text)[0], text
    assert lint.cmd("fastdwarf 1", shell=True)[0]                # in a shell this runs nothing in DF


def test_env_controls_dev(monkeypatch):
    monkeypatch.setenv("DFLLM_DEV", "1")
    assert lint.cmd("dfhack-run autochop target 40 14")[0]
    monkeypatch.setenv("DFLLM_DEV", "0")
    assert not lint.cmd("dfhack-run autochop target 40 14")[0]


# ---------------------------------------------------------------- hook entry point
def payload(cmd, tool="Bash", **kw):
    return {"session_id": "s", "hook_event_name": "PreToolUse", "tool_name": tool,
            "tool_input": {"command": cmd, "description": "x"}, **kw}


def test_decide(tmp_path, monkeypatch):
    log = tmp_path / "hook.log"
    monkeypatch.setenv("DFLLM_HOOK_LOG", str(log))
    assert hook.decide(payload("dfhack-run fastdwarf 1"), env={}) [0] == 2
    assert hook.decide(payload("dfhack-run lever pull --instant", "PowerShell"), env={})[0] == 2
    assert hook.decide(payload("dfhack-run dfllm status"), env={}) == (0, "")
    assert hook.decide(payload("ls"), env={}) == (0, "")
    assert hook.decide(payload("dfhack-run autochop target 40 14"), env={"DFLLM_DEV": "1"}) == (0, "")
    assert hook.decide({"tool_name": "Read", "tool_input": {"file_path": "x"}}, env={}) == (0, "")
    assert hook.decide({"tool_name": "Bash", "tool_input": "junk"}, env={}) == (0, "")
    # every tool that runs tool_input.command (DESIGN §8: Monitor on `dfllm follow`)
    assert hook.decide(payload("dfhack-run reveal", "Monitor"), env={})[0] == 2
    assert hook.decide(payload("dfhack-run reveal", "mcp__terminal__run_in_terminal"), env={})[0] == 2
    assert hook.decide(payload("python -m df_llm_helper follow", "Monitor"), env={}) == (0, "")
    assert hook.decide(payload("dfhack-run reveal", "SomeFutureTool"), env={})[0] == 2
    lines = [json.loads(x) for x in log.read_text(encoding="utf-8").splitlines()]
    assert [e["ok"] for e in lines] == [False, False, True, True, False, False, False]  # 'ls' is not logged
    assert [e["tool"] for e in lines][4:6] == ["Monitor", "mcp__terminal__run_in_terminal"]
    assert all({"wall", "tool", "ok", "why", "dev", "cmd"} <= set(e) for e in lines)


def test_lint_error_fails_closed_only_for_df_commands(monkeypatch):
    monkeypatch.setenv("DFLLM_HOOK_LOG", os.devnull)

    def boom(*a, **k):
        raise RuntimeError("bug")
    monkeypatch.setattr(lint, "cmd", boom)
    assert hook.decide(payload("dfhack-run dfllm status"), env={})[0] == 2
    assert hook.decide(payload("git status"), env={}) == (0, "")


def test_main_reads_stdin(monkeypatch, capsys):
    monkeypatch.setenv("DFLLM_HOOK_LOG", os.devnull)
    assert hook.main(io.StringIO(json.dumps(payload("dfhack-run claude/x")))) == 2
    assert "claude/*" in capsys.readouterr().err
    assert hook.main(io.StringIO("not json")) == 0
    assert hook.main(io.StringIO("not json dfhack-run reveal")) == 2
    raw = json.dumps(payload("dfhack-run fastdwarf 1  # \u201d \u2501"), ensure_ascii=False).encode("utf-8")
    assert hook.main(io.BytesIO(raw)) == 2                       # bytes are decoded as UTF-8
    assert hook.main(io.BytesIO(b"\xff\xfe dfhack-run reveal")) == 2


def test_log_never_raises(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_HOOK_LOG", str(tmp_path / "h.log"))
    hook.log({"cmd": "dfhack-run x \udc81 \u201d"})              # lone surrogate from a cp1252 decode
    assert "\u201d" in (tmp_path / "h.log").read_text(encoding="utf-8")
    monkeypatch.setenv("DFLLM_HOOK_LOG", str(tmp_path))         # a directory: the write fails quietly
    hook.log({"cmd": "x"})


def test_import_error_fails_closed(monkeypatch):
    """A broken lint/fairplay/schema import (another WP's bug) must not open the door."""
    monkeypatch.setenv("DFLLM_HOOK_LOG", os.devnull)
    monkeypatch.setitem(sys.modules, "df_llm_helper.lint", None)  # the next import raises ImportError
    assert hook.main(io.StringIO(json.dumps(payload("dfhack-run dfllm status")))) == 2
    assert hook.main(io.StringIO(json.dumps(payload("git status")))) == 0


@pytest.mark.parametrize("argv", [["-m", "df_llm_helper.hook"], [str(ROOT / "df_llm_helper" / "hook.py")]])
def test_hook_process(argv, tmp_path):
    """Raw UTF-8 bytes on stdin, as Claude Code sends them (U+201D and U+2501 contain bytes that
    cp1252 cannot decode)."""
    env = dict(os.environ, DFLLM_HOOK_LOG=str(tmp_path / "h.log"), DFLLM_DEV="0")
    env.pop("PYTHONIOENCODING", None)
    env.pop("PYTHONUTF8", None)
    for cmd, code in (("dfhack-run fastdwarf 1", 2), ("dfhack-run dfllm status", 0), ("git log -1", 0),
                      ("dfhack-run fastdwarf 1  # \u00c1 \u2501 \u201d", 2),
                      ('git commit -m "\u201cdfhack-run\u201d \u2501 notes"', 0),
                      ("dfhack-run dfllm status  # \u2501 \u201d \u0441", 0)):
        data = json.dumps(payload(cmd), ensure_ascii=False).encode("utf-8")
        r = subprocess.run([sys.executable, *argv], input=data, capture_output=True, cwd=ROOT, env=env, timeout=60)
        err = r.stderr.decode("utf-8", "replace")
        assert r.returncode == code, (cmd, err)
        assert ("blocked" in err) == (code == 2), err
    lines = (tmp_path / "h.log").read_text(encoding="utf-8").splitlines()
    assert any("\u2501" in x for x in lines)                      # logged as UTF-8, not lost


def test_hook_process_fails_closed_when_lint_cannot_be_imported(tmp_path):
    env = dict(os.environ, DFLLM_HOOK_LOG=str(tmp_path / "h.log"), DFLLM_DEV="0")
    code = ("import runpy, sys; sys.modules['df_llm_helper.lint'] = None; "
            "runpy.run_module('df_llm_helper.hook', run_name='__main__')")
    for cmd, want in (("dfhack-run dfllm status", 2), ("git status", 0)):
        r = subprocess.run([sys.executable, "-c", code], input=json.dumps(payload(cmd)).encode("utf-8"),
                           capture_output=True, cwd=ROOT, env=env, timeout=60)
        assert r.returncode == want, (cmd, r.stderr.decode("utf-8", "replace"))


def test_project_settings_register_the_hook():
    s = json.loads((ROOT / ".claude" / "settings.json").read_text(encoding="utf-8"))
    entries = s["hooks"]["PreToolUse"]
    assert len(entries) == 1
    import re
    for tool in hook.TOOLS:                                      # every tool that runs a shell command
        assert re.fullmatch(entries[0]["matcher"], tool), tool
    assert set(hook.TOOLS) >= {"Bash", "PowerShell", "Monitor", "mcp__terminal__run_in_terminal"}
    h = entries[0]["hooks"][0]
    assert h["type"] == "command" and "python -m df_llm_helper.hook" in h["command"]
    assert "CLAUDE_PROJECT_DIR" in h["command"]
