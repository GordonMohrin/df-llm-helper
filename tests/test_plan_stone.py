"""Run 11 (Kilrudrabed site98 y432: 1 boulder, ~110 orders 'no rock', 2 picks, 1 iron bar, idle 46-64 %): stone and picks
as plan goals. `plan propose` drafts a bedrooms dig (boulders) while economy's free stone is below what the rock orders
and walls want and no dig is under way, and puts pick first in trade.want while the fort has fewer picks than the Miners
want and no bar; `plan check` warns without them. follow places economy's PROJECT_REQUEST bedrooms why=rock."""
import copy
import json

import pytest
from cli_v2_helpers import FIX, append_events, ev, make_runtime, reset_paths

from dfpilot import files, plan, schema

TPLS = ("tombs", "temple", "dining", "workshops", "fortcore", "explore", "bedrooms", "hospital", "tavern", "stockroom")
DIG = {"tpl": "bedrooms", "site": "S1", "p": {"n": 4}}


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))       # no decisions.yaml: defaults
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


@pytest.fixture
def base(save):
    return json.loads((save / "plan.json").read_text("utf-8")), files.read_state(save)


def stocked(state, **stock):
    """The fixture state with economy's Run 11 stock keys (Kilrudrabed: 1 free boulder, 111 wanted, 2 picks of 3)."""
    s = copy.deepcopy(state)
    s["stock"].update({"ore": 0, "bars": 1, "rock": 1, "rock_need": 111, "picks": 2, "pick_want": 3, **stock})
    assert schema.validate("state", s) == []
    return s


def check(doc, state, **kw):
    return plan.check(doc, state, decisions={}, banned=plan.BANNED, **kw)


def test_goals_read_economys_state(base):
    _, state = base
    assert plan.rock_goal(state) is None and plan.pick_goal(state) is None      # an older kernel: not checked
    s = stocked(state)
    assert plan.rock_goal(s) == "rock: 1 free boulders < 111 wanted (rock orders, walls)"
    assert plan.pick_goal(s) is None                                            # 1 bar: economy forges a pick
    assert plan.pick_goal(stocked(state, bars=0)) == "picks: 2 < 3 for the Miners and no bars"
    assert plan.rock_goal(stocked(state, rock=200)) is None
    assert plan.pick_goal(stocked(state, bars=0, picks=3)) is None
    bad = stocked(state)
    bad["stock"]["rock_need"] = -1
    assert schema.validate("state", bad) != []


def test_propose_drafts_a_stone_dig_and_picks(base):
    prev, state = base
    phases = json.loads((FIX / "phases.json").read_text("utf-8"))
    tinfo = {t: {"params": {}, "about": ""} for t in TPLS}
    s = stocked(state, bars=0)
    doc = plan.propose(s, phases, prev, decisions={}, tinfo=tinfo, fort={"stone_dig": False})
    assert schema.validate("plan", doc) == []
    cur = doc["seasons"][1]["build"]
    assert cur[:len(prev["seasons"][1]["build"]) + 1] == prev["seasons"][1]["build"] + [DIG], cur
    assert sum(b == DIG for se in doc["seasons"] for b in se["build"]) == 1
    assert doc["trade"]["want"][:2] == ["pick", "bar:iron"]
    assert "rock: 1 free boulders < 111 wanted (rock orders, walls): bedrooms@S1 n=4 first" in doc["notes"]
    errs, warn = check(doc, s, tpls=list(TPLS), fort={"stone_dig": False})
    assert errs == [] and not [w for w in warn if w.startswith(("rock", "picks"))], warn
    # a dig under way (a bedrooms project not done): no second one; enough stone: none
    for st, fort in ((s, {"stone_dig": True}), (stocked(state, rock=500, bars=0), {"stone_dig": False})):
        d = plan.propose(st, phases, prev, decisions={}, tinfo=tinfo, fort=fort)
        assert not any(b == DIG for se in d["seasons"] for b in se["build"])
    # an older kernel: nothing new
    d = plan.propose(state, phases, prev, decisions={}, tinfo=tinfo, fort={"stone_dig": False})
    assert not any(b == DIG for se in d["seasons"] for b in se["build"]) and "pick" not in d["trade"]["want"]


def test_check_warns_without_a_stone_dig_or_picks(base):
    doc, state = base
    s = stocked(state, bars=0)
    d = copy.deepcopy(doc)
    d["seasons"][1]["build"] = []                                       # the fixture's bedrooms gone
    d["seasons"][2]["build"] = []
    errs, warn = check(d, s, fort={"stone_dig": False})
    assert errs == []
    assert [w for w in warn if w.startswith("rock")] == [
        'rock: 1 free boulders < 111 wanted (rock orders, walls): add {"tpl":"bedrooms","site":"S1","p":{"n":4}} to '
        "the current season (a stone dig; economy orders doors and furniture in wood meanwhile)"]
    assert [w for w in warn if w.startswith("picks")] == [
        "picks: 2 < 3 for the Miners and no bars: put pick first in trade.want (and bar:iron for a forge)"]
    assert not [w for w in check(d, s, fort={"stone_dig": True})[1] if w.startswith("rock")]
    assert not [w for w in check(doc, s, fort={"stone_dig": False})[1] if w.startswith("rock")], "bedrooms planned"


def test_fort_facts_stone_dig(save, base):
    _, state = base
    for p in (save / "bp").glob("*.json"):
        p.unlink()
    assert plan.stone_digs(save) is False
    files.write_json_atomic(save / "bp" / "rk1.json", {"v": 2, "id": "rk1", "tpl": "bedrooms", "site": "S1"})
    assert plan.stone_digs(save) is True
    assert plan.fort_facts(save, state)["stone_dig"] is True
    append_events(save, [ev(99999, "PROJECT_DONE", "rk1 (bedrooms) done", {"proj": "rk1", "tpl": "bedrooms"})])
    assert plan.stone_digs(save) is False
