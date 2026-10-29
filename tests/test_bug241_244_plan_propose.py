"""Run 15 `plan propose` (Earthboat, Inkintense, Drillchamber).
BUG-241: explore@S1 drafted in all four seasons while one or two explore sites were free (check: 'only 0 free site(s) for
explore ... taken by y375s0b0'); the explore went ahead of a new seal.
BUG-242: the draft replaced the running `cmd trade.want ... food, seeds` by the old plan's (or the default) list.
BUG-243: drink 0 d and no accepted water, the cistern drafted in seasons[2]; food 10 d and no farm in the draft.
BUG-244: the summary printed 'fortcore@same' without the stage; 'add tpl gallery_o1' while check refused it (stage 2
not dug)."""
import copy
import json
import os
import time

import pytest
from cli_v2_helpers import FIX, make_runtime, reset_paths

from dfpilot import cmd, files, plan, schema

EX = {"tpl": "explore", "site": "S1"}
TPLS = ("tombs", "temple", "dining", "workshops", "fortcore", "explore", "bedrooms", "hospital", "tavern", "cistern",
        "farms", "seal")


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


@pytest.fixture
def base(save):
    return json.loads((save / "plan.json").read_text("utf-8")), files.read_state(save)


def phases():
    return json.loads((FIX / "phases.json").read_text("utf-8"))


def tinfo(*extra):
    return {t: {"params": {}, "about": ""} for t in TPLS + extra}


def noore(state):
    s = copy.deepcopy(state)
    s["stock"].update({"ore": 0, "bars": 8, "metal": "explore"})
    return s


def site(x, y, z=25, rot=1):
    return {"id": "S1", "anchor": [x, y, z], "rot": rot, "score": 900, "why": f"rot{rot}"}


# ---------------------------------------------------------------- BUG-241
def test_explore_room_counts_sites_that_fit_together(tmp_path):
    sv = tmp_path / "save"
    (sv / "bp").mkdir(parents=True)
    # the second site overlaps the first: two shafts fit, not three
    sites = [site(45, 56), site(46, 56), site(90, 90)]
    assert plan.explore_room(sv, sites, {}) == 2
    held = cmd.emit_at("explore", {}, site(90, 90), "S1", "y1s0b0")
    files.write_json_atomic(sv / "bp" / "y1s0b0.json", held)        # an applied project holds the third
    assert plan.explore_room(sv, sites, {}) == 1


def test_fit_explore_drafts_only_as_many_as_free_sites(save, base, monkeypatch):
    prev, state = base
    s = noore(dict(state, t=dict(state["t"], y=4, season=0)))
    monkeypatch.setattr(plan, "rank_sites", lambda *a, **k: ([site(45, 56), site(46, 56)], "c1"))
    doc = plan.propose(s, phases(), prev, decisions={}, tinfo=tinfo())
    assert [b for x in doc["seasons"] for b in x["build"] if b["tpl"] == "explore"] == [EX] * 4
    line = plan.fit_explore(save, doc, prev)
    ex = [si for si, x in enumerate(doc["seasons"]) for b in x["build"] if b["tpl"] == "explore"]
    assert ex == [0], doc["seasons"]
    assert line.endswith("; 1 free site(s): 1 of 4 drafted, the next one: propose next season")
    assert "BUG-241: 1 free explore site(s): 1 of 4 drafted (the next explore: propose next season)" in doc["notes"]
    assert schema.validate("plan", doc) == []
    # every site taken (Earthboat y374: a workshops project on the only one): none drafted, no self-collision
    monkeypatch.setattr(plan, "explore_room", lambda *a, **k: 0)
    doc = plan.propose(s, phases(), prev, decisions={}, tinfo=tinfo())
    plan.fit_explore(save, doc, prev)
    assert not [b for x in doc["seasons"] for b in x["build"] if b["tpl"] == "explore"]


def test_draft_supply_puts_the_explore_after_a_new_seal(base):
    _, state = base
    seal = {"tpl": "seal", "site": "S1", "p": {"at": "last"}}
    doc = {"seasons": [{"build": [copy.deepcopy(seal), {"tpl": "dining", "site": "S1"}]}] + [{"build": []}] * 3,
           "trade": {"want": ["bar:iron"], "sell": []}, "notes": ""}
    doc["seasons"] = [copy.deepcopy(x) for x in doc["seasons"]]
    plan.draft_supply(doc, noore(state), [0, 0, 0, 0], 0, None)
    assert [b["tpl"] for b in doc["seasons"][0]["build"]] == ["seal", "explore", "dining"]


