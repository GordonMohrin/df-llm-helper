"""BUG-040 (Run 11, Kilrudrabed site98, y453 summer, kernel b49acfb): `bp sites hospital` offered S1 139,61,139 and S2
144,61,139 while the plan check measured the hospital's water from the kernel's accepted sources (state water.src: one
wet well, 19098 at 137,77,143) and the game session waited for water; the site ranking knew nothing of that water. Now
the hospital's sites follow the accepted sources within water.lua's radius, and the plan check agrees with the sites;
the refuge's place and its nearest accepted water are named; a bucket-fed cistern without a fill source is warned
about and not drafted."""
import copy
import json
import sys
from pathlib import Path

import pytest
from cli_v2_helpers import FIX, make_runtime, reset_paths

from dfpilot import brief, cmd, files, plan, schema
from dfpilot.bp import sites
from dfpilot.cli import main

sys.path.insert(0, str(Path(__file__).resolve().parent / "bp"))
from bp_fixtures import fort_world  # noqa: E402

HOSP = {"tpl": "hospital", "site": "S1"}
CIS = {"tpl": "cistern", "site": "S1"}
LIVE_WELL = [137, 77, 143]                       # well 19098, the one wet well of Run 11 (inspect water_sources)
TIEFE = [126, 56, 129, 128, 77, 136]             # inspect refuge y453: bottom 126,56,129, mouth 128,77,136, z129-136


@pytest.fixture(scope="module")
def fort():
    w, _ = fort_world(big=True)
    return w.snapshot(purpose="sites"), w.manifest


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    for p in cmd.bp_files(d):
        p.unlink()
    yield d
    reset_paths()


def put_state(save, water=None, ref=None, ready=None):
    """Both state slots with the kernel's water key (and alert.ref, ready) as a newer kernel writes them."""
    out = None
    for slot in "ab":
        p = save / f"state.{slot}.json"
        doc = json.loads(p.read_text("utf-8"))
        if water is not None:
            doc["water"] = {"patients": 0, "thirst_max": 0, "hosp_ok": 0, "refuge_ok": 0, "buckets_free": 2, "hosp": 0,
                            **water}
        if ref is not None:
            doc["alert"] = {"want": "Tiefe+", "burrow": "Tiefe+", "tiles": 212, "inside": 0, "ok": 1,
                            "ref": {"ex": 1, "sep": 0, "beds": 60, "need": 8, **ref}}
        if ready is not None:
            doc["ready"] = ready
        assert schema.validate("state", doc) == [], schema.validate("state", doc)
        p.write_text(json.dumps(doc), encoding="utf-8")
        out = doc
    return out


def W(src, lbl=None, refuge=None, near=30):
    w = {"src": [list(s) for s in src], "near": near}
    if lbl is not None:
        w["lbl"] = lbl
    if refuge is not None:
        w["refuge"] = refuge
    return w


# ---------------------------------------------------------------- bp.sites
def test_hospital_sites_follow_the_accepted_water(fort):
    """Old: every hospital site of the core was offered whatever the water; now only those whose zone lies within 30
    tiles of an accepted source (water.lua's served(): the zone rect, z included), the nearer the better, each with
    the source and its distance in `why` and `water`."""
    snap, man = fort
    plain = sites.rank(snap, "hospital", manifest=man, n=12)
    assert len(plain) >= 6 and all("water" not in s for s in plain)
    src = [90, 66, 5]
    got = sites.rank(snap, "hospital", manifest=man, n=12, water=W([src], ["well 19098 in Kern+"]))
    assert got and len(got) < len(plain), (got, plain)
    for s in got:
        d = sites.box_dist(src, sites.zone_box("hospital", {}, s["anchor"], s["rot"]))
        assert d <= 30 and s["water"] == {"d": d, "src": src}
        assert f"well 19098 at 90,66,5 in Kern+ {d} tiles" in s["why"], s["why"]
    far = [s for s in plain if sites.box_dist(src, sites.zone_box("hospital", {}, s["anchor"], s["rot"])) > 30]
    assert far and not any(s["anchor"] == f["anchor"] and s["rot"] == f["rot"] for s in got for f in far)
    base = {(tuple(s["anchor"]), s["rot"]): s["score"] for s in plain}
    for s in got:                              # +2 per tile nearer than 30 on the score of the same site
        if (tuple(s["anchor"]), s["rot"]) in base:
            assert s["score"] == base[(tuple(s["anchor"]), s["rot"])] + 2 * (30 - s["water"]["d"])
    # without the water key (an older kernel): as before
    assert sites.rank(snap, "hospital", manifest=man, n=12, water=None) == plain


