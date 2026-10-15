"""Regressions for the bugs of the Run 9 live test (2026-10-15, bugs/BUG-003/004/005/008/009/010) on the Python side:
the event contract (AUTOLABOR_LEGACY, the new JOBS_SUSPENDED and DEPOT_MISSING fields), the allowlisted autolabor
forms the kernel's guard uses, the config mirror, and a luahost probe of the repeat rule (util/cadence.lua) and of
the kernel's fixes on k_mock (the Lua suites hold the detailed scenarios)."""
import json
import sys
from pathlib import Path

import pytest

from dfpilot import fairplay, lint, schema

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import luahost  # noqa: E402

needs_lua = pytest.mark.skipif(not luahost.available(), reason="no Lua 5.3 for luahost")


def test_autolabor_legacy_event_is_class_a_by_baseline():
    """BUG-010: the guard's event wakes the operator and names whether the switch held."""
    assert schema.EVENTS["AUTOLABOR_LEGACY"][:2] == ("A", "baseline")
    e = {"n": 1, "tick": 5, "type": "AUTOLABOR_LEGACY", "cls": "A", "msg": "x",
         "d": {"fixed": 1, "why": "boot", "after": "monitor"}}
    assert schema.validate("event", e) == []
    e["d"] = {"why": "boot"}
    assert schema.validate("event", e), "fixed is required"
    assert "AUTOLABOR_LEGACY" in (ROOT / "RULES.md").read_text(encoding="utf-8")


def test_new_event_fields_validate():
    """BUG-009/004 (JOBS_SUSPENDED names the reason) and BUG-005 (DEPOT_MISSING says why a planned depot stalls)."""
    js = {"n": 2, "tick": 9, "type": "JOBS_SUSPENDED", "cls": "B", "msg": "x",
          "d": {"suspended": 11, "released": 0, "resuspended": 2, "kept": 0, "planned": 9, "forbidden": 41,
                "other": 0, "unforbidden": 41, "missing": "coffin x1", "blocked": 1,
                "why": "buildingplan: waiting for materials x9; item blocking site x2"}}
    assert schema.validate("event", js) == []
    dm = {"n": 3, "tick": 9, "type": "DEPOT_MISSING", "cls": "A", "msg": "x",
          "d": {"civ": "Muboomon", "planned": 0, "stalled": 1, "proj": "",
                "why": "item blocking site: 41 forbidden, 0 other, 4 resumes failed"}}
    assert schema.validate("event", dm) == []
    dm["d"]["stalled"] = "yes"
    assert schema.validate("event", dm)


def test_guard_commands_are_allowlisted_and_legacy_is_not():
    """BUG-010: the guard reads `autolabor status` / `labormanager mode` and sets `autolabor mode monitor`; nothing
    may switch the legacy engine on."""
    al = fairplay.allowlist(ROOT / "config" / "allowlist.json")
    assert fairplay.check_run("autolabor", ["status"], al)[0]
    assert fairplay.check_run("autolabor", ["mode", "monitor"], al)[0]
    assert fairplay.check_run("labormanager", ["mode"], al)[0]
    assert not fairplay.check_run("autolabor", ["mode", "legacy"], al)[0]


def test_config_mirrors_the_new_knobs():
    cfg = json.loads((ROOT / "config" / "baseline.json").read_text(encoding="utf-8"))
    jobs = cfg["economy"]["jobs"]
    for k in ("sites_per_day", "unforbid_per_day", "mat_scan", "fail_alarm", "depot_move_after", "move_days",
              "move_r", "move_dz", "move_gap", "move_probes"):
        assert isinstance(jobs[k], int), k
    assert jobs["fail_alarm"] <= jobs["depot_move_after"], "the operator hears of a stuck depot before it moves"
    assert cfg["care"]["wake_wall_s"] == 600


def test_changed_lua_files_lint_clean():
    files = [str(ROOT / "lua" / "dfllm" / n) for n in ("economy.lua", "care.lua", "trade.lua", "reflex.lua", "water.lua",
                                                      "baseline.lua", "runner.lua", "snapshot.lua", "util/cadence.lua")]
    assert lint.lua(files) == []


CADENCE_PROBE = r"""
local CAD = require('dfllm.util.cadence')
local out = {}
local function now(t, w) return {tick = t, wall = w} end
local r = nil
out[#out + 1] = select(2, CAD.due(r, now(0, 0), {1}, {'no_coffin'}))            -- first
r = CAD.mark(now(0, 0), {1}, {'no_coffin'})
out[#out + 1] = tostring(CAD.due(r, now(9000, 10000), {1}, {'no_coffin'}))      -- unchanged: false
out[#out + 1] = tostring(CAD.due(r, now(9000, 60), {1, 2}, {'no_coffin'}))      -- grew, wall too short: false
out[#out + 1] = tostring(CAD.due(r, now(100, 9999), {1, 2}, {'no_coffin'}))     -- grew, ticks too short: false
out[#out + 1] = select(2, CAD.due(r, now(9000, 700), {1, 2}, {'no_coffin'}))    -- grew
out[#out + 1] = select(2, CAD.due(r, now(9000, 700), {1}, {'no_job'}))          -- cause
out[#out + 1] = tostring(CAD.due(r, now(9000, 700), {}, {}))                    -- shrank: false
local q = CAD.quiet(r)
out[#out + 1] = tostring(CAD.due(q, now(100, 50), {3}, {}))                     -- new episode within the cadence
print('cad ' .. table.concat(out, ','))
"""


@needs_lua
def test_cadence_rule_in_lua(tmp_path):
    """BUG-008: first at once; a repeat needs news (grew / new cause) and max(7 game days, 10 min wall clock)."""
    f = tmp_path / "cad.lua"
    f.write_text(CADENCE_PROBE, encoding="utf-8")
    r = luahost.run_file(f, [], timeout=20)
    assert r.ok, r.out + r.err
    line = next(x for x in r.out.splitlines() if x.startswith("cad "))
    assert line[4:].split(",") == ["first", "false", "false", "false", "grew", "cause", "false", "false"]


@needs_lua
@pytest.mark.parametrize("suite", ["test_economy_sites.lua", "test_baseline.lua"])
def test_kernel_suites_for_the_live_bugs(suite):
    """The k_mock scenarios of BUG-009/004/005 (economy) and BUG-010 (baseline) pass under luahost."""
    r = luahost.run_file(ROOT / "tests" / "lua" / suite, [], paths=[ROOT / "tests" / "lua"], timeout=120)
    assert r.ok, r.out[-2000:] + r.err[-2000:]
    assert "failed 0" in r.out
