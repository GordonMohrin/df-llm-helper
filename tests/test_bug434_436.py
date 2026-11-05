"""BUG-434..436 (Run 16d i4 Mazelanterns y399-y404, Run 16a i1 Syrupobeyed).
BUG-434: 11 died of thirst beside 272 days of barrel drink, 8 patients over 60,000, no hospital zone, the accepted water 83-101 tiles away.
  GiveWater needs water, not a hospital zone (kern.log: GiveWater jobs with 'hospital none'): the PROJECT_REQUEST cistern why=patient_water
  (kernel, tests/lua/test_bug434_435.lua) is answered by follow (with a tile) and by `plan propose` (without), and a held-back hospital
  is replaced by the aquifer cistern when no brook could fill a bucket-fed one.
BUG-435: projects set aside 300-900 days for ever (traps 'waits for trapparts' 912 d, tombs 461 d, fortcore 341 d): follow cancels the
  replaceable templates after plan.stale_project_days, `plan propose` draws them again.
BUG-436: 'plan REJECTED' right after propose with no ERROR line in the tail: the verdict line names the errors and the snapshot."""
import copy
import json

import pytest
from cli_v2_helpers import FIX, append_events, ev, make_runtime, reset_paths

from dfpilot import fairplay, files, plan, schema, wake

TPLS = ("tombs", "temple", "dining", "workshops", "fortcore", "explore", "bedrooms", "hospital", "tavern", "cistern", "traps")
HOSP = {"tpl": "hospital", "site": "S1"}
CIS = {"tpl": "cistern", "site": "S1"}
CIS_AQ = {"tpl": "cistern", "site": "S1", "p": {"water": "aquifer"}}


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


@pytest.fixture
def base(save):
    return json.loads((save / "plan.json").read_text("utf-8")), files.read_state(save)


def tinfo():
    return {t: {"params": {"stage": 1} if t == "fortcore" else {"water": ""} if t == "cistern" else {}, "about": ""}
            for t in TPLS}


def phases():
    return json.loads((FIX / "phases.json").read_text("utf-8"))


def watered(state, src=()):
    s = copy.deepcopy(state)
    s["water"] = {"patients": 8, "thirst_max": 65000, "hosp_ok": 0, "refuge_ok": 0, "buckets_free": 3, "hosp": 0,
                  "src": [list(p) for p in src]}
    return s


def built(doc):
    return [b for se in doc["seasons"] for b in se["build"]]


# ---------------------------------------------------------------- BUG-434
def test_held_hospital_gets_the_aquifer_cistern_when_no_brook_can_fill_one(base):
    """Mazelanterns y399: 'hospital held back: no site within 30 tiles of accepted water, nearest 86 tiles', no cistern in the
    draft because no brook was reachable (fill ok False): the aquifer was known and the player appended aqshaft/cistern by hand."""
    _, state = base
    s = watered(state, src=[(160, 170, 137)])
    fort = {"hosp": {"cistern": False, "site": None, "why": "no site within 30 tiles of accepted water, nearest 86 tiles",
                     "fill": {"ok": False, "why": "no revealed brook"}, "aq": True}}
    doc = plan.propose(s, phases(), None, decisions={}, tinfo=tinfo(), applied=set(), fort=fort)
    assert schema.validate("plan", doc) == []
    b = built(doc)
    assert HOSP not in b and b.count(CIS_AQ) == 1 and CIS not in b, b
    assert "hospital held back (BUG-034)" in doc["notes"] and "cistern@S1 water=aquifer in its place (BUG-434" in doc["notes"]
    # no aquifer known: nothing to draft, the old note
    fort2 = copy.deepcopy(fort)
    fort2["hosp"]["aq"] = False
    d2 = plan.propose(s, phases(), None, decisions={}, tinfo=tinfo(), applied=set(), fort=fort2)
    assert CIS_AQ not in built(d2) and "no cistern either (BUG-040" in d2["notes"]
    # a brook a bucket-fed one can be filled from: the plain cistern as before
    fort3 = copy.deepcopy(fort)
    fort3["hosp"]["fill"] = {"ok": True}
    d3 = plan.propose(s, phases(), None, decisions={}, tinfo=tinfo(), applied=set(), fort=fort3)
    assert CIS in built(d3) and CIS_AQ not in built(d3)
    # a cistern under way or applied before: no second one
    fort4 = copy.deepcopy(fort)
    fort4["hosp"]["cistern"] = True
    assert CIS_AQ not in built(plan.propose(s, phases(), None, decisions={}, tinfo=tinfo(), applied=set(), fort=fort4))
    assert CIS_AQ not in built(plan.propose(s, phases(), None, decisions={}, tinfo=tinfo(), applied={("cistern", None)},
                                            fort=fort))