# ---------------------------------------------------------------- BUG-242
def _cli(save, wall, what, args, result):
    with open(save / "cli.log", "a", encoding="utf-8", newline="\n") as f:
        f.write("\t".join([str(wall), "cli", what, json.dumps(args), result]) + "\n")


def test_live_trade_reads_the_cmd_after_the_last_apply(save):
    applied = time.time() - 100
    os.utime(save / "plan.json", (applied, applied))
    (save / "cli.log").unlink(missing_ok=True)
    assert plan.live_trade(save) is None
    _cli(save, int(applied) - 50, "verb:trade.want", {"want": ["gem"]}, "sent c1")          # before the apply: ended
    assert plan.live_trade(save) is None
    _cli(save, int(applied) + 10, "verb:trade.want", {"want": ["food", "seeds", "cloth"]}, "sent c2")
    _cli(save, int(applied) + 11, "reply:trade.want", {"id": "c2"}, "ok want 3, sell 0")
    assert plan.live_trade(save) == {"want": ["food", "seeds", "cloth"]}
    _cli(save, int(applied) + 20, "verb:trade.want", {"sell": ["crafts"]}, "sent c3")       # sell only: want stays
    assert plan.live_trade(save) == {"want": ["food", "seeds", "cloth"], "sell": ["crafts"]}
    _cli(save, int(applied) + 30, "verb:trade.want", {"want": ["bad token!"]}, "sent c4")
    _cli(save, int(applied) + 31, "reply:trade.want", {"id": "c4"}, "ERR want/sell must be token lists")
    assert plan.live_trade(save)["want"] == ["food", "seeds", "cloth"]


def test_propose_keeps_the_running_trade_want(base):
    prev, state = base
    live = {"want": ["food", "seeds", "cloth"]}
    doc = plan.propose(state, phases(), prev, decisions={}, tinfo=tinfo(), live=live)
    assert doc["trade"]["want"] == ["food", "seeds", "cloth"]
    assert doc["trade"]["sell"] == prev["trade"]["sell"]
    assert "BUG-242: trade.want kept from the running cmd trade.want: food,seeds,cloth" in doc["notes"]
    # the metal goal still puts bar:iron in front of the kept list
    doc = plan.propose(noore(state), phases(), prev, decisions={}, tinfo=tinfo(), live=live)
    assert doc["trade"]["want"] == ["bar:iron", "food", "seeds", "cloth"]
    assert plan.propose(state, phases(), prev, decisions={}, tinfo=tinfo())["trade"] == prev["trade"]


# ---------------------------------------------------------------- BUG-243
def _thirsty(state, **stock):
    s = copy.deepcopy(state)
    s["stock"].update({"drink_d": 0, "food_d": 75, **stock})
    s["t"] = dict(s["t"], y=4, season=0)
    return s


def test_emergency_names_why(base):
    _, state = base
    assert plan.emergency(state) is None
    assert plan.emergency(_thirsty(state)) == "drink 0 d"
    s = _thirsty(state, food_d=10)
    s["water"] = {"patients": 0, "thirst_max": 0, "hosp_ok": 0, "refuge_ok": 0, "buckets_free": 0, "hosp": 0, "src": []}
    assert plan.emergency(s) == "drink 0 d, food 10 d, no accepted water"


