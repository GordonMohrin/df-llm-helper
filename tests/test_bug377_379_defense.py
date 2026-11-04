"""Run 16d Plankscale (runs/run-16d/FR-BUGS.md 'FORT GEFALLEN y382'): pop 7 -> 66 on a dry refuge, 6 traps and armor worn 30-55 %,
then two goblin sieges: 66 -> 1, no attacker killed. Phase P5 'waits for squads 3, drill, ready 1' for ten years, so the hall
(a P6 deliverable) and the armor never came, while propose kept drafting explore / bedrooms / tavern / temple.
BUG-377: while the defence is short (refuge dry, an attacker path without a trap, soldiers' armor worn < 60 %) the year plan holds the population
at the citizens it has, drafts the traps and the P6 hall (the refuge pieces stay first) before the growth builds, bar:iron first for the armor.
BUG-378 (Lua, tests/lua/test_seal_refuge.lua) and BUG-379 (tests/lua/test_care_deaths.lua) have their own tests; here only the
Python side of BUG-379: the brief names a siege's unfound dead `siege`, the DEATH event takes the new `fight` field."""
import copy
import json

import pytest
from cli_v2_helpers import FIX, make_runtime, reset_paths

from dfpilot import brief, files, plan, schema


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


TPLS = ("tombs", "temple", "dining", "workshops", "fortcore", "explore", "bedrooms", "hospital", "tavern", "traps",
        "refuge_drink", "refuge_beds", "seal", "depot")
CORE = {("fortcore", 1), ("fortcore", 2), ("fortcore", 3)}
FORT = {"traps": {"doors": 0, "open": 0, "trapped": 0, "partial": 0, "ways": [], "bridges": 2, "bopen": 2,
                  "bways": ["O1", "B1"]}, "core_any": True, "core_dig": False, "core": None}


def world(save, pop=48, **kw):
    s = copy.deepcopy(files.read_state(save))
    s["phase"] = "P5"
    s["pop"] = dict(s.get("pop") or {}, cit=pop, soldiers=10)
    s["ready"] = {"lvl": 0, "worn": 40, "cv": 8, "drill_age": -1, "fail": ["refuge_dry"],
                  "audit": {"ok": 1, "age": 900, "min_traps": 0}}
    s["mil"] = {"soldiers": 10, "worn": 38, "squads": 3, "cv": 8, "kit": {"n": 10, "full": 0, "armor": 0, "weapon": 6}}
    s["traps"] = {"m": 6, "n": 6}
    s["phw"] = {"wait": ["squads 3", "drill", "ready 1"], "waived": []}
    s.update(kw)
    return s


def propose(save, s, fort=None, applied=None):
    prev = json.loads((save / "plan.json").read_text("utf-8"))
    prev["seasons"] = [{"build": []} for _ in range(4)]             # nothing applied this year: every build is new
    phases = json.loads((FIX / "phases.json").read_text("utf-8"))
    tinfo = {t: {"params": {"stage": 1} if t == "fortcore" else {}, "about": ""} for t in TPLS}
    return plan.propose(s, phases, prev, decisions={}, tinfo=tinfo, fort=dict(FORT, **(fort or {})),
                        applied=set(CORE) if applied is None else applied), prev


def builds(doc):
    return [b for se in doc["seasons"] for b in se["build"]]


def test_defense_gaps_name_each_hole(save):
    s = world(save)
    assert plan.defense_gaps(s) == ["refuge_dry", "traps 0", "armor worn 38 %"]
    s["ready"]["fail"], s["ready"]["audit"]["min_traps"], s["mil"]["worn"] = [], 22, 80     # 22 < 30: R2's, no hole
    s["mil"]["kit"] = {"n": 10, "full": 10, "armor": 10, "weapon": 10}
    assert plan.defense_gaps(s) == []
    s["mil"]["worn"], s["mil"]["kit"] = 90, {"n": 10, "armor": 0}
    assert plan.defense_gaps(s) == ["armor 0"]
    s["ready"]["audit"] = {}
    s["traps"] = {"m": 6, "n": 0}
    assert plan.defense_gaps(s) == ["traps 0", "armor 0"]
    assert plan.defense_on(s, "P2") == [] and plan.defense_on(world(save, pop=12), "P5") == []     # young or small: no hold


