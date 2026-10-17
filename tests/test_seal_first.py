"""Run 11 (Kilrudrabed site98, y441 spring d23, siege 8: pop 52 -> 3): the way in 114,73,143 had no door and its seal
(c1a147c261), placed two days before the attack, was not finished. Python side of seal first and the rebuild policy:
event SEAL_STUCK (A), state sched and its status line, config/baseline.json "runner", the wake hint; `plan check` and
`plan propose` (seal first in the season, the warnings). Each test fails on 2f6ab27."""
import copy
import json

import pytest
from cli_v2_helpers import FIX, make_runtime, reset_paths

from dfpilot import brief, fairplay, files, plan, schema, wake

ROOT = FIX.parent.parent.parent
SEAL = "c1a147c261"


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def put_state(save, **keys):
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    st.update(keys)
    assert schema.validate("state", st) == [], schema.validate("state", st)
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")
    return st


# ---------------------------------------------------------------- contracts
def test_seal_stuck_event_and_sched_state(save):
    e = {"n": 9100, "tick": 5, "type": "SEAL_STUCK", "cls": "A",
         "msg": f"{SEAL} (seal) built nothing for 3 days at seal.build: 1 piece open (door 114,73,143); the other "
                "projects run again",
         "d": {"proj": SEAL, "tpl": "seal", "stage": "seal.build", "days": 3, "n": 1, "pieces": ["door 114,73,143"],
               "mat": "no material for door: no rock, no logs", "blocked": "build_lost"}}
    assert schema.validate("event", e) == []
    assert schema.EVENTS["SEAL_STUCK"][:2] == ("A", "runner")
    assert schema.validate("event", dict(e, cls="B")) != []
    assert any("proj: missing" in x for x in schema.validate("event", dict(e, d={"n": 1})))
    assert schema.ACT["order_top"] == ["runner"] and schema.STATE_OWNERS["sched.*"] == "runner"
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    ok = {"seal": {"proj": SEAL, "n": 3, "paused": 2, "more": 0, "stuck": 0}, "rb": {"pop": 2, "lo": 10, "hi": 12,
                                                                                     "paused": 4}}
    assert schema.validate("state", dict(st, sched=ok)) == []
    for bad, needle in (({"seal": {"proj": SEAL, "n": 3}}, "paused: missing"),
                        ({"seal": dict(ok["seal"], stuck=2)}, "stuck"),
                        ({"rb": {"pop": 2, "paused": 1}}, "lo: missing")):
        errs = schema.validate("state", dict(st, sched=bad))
        assert any(needle in x for x in errs), (needle, errs)
    assert wake.NEXT["SEAL_STUCK"].startswith("tell Gordon")
    assert wake.PRIO.index("SEAL_STUCK") < wake.PRIO.index("PROJECT_BLOCKED")


def test_status_shows_the_open_seal_the_stuck_seal_and_the_rebuild(save):
    put_state(save, sched={"seal": {"proj": SEAL, "n": 3, "paused": 2, "more": 0, "stuck": 0}})
    out = brief.status_text(save)
    assert f"seal open: 3 pieces ({SEAL}), others paused" in out, out
    put_state(save, sched={"seal": {"proj": SEAL, "n": 1, "paused": 0, "more": 1, "stuck": 0}})
    assert f"seal open: 1 piece ({SEAL} +1 seal), runs first" in brief.status_text(save)
    put_state(save, sched={"seal": {"proj": SEAL, "n": 1, "paused": 0, "more": 0, "stuck": 1, "days": 3}})
    assert f"seal stuck 3 d: 1 piece ({SEAL}), others run (SEAL_STUCK)" in brief.status_text(save)
    put_state(save, sched={"rb": {"pop": 2, "lo": 10, "hi": 12, "paused": 4}})
    out = brief.status_text(save)
    assert "rebuild: pop 2 < 10, only seal/tombs/food/beds (4 paused, ends at 12)" in out, out
    assert len(out) // 4 <= brief.STATUS_TOKENS * 2
    assert "rebuild:" in brief.brief_text(save)
    put_state(save)
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    st.pop("sched", None)
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")
    out = brief.status_text(save)
    assert "seal open" not in out and "rebuild:" not in out


def test_runner_config_validates(tmp_path):
    cfg = json.loads((ROOT / "config" / "baseline.json").read_text(encoding="utf-8"))
    assert cfg["runner"] == {"seal_first": {"on": True, "stuck_days": 3, "food_d": 30, "drink_d": 30},
                             "rebuild": {"pop": 10, "off": 12}}
    assert fairplay.runner_errors() == []
    p = tmp_path / "baseline.json"
    p.write_text(json.dumps({"v": 2, "runner": {"seal_first": {"on": 1, "stuck_days": 0, "wait": 2},
                                                "rebuild": {"pop": 10, "off": 8}, "pause": {}}}), encoding="utf-8")
    assert fairplay.runner_errors(p) == [
        "config/baseline.json: runner.seal_first.on: true or false expected, got 1",
        "config/baseline.json: runner.seal_first.stuck_days: int 1..60 expected, got 0",
        "config/baseline.json: runner.seal_first.wait: unknown key",
        "config/baseline.json: runner.pause: unknown key",
        "config/baseline.json: runner.rebuild.off 8 < pop 10 (the policy would end at once; the kernel uses pop)"]
    p.write_text(json.dumps({"v": 2}), encoding="utf-8")
    assert fairplay.runner_errors(p) == [] and fairplay.runner_errors(tmp_path / "none.json") == []
    src = (ROOT / "lua" / "dfllm" / "runner.lua").read_text(encoding="utf-8")
    for k in ("seal_first = true", "seal_stuck_days = 3", "emerg_food_d = 30", "emerg_drink_d = 30",
              "rebuild_pop = 10", "rebuild_off = 12"):
        assert k in src, k