def test_propose_puts_water_and_food_first_when_drink_is_out(base):
    prev, state = base
    s = _thirsty(state, food_d=10)
    fort = {"food_shops": ["Still", "Kitchen"]}
    doc = plan.propose(s, phases(), prev, decisions={}, tinfo=tinfo(), fort=fort)
    new = [b for x in doc["seasons"] for b in x["build"]]
    # the fixture's new fortcore@S1 (the Z4 floor these rooms open from) stays ahead, then water and food
    assert [b["tpl"] for b in new[:4]] == ["fortcore", "cistern", "farms", "workshops"], doc["seasons"]
    assert [b["tpl"] for b in doc["seasons"][0]["build"]] == ["fortcore", "cistern", "farms"]
    shops = new[3]["p"]
    assert shops["add"] == "Still,Kitchen" and plan.build_kind(new[3]) == "supply"
    assert "BUG-243: drink 0 d, food 10 d (< 30): cistern, farms, workshops@S1 first" in doc["notes"]
    assert schema.validate("plan", doc) == []
    # a seal stays ahead of them
    fort2 = dict(fort, audit={"open": True, "fails": []})
    doc = plan.propose(s, phases(), prev, decisions={}, tinfo=tinfo(), fort=fort2)
    assert [b["tpl"] for b in doc["seasons"][0]["build"][:3]] == ["seal", "fortcore", "cistern"]
    # applied before: not drafted again; no template: not drafted
    doc = plan.propose(s, phases(), prev, decisions={}, tinfo={t: v for t, v in tinfo().items() if t != "cistern"},
                       applied={("farms", None)}, fort={"food_shops": []})
    assert not [b for x in doc["seasons"] for b in x["build"] if b["tpl"] in ("cistern", "farms", "workshops")]
    assert "BUG-243: drink 0 d, food 10 d (< 30): no water or food build left to draft" in doc["notes"]
    # fed and watered: nothing moves
    doc = plan.propose(state, phases(), prev, decisions={}, tinfo=tinfo(), fort=fort)
    assert "BUG-243" not in doc["notes"]


def test_emergency_cistern_moves_ahead_of_the_phase_builds(base):
    """Drillchamber y373: the held-back hospital's cistern came after the phase builds (seasons[2])."""
    prev, state = base
    s = _thirsty(state)
    hold = {"hosp": {"cistern": False, "fill": {"ok": True}}}
    monkey = plan.hospital_water
    try:
        plan.hospital_water = lambda *a, **k: {"ok": False, "why": "no accepted water in the fort"}
        doc = plan.propose(s, phases(), prev, decisions={}, tinfo=tinfo(), fort=hold)
    finally:
        plan.hospital_water = monkey
    builds = [b["tpl"] for b in doc["seasons"][0]["build"]]
    assert builds[:2] == ["fortcore", "cistern"], doc["seasons"]
    assert sum(b["tpl"] == "cistern" for x in doc["seasons"] for b in x["build"]) == 1


def test_no_z4_yet_notes_the_emergency_builds_for_after_s1_dig(base):
    prev, state = base
    doc = plan.propose(_thirsty(state), phases(), None, decisions={}, tinfo=tinfo(), fort={"z4": False})
    tpls = {b["tpl"] for x in doc["seasons"] for b in x["build"]}
    assert tpls <= {"fortcore", "seal"}
    assert "after s1.dig propose again: cistern, farms and a Still/Kitchen first" in doc["notes"]
    assert doc["notes"].rstrip().endswith("apply, wait for s1.dig, propose again")


# ---------------------------------------------------------------- BUG-244
def test_summary_shows_the_stage():
    doc = {"year": 3, "phase_target": "P3", "policy": {"option": "B", "pop_ceiling": 100, "beauty": "none"},
           "seasons": [{"build": [{"tpl": "fortcore", "site": "same", "p": {"stage": 3}}]},
                       {"build": [{"tpl": "fortcore", "site": "same", "p": {"stage": 2}}, EX]}, {"build": []},
                       {"build": []}], "orders": {"import": []}}
    out = plan._summary(doc)
    assert "s0: fortcore@same st3 (refuge); s1: fortcore@same st2, explore@S1; s2: -" in out


def test_gallery_warning_waits_for_stage_2_dug(base):
    doc, state = base
    d5, s5 = copy.deepcopy(doc), copy.deepcopy(state)
    d5["phase_target"] = s5["phase"] = "P5"
    kw = {"decisions": {}, "banned": plan.BANNED}
    gw = [w for w in plan.check(d5, s5, **kw)[1] if "no outward gallery" in w]
    assert gw == ['no outward gallery over O1: a waiting army cannot be shot; add {"tpl":"gallery_o1","site":"S1"} '
                  "to a season"]
    assert not [w for w in plan.check(d5, s5, fort={"o1": True, "core2": False}, **kw)[1] if "no outward gallery" in w]
    s5["proj"] = [["y3s2b0", "s2.dig", 30, ""]]
    assert not [w for w in plan.check(d5, s5, **kw)[1] if "no outward gallery" in w]
