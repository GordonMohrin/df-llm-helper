"""FR-95 (the aquifer pass): fair-play lint for the one allowed aquifer-flag read (revealed tiles only), the AQ_* event
contracts, `plan check` on a breach:damp park and a sealing shaft, and the documents that carry the decisions."""
import copy
import json
import re
import textwrap
from pathlib import Path

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import files, lint, plan, schema

ROOT = Path(__file__).resolve().parents[1]
GUARDED = """
    local M = {}
    function M.revealed_aquifer(des)
      if des == nil or des.hidden ~= false then return nil end
      return des.water_table == true
    end
    return M
"""


def rule_set(src, name):
    return {f["rule"] for f in lint.lua_source(textwrap.dedent(src), name)}


def test_lint_allows_the_revealed_aquifer_read_in_snapshot_only():
    assert "hidden-read" not in rule_set(GUARDED, "lua/dfllm/snapshot.lua")
    # the same function anywhere else, or another function name in snapshot.lua: refused
    assert "hidden-read" in rule_set(GUARDED, "lua/dfllm/runner.lua")
    assert "hidden-read" in rule_set(GUARDED.replace("revealed_aquifer", "aquifer_of"), "lua/dfllm/snapshot.lua")
    # a read before (or without) the hidden check is refused, hidden tiles stay forbidden
    unguarded = """
        local M = {}
        function M.revealed_aquifer(des)
          return des.water_table == true
        end
        return M
    """
    assert "hidden-read" in rule_set(unguarded, "lua/dfllm/snapshot.lua")
    early = """
        local M = {}
        function M.revealed_aquifer(des)
          local w = des.water_table
          if des.hidden then return nil end
          return w
        end
        return M
    """
    assert "hidden-read" in rule_set(early, "lua/dfllm/snapshot.lua")
    nested = """
        local M = {}
        function M.revealed_aquifer(des)
          if des.hidden then return nil end
          local function f(d) return d.water_table end
          return f(des)
        end
        return M
    """
    assert "hidden-read" in rule_set(nested, "lua/dfllm/snapshot.lua")
    assert "hidden-read" in rule_set("local function f(d) return d.isTileAquifer end", "lua/dfllm/snapshot.lua")


def test_kernel_lint_and_the_one_reader():
    found = lint.lua([ROOT / "lua" / "dfllm"])
    assert [f for f in found if f["rule"] == "hidden-read"] == []
    hits = [p.name for p in (ROOT / "lua" / "dfllm").rglob("*.lua")
            if "water_table" in re.sub(r"--[^\n]*", "", p.read_text("utf-8"))]
    assert hits == ["snapshot.lua"]


def test_aq_event_contracts():
    want = {"AQ_OBSERVE": "B", "AQ_LEVEL_SEALED": "B", "AQ_SEEP": "B", "AQ_PASS_DONE": "B", "AQ_HEAVY": "A"}
    lua = (ROOT / "lua" / "dfllm" / "util" / "contract.lua").read_text("utf-8")
    for t, cls in want.items():
        assert schema.EVENTS[t][0] == cls and schema.EVENTS[t][1] == "runner"
        assert re.search(rf"{t} = {{cls = '{cls}', by = 'runner'}}", lua), t
    e = {"n": 1, "tick": 10, "type": "AQ_HEAVY", "cls": "A", "msg": "aq1: heavy aquifer at z99",
         "d": {"proj": "aq1", "z": 99, "flow": 7, "why": "flow", "pos": [50, 50, 99], "plug": "pl10"}}
    assert schema.validate("event", e) == []
    assert len(json.dumps(e["d"])) < 200
    ok = {"n": 2, "tick": 11, "type": "AQ_PASS_DONE", "cls": "B", "msg": "x", "d": {"proj": "aq1", "top": 100, "bot": 97,
                                                                                     "lv": [99], "n": 1}}
    assert schema.validate("event", ok) == []
    rules = (ROOT / "RULES.md").read_text("utf-8")
    assert re.search(r"^\| [^|]*AQ_HEAVY[^|]* \|", rules, re.M), "a class A event needs its RULES section 7 row"


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def _check(doc, state):
    return plan.check(doc, state, decisions={}, banned=plan.BANNED)


