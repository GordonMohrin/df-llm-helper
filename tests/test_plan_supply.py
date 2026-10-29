"""Run 10 (Handlelock): metal and mood materials as plan goals. Iron stayed at 8 bars for years, three caravans a year
never brought any, the soldiers wore 38-53 %, and a fey mood died for two leather: `plan propose` drafts the `explore`
template each season while the fort has no ore, and `plan check` refuses a plan with neither an ore search nor a bar
trade want; leather goes first in trade.want after a mood missed it."""
import copy
import json

import pytest
from cli_v2_helpers import FIX, make_runtime, reset_paths

from dfpilot import cmd, files, plan, schema

EX = {"tpl": "explore", "site": "S1"}
TPLS = ("tombs", "temple", "dining", "workshops", "fortcore", "explore", "bedrooms", "hospital", "tavern")


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))       # no decisions.yaml: defaults
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


@pytest.fixture
def base(save):
    return json.loads((save / "plan.json").read_text("utf-8")), files.read_state(save)


def noore(state, **stock):
    """The fixture state (y3 season 1, 8 soldiers worn 94 %) with economy's Run 10 stock keys: no ore, 8 bars."""
    s = copy.deepcopy(state)
    s["stock"].update({"ore": 0, "bars": 8, "leather": 3, "metal": "explore", **stock})
    assert schema.validate("state", s) == []
    return s


def check(doc, state, **kw):
    return plan.check(doc, state, decisions={}, banned=plan.BANNED, **kw)


def test_ore_goal_reads_economys_state(base):
    _, state = base
    assert plan.ore_goal(state) is None                                 # a kernel without stock.ore: not checked
    assert plan.ore_goal(noore(state)) == "no ore, 8 bars and economy wants metal"
    s = noore(state, metal="")
    assert plan.ore_goal(s) is None                                     # worn 94 % and economy wants no metal
    s["mil"]["worn"] = 53
    assert plan.ore_goal(s) == "no ore, 8 bars, the soldiers wear 53 % < 80"
    assert plan.ore_goal(noore(state, ore=4)) is None                   # ore at hand: economy smelts it


def test_check_wants_an_ore_search_or_a_bar_want(base):
    doc, state = base
    s = noore(state)
    errs, warn = check(doc, s)                                          # the fixture plan wants bar:iron
    assert errs == []
    assert [w for w in warn if w.startswith("metal")] == [
        "metal: no ore, 8 bars and economy wants metal; only trade.want bar (Run 10: three caravans a year brought no "
        "iron): add tpl explore (site S1) to each season until ore is found"]
    d2 = copy.deepcopy(doc)
    d2["trade"]["want"] = ["anvil", "cloth"]
    errs, _ = check(d2, s)
    assert len(errs) == 1 and errs[0].startswith("metal: no ore, 8 bars and economy wants metal; the plan has neither "
                                                 "tpl explore nor a trade want bar:*")
    d3 = copy.deepcopy(d2)
    d3["seasons"][3]["build"].append(dict(EX))
    errs, warn = check(d3, s, tpls=list(TPLS))
    assert errs == [] and not [w for w in warn if w.startswith("metal")]
    assert check(d2, noore(state, ore=3, metal="smelt"))[0] == []        # ore in the fort: no goal
    assert check(d2, state)[0] == []                                    # an older kernel's state: not checked


def test_check_wants_leather_first_after_a_mood_missed_it(base):
    doc, state = base
    s = noore(state, ore=5, metal="smelt", leather=0, mood_miss=["leather"])
    warn = [w for w in check(doc, s)[1] if w.startswith("leather")]
    assert warn == ["leather: a strange mood missed leather and the fort has none: put leather first in trade.want "
                    "(not among its first three; economy staffs hunters and asks for a tannery)"]
    d = copy.deepcopy(doc)
    d["trade"]["want"] = ["leather"] + d["trade"]["want"]
    assert not [w for w in check(d, s)[1] if w.startswith("leather")]
    assert not [w for w in check(doc, noore(state, ore=5, leather=4, mood_miss=["leather"]))[1] if w.startswith("leather")]