def test_hospital_sites_say_why_none_is_offered(fort):
    snap, man = fort
    with pytest.raises(ValueError, match=r"hospital: no accepted water in the fort \(state water.src is empty"):
        sites.rank(snap, "hospital", manifest=man, water=W([]))
    ref = {"name": "Tiefe+", "box": [50, 60, 2, 54, 70, 2], "wd": 12, "ws": [5, 5, 5], "ok": 0}
    with pytest.raises(ValueError) as e:
        sites.rank(snap, "hospital", manifest=man, water=W([[5, 5, 5]], ["well 19098 in Kern+"], ref))
    msg = str(e.value)
    assert msg.startswith("hospital: no site within 30 tiles of accepted water (nearest: well 19098 at 5,5,5 in Kern+; "
                          "the nearest candidate "), msg
    assert "no accepted water in Tiefe+ (50-54,60-70 z2-2; nearest: well 19098 at 5,5,5 in Kern+, 12 tiles from " \
           "Tiefe+)" in msg, msg
    assert "dig the core toward that water" in msg


def test_live_case_y453():
    """The live numbers (inspect water_sources: one wet well 19098 at 137,77,143; bp sites hospital: S1 139,61,139, S2
    144,61,139 at rot 0): by water.lua's measure both zones lie 10 tiles from the well, inside its 30, so the new
    ranking offers them and the plan check passes them. The refusal the session saw can only have come from an empty
    water.src (no accepted source at check time), which the sites now refuse the same way."""
    for anchor in ([139, 61, 139], [144, 61, 139]):
        zb = sites.zone_box("hospital", {}, anchor, 0)
        assert sites.box_dist(LIVE_WELL, zb) == 10, zb
        hw = plan.hospital_water({"water": {"src": [LIVE_WELL]}}, {"hosp": {"site": anchor, "rot": 0}})
        assert hw["ok"] and hw["d"] == 10
    hw = plan.hospital_water({"water": {"src": []}}, {"hosp": {"site": [139, 61, 139], "rot": 0}})
    assert not hw["ok"] and hw["why"].startswith("no accepted water in the fort")
    # a site the sites never offer (no zone within 30 of the well) is refused by the check, with the same measure
    hw = plan.hospital_water({"water": {"src": [LIVE_WELL]}}, {"hosp": {"site": [139, 30, 139], "rot": 0}})
    assert not hw["ok"] and hw["d"] == 41


def test_fill_source_for_a_bucket_fed_cistern():
    """A bucket-fed cistern fills only from revealed open water a walker reaches from the core (a brook, river or
    lake; never cavern water, a sump or a cistern); the fixture fort's river is one."""
    w, _ = fort_world(big=True)
    snap, man = w.snapshot(purpose="sites"), w.manifest
    f = sites.fill_source(snap, man)
    assert f["ok"] is True and f["steps"] > 0 and f["why"].startswith(f"revealed water at {f['at'][0]},"), f
    dry = fort_world(big=False)[0]
    f = sites.fill_source(dry.snapshot(purpose="sites"), dry.manifest)
    assert f == {"ok": False, "steps": None, "at": None,
                 "why": "no revealed brook, river or lake (>= 8 tiles) on snapshot sim"}
    # the river marked as cavern water: never a fill source
    cav = {**snap, "marks": {**(snap.get("marks") or {}), "cavern": [[81, 50, 10]]}}
    f = sites.fill_source(cav, man)
    assert f["ok"] is False and "(1 cavern water body: never)" in f["why"], f


