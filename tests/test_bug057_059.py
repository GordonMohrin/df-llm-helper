"""BUG-057/058/059 and FR-72 (Run 12-14, Wheelsblows and Kilrudrabed). Python side: the status line names the hungry
citizens first and says that "food N d" counts raw food when no meal stands (note 37: 12 starved under "food 41 d"),
the stuck orders tell a missing workshop (named) from a missing worker (note 62: "no Farmers" was a missing Farmer's
Workshop), the new state fields and the ORDER_STUCK kind are schema-valid, the new economy knobs are validated, and
`disable autofarm` is allowlisted while the other disables stay as they were."""
import json
from pathlib import Path

import pytest
from cli_v2_helpers import ev, make_runtime, reset_paths

from dfpilot import brief, fairplay, schema
from dfpilot.events import est_tokens

ROOT = Path(__file__).resolve().parent.parent


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def put_state(save, **parts):
    for slot in "ab":
        p = save / f"state.{slot}.json"
        doc = json.loads(p.read_text("utf-8"))
        for k, v in parts.items():
            doc[k] = dict(doc.get(k) or {}, **v)
        assert schema.validate("state", doc) == [], schema.validate("state", doc)
        p.write_text(json.dumps(doc), encoding="utf-8")


def stock_line(out: str) -> str:
    return next(ln for ln in out.splitlines() if "stock " in ln)


def test_status_names_the_hungry_first_and_says_raw_food_is_not_cooked(save):
    """Note 37 (Run 12 y503): `food 41d meals 0` and 12 dwarves dead of hunger. The hungry count leads the stock line;
    with no meal at all it adds that the food days count raw food."""
    put_state(save, stock={"drink_d": 300, "food_d": 41, "meals": 0, "hungry": 12})
    line = stock_line(brief.status_text(save))
    assert "stock HUNGRY 12 drink 300d food 41d! meals 0 (raw food is not cooked)" in line, line
    put_state(save, stock={"meals": 3})
    line = stock_line(brief.status_text(save))
    assert "HUNGRY 12" in line and "raw food is not cooked" not in line, line
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    st["stock"].pop("hungry")
    st["stock"]["meals"] = 0
    (save / "state.b.json").write_text(json.dumps(st), encoding="utf-8")
    (save / "state.a.json").write_text(json.dumps(st), encoding="utf-8")
    line = stock_line(brief.status_text(save))
    assert "HUNGRY" not in line and "raw food" not in line, line


def test_status_separates_a_missing_workshop_from_a_missing_worker(save):
    """Note 62 (Run 14 y577): ORDER_STUCK said `no Farmers` for ProcessPlants; no Farmer's Workshop stood. The orders
    line names the missing workshops and counts the orders that miss a worker apart."""
    put_state(save, orders={"n": 40, "bad": 0, "stuck": 6, "stuck_ws": 4, "ws": "Farmer's Workshop x4",
                            "stuck_lab": 2})
    out = brief.status_text(save)
    assert "orders 40 stuck 6 (workshop missing 4: Farmer's Workshop x4; no worker 2)" in out, out
    put_state(save, orders={"stuck": 2, "stuck_lab": 2})
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    st["orders"].pop("stuck_ws"), st["orders"].pop("ws")
    for slot in "ab":
        (save / f"state.{slot}.json").write_text(json.dumps(st), encoding="utf-8")
    assert "orders 40 stuck 2 (no worker 2)" in brief.status_text(save)


def test_status_worst_case_with_the_new_fields(save):
    put_state(save, stock={"drink_d": 1, "food_d": 1, "meals": 0, "hungry": 999999, "dwhy": "d" * 80},
              orders={"n": 999, "bad": 99, "stuck": 99, "unval": 999, "uval_d": 999, "mgr": "m" * 80,
                      "stuck_ws": 99, "ws": "w" * 60, "stuck_lab": 99})
    assert est_tokens(brief.status_text(save)) <= brief.STATUS_TOKENS


def test_schema_accepts_the_new_fields_and_refuses_bad_ones(save):
    put_state(save, stock={"hungry": 3}, orders={"n": 1, "bad": 0, "stuck": 1, "stuck_ws": 1, "stuck_lab": 0,
                                                 "ws": "Farmer's Workshop x1"})
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    st["stock"]["hungry"] = -1
    st["orders"]["ws"] = "w" * 61
    errs = schema.validate("state", st)
    assert any("hungry" in e for e in errs) and any("ws" in e for e in errs), errs
    e = ev(1, "ORDER_STUCK", "order 3 ProcessPlants cannot run for 4 days: no Farmer's Workshop",
           {"order": 3, "job": "ProcessPlants", "why": "no Farmer's Workshop", "days": 4, "dropped": 0, "kind": "workshop"})
    assert schema.validate("event", e) == []
    e["d"]["kind"] = 5
    assert schema.validate("event", e) != []
    assert schema.ACT["plant_ungather"] == ["economy"]
    assert schema.STATE_OWNERS["stock.hungry"] == "economy"


def test_economy_knobs_of_the_cover_and_the_farms_are_validated(tmp_path):
    assert fairplay.economy_errors() == []
    doc = json.loads((ROOT / "config" / "baseline.json").read_text("utf-8"))
    doc["economy"]["cover"].update({"share": 0, "step": 99, "bogus": 1, "on": "yes",
                                    "labors": {"GatherPlants": "herbalist"}})
    doc["economy"]["farms"].update({"autofarm": "maybe", "now_max": 0})
    p = tmp_path / "baseline.json"
    p.write_text(json.dumps(doc), encoding="utf-8")
    errs = fairplay.economy_errors(p)
    assert "config/baseline.json: economy.cover.share: int 5..100 expected, got 0" in errs
    assert "config/baseline.json: economy.cover.step: int 1..20 expected, got 99" in errs
    assert "config/baseline.json: economy.cover.bogus: unknown key" in errs
    assert "config/baseline.json: economy.cover.on: true or false expected, got 'yes'" in errs
    assert any(e.startswith("config/baseline.json: economy.cover.labors: an object of job type -> LABOR names") for e in errs)
    assert "config/baseline.json: economy.farms.autofarm: one of ['auto', 'off', 'keep'] expected, got 'maybe'" in errs
    assert "config/baseline.json: economy.farms.now_max: int 1..200 expected, got 0" in errs


def test_disable_autofarm_is_allowlisted_the_others_stay_as_they_were():
    assert fairplay.check_run("disable", ["autofarm"]) == (True, "ok")
    assert fairplay.check_run("disable", ["work-now"]) == (True, "ok")
    ok, why = fairplay.check_run("disable", ["fastdwarf"])
    assert not ok, why
