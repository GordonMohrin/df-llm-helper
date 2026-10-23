"""Package A4 (Run 11-14 notes 11, 18, 24, 25, 61, 64, 65): patients dying of thirst (BUG-054), vacant offices and the
appoint/squad verbs (BUG-055), abandoned hospital locations (BUG-056), the civzone build verb (FR-78). Python side:
the contracts (events, verbs, config keys), the status texts and the blueprint text; the Lua side is tests/lua."""
import json
import re
from pathlib import Path

import pytest
from cli_v2_helpers import make_runtime, reset_paths
from test_cli_status import _r0_state

from dfpilot import brief, fairplay, files, schema, wake

ROOT = Path(__file__).resolve().parent.parent


# ---------------------------------------------------------------- BUG-054
def test_patient_dying_is_a_class_a_event_with_the_caregivers_state():
    assert schema.EVENTS["PATIENT_DYING"][:2] == ("A", "water")
    e = {"n": 9, "tick": 5, "type": "PATIENT_DYING", "cls": "A",
         "msg": "5 patient(s) near death of thirst (>= 60000), unit 28970 at 75000: hospital ok, caregivers 4 of 7 wanted "
                "(0 idle), 0 giving water; caregivers short",
         "d": {"units": [28970, 29039], "n": 5, "thirst": 75000, "carers": 4, "want": 7, "hosp": "ok", "idle": 0,
               "added": 2, "give": 0, "open": -1, "run": -1, "buckets": 24, "why": "caregivers short: 4 of 7 wanted"}}
    assert schema.validate("event", e) == []
    assert schema.validate("event", dict(e, cls="B")) != []
    assert any("carers: missing" in x for x in schema.validate("event", dict(e, d={"units": [1], "n": 1})))
    assert any("hosp" in x for x in schema.validate("event", dict(e, d=dict(e["d"], hosp=3))))
    assert schema.ACT["work_detail"] == ["economy", "water"]


def test_rules_names_patient_dying_and_stays_within_300_lines():
    text = (ROOT / "RULES.md").read_text(encoding="utf-8")
    assert len(text.splitlines()) <= 300
    assert "PATIENT_DYING" in text.split("## 7.")[1].split("## 8.")[0]


def test_carer_config_is_validated():
    keys = ("carers_per_patient", "carers_min", "carers_max", "carers_urgent", "carers_per_run", "carers_hold_days",
            "dying_thirst", "dying_every")
    assert set(keys) <= set(fairplay.WATER_LIM)
    cfg = json.loads((ROOT / "config" / "baseline.json").read_text(encoding="utf-8"))["water"]
    assert cfg["carers_max"] == 8 and cfg["dying_thirst"] == 60000
    assert cfg["dying_thirst"] > cfg["patient_thirst"]


def test_carer_config_errors_name_the_key(tmp_path):
    p = tmp_path / "baseline.json"
    p.write_text(json.dumps({"v": 2, "water": {"carers_max": 99, "carers_per_patient": "many", "dying_thirst": 80000}}),
                 encoding="utf-8")
    errs = fairplay.water_errors(p)
    assert any("water.carers_max" in e for e in errs)
    assert any("water.carers_per_patient" in e for e in errs)
    assert any("water.dying_thirst" in e for e in errs)


# ---------------------------------------------------------------- BUG-055
@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