# ---------------------------------------------------------------- cmd / plan check agree with the sites
def test_sites_and_plan_check_agree(save, monkeypatch):
    """The fixture core (anchors x 50-70 on y45 z120): accepted water at 100,50,120. `bp sites hospital` offers only
    sites within 30 tiles of it, plan check measures S1 the same way and passes it; with the water out of reach both
    refuse with the same reason; without accepted water both say so (old: the sites ignored the water, the check
    refused what the sites offered)."""
    doc = json.loads((save / "plan.json").read_text("utf-8"))
    d = copy.deepcopy(doc)
    d["seasons"][2]["build"].append(dict(HOSP))
    state = put_state(save, water={"src": [[100, 50, 120]], "src_l": ["well 19098 in Kern+"]})
    free, _, _ = cmd.free_sites(save, "hospital", {}, n=3)
    assert free and all(s["water"]["d"] <= 30 for s in free), free
    assert "well 19098 at 100,50,120 in Kern+" in free[0]["why"]
    fort = plan.fort_facts(save, state)
    assert fort["hosp"]["site"] == free[0]["anchor"] and fort["hosp"]["wd"] == free[0]["water"]["d"]
    errs, _ = plan.check(d, state, decisions={}, banned=plan.BANNED, fort=fort, prev=doc)
    assert not [e for e in errs if e.startswith("hospital")], errs
    # the water out of reach of every site: the sites refuse, and the check refuses with their reason
    state = put_state(save, water={"src": [[200, 200, 120]], "src_l": ["well 19098 in Kern+"]})
    with pytest.raises(cmd.BpError, match=r"no site within 30 tiles of accepted water \(nearest: well 19098 at "
                                          r"200,200,120 in Kern\+; the nearest candidate"):
        cmd.free_sites(save, "hospital", {}, n=3)
    fort = plan.fort_facts(save, state)
    assert fort["hosp"]["site"] is None and fort["hosp"]["why"].startswith("no site within 30 tiles"), fort["hosp"]
    errs, _ = plan.check(d, state, decisions={}, banned=plan.BANNED, fort=fort, prev=doc)
    he = [e for e in errs if e.startswith("hospital")]
    assert len(he) == 1 and he[0].startswith("hospital (seasons[2]): no site within 30 tiles of accepted water"), he
    # no accepted water at all
    state = put_state(save, water={"src": []})
    with pytest.raises(cmd.BpError, match="no accepted water in the fort"):
        cmd.free_sites(save, "hospital", {}, n=3)
    errs, _ = plan.check(d, state, decisions={}, banned=plan.BANNED, fort=plan.fort_facts(save, state), prev=doc)
    assert [e for e in errs if e.startswith("hospital (seasons[2]): no accepted water in the fort")]


def test_ranking_cache_follows_the_water(save):
    put_state(save, water={"src": [[100, 50, 120]]})
    a, _ = cmd.ranking(save, "hospital")
    put_state(save, water={"src": [[20, 50, 120]]})
    b, _ = cmd.ranking(save, "hospital")
    assert a and b and a[0]["water"]["src"] == [100, 50, 120] and b[0]["water"]["src"] == [20, 50, 120], \
        "old: the cached ranking was reused although the water changed"
    # other templates ignore the water (no water key in their cache digest's input)
    assert cmd.water_ctx(save, "tombs") is None


