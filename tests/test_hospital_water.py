"""BUG-034 (Run 11, Kilrudrabed site98, y439 spring d28): 5 bedridden patients died of thirst in a hospital without
accepted water (4 locations, 5 zones); HOSPITAL_DRY had said so for a long time and the plans drafted `hospital` again.
Python side: `plan check` refuses a new hospital without an accepted source near its site (state water.src), `plan
propose` holds it back and drafts the cistern instead; the state's water key, HOSPITAL_REMOVED and the config knobs."""
import copy
import json
import re

import pytest
from cli_v2_helpers import FIX, append_events, ev, make_runtime, reset_paths

from dfpilot import brief, fairplay, files, plan, schema
from dfpilot.cli import main

ROOT = FIX.parent.parent.parent
TPLS = ("tombs", "temple", "dining", "workshops", "fortcore", "explore", "bedrooms", "hospital", "tavern", "cistern")
HOSP = {"tpl": "hospital", "site": "S1"}
CIS = {"tpl": "cistern", "site": "S1"}


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))       # no decisions.yaml, no baseline: defaults
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


@pytest.fixture
def base(save):
    return json.loads((save / "plan.json").read_text("utf-8")), files.read_state(save)


def watered(state, src=(), patients=13, thirst=75000, hosp=5, ok=0):
    """The fixture state with the kernel's water key (BUG-034); default: Run 11 y439, 5 dry zones, no accepted water."""
    s = copy.deepcopy(state)
    s["water"] = {"patients": patients, "thirst_max": thirst, "hosp_ok": ok, "refuge_ok": 0, "buckets_free": 3,
                  "hosp": hosp, "src": [list(p) for p in src]}
    assert schema.validate("state", s) == []
    return s


def check(doc, state, **kw):
    """plan.check against the fixture's applied plan.json (its y3s0b1 hospital is applied, no new build)."""
    kw.setdefault("prev", json.loads((FIX / "runtime" / "region7" / "plan.json").read_text("utf-8")))
    return plan.check(doc, state, decisions={}, banned=plan.BANNED, **kw)


def with_hospital(doc, season=2):
    d = copy.deepcopy(doc)
    d["seasons"][season]["build"].append(dict(HOSP))
    return d


def hosp_errs(errs):
    return [e for e in errs if e.startswith("hospital")]


# ---------------------------------------------------------------- contracts
def test_state_water_key_and_hospital_removed_event(base):
    _, state = base
    s = watered(state, src=[(60, 12, 5)])
    assert schema.STATE_OWNERS["water.*"] == "water"
    for bad, needle in ((dict(s["water"], src=[[1, 2]]), "expected 3..3 items"),
                        (dict(s["water"], src=[[1, 2, 3]] * 9), "items"),
                        (dict(s["water"], hosp_ok=2), "hosp_ok"),
                        ({k: v for k, v in s["water"].items() if k != "src"}, "src: missing")):
        errs = schema.validate("state", dict(s, water=bad))
        assert any(needle in e for e in errs), (needle, errs)
    assert schema.ACT["hospital_remove"] == ["water"]
    e = {"n": 9001, "tick": 5, "type": "HOSPITAL_REMOVED", "cls": "A",
         "msg": "removed 5 dry hospital zone(s) 61,62,63,64,65 (location 6,8,10,17): 8 patient(s) over thirst 25000",
         "d": {"zones": [61, 62, 63, 64, 65], "locs": [6, 8, 10, 17], "units": [10, 9], "n": 8, "thirst": 48000,
               "patients": 13, "give": 0, "failed": 0, "near": 30, "src": [60, 12, 5], "d": 46}}
    assert schema.validate("event", e) == []
    assert schema.validate("event", dict(e, cls="B")) != []
    assert any("zones: missing" in x for x in schema.validate("event", dict(e, d={"n": 1})))
    assert schema.EVENTS["HOSPITAL_REMOVED"][:2] == ("A", "water")