@pytest.mark.parametrize("verb,args,ok", [
    ("appoint", {"code": "CHIEF_MEDICAL_DWARF", "unit": 28970}, True),
    ("appoint", {"code": "chief", "unit": 1}, False),
    ("appoint", {"code": "MANAGER"}, False),
    ("appoint", {"code": "MANAGER", "unit": -1}, False),
    ("squad.create", {"name": "A", "leader": 12}, True),
    ("squad.create", {"name": "Third squad", "assignment": 8}, True),
    ("squad.create", {}, False),
    ("squad.create", {"name": "x" * 31}, False),
    ("squad.leader", {"squad": "B", "unit": 5}, True),
    ("squad.leader", {"squad": 143, "unit": 5}, True),
    ("squad.leader", {"squad": "D", "unit": 5}, False),
    ("squad.add", {"squad": 143, "unit": 9}, True),
    ("squad.add", {"squad": 143}, False),
    ("squad.uniform", {"squad": "C", "kind": "xbow"}, True),
    ("squad.uniform", {"squad": "C"}, True),
    ("squad.uniform", {"squad": 143}, False),
    ("squad.uniform", {"squad": "C", "kind": "pike"}, False),
])
def test_office_and_squad_verb_args(verb, args, ok):
    doc = {"id": "c1", "verb": verb, "args": args, "by": schema.VERB_BY.get(verb, ["llm"])[0]}
    assert (schema.validate("inbox", doc) == []) is ok, schema.validate("inbox", doc)


def test_office_and_squad_verbs_are_registered_outside_fights_only():
    assert schema.VERBS["appoint"] == ("economy", None, False)
    for v in ("squad.create", "squad.leader", "squad.add", "squad.uniform"):
        assert schema.VERBS[v] == ("military", ["PEACE", "ALERT", "RECOVERY"], False), v
    text = (ROOT / "RULES.md").read_text(encoding="utf-8")
    for v in ("appoint", "squad.create", "squad.leader", "squad.add", "squad.uniform"):
        assert f"`{v}`" in text, v
    assert "what=offices" in text and "offices" in schema.VERB_ARGS["inspect"].req["what"].enum


def test_offices_config_is_validated(tmp_path):
    cfg = json.loads((ROOT / "config" / "baseline.json").read_text(encoding="utf-8"))
    assert cfg["offices"] == {"blocker_days": 7}
    assert fairplay.offices_errors() == []
    p = tmp_path / "baseline.json"
    p.write_text(json.dumps({"v": 2, "offices": {"blocker_days": 500, "days": 3}}), encoding="utf-8")
    assert fairplay.offices_errors(p) == ["config/baseline.json: offices.blocker_days: int 0..400 expected, got 500",
                                          "config/baseline.json: offices.days: unknown key"]
    p.write_text(json.dumps({"v": 2, "offices": "7"}), encoding="utf-8")
    assert fairplay.offices_errors(p) == ["config/baseline.json: offices must be an object"]


def test_siege_unready_event_and_state_carry_the_office():
    e = {"n": 5, "tick": 9, "type": "SIEGE_UNREADY", "cls": "A", "msg": "siege unready (R0: office)",
         "d": {"fails": ["office"], "office": 'CHIEF_MEDICAL_DWARF vacant 9 days (ACTIVE): dfllm cmd appoint {"code":"X"}'}}
    assert schema.validate("event", e) == []
    assert schema.validate("event", dict(e, d={"fails": ["office"], "office": 5})) != []


def test_status_names_the_vacant_office_and_its_fix(save):
    office = 'CHIEF_MEDICAL_DWARF vacant 9 days (ACTIVE): dfllm cmd appoint {"code":"CHIEF_MEDICAL_DWARF","unit":7}'
    _r0_state(save, open=0, ents=None, fail=["office"], audit={"ok": 1, "age": 9000, "min_traps": 35}, office=office)
    line = brief.status_text(save).splitlines()[1]
    assert line.startswith("SIEGE UNREADY (R0): office") and f"next: {office}" in line, line
    _r0_state(save, open=0, ents=None, fail=["office"], audit={"ok": 1, "age": 9000, "min_traps": 35})
    assert "a vacant office or squads without a leader: dfllm cmd inspect what=offices" in \
        brief.status_text(save).splitlines()[1]


def test_wake_hint_for_a_siege_unready_office():
    hint = wake.next_hint("SIEGE_UNREADY", {"d": {"fails": ["office"]}})
    assert "appoint" in hint and "squad.create" in hint and "offices" in hint
    assert wake.next_hint("SIEGE_UNREADY", {"d": {"fails": ["audit"]}}) != hint