def test_bp_sites_cli_names_the_water_and_the_refuge(save, capsys):
    put_state(save, water={"src": [[100, 50, 120]], "src_l": ["well 19098 in Kern+"]},
              ref={"box": TIEFE, "wd": 9, "ws": [100, 50, 120]})
    assert main(["--runtime", str(save.parent), "bp", "sites", "hospital"]) == 0
    out = capsys.readouterr().out
    assert ("  accepted water (sites lie within 30 tiles of it): well 19098 at 100,50,120 in Kern+; no accepted water "
            "in Tiefe+ (126-128,56-77 z129-136; nearest: well 19098 at 100,50,120 in Kern+, 9 tiles from Tiefe+): the "
            "hospital goes into Kern+ next to the water") in out, out
    assert "well 19098 at 100,50,120 in Kern+" in out.split("S1 anchor", 1)[1].split("\n", 1)[0]
    put_state(save, water={"src": [[300, 300, 120]], "src_l": ["well 19098 in Kern+"]})
    assert main(["--runtime", str(save.parent), "bp", "sites", "hospital"]) == 1
    out = capsys.readouterr().out
    assert "no site within 30 tiles of accepted water (nearest: well 19098 at 300,300,120 in Kern+" in out, out


# ---------------------------------------------------------------- cisterns without a fill source
def test_check_warns_and_propose_drafts_no_bucket_fed_cistern_without_fill(save):
    """Run 11 y450/y452: plan propose drafted cistern@S1 (bucket-fed) as the hospital's water; with no revealed open
    water in reach nothing could fill it. Now: a warning in check, no such draft in propose, the note says why."""
    doc = json.loads((save / "plan.json").read_text("utf-8"))
    state = files.read_state(save)
    s = dict(state, water={"patients": 3, "thirst_max": 40000, "hosp_ok": 0, "refuge_ok": 0, "buckets_free": 2,
                           "hosp": 0, "src": []})
    nofill = {"ok": False, "why": "no revealed brook, river or lake (>= 8 tiles) on snapshot c201", "steps": None,
              "at": None}
    fort = {"hosp": {"cistern": False, "site": None, "fill": nofill}}
    d = copy.deepcopy(doc)
    d["seasons"][1]["build"].append(dict(CIS))
    _, warn = plan.check(d, s, decisions={}, banned=plan.BANNED, fort=fort, prev=doc)
    cw = [w for w in warn if w.startswith("cistern")]
    assert cw == ["cistern (seasons[1]): bucket-fed (no p.path) and no fill source: no revealed brook, river or lake "
                  "(>= 8 tiles) on snapshot c201; it stays dry like y450s0b0/y452s1b0 (BUG-040): leave it out; a piped "
                  "cistern needs revealed water too (python -m dfpilot.bp.sites cistern); drink stockpiles in the "
                  "refuge instead"], warn
    piped = copy.deepcopy(doc)
    piped["seasons"][1]["build"].append({"tpl": "cistern", "site": "S1", "p": {"path": "1,6;1,9"}})
    assert not [w for w in plan.check(piped, s, decisions={}, banned=plan.BANNED, fort=fort, prev=doc)[1]
                if w.startswith("cistern")]
    ok = {"hosp": {"cistern": False, "site": None, "fill": {"ok": True, "why": "revealed water", "steps": 4,
                                                            "at": [1, 2, 3]}}}
    assert not [w for w in plan.check(d, s, decisions={}, banned=plan.BANNED, fort=ok, prev=doc)[1]
                if w.startswith("cistern")]
    # propose: the hospital waits for water, and no dry cistern takes its place
    phases = json.loads((FIX / "phases.json").read_text("utf-8"))
    tpls = ("tombs", "temple", "dining", "workshops", "fortcore", "explore", "bedrooms", "hospital", "tavern", "cistern")
    tinfo = {t: {"params": {"stage": 1} if t == "fortcore" else {}, "about": ""} for t in tpls}
    dr = plan.propose(s, phases, None, decisions={}, tinfo=tinfo, applied=set(), fort=fort)
    built = [b for se in dr["seasons"] for b in se["build"]]
    assert HOSP not in built and CIS not in built, built
    assert "no cistern either (BUG-040: no revealed brook, river or lake (>= 8 tiles) on snapshot c201)" in dr["notes"]
    # the hospital gate's fix no longer sends the player to a cistern that cannot fill
    errs, _ = plan.check(dict(doc, seasons=[*doc["seasons"][:2], {**doc["seasons"][2],
                                                                   "build": doc["seasons"][2]["build"] + [HOSP]},
                                            doc["seasons"][3]]),
                         s, decisions={}, banned=plan.BANNED, fort=fort, prev=doc)
    he = [e for e in errs if e.startswith("hospital")]
    assert len(he) == 1 and "no cistern either: no revealed brook, river or lake" in he[0] and \
        '{"tpl":"cistern","site":"S1"}' not in he[0], he