def test_the_aquifer_cistern_is_no_dry_bucket_cistern_warning(base):
    _, state = base
    s = watered(state, src=[(160, 170, 137)])
    fort = {"hosp": {"cistern": False, "site": None, "why": "no site within 30 tiles of accepted water",
                     "fill": {"ok": False, "why": "no brook"}, "aq": True}}
    doc = plan.propose(s, phases(), None, decisions={}, tinfo=tinfo(), applied=set(), fort=fort)
    assert CIS_AQ in built(doc)
    assert plan.cistern_gate(doc, s, fort, None) == [], "p.water=aquifer fills itself"
    plain = copy.deepcopy(doc)
    for se in plain["seasons"]:
        for b in se["build"]:
            if b["tpl"] == "cistern":
                b.pop("p", None)
    assert plan.cistern_gate(plain, s, fort, None), "a bucket-fed one without a fill source still warns (BUG-040)"


def test_emergency_prefers_the_aquifer_cistern_over_nothing(base):
    """drink 0 d and no brook: the emergency draft puts the aquifer cistern first (old: nothing, the template 'aqwell' does not exist)."""
    _, state = base
    s = copy.deepcopy(state)
    s["stock"].update({"drink_d": 0})
    fort = {"hosp": {"cistern": False, "fill": {"ok": False, "why": "no brook"}, "aq": True}}
    out = plan.emergency_drafts(s, fort, set(), [], tinfo())
    assert CIS_AQ in out and CIS not in out


def test_patient_water_request_is_read_with_and_without_a_tile(save, base):
    _, state = base
    append_events(save, [ev(50000, "PROJECT_REQUEST", "cistern: patient 5 has no accepted water at all",
                            {"tpl": "cistern", "n": 1, "why": "patient_water"})])
    reqs = plan.request_facts(save, state)
    r = [x for x in reqs if x["tpl"] == "cistern"]
    assert len(r) == 1 and r[0]["why"] == "patient_water" and r[0]["at"] is None and "no water tile" in r[0]["access"]["why"]
    # propose answers it without a tile: the cistern it can fill, else the aquifer basin
    fort = {"requests": r, "hosp": {"cistern": False, "fill": {"ok": False, "why": "no brook"}, "aq": True}}
    doc = plan.propose(watered(state, src=[(160, 170, 137)]), phases(), None, decisions={}, tinfo=tinfo(), applied=set(), fort=fort)
    assert CIS_AQ in built(doc), built(doc)
    assert "cistern for the patients' water (aquifer basin)" in doc["notes"]
    fort2 = {"requests": r, "hosp": {"cistern": False, "fill": {"ok": True}, "aq": True}}
    d2 = plan.propose(watered(state, src=[(160, 170, 137)]), phases(), None, decisions={}, tinfo=tinfo(), applied=set(), fort=fort2)
    assert CIS in built(d2)
    # with a tile the old no_water path applies unchanged
    append_events(save, [ev(50001, "PROJECT_REQUEST", "cistern: no water", {"tpl": "cistern", "n": 9, "why": "no_water",
                                                                          "at": [1, 2, 3]})])
    r2 = [x for x in plan.request_facts(save, state) if x["tpl"] == "cistern"]
    assert r2[0]["why"] == "no_water" and r2[0]["at"] == [1, 2, 3]


def test_config_knobs_are_known():
    assert fairplay.WATER_LIM["patient_far"] == (0, 400)
    assert fairplay.RUNNER_LIM["queue"]["stale_days"] == (0, 3000) and fairplay.RUNNER_LIM["queue"]["stale_every"] == (1, 400)
    assert fairplay.PLAN_LIM["stale_project_days"] == (0, 3000)


# ---------------------------------------------------------------- BUG-435
def proj_row(pid, text):
    return [pid, "s1.build", 20, text]


def write_bp(save, pid, tpl):
    files.write_json_atomic(save / "bp" / f"{pid}.json", {"v": 2, "id": pid, "tpl": tpl, "site": "S1"})


def test_stale_projects_picks_replaceable_templates_after_the_limit(save, base):
    _, state = base
    write_bp(save, "tr1", "traps")
    write_bp(save, "tb1", "tombs")
    write_bp(save, "fc1", "fortcore")
    write_bp(save, "tr2", "traps")
    s = copy.deepcopy(state)
    s["proj"] = [proj_row("tr1", "set aside 912 d: stalled (bp.resume)"), proj_row("tb1", "set aside 461 d: no progress (bp.resume)"),
                 proj_row("fc1", "set aside 341 d: stalled (bp.resume)"), proj_row("tr2", "set aside 120 d: stalled (bp.resume)"),
                 proj_row("zz9", "set aside 999 d: stalled (bp.resume)")]
    got = plan.stale_projects(save, s, 300)
    assert [(g["proj"], g["tpl"], g["days"]) for g in got] == [("tr1", "traps", 912), ("tb1", "tombs", 461)], got
    assert plan.stale_projects(save, s, 0) == [], "0 = off"
    assert plan.stale_project_days() == plan.STALE_PROJECT_DEF == 300