def test_propose_holds_the_population_and_puts_the_defence_first(save):
    s = world(save)
    doc, prev = propose(save, s)
    bs = builds(doc)
    assert doc["policy"]["pop_ceiling"] == 48                       # old: 100 (the R0 cap), the fort grew 7 -> 66
    assert {"tpl": "fortcore", "site": "same", "p": {"stage": 4}} in bs                  # the P6 hall, without P6's approval
    assert any(b["tpl"] == "traps" for b in bs)
    tpls = [b["tpl"] for b in bs]
    growth = [i for i, t in enumerate(tpls) if t in ("explore", "bedrooms", "tavern", "temple", "dining", "hospital")]
    first = [i for i, b in enumerate(bs) if plan._defense_first(b)]
    assert first and (not growth or max(first) < min(growth)), tpls
    assert doc["trade"]["want"][0] == "bar:iron"
    n = doc["notes"]
    assert "BUG-377: defence short (refuge_dry, traps 0, armor worn 38 %): pop_ceiling 48" in n, n
    assert "phase P5 waits for squads 3, drill, ready 1: the P6 hall is drafted all the same" in n, n
    assert schema.validate("plan", doc) == []
    e, w = plan.check(doc, world(save), decisions={}, banned=plan.BANNED, prev=prev, fort=dict(FORT))
    assert not [x for x in w if x.startswith("defense:")], w         # the draft passes its own check


def test_propose_without_a_gap_is_unchanged(save):
    s = world(save)
    s["ready"] = {"lvl": 0, "worn": 90, "cv": 8, "drill_age": -1, "fail": [], "audit": {"ok": 1, "age": 900, "min_traps": 40}}
    s["mil"] = {"soldiers": 10, "worn": 90, "squads": 3, "cv": 8, "kit": {"n": 10, "full": 10, "armor": 10, "weapon": 10}}
    doc, _ = propose(save, s)
    assert doc["policy"]["pop_ceiling"] == 100
    assert {"tpl": "fortcore", "site": "same", "p": {"stage": 4}} not in builds(doc)
    assert "BUG-377" not in doc["notes"]


def test_hall_is_not_drafted_twice_or_without_a_core(save):
    s = world(save)
    doc, _ = propose(save, s, applied=set(CORE) | {("fortcore", 4)})
    assert {"tpl": "fortcore", "site": "same", "p": {"stage": 4}} not in builds(doc)     # applied: not again
    assert any(b["tpl"] == "traps" for b in builds(doc))                                  # the lanes still come
    doc, _ = propose(save, s, fort={"core_dig": True}, applied={("fortcore", 1)})
    assert {"tpl": "fortcore", "site": "same", "p": {"stage": 4}} not in builds(doc)     # stage 1 still digging


def test_check_warns_about_the_ceiling_the_missing_hall_and_iron(save):
    s = world(save)
    prev = json.loads((save / "plan.json").read_text("utf-8"))
    d = copy.deepcopy(prev)
    d["phase_target"] = "P5"
    d["policy"]["pop_ceiling"] = 100
    d["trade"]["want"] = ["cloth"]
    w = [x for x in plan.check(d, s, decisions={}, banned=plan.BANNED, prev=prev, fort=dict(FORT))[1]
         if x.startswith("defense:")]
    assert len(w) == 3, w
    assert "pop_ceiling 100 lets the fort grow past 48 citizens" in w[0] and "set it to 48" in w[0]
    assert '{"tpl":"fortcore","site":"same","p":{"stage":4}}' in w[1]
    assert "bar:iron first" in w[2]
    d["policy"]["pop_ceiling"] = 48
    d["seasons"][3]["build"].append(copy.deepcopy(plan.HALL))
    d["trade"]["want"] = ["bar:iron"]
    assert not [x for x in plan.check(d, s, decisions={}, banned=plan.BANNED, prev=prev, fort=dict(FORT))[1]
                if x.startswith("defense:")]