def test_plan_check_a_damp_park_suggests_observe_and_aqshaft(save):
    doc = json.loads((save / "plan.json").read_text("utf-8"))
    state = copy.deepcopy(files.read_state(save))
    state["proj"] = [["fc1", "s1.dig", 12, "parked: breach:damp"], ["aq1", "l3.dig", 50, ""]]
    _, warn = _check(doc, state)
    damp = [w for w in warn if "fc1" in w]
    assert len(damp) == 1 and "observe" in damp[0] and '"tpl":"aqshaft"' in damp[0], warn
    assert not any("aq1" in w for w in warn), "a sealing shaft is progress, never a blocked project"
    state["proj"] = [["aq1", "l3.dig", 50, "parked: breach:heavy_aquifer"]]
    _, warn = _check(doc, state)
    assert any("aq1" in w and "heavy aquifer" in w and "above" in w for w in warn), warn


def test_plan_check_fortcore_pass_needs_a_shaft(save):
    doc = json.loads((save / "plan.json").read_text("utf-8"))
    state = files.read_state(save)
    doc["seasons"][0]["build"].append({"tpl": "fortcore", "site": "S1", "p": {"stage": 1, "aquifer": "pass"}})
    _, warn = _check(doc, state)
    assert any("aquifer pass" in w and "aqshaft" in w for w in warn), warn
    doc["seasons"][0]["build"].insert(0, {"tpl": "aqshaft", "site": "S1", "p": {"x": 40, "y": 40, "top": 120}})
    _, warn = _check(doc, state)
    assert not any("aquifer pass" in w for w in warn), warn


def test_documents_carry_the_decisions():
    dec = (ROOT / "docs" / "v2" / "DECISIONS.md").read_text("utf-8")
    assert "2026-10-28" in dec and "orchestrator" in dec and "FR-95" in dec
    assert "water_table" in dec and "revealed" in dec
    rules = (ROOT / "RULES.md").read_text("utf-8")
    assert "never re-designate" not in rules
    assert len(rules.splitlines()) <= 300
    doctrine = (ROOT / "docs" / "v2" / "DOCTRINE.md").read_text("utf-8")
    assert "never re-designate" not in doctrine and "aqshaft" in doctrine
    fr = (ROOT / "docs" / "feature-requests" / "README.md").read_text("utf-8")
    assert len(re.findall(r"^\*\*FR-95\b", fr, re.M)) == 1, "one FR-95 entry in docs/feature-requests/README.md"
    log = (ROOT / "CHANGELOG.md").read_text("utf-8")
    entry = log[log.index("FR-95"):][:6000]
    for part in ("Why", "What changed", "Live check"):
        assert part in entry


# ---------------------------------------------------------------- merge with BUG-130 (the parked fortcore case)
def test_a_core_resumed_in_observe_mode_is_no_stopped_core_for_the_re_site(tmp_path, monkeypatch):
    """BUG-130 re-sites a fortcore parked at breach:damp; FR-95's boot resumes that core in observe mode (AQ_OBSERVE src
    resume). A core whose newest word is AQ_OBSERVE digs again: no re-site, no second fortcore. A later stop counts."""
    from cli_v2_helpers import append_events, ev
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    save = make_runtime(tmp_path)
    try:
        pid, damp = "y707s0b1", [87, 59, 5]
        doc = json.loads((save / "bp" / "y3s0b0.json").read_text("utf-8"))
        doc.update(id=pid, tpl="fortcore", site="S1", anchor=[48, 30, 130], rot=0, params={"stage": 1},
                   manifest={"v": 2})
        (save / "bp" / f"{pid}.json").write_text(json.dumps(doc), "utf-8")
        files.write_json_atomic(save / "manifest.json", {"v": 2, "breaches": [
            {"pos": damp, "why": "damp", "proj": pid, "tpl": "fortcore"}]})          # a manifest from before the boot
        n0 = max([e["n"] for e in files.iter_events_rev(save)] or [0])
        append_events(save, [ev(n0 + 1, "BREACH_STOP", "stop", {"proj": pid, "why": "damp", "pos": damp}),
                             ev(n0 + 2, "AQ_OBSERVE", "observe", {"proj": pid, "tpl": "fortcore", "src": "resume"})])
        st = copy.deepcopy(files.read_state(save))
        st["proj"] = [[pid, "s1.dig", 0, ""]]
        assert plan.core_breaches(save, st) == []
        append_events(save, [ev(n0 + 3, "BREACH_STOP", "stop", {"proj": pid, "why": "heavy_aquifer", "pos": damp})])
        assert [b["proj"] for b in plan.core_breaches(save, st)] == [pid]
    finally:
        reset_paths()
