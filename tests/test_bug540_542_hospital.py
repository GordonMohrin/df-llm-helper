"""Round 34 (fix34-hosp): BUG-540 (the dry hospital memory: bp sites not blocked while no water is near, the entry expires, the zoneless
hospital room), BUG-541 (the verb well.retire, the act well_remove, the dry_well wake line and the config keys), BUG-542 (water.unstick
keeps the zone). The Lua side: tests/lua/test_bug540_542_hospital.lua."""
import shlex
from pathlib import Path

import pytest

from dfpilot import fairplay, lint, schema, wake
from dfpilot.bp import sites
from dfpilot.cmd import parse_kv

ROOT = Path(__file__).resolve().parent.parent


def test_the_verb_and_the_act_are_in_the_registry():
    assert schema.VERBS["well.retire"] == ("water", None, False)
    assert schema.validate_args("well.retire", {"id": 18136}) == []
    assert schema.validate_args("well.retire", {"id": 18136, "approve": True}) == []
    assert schema.validate_args("well.retire", {}) != []
    assert schema.validate_args("well.retire", {"id": "x"}) != []
    assert schema.ACT["well_remove"] == ["water"]
    contract = (ROOT / "lua" / "dfllm" / "util" / "contract.lua").read_text(encoding="utf-8")
    assert "['well.retire'] = {mod = 'water'}" in contract and "well_remove = {'water'}" in contract
    act = (ROOT / "lua" / "dfllm" / "act.lua").read_text(encoding="utf-8")
    assert "function I.well_remove(id)" in act


@pytest.mark.parametrize("line", ["dfllm cmd well.retire id=18136", "dfllm cmd well.retire id=18136 approve=true"])
def test_the_commands_parse_and_pass_the_hook(line):
    w = shlex.split(line)
    assert schema.validate_args(w[2], parse_kv(w[3:])) == []
    ok, why = lint.cmd(line, dev=False, shell=True)
    assert ok, why


def test_the_config_keys_are_known_and_checked():
    water = (ROOT / "lua" / "dfllm" / "water.lua").read_text(encoding="utf-8")
    for k in ("hrm_expire", "trap", "trap_days", "trap_near", "trap_dying"):
        assert f" {k} = " in water, k
        assert k in fairplay.WATER_LIM, k
    assert fairplay.water_errors() == []


def test_the_site_search_names_the_verb_for_what_the_kernel_counts():
    # the kernel counts only what can come back in water.hrm (a dry memory without water near is 0 = no key): the site is found
    snap = {"id": "x", "w": 1, "h": 1}
    with pytest.raises(ValueError) as e:
        sites.rank(snap, "hospital", None, {"zones": {"Z4": [[0, 0, 0, 1, 1, 1]]}}, water={"src": [[1, 2, 3]], "near": 30, "hrm": 1})
    assert "hospital.restore" in str(e.value) and "no second hospital" in str(e.value)


def test_dry_well_wake_line_names_the_command_and_is_urgent():
    cmds = ["dfllm cmd well.retire id=18136", "dfllm cmd water.unstick unit=26505"]
    d = {"id": "dry_well", "q": "1 GiveWater carrier(s) stand at the DRY well 18136 (82,119,134, no water below)", "units": [26505],
         "cmds": cmds}
    hint = wake.next_hint("DECISION_NEEDED", {"d": d})
    assert cmds[0] in hint and cmds[1] in hint and "DRY well" in hint, hint
    assert "dry_well" in wake.URGENT_DECISIONS


def test_job_stalled_line_no_longer_promises_a_zone_removal():
    d = {"id": "job_stalled", "q": "1 water job(s) stalled", "units": [1], "cmds": ["dfllm cmd water.unstick unit=1"]}
    hint = wake.next_hint("DECISION_NEEDED", {"d": d})
    assert "hospital zone stays" in hint, hint


def test_the_lua_unstick_verb_never_calls_the_hospital_rung():
    water = (ROOT / "lua" / "dfllm" / "water.lua").read_text(encoding="utf-8")
    assert "if deep and not opt.force then" in water
    assert "the hospital zone stays" in water