def test_water_config_mirrors_water_lua_and_validates(tmp_path):
    src = (ROOT / "lua" / "dfllm" / "water.lua").read_text(encoding="utf-8")
    block = src.split("M.DEFAULTS = {", 1)[1].split("\n}", 1)[0]
    keys = set(re.findall(r"(?<![\w.])([a-z_]+) = ", re.sub(r"--[^\n]*", "", block)))
    assert keys == set(fairplay.WATER_LIM), keys ^ set(fairplay.WATER_LIM)
    cfg = json.loads((ROOT / "config" / "baseline.json").read_text(encoding="utf-8"))
    assert cfg["water"] == {"patient_thirst": 25000, "hosp_remove": True, "remove_per_run": 8}
    assert fairplay.water_errors() == []
    p = tmp_path / "baseline.json"
    p.write_text(json.dumps({"v": 2, "water": {"patient_thirst": "high", "hosp_remove": 1, "remove_per_run": 99,
                                               "pond_far": 3}}), encoding="utf-8")
    assert fairplay.water_errors(p) == [
        "config/baseline.json: water.patient_thirst: int 1000..75000 expected, got 'high'",
        "config/baseline.json: water.hosp_remove: true or false expected, got 1",
        "config/baseline.json: water.remove_per_run: int 0..32 expected, got 99",
        "config/baseline.json: water.pond_far: unknown key"]
    p.write_text(json.dumps({"v": 2}), encoding="utf-8")
    assert fairplay.water_errors(p) == [] and fairplay.water_errors(tmp_path / "none.json") == []


# ---------------------------------------------------------------- plan check
def test_check_refuses_a_hospital_without_accepted_water(base):
    """The live y439 case: no accepted water (state water.src empty); a plan that adds a hospital is refused, with the
    cistern as the fix (old: accepted, and the hospital came back each review)."""
    doc, state = base
    s = watered(state)
    d = with_hospital(doc)
    errs, _ = check(d, s, fort={"hosp": {"cistern": False, "site": None}})
    assert hosp_errs(errs) == [
        "hospital (seasons[2]): no accepted water in the fort (a well over water or a Water Source zone on water >= 4/7: "
        "state water.src is empty): its patients would die of thirst (BUG-034); remove it and add "
        '{"tpl":"cistern","site":"S1"} first (dfllm bp sites cistern), or zone deep water as Water Source (dfllm cmd '
        "inspect '{\"what\":\"water_sources\"}'); plan propose drafts the hospital again once the state's water.src "
        "lists a source within 30 tiles of its site"]
    assert check(doc, s, fort={})[0] == [], "the applied hospital (y3s0b1) is no new build"
    # a cistern under way or planned: it must hold water first
    e1 = hosp_errs(check(d, s, fort={"hosp": {"cistern": True, "site": None}})[0])
    assert len(e1) == 1 and "remove it; the cistern under way or standing must hold water first" in e1[0]
    d2 = copy.deepcopy(d)
    d2["seasons"][1]["build"].append(dict(CIS))
    e2 = hosp_errs(check(d2, s, fort={})[0])
    assert len(e2) == 1 and "remove it; the planned cistern must hold water first" in e2[0]


def test_check_measures_the_water_from_the_hospital_site(base):
    doc, state = base
    d = with_hospital(doc)
    near = watered(state, src=[(90, 90, 5), (40, 20, 6)])
    fort = {"hosp": {"cistern": False, "site": [20, 20, 5]}}
    errs, warn = check(d, near, fort=fort)
    assert hosp_errs(errs) == [] and not [w for w in warn if w.startswith("hospital")]
    far = watered(state, src=[(90, 90, 5), (60, 20, 5)])
    e = hosp_errs(check(d, far, fort=fort)[0])
    # BUG-040: measured from the hospital's zone (x 17-23 at rot 0), as water.lua and the site ranking do: 37, not 40
    assert len(e) == 1 and e[0].startswith("hospital (seasons[2]): the nearest accepted water 60,20,5 is 37 tiles from "
                                           "the hospital site 20,20,5 (> 30): its patients would die of thirst")
    # a source but no site to measure from (no snapshot): allowed, with a warning
    errs, warn = check(d, far, fort={"hosp": {"cistern": False, "site": None}})
    assert hosp_errs(errs) == []
    assert [w for w in warn if w.startswith("hospital")] == [
        "hospital (seasons[2]): accepted water at 90,90,5; its distance to the hospital's site is not checked (no sites "
        "snapshot: dfllm bp sites hospital --fresh)"]
    # an older kernel (no state.water): not checked (as the supply goals)
    errs, warn = check(d, state, fort=fort)
    assert hosp_errs(errs) == [] and not [w for w in warn if w.startswith("hospital")]