def test_rules_name_the_first_move():
    rules = (ROOT / "RULES.md").read_text(encoding="utf-8")
    assert "| SEAL_STUCK |" in rules and "**Rebuild (Run 11):**" in rules
    assert len(rules.splitlines()) <= 300


# ---------------------------------------------------------------- plan check / propose
TPLS = ("tombs", "temple", "dining", "workshops", "fortcore", "explore", "bedrooms", "hospital", "tavern", "seal",
        "stockroom", "cistern", "farms")
OPEN = [{"proj": SEAL, "n": 3, "stuck": False, "days": 0}]


@pytest.fixture
def base(save):
    return json.loads((save / "plan.json").read_text("utf-8")), files.read_state(save)


def check(doc, state, **kw):
    return plan.check(doc, state, decisions={}, banned=plan.BANNED, **kw)


def added(doc, season, *builds):
    d = copy.deepcopy(doc)
    d["seasons"][season]["build"] += [dict(b) for b in builds]
    return d


def sealw(warn):
    return [w for w in warn if "seal" in w and ("first" in w or "open" in w or "stuck" in w)]


def test_check_warns_when_other_builds_come_before_a_seal(base):
    prev, state = base
    seal = {"tpl": "seal", "site": "S1", "p": {"at": "last"}}
    temple = {"tpl": "temple", "site": "S1"}
    _, warn = check(added(prev, 1, temple, seal), state, prev=prev, fort={})
    assert ("seasons[1].build[2] seal comes after temple: seal first (Run 11 siege 8: a seal placed late was unfinished "
            "at the attack); put it first in seasons[1]") in warn, warn
    d = added(added(prev, 1, temple), 2, seal)
    _, warn = check(d, state, prev=prev, fort={})
    assert any(w.startswith("seasons[2].build[1] seal comes after temple") and w.endswith(
        "move it to the front of seasons[1]") for w in warn), warn
    _, warn = check(added(prev, 1, seal, temple), state, prev=prev, fort={})
    assert sealw(warn) == [], "seal first: no warning"


def test_check_warns_on_builds_an_open_seal_pauses(base):
    prev, state = base
    d = added(prev, 1, {"tpl": "temple", "site": "S1"}, {"tpl": "fortcore", "site": "same", "p": {"stage": 3}})
    _, warn = check(d, state, prev=prev, fort={"seals": OPEN})
    assert (f"seal {SEAL} (3 pieces open) is open: the runner pauses temple in PEACE until it is done (seal first); "
            "food/drink only in an emergency") in warn, warn
    _, warn = check(d, state, prev=prev, fort={"seals": [dict(OPEN[0], stuck=True, days=4)]})
    assert any(w.startswith(f"seal {SEAL} (3 pieces open) is stuck for 4 d (SEAL_STUCK): fix it first") for w in warn)
    _, warn = check(added(prev, 3, {"tpl": "temple", "site": "S1"}), state, prev=prev, fort={"seals": OPEN})
    assert sealw(warn) == [], "a later season: not due now"


def test_open_seals_reads_the_state_and_the_bp_folder(save):
    s = files.read_state(save)
    assert plan.open_seals(save, s) == []
    (save / "bp" / "y3s1b1.json").write_text(json.dumps({"v": 2, "id": "y3s1b1", "tpl": "seal"}), encoding="utf-8")
    assert plan.open_seals(save, s) == [], "the state's running projects do not list it (cancelled)"
    s["proj"] = [["y3s1b1", "seal.build", 0, ""]] + s["proj"]
    assert plan.open_seals(save, s) == [{"proj": "y3s1b1", "n": None, "stuck": False, "days": 0}]
    assert plan.open_seals(save, {k: v for k, v in s.items() if k != "proj"})[0]["proj"] == "y3s1b1", "no rows: files"
    s["sched"] = {"seal": {"proj": SEAL, "n": 2, "paused": 1, "stuck": 0}}
    assert [x["proj"] for x in plan.open_seals(save, s)] == [SEAL, "y3s1b1"]
    assert plan.fort_facts(save, s)["seals"][0] == {"proj": SEAL, "n": 2, "stuck": False, "days": 0}


def rebuilt(state, cit=2, phase="P4", sched=True):
    s = copy.deepcopy(state)
    s["pop"]["cit"], s["phase"] = cit, phase
    if sched:
        s["sched"] = {"rb": {"pop": cit, "lo": 10, "hi": 12, "paused": 3}}
    assert schema.validate("state", s) == []
    return s


