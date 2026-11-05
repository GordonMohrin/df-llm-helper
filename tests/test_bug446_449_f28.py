"""Round 28 (fix28-water), Python side: BUG-448 an aquifer cistern answers the cistern request like a piped one (propose and follow do
not place or draft another); BUG-447 is in tests/bp/test_bug447_refuge_aquifer.py, BUG-446/448/449 in tests/lua/test_bug446_449_water.lua."""
import json
import sys

from cli_v2_helpers import append_events, ev, inbox_docs, install_fake_bp
from test_cli_wake import Clock, F, save  # noqa: F401  (fixtures)

from dfpilot import files, plan
from test_bug418_419_requests_wet_core import DAY, T0, _req, _state, world  # noqa: F401  (the world fixture)
from test_bug423_425_access import PARAMS, fake_access

AQ = {"water": "aquifer"}


def test_request_facts_an_aquifer_cistern_answers_the_request(world, monkeypatch):
    save, _ = world
    n0 = files.last_event_n(save) + 100
    monkeypatch.setattr(plan, "water_access", lambda d, at: {"site": "A1_2_3_0", "params": PARAMS, "unsafe": False, "rock": 1, "why": "w"})
    append_events(save, [_req(n0, "cistern", {"why": "patient_water", "n": 80, "at": [164, 170, 137]}, T0 - 2 * DAY)])
    assert plan.request_facts(save, _state(save))[0]["tpl"] == "cistern"
    (save / "bp").mkdir(exist_ok=True)
    (save / "bp" / "y1s0b0.json").write_text(json.dumps({"tpl": "cistern", "anchor": [1, 2, 3], "rot": 0, "params": {}}))
    assert plan.request_facts(save, _state(save))[0]["tpl"] == "cistern", "a bucket-fed cistern still does not answer it"
    (save / "bp" / "y1s0b0.json").write_text(json.dumps({"tpl": "cistern", "anchor": [1, 2, 3], "rot": 0, "params": AQ}))
    assert plan.request_facts(save, _state(save)) == [], "old code: the aquifer cistern (no pipe) was not seen, propose drafted another"
    # a finished one (PROJECT_DONE y1s0b0) answers it as well
    append_events(save, [ev(n0 + 5, "PROJECT_DONE", "y1s0b0 (cistern) done", {"proj": "y1s0b0", "tpl": "cistern"})])
    assert plan.request_facts(save, _state(save)) == []


def test_follow_places_no_second_cistern_beside_an_aquifer_one(save, monkeypatch):
    install_fake_bp(monkeypatch)
    sys.modules["dfpilot.bp.sites"].cistern_access = fake_access()
    files.write_json_atomic(save / "bp" / "y1s0b0.json", {"tpl": "cistern", "params": AQ})
    f, out = F(Clock())
    f.poll()
    append_events(save, [ev(8813, "PROJECT_REQUEST", "cistern", {"tpl": "cistern", "why": "patient_water", "n": 80, "at": [1, 2, 3]})])
    f.poll()
    assert inbox_docs(save) == []
