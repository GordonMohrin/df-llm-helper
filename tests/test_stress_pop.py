"""FR-74 (Run 13/14 notes 12 and 15: stress 52-78 % for years with no countermeasure; the population fell from 50 to 33 in
peace, no migrants since y481): `plan propose` drafts a temple and a tavern while the stress is high, `plan check` warns
without them, and status/brief name the stress sources and the population record (children vs adults, deaths of the year
by cause, migrant waves, the game's conditions). Nothing steers the migrants (DECISIONS 16)."""
import copy
import json

import pytest
from cli_v2_helpers import FIX, make_runtime, reset_paths

from dfpilot import brief, files, plan, schema

TPLS = ("tombs", "temple", "dining", "workshops", "fortcore", "explore", "bedrooms", "hospital", "tavern")


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


@pytest.fixture
def base(save):
    return json.loads((save / "plan.json").read_text("utf-8")), files.read_state(save)


def stressed(state, pct=52, src=None, **pop):
    s = copy.deepcopy(state)
    s["care"] = {**s["care"], "ghosts": 9, "stressed_pct": pct,
                 "src": {"ghosts": 12, "deaths": 30, "beds": 2} if src is None else src}
    s["pop"] = {**s.get("pop", {}), "cit": pop.get("cit", 33)}
    assert schema.validate("state", s) == []
    return s


def check(doc, state, **kw):
    return plan.check(doc, state, decisions={}, banned=plan.BANNED, **kw)


def test_stress_high_reads_the_state(base):
    _, state = base
    assert plan.stress_high(state) is None or state["care"]["stressed_pct"] >= plan.STRESS_DEF
    s = stressed(state)
    assert plan.stress_high(s) == {"pct": 52, "src": "deaths 30, ghosts 12, beds 2", "ghosts": 9}
    assert plan.stress_high(stressed(state, 29)) is None                # under care.stress_high (30)
    assert plan.stress_high(stressed(state, 80, cit=6)) is None         # a fort of 6 gets no temple
    assert plan.stress_high(stressed(state, 40, src={}))["src"] == "no cause named"
    assert plan.stress_high(None) is None and plan.stress_high({}) is None


def test_stress_threshold_is_the_kernels_config(base, tmp_path, monkeypatch):
    _, state = base
    cfg = tmp_path / "config"
    cfg.mkdir(exist_ok=True)
    (cfg / "baseline.json").write_text(json.dumps({"care": {"stress_high": 60}}), encoding="utf-8")
    monkeypatch.setenv("DFLLM_CONFIG", str(cfg))
    assert plan.stress_cfg() == 60 and plan.stress_high(stressed(state, 52)) is None
    assert plan.stress_high(stressed(state, 61)) is not None
    (cfg / "baseline.json").write_text(json.dumps({"care": {"stress_high": "x"}}), encoding="utf-8")
    assert plan.stress_cfg() == plan.STRESS_DEF


def test_propose_drafts_a_temple_and_a_tavern_once(base):
    prev, state = base
    prev = copy.deepcopy(prev)
    prev["seasons"][2]["build"] = []                                    # the fixture plan has a tavern in season 2
    phases = json.loads((FIX / "phases.json").read_text("utf-8"))
    tinfo = {t: {"params": {}, "about": ""} for t in TPLS}
    s = stressed(state)
    doc = plan.propose(s, phases, prev, decisions={}, tinfo=tinfo)
    assert schema.validate("plan", doc) == []
    builds = [b for se in doc["seasons"] for b in se["build"]]
    for t in ("temple", "tavern"):
        assert sum(b["tpl"] == t and b["site"] == "S1" for b in builds) == 1, t
    assert "stress 52 % (deaths 30, ghosts 12, beds 2): temple and tavern@S1 drafted (FR-74)" in doc["notes"]
    # calm: nothing of it
    calm = plan.propose(stressed(state, 10), phases, prev, decisions={}, tinfo=tinfo)
    assert "FR-74" not in calm["notes"]
    # standing / applied / known only: the fort already has a temple -> only the tavern; a bp package without the template
    d2 = plan.propose(s, phases, prev, decisions={}, tinfo=tinfo, fort={"social": ["temple"]})
    b2 = [b["tpl"] for se in d2["seasons"] for b in se["build"]]
    assert b2.count("tavern") == 1 and "tavern@S1 drafted (FR-74)" in d2["notes"] and "temple and tavern" not in d2["notes"]
    d3 = plan.propose(s, phases, prev, decisions={}, tinfo={t: v for t, v in tinfo.items() if t != "tavern"})
    assert "tavern@S1 drafted" not in d3["notes"] and "temple@S1 drafted" in d3["notes"]
    d4 = plan.propose(s, phases, prev, decisions={}, tinfo=tinfo, fort={"social": ["temple", "tavern"]})
    assert "FR-74" not in d4["notes"]


