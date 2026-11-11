"""BUG-731: `lua` through a wrapper script (a player's dh.sh around the DFHack client) is blocked like the direct call."""
import pytest

from dfpilot import hook, lint

BLOCKED = [
    "dh.sh lua",
    "./dh.sh lua",
    "./dh.sh lua -f probe.lua",
    "bash dh.sh lua",
    "bash ./tools/dh.sh :lua print(1)",
    "sh -x dh.sh lua -f x.lua",
    '"/e/x/My Tools/dh.sh" lua',
    "cd /e/x && ./dh.sh lua; echo done",
    'bash -c "./dh.sh lua -f a.lua"',
    "timeout 30 ./dh.sh lua",
    "x=$(./dh.sh lua)",
    "for i in 1 2; do ./dh.sh lua; done",
]
ALLOWED = [
    "./dh.sh dfllm status",
    "bash build.sh test",
    "./run.sh",
    "git commit -m 'fix dh.sh lua wrapper'",
    "echo dh.sh lua",
    "grep -n 'dh.sh lua' notes.md",
    "python -m dfpilot status",
    "ls dh.sh",
]


@pytest.mark.parametrize("text", BLOCKED)
def test_wrapper_lua_blocked(text):
    ok, why = lint.cmd(text, shell=True)
    assert not ok and "lua" in why, (text, why)


@pytest.mark.parametrize("text", ALLOWED)
def test_wrapper_other_allowed(text):
    ok, why = lint.cmd(text, shell=True)
    assert ok, (text, why)


def test_hook_decides_the_wrapper_call():
    code, msg = hook.decide({"tool_name": "Bash", "tool_input": {"command": "./dh.sh lua"}}, env={})
    assert code == 2 and "lua" in msg
    code, _ = hook.decide({"tool_name": "Bash", "tool_input": {"command": "bash run.sh"}}, env={})
    assert code == 0