# ---------------------------------------------------------------- status: where Tiefe+ lies
def test_status_names_the_refuge_place_and_its_nearest_water(save, capsys):
    ready = {"lvl": 0, "worn": 90, "cv": 13, "drill_age": -1, "audit": {"ok": 1, "age": 100, "min_traps": 35},
             "fail": ["refuge_dry", "hospital_out"], "open": 0}
    put_state(save, water={"src": [LIVE_WELL], "src_l": ["well 19098 in Kern+"], "hosp_out": 1},
              ref={"box": TIEFE, "wd": 9, "ws": LIVE_WELL}, ready=ready)
    assert main(["--runtime", str(save.parent), "status"]) == 0
    out = capsys.readouterr().out
    assert ("the refuge has no drink (Tiefe+ 126-128,56-77 z129-136; no accepted water in it; nearest accepted water: "
            "well 19098 at 137,77,143 in Kern+, 9 tiles)") in out, out
    assert ("the hospital lies outside Kern+/Tiefe+: Tiefe+ has no accepted water near it, so plan it inside Kern+ next "
            "to well 19098 at 137,77,143 in Kern+") in out, out
    assert "hospital none src 1 (well 19098 at 137,77,143 in Kern+)" in out, out
    # an older kernel (no alert.ref box): the old lines
    assert brief.refuge_place({"alert": {"ref": {"ex": 1, "sep": 1, "beds": 1, "need": 1}}}) == ("", False, "")


def test_contracts_bug040():
    st = json.loads((FIX / "runtime" / "region7" / "state.a.json").read_text("utf-8"))
    st["water"] = {"patients": 0, "thirst_max": 0, "hosp_ok": 0, "refuge_ok": 0, "buckets_free": 0, "hosp": 0,
                   "src": [LIVE_WELL], "src_l": ["well 19098 in Kern+"]}
    st["alert"] = {"want": "Tiefe+", "burrow": "Tiefe+", "tiles": 212, "inside": 0, "ok": 1,
                   "ref": {"ex": 1, "sep": 0, "beds": 60, "need": 8, "box": TIEFE, "wd": 9, "ws": LIVE_WELL}}
    assert schema.validate("state", st) == []
    bad = copy.deepcopy(st)
    bad["water"]["src_l"] = ["x" * 40]
    assert schema.validate("state", bad) != []
    e = {"n": 9200, "tick": 5, "type": "CISTERN_DRY", "cls": "B",
         "msg": "cistern y450s0b0 done, its well 812 at 139,70,139 dry for 30 days: bucket-fed (pond zone 77); no "
                "accepted water to carry from (no revealed water source)",
         "d": {"room": "cistern139_68_139r0", "proj": "y450s0b0", "well": 812, "pos": [139, 70, 139], "days": 30,
               "fill": "pond", "pond": 77}}
    assert schema.validate("event", e) == []
    assert schema.EVENTS["CISTERN_DRY"][:2] == ("B", "water")
    assert any("fill: missing" in x for x in schema.validate("event", dict(e, d={"room": "r", "days": 1})))