def test_the_rebuild_policy_drafts_no_temple(base):
    prev, state = base
    phases = json.loads((FIX / "phases.json").read_text("utf-8"))
    tinfo = {t: {"params": {}, "about": ""} for t in TPLS}
    prev = copy.deepcopy(prev)
    prev["seasons"][2]["build"] = []
    s = stressed(state)
    s["sched"] = {"rb": {"pop": 8, "lo": 10, "paused": 1, "hi": 12}}      # pop 8 < 10: only seal/tombs/food/beds
    doc = plan.propose(s, phases, prev, decisions={}, tinfo=tinfo)
    assert not any(b["tpl"] in ("temple", "tavern") for se in doc["seasons"] for b in se["build"])
    assert "FR-74" not in doc["notes"]


def test_check_warns_without_a_temple_and_a_tavern(base):
    doc, state = base
    doc = copy.deepcopy(doc)
    doc["seasons"][2]["build"] = []                                     # the fixture plan has a tavern in season 2
    s = stressed(state)
    warn = [w for w in check(doc, s)[1] if w.startswith("stress:")]
    assert len(warn) == 1
    assert "52 % of the citizens are stressed (sources: deaths 30, ghosts 12, beds 2)" in warn[0]
    assert '{"tpl":"temple","site":"S1"}' in warn[0] and '{"tpl":"tavern","site":"S1"}' in warn[0]
    assert not [w for w in check(doc, state)[1] if w.startswith("stress:")] or state["care"]["stressed_pct"] >= 30
    d = copy.deepcopy(doc)
    d["seasons"][3]["build"] += [{"tpl": "temple", "site": "S1"}, {"tpl": "tavern", "site": "S1"}]
    assert not [w for w in check(d, s)[1] if w.startswith("stress:")]
    assert not [w for w in check(doc, s, fort={"social": ["temple", "tavern"]})[1] if w.startswith("stress:")]
    one = [w for w in check(doc, s, fort={"social": ["temple"]})[1] if w.startswith("stress:")]
    assert len(one) == 1 and '"tavern"' in one[0] and '"temple"' not in one[0]


def test_social_rooms(base):
    assert plan.social_rooms({("temple", None), ("bedrooms", None)}, [{"tpl": "tavern"}, {"tpl": "x"}, "junk"]) == ["tavern", "temple"]
    assert plan.social_rooms(set(), []) == []


def test_status_and_brief_name_the_stress_sources_and_the_population(save):
    state = files.read_state(save)
    s = stressed(state)
    s["care"]["tombs_locked"] = 4
    free = s["care"]["tombs_free"]
    s["care"]["pop"] = {"kids": 17, "res": 0, "peak": 50, "dy": 17, "waves": 0, "mig": 0, "lastw": -1}
    s["care"]["died_y"] = {"mood": 6, "old age": 4, "dehydrated": 2}
    s["pop"] = {**s["pop"], "cit": 33, "adults": 16}
    assert schema.validate("state", s) == []
    (save / "state.a.json").write_text(json.dumps(s), encoding="utf-8")
    (save / "state.b.json").write_text(json.dumps(s), encoding="utf-8")
    txt = brief.status_text(save)
    assert "stress 52% (deaths 30, ghosts 12, no beds 2)" in txt and f"tombs {free} (4 closed to citizens)" in txt
    assert "pop trend: 33 of peak 50, 16 adults + 17 children/babies + 0 residents; deaths in 365 d: 17 (mood 6, old age 4, " \
           "dehydrated 2); migrants in 365 d: 0 waves, 0 people (none seen)" in txt
    full = brief.brief_text(save)
    assert brief.MIGRANT_RULES in full
    # a fort that kept its size and sees waves: not in the status
    s["care"]["pop"] = {"kids": 5, "res": 0, "peak": 34, "dy": 1, "waves": 2, "mig": 9, "lastw": 40}
    s["care"]["stressed_pct"] = 5
    for n in ("a", "b"):
        (save / f"state.{n}.json").write_text(json.dumps(s), encoding="utf-8")
    assert "pop trend" not in brief.status_text(save) and "pop trend" in brief.brief_text(save)


def test_a_small_young_fort_without_a_wave_is_not_a_trend(save):
    """review: seven citizens that have seen no wave yet are no decline; the status stays without the line (the brief has it)."""
    state = files.read_state(save)
    s = copy.deepcopy(state)
    s["care"]["stressed_pct"] = 5
    s["care"]["pop"] = {"kids": 0, "res": 0, "peak": 7, "dy": 0, "waves": 0, "mig": 0, "lastw": -1}
    s["pop"] = {**s["pop"], "cit": 7, "adults": 7}
    assert schema.validate("state", s) == []
    for n in ("a", "b"):
        (save / f"state.{n}.json").write_text(json.dumps(s), encoding="utf-8")
    assert "pop trend" not in brief.status_text(save) and "pop trend" in brief.brief_text(save)
    s["care"]["pop"]["peak"] = 12                                      # a real loss (5 of 12) is shown
    for n in ("a", "b"):
        (save / f"state.{n}.json").write_text(json.dumps(s), encoding="utf-8")
    assert "pop trend: 7 of peak 12" in brief.status_text(save)