def test_water_near_follows_the_config(save, base, monkeypatch, tmp_path):
    doc, state = base
    cfg = tmp_path / "config"
    cfg.mkdir()
    (cfg / "baseline.json").write_text(json.dumps({"v": 2, "water": {"near": 45}}), encoding="utf-8")
    assert plan.water_near() == 45
    far = watered(state, src=[(60, 20, 5)])
    assert plan.hospital_water(far, {"hosp": {"site": [20, 20, 5]}})["ok"] is True


# ---------------------------------------------------------------- plan propose
def test_propose_holds_the_hospital_back_and_drafts_the_cistern(base):
    """y439: the P3 hospital is not drafted while the fort has no accepted water; the cistern takes its place once, and
    the notes say why (old: `hospital` in every draft)."""
    _, state = base
    phases = json.loads((FIX / "phases.json").read_text("utf-8"))
    tinfo = {t: {"params": {"stage": 1} if t == "fortcore" else {}, "about": ""} for t in TPLS}
    s = watered(state)
    fort = {"hosp": {"cistern": False, "site": None}}
    doc = plan.propose(s, phases, None, decisions={}, tinfo=tinfo, applied=set(), fort=fort)
    assert schema.validate("plan", doc) == []
    built = [b for se in doc["seasons"] for b in se["build"]]
    assert HOSP not in built and built.count(CIS) == 1, built
    assert "hospital held back (BUG-034): no accepted water in the fort" in doc["notes"]
    assert "cistern@S1 in its place" in doc["notes"]
    assert hosp_errs(check(doc, s, fort=fort, prev=None)[0]) == []
    # a cistern under way: neither a second cistern nor the hospital
    d = plan.propose(s, phases, None, decisions={}, tinfo=tinfo, applied=set(), fort={"hosp": {"cistern": True}})
    built = [b for se in d["seasons"] for b in se["build"]]
    assert HOSP not in built and CIS not in built
    assert "the cistern under way or standing must hold water first" in d["notes"]
    # no cistern template (an older bp package): the hospital still waits, the note says what comes first
    t2 = {k: v for k, v in tinfo.items() if k != "cistern"}
    d = plan.propose(s, phases, None, decisions={}, tinfo=t2, applied=set(), fort=fort)
    built = [b for se in d["seasons"] for b in se["build"]]
    assert HOSP not in built and CIS not in built
    assert "water first (a cistern or a Water Source zone on deep water" in d["notes"]
    # water near the hospital's site: drafted as before, no cistern
    ok = watered(state, src=[(25, 20, 5)], ok=1)
    d = plan.propose(ok, phases, None, decisions={}, tinfo=tinfo, applied=set(),
                     fort={"hosp": {"cistern": False, "site": [20, 20, 5]}})
    built = [b for se in d["seasons"] for b in se["build"]]
    assert HOSP in built and CIS not in built and "held back" not in d["notes"]
    # an older kernel (no water key): drafted as before
    d = plan.propose(state, phases, None, decisions={}, tinfo=tinfo, applied=set(), fort=fort)
    assert HOSP in [b for se in d["seasons"] for b in se["build"]]


def test_fort_facts_hosp(save, base):
    _, state = base
    f = plan.fort_facts(save, state)["hosp"]
    assert f == {"cistern": False, "site": None}, f
    files.write_json_atomic(save / "bp" / "cs1.json", {"v": 2, "id": "cs1", "tpl": "cistern", "site": "S1"})
    assert plan.hospital_facts(save, state, [])["cistern"] is True
    append_events(save, [ev(99999, "PROJECT_DONE", "cs1 (cistern) done", {"proj": "cs1", "tpl": "cistern"})])
    assert plan.hospital_facts(save, state, [])["cistern"] is False
    assert plan.hospital_facts(save, state, [{"id": "c1", "tpl": "cistern"}])["cistern"] is True