def test_follow_cancels_a_stale_project_and_retires_its_file(save, base, monkeypatch):
    _, state = base
    write_bp(save, "tr1", "traps")
    s = copy.deepcopy(state)
    s["mode"] = "PEACE"
    s["proj"] = [proj_row("tr1", "set aside 912 d: stalled (bp.resume)")]
    monkeypatch.setattr(files, "read_state", lambda d: s)
    f = wake.Follower(save=str(save), out=lambda line: None, clock=lambda: 1000.0)
    f.dir = save
    sent, woke = [], []
    monkeypatch.setattr(f, "_send", lambda verb, args, what, now, **k: sent.append((verb, args, what)) or "c1")
    monkeypatch.setattr(f, "_synth", lambda t, msg, now: woke.append((t, msg)))
    f._check_stale(1000.0)
    assert sent == [("bp.cancel", {"proj": "tr1"}, "stale cancel tr1")]
    assert woke and woke[0][0] == "PROJECT_STALE" and "tr1 (traps, 912 d" in woke[0][1]
    f._check_stale(1000.0 + wake.STALE_CHECK_EVERY_S + 1)         # the same project again soon: not sent twice
    assert len(sent) == 1
    f._check_stale(1000.0 + wake.STALE_RETRY_S + 1)               # a refused cancel is tried again after STALE_RETRY_S
    assert len(sent) == 2
    # not in a fight, and not with --no-auto
    s["mode"] = "SIEGE"
    f2 = wake.Follower(save=str(save), out=lambda line: None, clock=lambda: 1000.0)
    f2.dir = save
    monkeypatch.setattr(f2, "_send", lambda *a, **k: sent.append("x"))
    f2._check_stale(5000.0)
    f3 = wake.Follower(save=str(save), out=lambda line: None, clock=lambda: 1000.0, auto=False)
    f3.dir = save
    s["mode"] = "PEACE"
    monkeypatch.setattr(f3, "_send", lambda *a, **k: sent.append("y"))
    f3._check_stale(5000.0)
    assert "x" not in sent and "y" not in sent


def test_a_confirmed_stale_cancel_moves_the_bp_file_away(save):
    write_bp(save, "tr1", "traps")
    f = wake.Follower(save=str(save), out=lambda line: None)
    f.dir = save
    cid = f._send("bp.cancel", {"proj": "tr1"}, "stale cancel tr1", 1.0)
    assert f.jobs["replies"][cid]["proj"] == "tr1"
    files.write_outbox = getattr(files, "write_outbox", None)
    rep = save / "outbox" / f"{cid}.json"
    rep.parent.mkdir(exist_ok=True)
    rep.write_text(json.dumps({"id": cid, "ok": True, "msg": "cancelled tr1"}), "utf-8")
    f._read_replies(2.0)
    assert not (save / "bp" / "tr1.json").exists() and (save / "bp" / ".cancelled" / "tr1.json").is_file()


def test_project_stale_is_a_wake_reason():
    assert "PROJECT_STALE" in wake.SYNTH and "PROJECT_STALE" in wake.PRIO and "PROJECT_STALE" in wake.NEXT


# ---------------------------------------------------------------- BUG-436
def test_reject_tail_names_errors_snapshot_and_refresh():
    t = plan.reject_tail(["blueprint: hospital: no site", "x"], {"id": "s77"}, "snapshot refreshed (PROJECT_DONE y1s0b0 came after snapshot s70): s77")
    assert ": 2 error(s), first: blueprint: hospital: no site" in t and "sites snapshot s77" in t and "refreshed" in t
    assert "no sites snapshot" in plan.reject_tail(["e"], None)
    assert "refreshed" not in plan.reject_tail(["e"], {"id": "s1"})


def test_plan_check_verdict_line_carries_the_first_error(save, capsys):
    from dfpilot.cli import main
    doc = json.loads((save / "plan.json").read_text("utf-8"))
    doc["policy"]["pop_ceiling"] = 9999                     # an ERROR before any placement
    draft = save / "plan.draft.json"
    draft.write_text(json.dumps(doc), "utf-8")
    capsys.readouterr()
    rc = main(["plan", "check", str(draft), "--save", str(save)]) if False else None
    from argparse import Namespace
    rc = plan.run(Namespace(action="check", file=str(draft), phases=None, by="llm", wait=1.0, dry_run=False), save)
    out = capsys.readouterr().out
    last = out.strip().splitlines()[-1]
    assert rc == 1 and last.startswith("plan REJECTED:") and "error(s), first:" in last and "sites snapshot" in last or "no sites snapshot" in last, out
