"""Package M1 (care; BUG-103 .. BUG-106): the contract side of the Lua changes (tests/lua/test_*_m1.lua are the behaviour).
- state: care.corpses_unreach and water.gaps validate (and only as specified);
- events: GHOSTS unreach, PATIENT_DYING stuck / reach / key; inspect what=hospital;
- config: water.give_stuck_days is in the file, in water.lua and validated;
- the brief carries `(+N unreachable)` and the hospital gaps, and a maximal state still fits both budgets."""
import json
import re
from pathlib import Path

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import brief, fairplay, files, schema, wake
from dfpilot.events import est_tokens

ROOT = Path(__file__).resolve().parent.parent


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def put_state(save, **extra):
    st = files.read_state(save)
    st.update(extra)
    st["seq"] = st["seq"] + 10
    files.write_json_atomic(save / "state.a.json", st)
    files.write_json_atomic(save / "state.b.json", dict(st, seq=st["seq"] - 1))
    return st


CARE = {"stressed_pct": 30, "naked": 1, "ghosts": 0, "corpses_old": 0, "tombs_free": 3, "moods": 0}
WATER = {"patients": 2, "thirst_max": 40000, "hosp_ok": 1, "refuge_ok": 1, "buckets_free": 3, "hosp": 1,
         "src": [[137, 77, 143]]}


def test_state_carries_the_unreachable_bodies_and_the_hospital_gaps():
    st = {"v": 2, "care": dict(CARE, corpses_unreach=5), "water": dict(WATER, gaps=["no_table", "no_suture"])}
    base = {"v": 2}
    for k, v in st.items():
        if k == "v":
            continue
        assert [e for e in schema.validate("state", dict(base, **{k: v})) if f"$.{k}" in e] == [], k
    bad = schema.validate("state", {"v": 2, "care": dict(CARE, corpses_unreach=-1),
                                    "water": dict(WATER, gaps=["x" * 17])})
    assert any("corpses_unreach" in e for e in bad) and any("gaps" in e for e in bad), bad
    too_many = schema.validate("state", {"v": 2, "water": dict(WATER, gaps=["no_table"] * 9)})
    assert any("gaps" in e for e in too_many), too_many


def test_events_and_the_inspect_topic_are_in_the_schema():
    ghosts = {"n": 4, "tick": 5, "type": "GHOSTS", "cls": "A", "msg": "g",
              "d": {"ghosts": 0, "corpses": 5, "old": 0, "units": [], "causes": ["6119:corpse_unreachable"], "far": 1,
                    "unreach": 1}}
    assert schema.validate("event", ghosts) == []
    assert any("unreach" in e for e in schema.validate("event", dict(ghosts, d=dict(ghosts["d"], unreach="one"))))
    dying = {"n": 5, "tick": 5, "type": "PATIENT_DYING", "cls": "A", "msg": "d",
             "d": {"units": [5], "n": 1, "thirst": 61000, "carers": 4, "want": 4, "hosp": "ok", "stuck": 2, "reach": 0,
                   "key": "stuck"}}
    assert schema.validate("event", dying) == []
    assert any("stuck" in e for e in schema.validate("event", dict(dying, d=dict(dying["d"], stuck="two"))))
    assert any("key" in e for e in schema.validate("event", dict(dying, d=dict(dying["d"], key=3))))
    assert schema.validate_args("inspect", {"what": "hospital"}) == []
    assert schema.validate_args("inspect", {"what": "hospitals"}) != []


def test_give_stuck_days_is_in_the_file_in_water_lua_and_validated(tmp_path):
    cfg = json.loads((ROOT / "config" / "baseline.json").read_text(encoding="utf-8"))["water"]
    assert cfg["give_stuck_days"] == 2
    src = (ROOT / "lua" / "dfllm" / "water.lua").read_text(encoding="utf-8")
    assert re.search(r"give_stuck_days = 2", src)
    assert fairplay.water_errors() == []
    p = tmp_path / "baseline.json"
    p.write_text(json.dumps({"v": 2, "water": {"give_stuck_days": 0}}), encoding="utf-8")
    assert any("water.give_stuck_days" in e for e in fairplay.water_errors(p))


def test_contract_docs_name_the_new_fields():
    text = (ROOT / "docs" / "v2" / "CONTRACTS.md").read_text(encoding="utf-8")
    for needle in ("corpses_unreach", "unreach (BUG-105", "hospital: 6 gaps", "give_stuck_days", "gaps?:[str",
                   "corpse_unreachable"):
        assert needle in text, needle
    rules = (ROOT / "RULES.md").read_text(encoding="utf-8")
    assert len(rules.splitlines()) <= 300
    assert "what=hospital" in rules and "corpse_unreachable" in rules


def test_the_brief_says_unreachable_and_the_hospital_gaps(save):
    put_state(save, care=dict(CARE, corpses_unreach=5), water=dict(WATER, gaps=["no_table", "no_suture", "no_thread"]))
    line = brief.line_supply(brief.Ctx(save, full=False))
    assert "corpses 0 (+5 unreachable)" in line, line
    assert "hospital gaps: no_table, no_suture, no_thread" in line and "\"what\":\"hospital\"" in line, line
    put_state(save, care=dict(CARE), water=dict(WATER))
    plain = brief.line_supply(brief.Ctx(save, full=False))
    assert "unreachable" not in plain and "hospital gaps" not in plain, plain


def test_a_worst_case_with_eight_gaps_still_fits_status_and_brief(save):
    from test_i1_state import maximal
    st = maximal()
    st["care"] = dict(st["care"], corpses_unreach=5)
    st["water"] = dict(st["water"], gaps=["no_table", "no_traction", "no_suture", "no_dress", "no_thread", "no_cloth",
                                          "no_splints", "no_crutches"])
    assert [e for e in schema.validate("state", dict(st, v=2)) if "gaps" in e or "unreach" in e] == []
    put_state(save, **st)
    assert est_tokens(brief.status_text(save)) <= brief.STATUS_TOKENS
    assert est_tokens(brief.brief_text(save)) <= brief.BRIEF_TOKENS


def test_the_wake_hint_of_a_dying_patient_names_the_hospital_audit():
    hint = wake.next_hint("PATIENT_DYING", {"d": {}})
    assert "\"what\":\"hospital\"" in hint and "water_sources" in hint, hint
