"""FR-100/FR-101 (Gordon's goal G18: every soldier armor + weapon, sparring always with wooden training weapons), Python
side: state mil.kit, the status/brief line `gear: N/M soldiers fully equipped`, the plan's military.training (schema,
propose, check), the phase deliverable `kit` (plans/year1.json P6), config/baseline.json military.training with its
lint --config check, and the bone route of the gear orders. The kernel side is tests/lua/test_fr100_kit.lua and
tests/lua/test_fr100_phase.lua."""
import json
from pathlib import Path
from types import SimpleNamespace

from dfpilot import brief, fairplay, plan, schema

ROOT = Path(__file__).resolve().parents[1]
KIT = {"n": 5, "full": 3, "armor": 3, "weapon": 5, "wood": 4, "tr": 2}
MIL = {"squads": 2, "soldiers": 5, "worn": 60, "cv": 8, "metal_pct": 0, "on_station": 0}
STATE = {"v": 2, "seq": 1, "t": {"y": 3, "tick": 10, "season": 0, "tps": 100, "paused": False}, "mode": "PEACE",
         "k": {"ms_s": 1, "gap_max_ms": 1, "slow": [], "faults": 0}, "ev": 1}


def _state(**mil):
    s = json.loads(json.dumps(STATE))
    s["mil"] = dict(MIL, **mil)
    return s


def test_state_mil_kit_validates():
    assert schema.validate("state", _state(kit=KIT)) == []
    assert schema.validate("state", _state(kit={k: v for k, v in KIT.items() if k != "wood"})) != []
    assert schema.validate("state", _state(kit=dict(KIT, full=-1))) != []


def test_status_line_says_how_many_soldiers_are_fully_equipped():
    _, extra = brief.def_parts(SimpleNamespace(s={"mil": dict(MIL, kit=KIT)}))
    assert "gear: 3/5 soldiers fully equipped (armor 3, weapon 5, wood 4)" in extra, extra
    _, extra = brief.def_parts(SimpleNamespace(s={"mil": dict(MIL, kit=dict(KIT, wood=0))}))
    assert "gear: 3/5 soldiers fully equipped (armor 3, weapon 5)" in extra, extra
    _, extra = brief.def_parts(SimpleNamespace(s={"mil": dict(MIL, kit=dict(KIT, n=0, full=0))}))
    assert not [e for e in extra if e.startswith("gear:")], "no soldiers: no line"


def _plan(**mil):
    doc = plan.propose({"t": {"y": 3, "season": 0}, "phase": "P2", "ready": {"lvl": 0}, "pop": {"cit": 40}}, None, None,
                       decisions={"D-01": "B"})
    doc["military"].update(mil)
    return doc


def test_plan_military_training_schema_propose_and_check():
    doc = _plan()
    assert doc["military"]["training"] is True, "propose drafts the default"
    assert schema.validate("plan", doc) == []
    assert schema.validate("plan", _plan(training="yes")) != []
    assert schema.PLAN_DEFAULTS["military"]["training"] is True
    prev = _plan(training=False)
    again = plan.propose({"t": {"y": 3, "season": 0}, "phase": "P2", "ready": {"lvl": 0}, "pop": {"cit": 40}}, None, prev,
                         decisions={"D-01": "B"})
    assert again["military"]["training"] is False, "a player's false is kept"
    doc = _plan(training=False)
    doc["phase_target"] = "P2"
    _, warn = plan.check(doc, {"t": {"y": 3}}, decisions={"D-01": "B"}, banned=[])
    assert any("military.training false" in w for w in warn), warn
    doc = _plan()
    _, warn = plan.check(doc, {"t": {"y": 3}}, decisions={"D-01": "B"}, banned=[])
    assert not any("military.training" in w for w in warn), warn


def test_plan_check_names_the_soldiers_short_of_kit_from_p5():
    doc = _plan()
    doc["phase_target"] = "P5"
    _, warn = plan.check(doc, {"t": {"y": 3}, "mil": dict(MIL, kit=KIT)}, decisions={"D-01": "B"}, banned=[])
    assert any(w.startswith("gear: 3/5 soldiers fully equipped") for w in warn), warn
    _, warn = plan.check(doc, {"t": {"y": 3}, "mil": dict(MIL, kit=dict(KIT, full=5))}, decisions={"D-01": "B"}, banned=[])
    assert not any(w.startswith("gear:") for w in warn), warn
    doc["phase_target"] = "P2"
    _, warn = plan.check(doc, {"t": {"y": 3}, "mil": dict(MIL, kit=KIT)}, decisions={"D-01": "B"}, banned=[])
    assert not any(w.startswith("gear:") for w in warn), "before P5 the gear is still coming"


def test_phase_deliverable_kit_in_year1_p6():
    doc = json.loads((ROOT / "plans" / "year1.json").read_text("utf-8"))
    assert schema.validate("phases", doc) == []
    p6 = next(p for p in doc["phases"] if p["id"] == "P6")
    assert {"k": "kit", "pct": 80} in p6["deliver"]
    bad = {"v": 2, "kind": "phases", "phases": [{"id": "P0", "title": "x", "approve": False, "deliver": [{"k": "kit"}]}]}
    assert any("kit" in e for e in schema.validate("phases", bad))
    runner = (ROOT / "lua" / "dfllm" / "runner.lua").read_text("utf-8")
    assert "kit = function(K, dv)" in runner and "kit = 'military'" in runner


def test_config_military_training_and_lint(tmp_path):
    doc = json.loads(fairplay.BASELINE_PATH.read_text("utf-8"))
    assert doc["military"]["training"] == {"on": True, "fallback": "SPEAR", "refit_days": 7}
    assert fairplay.military_errors() == []
    p = tmp_path / "baseline.json"
    p.write_text(json.dumps({"v": 2, "military": {"training": {"on": "yes", "fallback": "MACE", "refit_days": 99,
                                                               "x": 1}}}), encoding="utf-8")
    errs = fairplay.military_errors(p)
    for needle in ("training.on: true or false", "training.fallback: one of AXE, SWORD, SPEAR, none",
                   "training.refit_days: int 0..56", "training.x: unknown key"):
        assert any(needle in e for e in errs), (needle, errs)
    p.write_text(json.dumps({"v": 2, "military": {"training": []}}), encoding="utf-8")
    assert fairplay.military_errors(p) == ["config/baseline.json: military.training must be an object"]
    lua = (ROOT / "lua" / "dfllm" / "kit.lua").read_text("utf-8")
    assert "KIT.DEF = {on = true, fallback = 'SPEAR', refit_days = 7}" in lua           # Python and Lua agree
    assert "KIT.REFIT_LIM = {0, 56}" in lua


def test_gear_orders_have_a_bone_route_for_helm_gauntlets_greaves():
    items = {it["cat"]: it for it in json.loads(fairplay.BASELINE_PATH.read_text("utf-8"))["economy"]["gear"]["items"]}
    for cat, job, sub in (("head", "MakeHelm", "ITEM_HELM_HELM"), ("gloves", "MakeGloves", "ITEM_GLOVES_GAUNTLETS"),
                          ("pants", "MakePants", "ITEM_PANTS_GREAVES")):
        assert items[cat]["bone"] == {"job": job, "sub": sub, "ws": ["workshop:Craftsdwarfs"]}, cat
    eco = (ROOT / "lua" / "dfllm" / "economy.lua").read_text("utf-8")
    assert "bone = {job = 'MakeHelm', sub = 'ITEM_HELM_HELM', ws = {'workshop:Craftsdwarfs'}}" in eco