def test_propose_drafts_explore_each_season_until_ore(base):
    prev, state = base
    phases = json.loads((FIX / "phases.json").read_text("utf-8"))
    tinfo = {t: {"params": {}, "about": ""} for t in TPLS}
    s = noore(state, leather=0, mood_miss=["leather"])
    doc = plan.propose(s, phases, prev, decisions={}, tinfo=tinfo)
    assert schema.validate("plan", doc) == []
    se = doc["seasons"]
    assert se[0] == prev["seasons"][0]                                  # a past season stays as applied
    # the current season (1): the first build after the applied ones; then one in each later season
    assert se[1]["build"][:2] == prev["seasons"][1]["build"] + [EX]
    assert se[2]["build"][:2] == prev["seasons"][2]["build"] + [EX]
    assert se[3]["build"][0] == EX
    assert sum(b == EX for x in se for b in x["build"]) == 3
    assert plan.stable_ids(doc, prev) == []
    assert doc["trade"]["want"] == ["leather", "bar:iron", "anvil", "cloth"]
    assert "explore@S1 each season until ore is found" in doc["notes"]
    errs, warn = check(doc, s, tpls=list(TPLS))
    assert errs == [] and not [w for w in warn if w.startswith(("metal", "leather"))]
    # proposed again from that plan: still one per season; no bar want left -> bar:iron comes in
    doc["trade"]["want"] = ["anvil"]
    again = plan.propose(s, phases, doc, decisions={}, tinfo=tinfo)
    assert sum(b == EX for x in again["seasons"] for b in x["build"]) == 3
    assert again["trade"]["want"] == ["leather", "bar:iron", "anvil"]
    # the next year: one in every season
    y4 = plan.propose(dict(s, t=dict(s["t"], y=4, season=0)), phases, prev, decisions={}, tinfo=tinfo)
    assert [x["build"][0] for x in y4["seasons"]] == [EX] * 4
    # ore found (or an older kernel): no explore, the wants as before
    for st in (noore(state, ore=6, metal="smelt"), state):
        d = plan.propose(st, phases, prev, decisions={}, tinfo=tinfo)
        assert not any(b["tpl"] == "explore" for x in d["seasons"] for b in x["build"])
        assert d["trade"]["want"] == prev["trade"]["want"]
    # a bp package without the template: nothing drafted, bar:iron still wanted
    tin = {t: v for t, v in tinfo.items() if t != "explore"}
    d = plan.propose(s, phases, prev, decisions={}, tinfo=tin)
    assert not any(b["tpl"] == "explore" for x in d["seasons"] for b in x["build"]) and "bar:iron" in d["trade"]["want"]


def test_fit_explore_takes_the_deepest_depth_with_a_site(save, base, monkeypatch):
    prev, state = base
    phases = json.loads((FIX / "phases.json").read_text("utf-8"))
    tinfo = {t: {"params": {}, "about": ""} for t in TPLS}
    s = noore(state)
    asked = []

    def rank(save_dir, tpl, params=None, snap=None, n=3, manifest=None):
        asked.append(params["depth"])
        if params["depth"] > 6:
            raise cmd.BpError("rank explore: explore: every anchor's shaft of depth 9 reaches an avoided level (z20)")
        return [{"id": "S1", "anchor": [45, 56, 25], "rot": 1, "score": 990, "why": "rot1, shaft to z19"}], "c1"
    monkeypatch.setattr(plan, "rank_sites", rank)
    monkeypatch.setattr(plan, "explore_room", lambda *a, **k: 9)       # BUG-241's site count: tests/test_bug241_244_*
    prev2 = copy.deepcopy(prev)
    prev2["seasons"][1]["build"].append(dict(EX))                       # applied in season 1: kept as it is
    doc = plan.propose(s, phases, prev2, decisions={}, tinfo=tinfo)
    line = plan.fit_explore(save, doc, prev2)
    assert asked == [12, 9, 6] and line == "explore: depth 6 at [45, 56, 25] (rot1, shaft to z19)"
    ex = [(si, b) for si, x in enumerate(doc["seasons"]) for b in x["build"] if b["tpl"] == "explore"]
    assert ex == [(1, EX), (2, {**EX, "p": {"depth": 6}}), (3, {**EX, "p": {"depth": 6}})]
    assert plan.stable_ids(doc, prev2) == []
    # nothing fits at any depth: the new explore builds leave the draft, the note says why
    monkeypatch.setattr(plan, "rank_sites", lambda *a, **k: (_ for _ in ()).throw(
        cmd.BpError("explore: every anchor's shaft of depth 2 reaches an avoided level (z24)")))
    doc = plan.propose(s, phases, prev2, decisions={}, tinfo=tinfo)
    assert plan.fit_explore(save, doc, prev2) == "explore: no site at depth 2..12: not drafted"
    assert [b for x in doc["seasons"] for b in x["build"] if b["tpl"] == "explore"] == [EX]   # the kept one
    assert "no explore site at any depth" in doc["notes"]
    # no snapshot: nothing fitted, the draft stays
    monkeypatch.setattr(plan, "rank_sites", lambda *a, **k: (_ for _ in ()).throw(cmd.BpError("no snapshot: run ...")))
    doc = plan.propose(s, phases, prev, decisions={}, tinfo=tinfo)
    assert plan.fit_explore(save, doc, prev) is None
    assert sum(b == EX for x in doc["seasons"] for b in x["build"]) == 3


def test_status_shows_ore_and_leather(save, base):
    from dfpilot import brief
    _, state = base
    s = noore(state, leather=0, mood_miss=["leather"])
    s["seq"] += 10
    files.write_json_atomic(save / ("state.a.json" if s["seq"] % 2 else "state.b.json"), s)
    text = brief.status_text(save)
    assert "ore 0 bars 8 (explore) leather 0 moods missed leather" in text, text