def test_bug379_deaths_census_names_the_siege_dead():
    """BUG-379: DEATH events with d.fight and cause unknown are `siege` in the brief's death census (old: 'unknown 61')."""
    ev = {"type": "DEATH", "cls": "B", "tick": 5000, "msg": "x",
          "d": {"unit": 1, "citizen": 1, "cause": "unknown", "found": 0, "fight": "SIEGE"}}
    assert schema.validate_event("DEATH", ev["d"]) == [] if hasattr(schema, "validate_event") else True

    class Ctx:
        b = [dict(ev, tick=5000 + i, d=dict(ev["d"], unit=i)) for i in range(1, 4)] + [
            {"type": "DEATH", "cls": "B", "tick": 5010, "msg": "y",
             "d": {"unit": 9, "citizen": 1, "cause": "unknown", "found": 0}},
            {"type": "DEATH", "cls": "B", "tick": 5011, "msg": "y",
             "d": {"unit": 10, "citizen": 1, "cause": "killed", "found": 1, "by": "goblin"}}]

        @staticmethod
        def now_tick():
            return 6000
    out = brief.sec_deaths(Ctx)
    assert out and out[0].startswith("siege 3: 1 missing, 2 missing, 3 missing"), out
    assert "unknown 1: 9 missing" in out[0] and "killed 1: 10 by goblin" in out[0]


def _fc(stage, site="same"):
    return {"tpl": "fortcore", "site": site, "p": {"stage": stage}}


def test_review_merge20_hall_stays_behind_core_stages_2_and_3(save):
    """Review fix (merge20): defense_order pulled the hall (stage 4) ahead of the stages 2/3 core_gaps had inserted."""
    s = world(save)
    growth = {"tpl": "bedrooms", "site": "S1"}
    traps = {"tpl": "traps", "site": "S1"}
    out = plan.defense_order([growth, _fc(2), growth, _fc(3), traps, _fc(4)], [])
    st = [(b["tpl"], plan._stage_of(b.get("p") or {})) for b in out]
    assert st.index(("fortcore", 2)) < st.index(("fortcore", 3)) < st.index(("fortcore", 4)), st
    assert st.index(("fortcore", 4)) < st.index(("bedrooms", None)), st
    # end to end: stages 2/3 not applied, the draft needs them before the hall
    doc, prev = propose(save, s, applied={("fortcore", 1)})
    fc = [plan._stage_of(b["p"]) for b in builds(doc) if b["tpl"] == "fortcore" and b["site"] == "same"]
    assert fc == sorted(fc) and 4 in fc and 2 in fc, fc
    e, _ = plan.check(doc, world(save), decisions={}, banned=plan.BANNED, prev=prev, fort=dict(FORT))
    assert not [x for x in e if "BUG-164" in x], e


def test_review_merge20_check_errors_on_stage_before_its_predecessor(save):
    s = world(save)
    prev = json.loads((save / "plan.json").read_text("utf-8"))
    d = copy.deepcopy(prev)
    d["seasons"][0]["build"] = [_fc(4), _fc(2), _fc(3)]
    e, _ = plan.check(d, s, decisions={}, banned=plan.BANNED, prev=prev, fort=dict(FORT))
    bad = [x for x in e if "BUG-164" in x]
    assert len(bad) == 1 and "stage 4 @same comes before stage 3" in bad[0], bad
    d["seasons"][0]["build"] = [_fc(3), _fc(2)]
    e, _ = plan.check(d, s, decisions={}, banned=plan.BANNED, prev=prev, fort=dict(FORT))
    assert len([x for x in e if "BUG-164" in x]) == 1
    d["seasons"][0]["build"] = [_fc(2), _fc(3), _fc(4)]
    e, _ = plan.check(d, s, decisions={}, banned=plan.BANNED, prev=prev, fort=dict(FORT))
    assert not [x for x in e if "BUG-164" in x], e