def test_rebuild_propose_drafts_only_seal_tombs_food_and_beds(base):
    _, state = base
    phases = json.loads((FIX / "phases.json").read_text("utf-8"))
    tinfo = {t: {"params": {}, "about": ""} for t in TPLS}
    s = rebuilt(state)
    doc = plan.propose(s, phases, None, decisions={}, tinfo=tinfo, applied=set(), fort={})
    assert schema.validate("plan", doc) == []
    tpls = [b["tpl"] for se in doc["seasons"] for b in se["build"]]
    assert sorted(tpls) == ["bedrooms", "tombs"], tpls
    assert doc["phase_target"] == "P4", "no phase raise in the rebuild"
    assert "rebuild (pop 2 < 10, until 12): only seal/tombs/food/beds drafted (left out: tavern, temple); " \
           "phase_target stays P4" in doc["notes"]
    errs, warn = check(doc, s, tpls=list(TPLS), fort={})
    assert not [w for w in warn if w.startswith("rebuild")], warn
    _, warn = check(added(doc, 1, {"tpl": "temple", "site": "S1"}, {"tpl": "explore", "site": "S1"}), s,
                    tpls=list(TPLS), fort={})
    assert ("rebuild: pop 2 < 10: the runner pauses temple, explore until pop >= 12 (only seal, tombs, food/drink, beds "
            "and the depot run); dfllm plan propose drafts only those") in warn, warn
    # metal short (no ore, no bars, soldiers wanted): no metal error while the rebuild pauses an explore
    m = copy.deepcopy(s)
    m["stock"].update({"ore": 0, "bars": 0, "metal": "explore", "mshort": 1})
    m.setdefault("mil", {})["worn"] = 40
    mdoc = copy.deepcopy(doc)
    mdoc["trade"]["want"] = []
    errs, warn = check(mdoc, m, tpls=list(TPLS), fort={"metal": {"depot": False, "explore": False}})
    assert not [e for e in errs if e.startswith("metal")], errs
    assert [w for w in warn if w.startswith("metal")] == [
        "metal: waits for the rebuild (pop 2 < 10): the runner pauses an explore until pop >= 12; trade.want only "
        "meanwhile"], warn
    n52 = copy.deepcopy(m)
    n52.pop("sched")
    n52["pop"]["cit"] = 52
    assert [e for e in check(mdoc, n52, tpls=list(TPLS), fort={"metal": {"depot": False, "explore": False}})[0]
            if e.startswith("metal")], "a fort of 52: the metal route is required"
    d = copy.deepcopy(doc)
    d["phase_target"] = "P5"
    assert any(w.startswith("rebuild: phase_target P4 -> P5") for w in check(d, s, tpls=list(TPLS), fort={})[1])
    # a normal fort of 52: the same propose drafts the P4/P5 builds and raises the target
    n = plan.propose(rebuilt(state, cit=52, sched=False), phases, None, decisions={}, tinfo=tinfo, applied=set(),
                     fort={})
    assert {"tavern", "temple"} <= {b["tpl"] for se in n["seasons"] for b in se["build"]} and n["phase_target"] > "P4"
    # an open seal: the note says housing waits for it
    o = plan.propose(state, phases, None, decisions={}, tinfo=tinfo, applied=set(), fort={"seals": OPEN})
    assert f"seal {SEAL} open: housing/work builds wait for it (seal first)" in o["notes"]


def test_rebuild_state_without_the_kernels_record(save, tmp_path):
    s = files.read_state(save)
    assert plan.rebuild_state(rebuilt(s)) == {"pop": 2, "lo": 10, "hi": 12}
    assert plan.rebuild_state(rebuilt(s, sched=False)) == {"pop": 2, "lo": 10, "hi": 12}, "an older kernel: pop.cit"
    assert plan.rebuild_state(rebuilt(s, phase="P1", sched=False)) is None, "a new fort"
    x = rebuilt(s, sched=False)
    x["sched"] = {"seal": {"proj": SEAL, "n": 1, "paused": 0}}
    assert plan.rebuild_state(x) is None, "the kernel publishes sched without rb: no rebuild"
    cfg = tmp_path / "config"
    cfg.mkdir(exist_ok=True)
    (cfg / "baseline.json").write_text(json.dumps({"v": 2, "runner": {"rebuild": {"pop": 0}}}), encoding="utf-8")
    assert plan.rebuild_state(rebuilt(s, sched=False)) is None, "rebuild.pop 0: off"
    assert plan.build_kind({"tpl": "workshops", "site": "S1", "p": {"add": "Fishery", "skip": ",".join(
        plan._moodable())}}) == "supply"
    assert [plan.build_kind(b) for b in ({"tpl": "fortcore", "site": "S1", "p": {"stage": 1}},
                                         {"tpl": "fortcore", "site": "same", "p": {"stage": 3}},
                                         {"tpl": "refuge_beds", "site": "S1"}, {"tpl": "cistern", "site": "S1"})] == \
        ["work", "defense", "beds", "supply"]