# ---------------------------------------------------------------- Run 11: the metal route
# Kilrudrabed (y431-y441): no ore on the site, bars 0 for ten years, the explore never found any, the caravans never
# brought iron; 10 soldiers at worn 58 % lost siege 8. While the plan wants soldiers and the fort holds no metal for
# them, `plan check` refuses a plan without any metal route (explore, metal to melt, a depot for the caravans)
def bare(state, **stock):
    """No ore, no bars, economy says metal is short for the soldiers (stock.mshort), nothing marked for melting."""
    return noore(state, **{"bars": 0, "metal": "explore", "mshort": 1, "melt": 0, **stock})


def test_metal_short_reads_economys_judgment(base):
    _, state = base
    assert plan.metal_short(state) is None                              # an older kernel without stock.ore
    assert plan.metal_short(bare(state)) is True
    assert plan.metal_short(bare(state, mshort=0)) is False             # economy: worn >= 80 or no soldiers wanted
    assert plan.metal_short(noore(state)) is False                      # 8 bars
    old = noore(state, bars=0)                                          # no stock.mshort: the soldiers' worn %
    assert plan.metal_short(old) is False                               # the fixture's 94 %
    old["mil"]["worn"] = 58
    assert plan.metal_short(old) is True


def test_metal_gate_no_route_at_all_is_an_error(base):
    # old code: no metal_gate; plan check passed a plan with soldiers and no way to any metal
    doc, state = base
    d = copy.deepcopy(doc)
    d["trade"]["want"] = ["anvil", "cloth"]
    s = bare(state)
    none = {"metal": {"depot": False, "explore": False}}
    errs, warn = plan.metal_gate(d, s, none)
    assert errs == ["metal: no route: the plan wants soldiers (1 melee, 0 crossbow squads) and the fort has no ore, no "
                    "bars, no explore, nothing to melt and no trade depot: add {\"tpl\":\"explore\",\"site\":\"S1\"} (or a "
                    "depot for the caravans; the melee squads fill only as far as armor, weapon and shield sets go)"]
    # through check: the Run 10 "neither explore nor bar:*" error gives way to it (one metal error)
    errs, _ = check(d, s, fort=none)
    assert [e for e in errs if e.startswith("metal")] == plan.metal_gate(d, s, none)[0]
    # a depot: only the caravans (the kernel asks each for metal): a warning
    errs, warn = plan.metal_gate(d, s, {"metal": {"depot": True, "explore": False}})
    assert errs == [] and len(warn) == 1 and warn[0].startswith("metal: the plan wants soldiers")
    assert "only the caravans (the kernel asks each for bars, metal gear, picks and axes)" in warn[0]
    # a route: an explore build, one under way, or the invaders' gear to melt
    d2 = copy.deepcopy(d)
    d2["seasons"][2]["build"].append(dict(EX))
    assert plan.metal_gate(d2, s, none) == ([], [])
    assert plan.metal_gate(d, s, {"metal": {"depot": False, "explore": True}}) == ([], [])
    assert plan.metal_gate(d, bare(state, melt=4), none) == ([], [])
    # no soldiers wanted (before P2, or no squad), or metal not short: nothing
    d3 = copy.deepcopy(d)
    d3["phase_target"] = "P1"
    assert plan.metal_gate(d3, s, none) == ([], [])
    d4 = copy.deepcopy(d)
    d4["military"]["squads"] = {"melee": 0, "xbow": 0}
    assert plan.metal_gate(d4, s, none) == ([], [])
    assert plan.metal_gate(d, bare(state, mshort=0), none) == ([], [])
    assert plan.metal_gate(d, state, none) == ([], [])                  # an older kernel: not checked


def test_fort_facts_metal_route(save, base):
    _, state = base
    fm = plan.fort_facts(save, state)["metal"]
    assert fm["explore"] is False
    files.write_json_atomic(save / "bp" / "y3s1b9.json", {"tpl": "explore", "id": "y3s1b9"})
    assert plan.fort_facts(save, state)["metal"]["explore"] is True     # an explore without PROJECT_DONE
    from cli_v2_helpers import append_events
    append_events(save, [{"n": 99990, "t": 1, "y": 3, "type": "PROJECT_DONE", "cls": "B", "mod": "runner",
                          "msg": "done", "d": {"proj": "y3s1b9"}}])
    assert plan.fort_facts(save, state)["metal"]["explore"] is False
    assert isinstance(fm["depot"], bool)


def test_brief_shows_metal_short_and_the_gear_cap(save, base):
    from dfpilot import brief
    _, state = base
    s = bare(state, melt=3)
    s["mil"]["cap"] = {"sets": 3, "melee": 3, "want": 6, "xbow": 2}
    assert schema.validate("state", s) == []
    s["seq"] += 10
    files.write_json_atomic(save / ("state.a.json" if s["seq"] % 2 else "state.b.json"), s)
    assert "ore 0 bars 0 (explore) METAL SHORT melt 3" in brief.status_text(save)
    text = brief.brief_text(save)
    assert "melee 3/6 (gear sets 3), +2 crossbow (metal short)" in text, text