# ---------------------------------------------------------------- brief / status
def test_status_shows_the_kernels_hospital_water(save, capsys):
    for slot in "ab":
        p = save / f"state.{slot}.json"
        doc = json.loads(p.read_text("utf-8"))
        doc["water"] = {"patients": 13, "thirst_max": 75000, "hosp_ok": 0, "refuge_ok": 0, "buckets_free": 3, "hosp": 5,
                        "src": []}
        p.write_text(json.dumps(doc), encoding="utf-8")
    assert main(["--runtime", str(save.parent), "status"]) == 0
    out = capsys.readouterr().out
    assert "hospital DRY src 0 patients 13 (thirst 75000)" in out, out
    assert "water ok" not in out, "care's stock.hosp_water gives way to the water module's view"
    assert brief._hospital({"water": {"patients": 0, "thirst_max": 0, "hosp_ok": 0, "refuge_ok": 0,
                                      "buckets_free": 0, "hosp": 0, "src": [[1, 2, 3]]}}, {}) == " hospital none src 1"
    assert brief._hospital({}, {"hosp_water": 0}) == " water NO"


# ---------------------------------------------------------------- BUG-036: the hospital outside the core
def test_bug036_contracts_hosp_out_state_patients_out_event_and_unready_hout(base):
    """Run 11 siege 9 (y445): two cave dragons struck down 8 citizens in the BREACH, 7 of them patients in hospital
    beds outside the refuge. The kernel's water state counts the hospital zones outside Kern+/Tiefe+ (hosp_out),
    PATIENTS_OUT (B) says in a fight how many patients lie outside the alert burrow, SIEGE_UNREADY carries hout."""
    _, state = base
    s = watered(state, src=[(60, 12, 5)])
    s["water"]["hosp_out"] = 2
    assert schema.validate("state", s) == []
    assert any("hosp_out" in e for e in schema.validate("state", dict(s, water=dict(s["water"], hosp_out=-1))))
    e = {"n": 9100, "tick": 5, "type": "PATIENTS_OUT", "cls": "B",
         "msg": "BREACH: 7 of 7 patients lie outside the alert burrow Tiefe+ (28392 at 115,77,144): they cannot walk "
                "there, only a rescue moves them",
         "d": {"n": 7, "patients": 7, "burrow": "Tiefe+", "units": [1, 2, 3, 4, 5, 6, 7], "mode": "BREACH",
               "hosp_out": 1}}
    assert schema.validate("event", e) == []
    assert schema.EVENTS["PATIENTS_OUT"][:2] == ("B", "water")
    assert any("burrow: missing" in x for x in schema.validate("event", dict(e, d={"n": 1})))
    u = {"fails": ["hospital_out"], "hout": "the hospital lies outside Kern+/Tiefe+ (1 of 2 zones; zone 34 at "
                                            "115,77,144): its patients cannot walk to the refuge; move it into Tiefe+ "
                                            "next to accepted water"}
    assert schema.validate_event_d("SIEGE_UNREADY", u) == []


def test_bug036_check_warns_while_the_hospital_lies_outside_kern_and_tiefe(base):
    """plan check: the kernel counts hospital zones outside Kern+/Tiefe+ (state water.hosp_out): a warning names the
    fix (a hospital inside Tiefe+ next to accepted water, BUG-034 first); a new hospital in the plan is named too. No
    warning without the key (an older kernel) or with 0."""
    doc, state = base
    s = watered(state, src=[(40, 20, 6)])
    s["water"]["hosp_out"] = 2
    fort = {"hosp": {"cistern": False, "site": [20, 20, 5]}}
    _, warn = check(doc, s, fort=fort)
    hw = [w for w in warn if w.startswith("hospital")]
    assert hw == ["hospital: 2 of 5 zones lie outside Kern+/Tiefe+ (readiness R0 hospital_out, BUG-036): its lying "
                  "patients cannot walk to the refuge in a breach; plan a hospital inside Tiefe+ (or Kern+ behind the "
                  "seal) next to accepted water (a cistern there first, BUG-034), then remove the old zones"], hw
    d = with_hospital(doc)
    errs, warn = check(d, s, fort=fort)
    assert hosp_errs(errs) == []
    hw = [w for w in warn if w.startswith("hospital (seasons[2])")]
    assert hw == ["hospital (seasons[2]): its site must lie inside Tiefe+ (or Kern+ behind the seal): the fort's "
                  "hospital lies outside them now (hosp_out 2, BUG-036)"], hw
    s["water"]["hosp_out"] = 0
    assert not [w for w in check(d, s, fort=fort)[1] if w.startswith("hospital")]
    del s["water"]["hosp_out"]
    assert not [w for w in check(d, s, fort=fort)[1] if w.startswith("hospital")]
