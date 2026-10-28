"""The live test i2/i1 of the curse package (DF 53.16): the Python side. BUG-137: `dfllm cmd inspect what=unit key=39052`
was refused by the schema ("$.args.key: expected str, got int", cmd.parse_kv turns digits into an int); i1: `next` said
"1 cursed citizens". The Lua suites (tests/lua/test_curse_live.lua, test_curse_live_kern.lua) prove the kernel side.
Every test here fails on the commit before the package (dec5132)."""
from pathlib import Path

from dfpilot import cmd, guide, schema

ROOT = Path(__file__).resolve().parent.parent


def test_bug137_inspect_takes_a_unit_id_from_the_cli():
    args = cmd.parse_kv(["what=unit", "key=39052"])
    assert args == {"what": "unit", "key": 39052}
    assert schema.validate_args("inspect", args) == []
    assert schema.validate_args("inspect", {"what": "unit", "key": "Lorbam Ekastreg"}) == []
    assert schema.validate_args("inspect", {"what": "unit", "key": -1}) != []
    assert schema.validate_args("inspect", {"what": "unit", "key": "x" * 81}) != []


def test_i1_the_curse_tell_line_has_the_singular_for_one_citizen():
    s = {"curse": {"n": 1, "tf": 0, "ids": [5], "mi": 17}}
    steps = [x for x in guide._danger({"state": s, "a": [], "now": 1000}, s, False) if x.key == "curse"]
    assert steps, "a curse step"
    assert "1 cursed citizens" not in (steps[0].tell or "")
    assert "1 cursed citizen" in (steps[0].tell or "")


def test_bug136_the_watch_pass_is_in_the_module_contract():
    text = (ROOT / "docs/v2/CONTRACTS.md").read_text("utf-8")
    assert "watch_every" in text and "M.watch(K)" in text
