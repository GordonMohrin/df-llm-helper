"""WP2 plan propose|check|apply: schema, semantic validators, fair play, pop_ceiling <= R-level cap."""
import copy
import json

import pytest
from cli_v2_helpers import FIX, FakeKern, append_events, ev, inbox_docs, install_fake_bp, make_runtime, reset_paths

from dfpilot import files, plan, schema


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))       # no decisions.yaml: defaults
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


@pytest.fixture
def base(save):
    return json.loads((save / "plan.json").read_text("utf-8")), files.read_state(save)


def errs_of(doc, state, **kw):
    kw.setdefault("decisions", {})
    kw.setdefault("banned", plan.BANNED)
    return plan.check(doc, state, **kw)


def with_lvl(state, lvl, cit=52):
    s = copy.deepcopy(state)
    s["ready"]["lvl"] = lvl
    s["pop"]["cit"] = cit
    return s


# ---------------------------------------------------------------- check
def with_refuge(state, ex=1, sep=1, beds=13, need=13):
    """The state with seal's refuge (alert.ref, Run 10): by default separated, beds for 25 % of the 52 citizens."""
    s = copy.deepcopy(state)
    s.setdefault("alert", {"want": "Kern+", "burrow": "Kern+", "tiles": 100, "inside": 5, "ok": 1})
    s["alert"]["ref"] = {"ex": ex, "sep": sep, "beds": beds, "need": need}
    assert schema.validate("state", s) == []
    return s


def test_fixture_plan_passes(base):
    doc, state = base
    errs, warn = errs_of(doc, with_refuge(state), tpls=["workshops", "hospital", "bedrooms", "tavern"])
    assert errs == [] and warn == []
    errs, warn = errs_of(doc, state, tpls=["workshops", "hospital", "bedrooms", "tavern"])
    assert errs == [] and warn == ["refuge not checked: the state has no alert.ref (dfhack-run dfllm reload); "
                                   "phase_target P4 (P3+) needs a separated refuge with beds for refuge.bed_pct of "
                                   "the citizens"]


def test_core_supply_days_warn(base):
    """BUG-028 (Run 10 y419: 737 drink units, 60 days, in the core; 3093 outside O1): seal's core days in the state
    give a warning (not an error) below 90 days, for drink and food separately."""
    doc, state = base
    s = copy.deepcopy(state)
    s.setdefault("alert", {"want": "Kern+", "burrow": "Kern+", "tiles": 100, "inside": 5, "ok": 1})
    s["alert"].update(core_d=60, core_f=120)
    errs, warn = errs_of(doc, s, tpls=["workshops", "hospital", "bedrooms", "tavern"])
    assert errs == []
    assert [w for w in warn if "inside Kern+" in w] == [
        "drink inside Kern+/the refuge lasts 60 d < 90: build a still and a barrel stockpile inside the core "
        "(a siege cuts the rest off)"]
    s["alert"].update(core_d=95)
    assert not [w for w in errs_of(doc, s)[1] if "inside Kern+" in w]


def test_schema_errors_reported(base):
    doc, state = base
    doc["policy"]["pop_ceiling"] = 55.0
    del doc["seasons"][3]
    errs, _ = errs_of(doc, state)
    assert any("pop_ceiling: expected int" in e for e in errs) and any("seasons: 3 items < 4" in e for e in errs)


@pytest.mark.parametrize("lvl,ceiling,d01,option,ok", [
    (0, 55, "A", "A", True), (1, 56, "A", "A", False), (1, 75, "A", "A", False), (2, 75, "A", "A", True),
    (2, 76, "A", "A", False), (3, 80, "A", "A", False), (3, 80, "A", "B", False), (3, 120, "B", "B", True),
    (2, 75, "B", "B", True), (2, 80, "B", "B", False)])
def test_pop_ceiling_vs_readiness(base, lvl, ceiling, d01, option, ok):
    doc, state = base
    doc["policy"].update(pop_ceiling=ceiling, option=option)
    errs, _ = errs_of(doc, with_lvl(state, lvl), decisions={"D-01": d01})
    assert (errs == []) is ok, errs


def test_no_state_assumes_r0(base):
    doc, _ = base
    doc["policy"]["pop_ceiling"] = 60
    errs, _ = errs_of(doc, None)
    assert any("R0 cap 55" in e and "no state" in e for e in errs)


def test_semantic_rejections(base):
    doc, state = base
    bad = copy.deepcopy(doc)
    bad["year"] = 2
    bad["military"]["pct"] = 10
    bad["supply"]["drink_d"] = 100
    bad["seasons"][0]["build"].append({"tpl": "ballroom", "site": "S1"})
    errs, _ = errs_of(bad, state, tpls=["workshops", "hospital", "bedrooms", "tavern"])
    text = " ".join(errs)
    for frag in ("current year 3", "military.pct 10 < 15", "supply.drink_d 100", "unknown template 'ballroom'"):
        assert frag in text, (frag, errs)
    big = copy.deepcopy(doc)
    big["military"]["pct"] = 15
    errs, _ = errs_of(big, with_lvl(state, 1, cit=64))                  # D-12: 20 % from pop 60
    assert any("military.pct 15 < 20" in e for e in errs)


def test_fair_play_strings(base):
    doc, state = base
    doc["seasons"][1]["build"][0]["p"]["mode"] = "reveal"
    doc["notes"] = "never use fastdwarf"
    errs, warn = errs_of(doc, state)
    assert any("seasons[1].build[0].p.mode mentions 'reveal'" in e for e in errs)
    assert any("$.notes mentions 'fastdwarf'" in w for w in warn) and not any("notes" in e for e in errs)
    doc["seasons"][1]["build"][0]["p"]["mode"] = "revealed_rooms"                  # whole tokens only
    assert errs_of(doc, state)[0] == []


def test_warnings_do_not_block(base):
    doc, state = base
    doc["phase_target"] = "P2"
    doc["seasons"][0]["build"] += [{"tpl": "workshops", "site": "S1"}, {"tpl": "tavern", "site": "north"}]
    errs, warn = errs_of(doc, state)
    assert errs == []
    assert any("below the current phase P3" in w for w in warn) and any("duplicate workshops@S1" in w for w in warn)
    assert any("'north' is not a `bp sites` label" in w for w in warn)


# ---------------------------------------------------------------- propose
def test_propose_from_phases(save, base):
    prev, state = base
    phases = json.loads((FIX / "phases.json").read_text("utf-8"))
    tinfo = {t: {"params": {"stage": 1} if t == "fortcore" else {}, "about": ""}
             for t in ("fortcore", "tombs", "temple", "bedrooms", "tavern", "hospital", "dining", "workshops")}
    doc = plan.propose(state, phases, prev, decisions={}, tinfo=tinfo)
    assert schema.validate("plan", doc) == []
    assert doc["year"] == 3 and doc["phase_target"] == "P5" and "P6 needs approval" in doc["notes"]
    # applied same-year builds keep their index (= project id); new ones are appended from the current season;
    # already-planned tpls are skipped; a staged template reuses the earlier anchor (site 'same')
    assert doc["seasons"][0] == prev["seasons"][0] and doc["seasons"][2] == prev["seasons"][2]
    # DECISIONS 1: fortcore stage 3 (a P3 deliverable now, P5 before) is the first new build
    assert doc["seasons"][1]["build"] == prev["seasons"][1]["build"] + [
        {"tpl": "fortcore", "site": "same", "p": {"stage": 3}},
        {"tpl": "tombs", "site": "S1"}, {"tpl": "temple", "site": "S1"}]
    assert doc["orders"]["import"] == ["library/furnace", "library/smelting", "library/military"]
    assert plan.stable_ids(doc, prev) == []
    # year 4: hospital (y3s0b1, running), bedrooms and tavern were applied in y3 -> never drafted again
    s4 = dict(state, t=dict(state["t"], y=4, season=0))
    for nxt in (plan.propose(s4, phases, prev, decisions={}, tinfo=tinfo),
                plan.propose(s4, phases, None, decisions={}, tinfo=tinfo, applied=plan.applied_builds(save, s4))):
        built = [b for se in nxt["seasons"] for b in se["build"]]
        assert nxt["year"] == 4 and built == [{"tpl": "fortcore", "site": "same", "p": {"stage": 3}},
                                              {"tpl": "tombs", "site": "S1"}, {"tpl": "temple", "site": "S1"}], built
    applied = plan.applied_builds(save, state)
    assert {("hospital", None), ("bedrooms", None), ("tavern", None), ("workshops", None)} <= applied
    assert ("fortcore", 2) in applied                     # proj 'fortcore' at s2.build (no bp file)
    assert doc["policy"] == {"option": "B", "pop_ceiling": 55, "beauty": "used_rooms"}   # D-01 = B (Gordon 2026-10-24)
    assert doc["military"]["squads"] == {"melee": 2, "xbow": 1} and doc["military"]["pct"] == 15
    assert errs_of(doc, state)[0] == []


def test_propose_without_anything_is_valid():
    doc = plan.propose(None, None, None, decisions={})
    assert schema.validate("plan", doc) == [] and doc["phase_target"] == "P0"
    assert plan.check(doc, None, decisions={}, banned=[])[0] == []


def test_propose_r2_option_b(base):
    prev, state = base
    doc = plan.propose(with_lvl(state, 3, cit=70), None, None, decisions={"D-01": "B"})
    assert doc["policy"]["option"] == "B" and doc["policy"]["pop_ceiling"] == plan.R_CAPS[3]
    assert doc["military"]["pct"] == 20
    doc = plan.propose(with_lvl(state, 2), None, None, decisions={})
    assert doc["policy"]["pop_ceiling"] == 75


# ---------------------------------------------------------------- apply
def test_apply_writes_bp_then_plan_then_inbox(save, base, monkeypatch):
    calls = install_fake_bp(monkeypatch)
    doc, _ = base
    doc["year"] = 4                                                   # a new year: every build is new
    with FakeKern(save, lambda d: (True, "plan y4 loaded", {"year": 4, "builds": 4})) as k:
        errs, msg = plan.apply(save, doc, wait_s=5)
    assert errs == [] and "ok" in msg and "plan y4 loaded" in msg and "kept" not in msg
    assert [d["verb"] for d in k.seen] == ["plan.reload"] and k.seen[0]["by"] == "llm"
    # workshops@S1, hospital@S2 (2nd free), bedrooms@S1 (1st free after the two), tavern@S1: never the same site
    want = {"y4s0b0": ("workshops", [45, 32, 120]), "y4s0b1": ("hospital", [55, 32, 120]),
            "y4s1b0": ("bedrooms", [50, 32, 120]), "y4s2b0": ("tavern", [60, 32, 120])}
    for bid, (tpl, anchor) in want.items():
        bp = json.loads((save / "bp" / f"{bid}.json").read_text("utf-8"))
        assert bp["id"] == bid and schema.validate("bp", bp) == [] and (bp["tpl"], bp["anchor"]) == (tpl, anchor)
    assert json.loads((save / "bp" / "y4s1b0.json").read_text("utf-8"))["params"] == {"n": 20, "tier": 500}
    assert json.loads((save / "plan.json").read_text("utf-8")) == doc
    assert {c[0] for c in calls["emit"]} == {"workshops", "hospital", "bedrooms", "tavern"}


def test_apply_same_year_keeps_applied_builds(save, base, monkeypatch):
    calls = install_fake_bp(monkeypatch)
    doc, _ = base
    before = (save / "bp" / "y3s1b0.json").read_text("utf-8")
    doc["seasons"][1]["build"].append({"tpl": "tombs", "site": "S1", "p": {"n": 6}})
    errs, msg = plan.apply(save, doc, wait_s=0)
    assert errs == [] and "1 bp (4 kept)" in msg
    assert [c[0] for c in calls["emit"]] == ["tombs"]                 # applied projects are not re-emitted
    assert (save / "bp" / "y3s1b0.json").read_text("utf-8") == before
    assert json.loads((save / "bp" / "y3s1b1.json").read_text("utf-8"))["tpl"] == "tombs"


@pytest.mark.parametrize("edit,frag", [
    (lambda d: d["seasons"][0]["build"].reverse(), "y3s0b0 is workshops@S1"),
    (lambda d: d["seasons"][1]["build"].clear(), "is applied as y3s1b0; keep it"),
    (lambda d: d["seasons"][2]["build"][0].update(site="S2"), "y3s2b0 is tavern@S1"),
    (lambda d: d["seasons"][1]["build"][0]["p"].update(n=30), "y3s1b0 is bedrooms@S1")])
def test_same_year_plan_must_keep_build_ids(base, edit, frag):
    doc, state = base
    prev = copy.deepcopy(doc)
    edit(doc)
    errs, _ = errs_of(doc, state, prev=prev)
    assert any(frag in e for e in errs), errs
    doc2 = copy.deepcopy(prev)
    doc2["seasons"][3]["build"].append({"tpl": "temple", "site": "S1"})
    assert errs_of(doc2, state, prev=prev)[0] == []                   # appending is fine
    doc2["year"] = 4
    doc2["seasons"][0]["build"].reverse()
    assert errs_of(doc2, state, prev=prev)[0] == []                   # next year: new ids


def test_apply_same_site_within_one_plan(save, base, monkeypatch):
    calls = install_fake_bp(monkeypatch)
    (save / "bp" / ".placed-fortcore.json").unlink()
    doc, _ = base
    doc["year"] = 4
    doc["seasons"] = [{"build": [{"tpl": "fortcore", "site": "S2", "p": {"stage": 1}}]},
                      {"build": [{"tpl": "fortcore", "site": "same", "p": {"stage": 2}}]}, {"build": []}, {"build": []}]
    errs, msg = plan.apply(save, doc, dry_run=True)
    assert errs == [] and "2 blueprint(s)" in msg and not (save / "bp" / ".placed-fortcore.json").exists()
    errs, _ = plan.apply(save, doc, wait_s=0)
    assert errs == []
    a = json.loads((save / "bp" / "y4s0b0.json").read_text("utf-8"))
    b = json.loads((save / "bp" / "y4s1b0.json").read_text("utf-8"))
    assert a["anchor"] == b["anchor"] == [50, 32, 120] and b["site"] == "same"
    assert [c[2]["anchor"] for c in calls["emit"][-2:]] == [[50, 32, 120], [50, 32, 120]]


def _y4(doc, *seasons):
    doc = copy.deepcopy(doc)
    doc["year"] = 4
    doc["seasons"] = [{"build": list(s)} for s in seasons] + [{"build": []} for _ in range(4 - len(seasons))]
    return doc


def test_apply_real_bp_never_shares_cells(save, base):
    """Review blocker: dining@S1, tombs@S1, tavern@S1, temple@S1 all ranked S1 = [59,45,120] on c201."""
    pytest.importorskip("dfpilot.bp.sites")
    from dfpilot import cmd
    for p in cmd.bp_files(save):                     # a fresh fort: the fixture's y3 files lie off the corridor
        p.unlink()
    doc = _y4(base[0], [{"tpl": "dining", "site": "S1"}, {"tpl": "tombs", "site": "S1"}],
              [{"tpl": "tavern", "site": "S1"}, {"tpl": "hospital", "site": "S1"}], [{"tpl": "temple", "site": "S1"}])
    errs, msg = plan.apply(save, doc, wait_s=0)
    assert errs == [], errs
    docs = [json.loads(p.read_text("utf-8")) for p in cmd.bp_files(save)]
    assert len(docs) == 5 and len({tuple(d["anchor"] + [d["rot"]]) for d in docs}) == 5
    occ = cmd.Occupancy()
    for d in docs:
        assert occ.clash(d) == [], d["id"]           # neither shares nor touches an earlier one
        occ.add(d)
    cells = [cmd.bp_cells(d) for d in docs]
    assert all(not (cells[i] & cells[j]) for i in range(5) for j in range(i + 1, 5))
    # a second plan for the same year: the applied builds keep their sites, the new one avoids all of them
    applied = 0
    for extra in ({"tpl": "dining", "site": "S1", "p": {"seats": 8}}, {"tpl": "tombs", "site": "S1", "p": {"n": 4}},
                  {"tpl": "tombs", "site": "S1", "p": {"n": 2}}):
        doc2 = copy.deepcopy(doc)
        doc2["seasons"][3]["build"].append(extra)
        errs, msg = plan.apply(save, doc2, wait_s=0)
        if errs:                                     # the 40x30 snapshot is full: refused, nothing written
            assert "free site(s)" in errs[0] and not (save / "bp" / "y4s3b0.json").exists()
            continue
        new = json.loads((save / "bp" / "y4s3b0.json").read_text("utf-8"))
        assert "(5 kept)" in msg and occ.clash(new) == []
        applied += 1
        break
    assert applied == 1


def test_apply_rejects_when_no_free_site(save, base, monkeypatch):
    install_fake_bp(monkeypatch, sites=lambda snap, tpl, params, n: [
        {"id": "S1", "anchor": [40, 32, 120], "rot": 0, "score": 9, "why": ""}])
    doc = _y4(base[0], [{"tpl": "dining", "site": "S1"}, {"tpl": "tavern", "site": "S1"}])
    before = sorted(p.name for p in (save / "bp").iterdir())
    errs, msg = plan.apply(save, doc, wait_s=0)
    assert msg == "not applied" and "site S1: only 0 free site(s) for tavern" in errs[0] and "~y4s0b0" in errs[0]
    assert sorted(p.name for p in (save / "bp").iterdir() if not p.name.startswith(".sites-")) == before
    assert not (save / "inbox").exists() or inbox_docs(save) == []


def test_apply_avoids_existing_projects(save, base, monkeypatch):
    install_fake_bp(monkeypatch)
    from dfpilot import cmd
    cmd.write_bp(save, dict(cmd.emit_at("tombs", {}, {"id": "S1", "anchor": [45, 32, 120], "rot": 0}, "S1", "c77")))
    errs, _ = plan.apply(save, _y4(base[0], [{"tpl": "dining", "site": "S1"}]), wait_s=0)
    assert errs == [] and json.loads((save / "bp" / "y4s0b0.json").read_text("utf-8"))["anchor"] == [50, 32, 120]


def test_apply_refuses_bad_plan_and_writes_nothing(save, base, monkeypatch):
    install_fake_bp(monkeypatch)
    doc, _ = base
    doc["year"] = 4
    doc["policy"]["pop_ceiling"] = 75
    before = (save / "plan.json").read_text("utf-8")
    bp_before = sorted(p.name for p in (save / "bp").iterdir())
    errs, msg = plan.apply(save, doc, wait_s=0)
    assert errs and msg == "not applied" and (save / "plan.json").read_text("utf-8") == before
    assert not (save / "inbox").exists() or inbox_docs(save) == []
    assert sorted(p.name for p in (save / "bp").iterdir()) == bp_before


def test_apply_without_bp_package(save, base, monkeypatch):
    import sys
    for m in ("emit", "sites"):
        monkeypatch.setitem(sys.modules, f"dfpilot.bp.{m}", None)
    doc, _ = base
    doc["year"] = 4
    errs, _ = plan.apply(save, doc, wait_s=0)
    assert errs and "blueprint" in errs[0] and "not available" in errs[0]
    doc["seasons"] = [{"build": []} for _ in range(4)]
    errs, msg = plan.apply(save, doc, wait_s=0)                     # no builds: no bp needed
    assert errs == [] and "no reply yet" in msg and inbox_docs(save)[0]["verb"] == "plan.reload"


def test_plan_cli_propose_check_apply(save, monkeypatch, capsys):
    from dfpilot.cli import main
    install_fake_bp(monkeypatch)
    rt = str(save.parent)
    assert main(["--runtime", rt, "plan", "propose", "--phases", str(FIX / "phases.json")]) == 0
    out = capsys.readouterr().out
    assert "draft" in out and "target P5" in out and "dfllm plan check" in out
    assert (save / "plan.draft.json").exists()
    assert main(["--runtime", rt, "plan", "check"]) == 0
    out = capsys.readouterr().out
    assert "plan OK" in out and "tombs@S1 -> y3s1b2 at [" in out and "kept y3s0b0" in out   # placement dry run
    assert main(["--runtime", rt, "plan", "apply", "--dry-run"]) == 0
    assert "dry run ok: 3 blueprint(s)" in capsys.readouterr().out
    bad = json.loads((save / "plan.draft.json").read_text("utf-8"))
    bad["policy"]["pop_ceiling"] = 99
    files.write_json_atomic(save / "bad.json", bad)
    assert main(["--runtime", rt, "plan", "check", str(save / "bad.json")]) == 1
    out = capsys.readouterr().out
    assert "ERROR" in out and "REJECTED" in out


# ---------------------------------------------------------------- outward gallery over O1 (Run 10)
GALLERY_WARN = "no outward gallery over O1"


def _p5(doc, state, bridges=True):
    doc, s = copy.deepcopy(doc), copy.deepcopy(state)
    doc["phase_target"] = "P5"
    s["phase"] = "P5"
    if not bridges:
        s.pop("bridges", None)
    return doc, s


def test_outer_gallery_warning_from_the_o1_phase(base):
    """Run 10: O1 up in a siege, 47 goblins waited outside for weeks, nothing could shoot them. A warning (never an
    error) once O1 exists and the plan reaches its phase; gone when a gallery_o1 is planned or exists."""
    doc, state = base
    assert not [w for w in errs_of(doc, state)[1] if GALLERY_WARN in w]          # P3/P4: before the O1 phase
    d5, s5 = _p5(doc, state)
    errs, warn = errs_of(d5, s5)
    assert errs == [] and [w for w in warn if GALLERY_WARN in w] == [
        "no outward gallery over O1: a waiting army cannot be shot; add tpl gallery_o1 to a season "
        "(site S1, once fortcore stage 2 is dug)"]
    assert not [w for w in errs_of(d5, s5, fort={"o1": True, "gallery": True})[1] if GALLERY_WARN in w]
    planned = copy.deepcopy(d5)
    planned["seasons"][3]["build"].append({"tpl": "gallery_o1", "site": "S1"})
    assert not [w for w in errs_of(planned, s5)[1] if GALLERY_WARN in w]
    # no O1 anywhere: no warning; the plan's own fortcore stage 3 counts as O1
    d5, s5 = _p5(doc, state, bridges=False)
    assert not [w for w in errs_of(d5, s5)[1] if GALLERY_WARN in w]
    d5["seasons"][3]["build"].append({"tpl": "fortcore", "site": "same", "p": {"stage": 3}})
    assert [w for w in errs_of(d5, s5)[1] if GALLERY_WARN in w]
    assert [w for w in errs_of(_p5(doc, state, bridges=False)[0], s5, fort={"o1": True})[1] if GALLERY_WARN in w]


def test_fort_facts_read_the_save(save, base):
    from dfpilot import cmd
    facts = plan.fort_facts(save, base[1])
    assert (facts["o1"], facts["gallery"]) == (False, False)                       # proj 'fortcore' at s2.build
    assert plan.fort_facts(save, {**base[1], "proj": [["fortcore", "s3.build", 10, ""]]})["o1"] is True

    def stub(bid, tpl, params, manifest):
        return {"v": 2, "id": bid, "tpl": tpl, "site": "S1", "class": "defense", "params": params,
                "anchor": [50, 33, 120], "rot": 0, "stages": [{"label": "s.dig", "mode": "dig", "orders": 0,
                "defense": 1, "chunks": [{"pos": [52, 30, 120], "cells": [[0, 0, 0, "d"]]}]}],
                "manifest": manifest, "materials": {}}
    o1 = {"v": 2, "bridges": {"O1": {"role": "outer", "fp": [49, 30, 120, 51, 30, 120],
                                     "levers": [[45, 40, 120], [45, 41, 120]]}}}
    cmd.write_bp(save, stub("c4", "fortcore", {"stage": 3}, o1))
    facts = plan.fort_facts(save, {**base[1], "proj": []})
    assert (facts["o1"], facts["gallery"]) == (True, False)
    cmd.write_bp(save, stub("c5", "gallery_o1", {}, {"v": 2}))
    facts = plan.fort_facts(save, {**base[1], "proj": []})
    assert (facts["o1"], facts["gallery"]) == (True, True)


# ---------------------------------------------------------------- core stock after a siege (BUG-028, stockroom)
def _low_core(state, d=60, f=120):
    s = copy.deepcopy(state)
    s.setdefault("alert", {"want": "Kern+", "burrow": "Kern+", "tiles": 100, "inside": 5, "ok": 1})
    s["alert"].update(core_d=d, core_f=f)
    return s


def test_core_days_become_the_doctrine_minimum_after_a_siege(base):
    """Run 10 y419: 60 days of drink inside the core while the army sat outside. Before any siege a warning (with the
    stockroom hint); after one an error until a stockroom is planned or exists."""
    doc, state = base
    s = _low_core(state)
    errs, warn = errs_of(doc, s, fort={"sieged": False})
    assert errs == [] and "core stock: add tpl stockroom to a season (site S1; barrel stockpile + still behind B2)" \
        in warn
    errs, warn = errs_of(doc, s, fort={"sieged": True})
    assert errs == ["drink inside Kern+/the refuge lasts 60 d < 90: build a still and a barrel stockpile inside the "
                    "core (a siege cuts the rest off); the doctrine minimum since the fort's first siege"]
    planned = copy.deepcopy(doc)
    planned["seasons"][3]["build"].append({"tpl": "stockroom", "site": "S1"})
    errs, warn = errs_of(planned, s, fort={"sieged": True})
    assert errs == [] and any("drink inside Kern+" in w for w in warn) and not any("core stock" in w for w in warn)
    assert errs_of(doc, s, fort={"sieged": True, "stockroom": True})[0] == []
    assert errs_of(doc, {**s, "mode": "RECOVERY"})[0]                              # in a siege's aftermath now
    assert not any("core stock" in w for w in errs_of(doc, _low_core(state, 95, 95))[1])


def test_sieged_reads_the_event_log(save, base):
    assert plan.sieged(save, base[1]) is True                  # the fixture log has a SIEGE_START (41 invaders)
    for p in (save / "events.jsonl", save / "events.1.jsonl"):
        lines = [ln for ln in p.read_text("utf-8").splitlines() if '"SIEGE_' not in ln and '"BREACH"' not in ln
                 and '"to":"SIEGE"' not in ln and '"to":"BREACH"' not in ln]
        p.write_text("".join(ln + "\n" for ln in lines), encoding="utf-8")
    assert plan.sieged(save, base[1]) is False
    assert plan.sieged(save, {**base[1], "mode": "SIEGE"}) is True


def test_propose_drafts_a_stockroom_first(base):
    prev, state = base
    phases = json.loads((FIX / "phases.json").read_text("utf-8"))
    tinfo = {t: {"params": {}, "about": ""} for t in ("tombs", "temple", "stockroom", "dining", "workshops")}
    doc = plan.propose(_low_core(state), phases, prev, decisions={}, tinfo=tinfo)
    new = doc["seasons"][1]["build"][len(prev["seasons"][1]["build"]):]
    assert new[0] == {"tpl": "stockroom", "site": "S1"}
    doc = plan.propose(_low_core(state, d=200, f=30), phases, prev, decisions={}, tinfo=tinfo)
    new = doc["seasons"][1]["build"][len(prev["seasons"][1]["build"]):]
    assert new[0] == {"tpl": "stockroom", "site": "S1", "p": {"still": 0}}          # food only: no second still
    for st in (state, _low_core(state, 95, 95)):
        assert all(b["tpl"] != "stockroom" for se in plan.propose(st, phases, prev, decisions={}, tinfo=tinfo)[
            "seasons"] for b in se["build"])
    done = plan.propose(_low_core(state), phases, prev, decisions={}, tinfo=tinfo, applied={("stockroom", None)})
    assert all(b["tpl"] != "stockroom" for se in done["seasons"] for b in se["build"])


# ---------------------------------------------------------------- audit bypass gate (Run 10)
BYPASS = "bypass: wall 100,127,122 floor -> 139,128,117"
REFUGE = "refuge: on the attack path, wall 100,127,122 floor"
T_AUDIT = 3 * 403200 + 124000
SEAL = {"tpl": "seal", "site": "S1", "p": {"at": "audit"}}
GATE_ERR = ('audit: bypass: wall 100,127,122 floor -> 139,128,117 (+1 more): wall 100,127,122 floor stands in no '
            'seal project; add {"tpl":"seal","site":"S1","p":{"at":"audit"}} as the first build of seasons[1] '
            "(dfllm plan propose drafts it)")


def _audit(save, fails, n=8813, tick=T_AUDIT):
    append_events(save, [ev(n, "AUDIT", "audit failed", {"ok": 0, "fails": fails, "min_traps": 35}, tick=tick)])


def _gate(errs_warn):
    errs, warn = errs_warn
    return [e for e in errs if e.startswith("audit:")], [w for w in warn if w.startswith("audit:")]


def test_audit_bypass_blocks_growth_until_the_seal_is_planned(save, base):
    """Run 10: `bypass: edge->Z3/Z4 avoids the trap hall` stood in the audit for months while the plans raised the
    phase; the 41 traps stayed unused. Now the audit names the wall, and a plan that raises phase_target or adds builds
    is refused until the seal at=audit is one of its new builds, due now (old code: no audit check at all)."""
    prev, state = base
    _audit(save, [BYPASS, REFUGE, "traps<30"])
    fort = plan.fort_facts(save, state)
    a = fort["audit"]
    assert (a["found"], a["routes"], a["walls"], a["open"], a["pending"]) == (
        True, [BYPASS, REFUGE], ["100,127,122 floor wall"], ["100,127,122 floor wall"], {})
    doc = copy.deepcopy(prev)                                             # phase_target P4 > the current P3
    assert _gate(errs_of(doc, state, fort=fort, prev=prev)) == (
        [GATE_ERR + "; raising phase_target P3 -> P4 waits for it"], [])
    doc["phase_target"] = "P3"
    doc["seasons"][1]["build"].append({"tpl": "tombs", "site": "S1"})
    assert _gate(errs_of(doc, state, fort=fort, prev=prev))[0] == [GATE_ERR + "; adding builds (tombs) waits for it"]
    nothing = copy.deepcopy(prev)
    nothing["phase_target"] = "P3"                                        # neither raises nor adds: a warning
    assert _gate(errs_of(nothing, state, fort=fort, prev=prev)) == ([], [GATE_ERR])
    ok = copy.deepcopy(doc)
    ok["phase_target"] = "P4"
    ok["seasons"][1]["build"].append(SEAL)
    assert _gate(errs_of(ok, state, fort=fort, prev=prev)) == ([], [])
    named = copy.deepcopy(doc)
    named["seasons"][0]["build"].append({"tpl": "seal", "site": "S1", "p": {"at": "100,127,122 floor wall"}})
    assert _gate(errs_of(named, state, fort=fort, prev=prev)) == ([], [])  # an earlier season is due now too
    late = copy.deepcopy(doc)
    late["seasons"][3]["build"].append(SEAL)
    (e,), _ = _gate(errs_of(late, state, fort=fort, prev=prev))
    assert "move the seal from seasons[3] to seasons[1] (it must run now)" in e
    entr = copy.deepcopy(doc)
    entr["seasons"][1]["build"].append({"tpl": "seal", "site": "S1"})   # at=last: the entrances, not the wall
    assert _gate(errs_of(entr, state, fort=fort, prev=prev))[0]
    # a plan for next year: its seasons[0] is the one due
    y4 = _y4(prev, [SEAL])
    assert _gate(errs_of(y4, state, fort=fort, prev=prev)) == ([], [])
    # an audit without route findings: no gate
    _audit(save, ["traps<30"], n=8814, tick=T_AUDIT + 10)
    assert plan.fort_facts(save, state)["audit"]["routes"] == []
    assert _gate(errs_of(prev, state, fort=plan.fort_facts(save, state), prev=prev)) == ([], [])


def test_audit_gate_pending_seal_done_seal_and_no_wall(save, base):
    from dfpilot import cmd
    prev, state = base
    _audit(save, [BYPASS])
    doc = cmd.place(save, "seal", {"at": "audit"}, "S1", "c9")
    assert doc["params"]["at"] == "100,127,122 floor wall"
    cmd.write_bp(save, doc)
    a = plan.fort_facts(save, state)["audit"]
    assert (a["open"], a["pending"]) == ([], {"100,127,122 floor wall": "c9"})
    errs, warn = _gate(errs_of(prev, state, fort={"audit": a}, prev=prev))
    assert errs == [] and warn == [f"audit: {BYPASS}: seal project c9 builds the wall; dfllm audit once it stands"]
    with pytest.raises(cmd.BpError, match=r"left out \(a seal project builds them\): 100,127,122 \(c9\)"):
        cmd.seal_openings(save, "audit")                                  # never a second seal for the same tile
    assert plan.propose(state, None, prev, decisions={}, fort={"audit": a})["seasons"] == prev["seasons"]
    # c9 finished after this audit (the audit has not seen the wall yet): still covered
    append_events(save, [ev(8814, "PROJECT_DONE", "c9 done", {"proj": "c9", "tpl": "seal"}, tick=T_AUDIT + 100)])
    assert plan.fort_facts(save, state)["audit"]["open"] == []
    # a newer audit still names the tile after c9 was done: the wall is gone (or never stood), seal it again
    _audit(save, [BYPASS], n=8815, tick=T_AUDIT + 200)
    a = plan.fort_facts(save, state)["audit"]
    assert (a["open"], a["pending"]) == (["100,127,122 floor wall"], {})
    assert _gate(errs_of(prev, state, fort={"audit": a}, prev=prev))[0]
    # a route without a wall tile (stairs, doors): only a warning, no plan build can fix it
    _audit(save, ["bypass: edge->Z3/Z4 avoids the trap hall (reaches 1,2,3)"], n=8816, tick=T_AUDIT + 300)
    a = plan.fort_facts(save, state)["audit"]
    assert (a["routes"], a["walls"]) == (["bypass: edge->Z3/Z4 avoids the trap hall (reaches 1,2,3)"], [])
    errs, warn = _gate(errs_of(prev, state, fort={"audit": a}, prev=prev))
    assert errs == [] and len(warn) == 1 and "no wall tile on the route" in warn[0]


def test_audit_routes_fall_back_to_the_state(save, base):
    """No AUDIT event left (rotated away): the state's ready.route (readiness publishes the finding) is the source."""
    from dfpilot import cmd
    _, state = base
    for p in (save / "events.jsonl", save / "events.1.jsonl"):
        p.write_text("", encoding="utf-8")
    s = copy.deepcopy(state)
    s["ready"]["route"] = BYPASS
    assert schema.validate("state", s) == []
    a = cmd.audit_routes(save, s)
    assert (a["found"], a["routes"], a["open"]) == (False, [BYPASS], ["100,127,122 floor wall"])
    assert cmd.audit_routes(save, state)["routes"] == []


def test_propose_drafts_the_audit_seal_first(save, base):
    prev, state = base
    phases = json.loads((FIX / "phases.json").read_text("utf-8"))
    tinfo = {t: {"params": {}, "about": ""} for t in ("tombs", "temple", "stockroom", "seal")}
    _audit(save, [BYPASS])
    fort = plan.fort_facts(save, state)
    doc = plan.propose(_low_core(state), phases, prev, decisions={}, tinfo=tinfo, fort=fort)
    new = doc["seasons"][1]["build"][len(prev["seasons"][1]["build"]):]
    assert new[:2] == [SEAL, {"tpl": "stockroom", "site": "S1"}]          # the seal first, the stockroom after it
    assert _gate(errs_of(doc, state, fort=fort, prev=prev)) == ([], [])
    # an earlier seal (done) does not stop it: `done` is per (tpl, stage), the seal is per wall
    doc = plan.propose(state, phases, prev, decisions={}, tinfo=tinfo, fort=fort, applied={("seal", None)})
    assert doc["seasons"][1]["build"][len(prev["seasons"][1]["build"])] == SEAL
    # next year's plan: seasons[0]
    s4 = dict(state, t=dict(state["t"], y=4, season=0))
    assert plan.propose(s4, phases, prev, decisions={}, tinfo=tinfo, fort=fort)["seasons"][0]["build"][0] == SEAL


def test_apply_builds_the_audit_wall(save, base):
    """End to end with the real templates: the plan's seal at=audit emits a constructed wall on the audit's tile."""
    pytest.importorskip("dfpilot.bp.sites")
    from dfpilot import cmd
    _audit(save, [BYPASS])
    doc = _y4(base[0], [SEAL])
    errs, msg = plan.apply(save, doc, wait_s=0)
    assert errs == [], errs
    bp = json.loads((save / "bp" / "y4s0b0.json").read_text("utf-8"))
    assert bp["tpl"] == "seal" and bp["params"]["at"] == "100,127,122 floor wall"
    cells = [(ch["pos"][0] + c[0], ch["pos"][1] + c[1], ch["pos"][2] + c[2], c[3]) for st in bp["stages"]
             for ch in st["chunks"] for c in ch["cells"]]
    assert cells == [(100, 127, 122, "Cw")]
    assert "seal:piece" in (save / "cli.log").read_text("utf-8")
    assert cmd.audit_routes(save)["pending"] == {"100,127,122 floor wall": "y4s0b0"}


# ---------------------------------------------------------------- no P3+ without a separated refuge (Run 10)
STAGE3 = {"tpl": "fortcore", "site": "same", "p": {"stage": 3}}


def _ref(errs_warn):
    errs, warn = errs_warn
    return [e for e in errs if e.startswith("refuge")], [w for w in warn if w.startswith("refuge")]


def test_refuge_gate_blocks_p3_without_a_separated_refuge_with_beds(base):
    """Run 10: Tiefe+ was never usable (beds 8 < 27, open over the door 95,127,123), Kern+ lay on the attack path,
    at pop 110 there was no safe room. phase_target P3+ is refused until the plan (or a project under way) fixes what
    the refuge lacks (old code: no refuge check)."""
    prev, state = base
    want = "phase_target P4 (P3+) needs a separated refuge with beds for refuge.bed_pct of the citizens"
    doc = copy.deepcopy(prev)                                            # phase_target P4
    # no refuge burrow: fortcore stage 3 (the refuge) in this plan
    none = with_refuge(state, ex=0, sep=-1, beds=0)
    assert _ref(errs_of(doc, none, prev=prev)) == ([
        f'refuge: no refuge burrow (Tiefe+); {want}: add {{"tpl":"fortcore","site":"same","p":{{"stage":3}}}} (the '
        "refuge with O1 and B2; dfllm plan propose drafts it)"], [])
    fix = copy.deepcopy(doc)
    fix["seasons"][3]["build"].append(STAGE3)                           # any season of this year
    assert _ref(errs_of(fix, none, prev=prev)) == ([], [])
    assert _ref(errs_of(doc, none, prev=prev, fort={"refuge": {"stage3": True}})) == ([], [])   # under way
    low = copy.deepcopy(doc)
    low["phase_target"] = "P2"
    assert _ref(errs_of(low, none, prev=prev)) == ([], [])             # below P3: no gate
    # an opening reaches it: a seal (doors on the open ways in) in this plan or under way
    opened = with_refuge(state, sep=0)
    (e,), _ = _ref(errs_of(doc, opened, prev=prev))
    assert e == (f"refuge: an opening reaches Tiefe+ without a door (dfllm cmd inspect what=refuge: `open`); {want}: "
                 'add {"tpl":"seal","site":"S1","p":{"at":"last"}} (doors on the open ways in) or wall it')
    sealed = copy.deepcopy(doc)
    sealed["seasons"][1]["build"].append({"tpl": "seal", "site": "S1"})
    assert _ref(errs_of(sealed, opened, prev=prev)) == ([], [])
    assert _ref(errs_of(doc, opened, prev=prev, fort={"refuge": {"seal": True}})) == ([], [])
    assert _ref(errs_of(doc, with_refuge(state, sep=-1), prev=prev)) == (
        [], ["refuge: Tiefe+ separation not known yet (seal's first check); dfllm cmd inspect what=refuge"])
    # Run 10's beds: 8 < 28 (25 % of 110 citizens)
    beds = with_refuge(state, beds=8, need=28)
    (e,), _ = _ref(errs_of(doc, beds, prev=prev))
    assert e == (f'refuge: Tiefe+ has 8 beds < 28; {want}: add {{"tpl":"refuge_beds","site":"S1","p":{{"n":20}}}}')
    some = copy.deepcopy(doc)
    some["seasons"][1]["build"].append({"tpl": "refuge_beds", "site": "S1", "p": {"n": 10}})
    (e,), _ = _ref(errs_of(some, beds, prev=prev))
    assert 'has 8 beds < 28 (+10 planned)' in e and '"p":{"n":10}' in e
    some["seasons"][2]["build"].append({"tpl": "refuge_beds", "site": "S1", "p": {"n": 10}})
    assert _ref(errs_of(some, beds, prev=prev)) == ([], [])
    assert _ref(errs_of(doc, beds, prev=prev, fort={"refuge": {"beds": 20}})) == ([], [])
    (e,), _ = _ref(errs_of(doc, with_refuge(state, beds=0, need=70), prev=prev))
    assert '"p":{"n":30}' in e and "(3 rooms of <= 30)" in e
    assert _ref(errs_of(doc, with_refuge(state), prev=prev)) == ([], [])          # separated, beds enough
    # the applied refuge_beds of this year's plan count only while under way (fort.refuge.beds), never twice
    applied = copy.deepcopy(prev)
    applied["seasons"][1]["build"].append({"tpl": "refuge_beds", "site": "S1", "p": {"n": 20}})
    assert _ref(errs_of(applied, beds, prev=applied))[0]


def test_refuge_projects_under_way(save, base):
    from dfpilot import cmd
    _, state = base

    def stub(bid, tpl, params):
        return {"v": 2, "id": bid, "tpl": tpl, "site": "S1", "class": "living", "params": params,
                "anchor": [50, 33, 120], "rot": 0, "stages": [{"label": "s.dig", "mode": "dig", "orders": 0,
                "defense": 0, "chunks": [{"pos": [52, 30, 120], "cells": [[0, 0, 0, "d"]]}]}],
                "manifest": {"v": 2}, "materials": {}}
    f = plan.fort_facts(save, state)["refuge"]
    assert f == {"stage3": False, "beds": 0, "seal": False, "fortcore": True, "ents": 0,   # fixture: fortcore at s2
                 "seal_n": 0, "refuge_n": 0, "open": [], "burrow": "", "head": None, "head_open": False,
                 "head_state": None, "head_man": None, "head_note": "",             # BUG-123/124
                 "bed_site": None, "drink": 0, "drink_room": False, "drink_fit": None, "drink_why": None}   # FR-69
    assert plan.fort_facts(save, {**state, "proj": []})["refuge"]["fortcore"] is False
    cmd.write_bp(save, stub("c1", "fortcore", {"stage": 3, "depth": 3, "refuge": 3, "beds": 8, "retrofit": 0}))
    cmd.write_bp(save, stub("c2", "refuge_beds", {"n": 12, "burrow": "Tiefe+"}))
    cmd.write_bp(save, stub("c3", "refuge_beds", {"n": 6, "burrow": "Tiefe+"}))
    cmd.write_bp(save, stub("c4", "fortcore", {"stage": 3, "depth": 3, "refuge": 3, "beds": 8, "retrofit": 2}))
    f = plan.fort_facts(save, {**state, "proj": []})["refuge"]
    assert (f["stage3"], f["beds"], f["seal"]) == (True, 18, False)
    append_events(save, [ev(8813, "PROJECT_DONE", "c1 done", {"proj": "c1"}),
                         ev(8814, "PROJECT_DONE", "c3 done", {"proj": "c3"})])
    f = plan.fort_facts(save, {**state, "proj": []})["refuge"]
    assert (f["stage3"], f["beds"]) == (False, 12)                       # done: its beds count in alert.ref now
    f = plan.fort_facts(save, {**state, "proj": [["fortcore", "s3.dig", 10, ""]]})["refuge"]
    assert f["stage3"] is True                                           # adopt's fortcore project, stage 3 running


def test_fort_facts_read_the_refuge_fail_and_the_seal_count(save, base):
    """Run 11: fort.refuge.open/burrow from a current REFUGE_FAIL, seal_n = what `seal at=last` would close now."""
    _, state = base
    refused = dict(with_refuge(state), alert={"want": "Kern+", "burrow": "Innen+", "tiles": 90, "inside": 4, "ok": 0,
                                              "ref": {"ex": 1, "sep": 1, "beds": 13, "need": 13}})
    append_events(save, [ev(8813, "REFUGE_FAIL", "alert burrow Kern+ refused", {
        "burrow": "Kern+", "fallback": "Innen+", "why": "open to 1 entrance 127,121,143 Door (62 steps)",
        "open": ["127,121,143 Door"]}), ev(8814, "SIEGE_UNREADY", "siege unready", {
        "fails": ["bypass"], "routes": 2, "open": 2, "ents": ["188,103,144 floor", "125,103,144 floor"]})])
    f = plan.fort_facts(save, refused)["refuge"]
    assert (f["open"], f["burrow"], f["seal_n"]) == (["127,121,143 Door"], "Kern+", 2)  # the door: no snapshot there
    assert plan.fort_facts(save, with_refuge(state))["refuge"]["open"] == []           # the alert's burrow passes now


def test_refuge_stair_head_needs_its_hatch(base):
    """BUG-031: fortcore's Tiefe+ hangs below Kern+ on the civilians' stair without a closer. While `seal at=refuge`
    would put a hatch on the stair head (fort.refuge.head_open), the plan needs a seal that does (at=refuge/all or the
    tile), no later than its first other new build; propose drafts it first."""
    prev, state = base
    s1 = dict(with_refuge(state), phase="P1")
    fort = {"refuge": {"head": "50,65,3 stair_updown", "head_open": True, "refuge_n": 1, "seal_n": 0}}
    doc = copy.deepcopy(prev)
    doc["phase_target"] = "P1"
    doc["seasons"][1]["build"].append({"tpl": "dining", "site": "S1"})
    (e,), _ = _ref(errs_of(doc, s1, prev=prev, fort=fort))
    assert e == ("refuge: the civilians' stair enters Tiefe+ below 50,65,3 without a hatch (whatever reaches Kern+ "
                 "reaches it, BUG-031); the refuge comes first (Run 11): adding builds (dining) waits for it: add "
                 '{"tpl":"seal","site":"S1","p":{"at":"refuge"}} (the hatch at its stair head and the REFUGE_FAIL tiles)')
    for at, ok in (("refuge", True), ("all", True), ("50,65,3 stair_updown", True), ("last", False)):
        d = copy.deepcopy(doc)
        d["seasons"][1]["build"].insert(len(prev["seasons"][1]["build"]), {"tpl": "seal", "site": "S1", "p": {"at": at}})
        assert (_ref(errs_of(d, s1, prev=prev, fort=fort))[0] == []) is ok, at
    phases = json.loads((FIX / "phases.json").read_text("utf-8"))
    tinfo = {t: {"params": {"stage": 1} if t == "fortcore" else {}, "about": ""}
             for t in ("fortcore", "tombs", "temple", "seal", "refuge_beds", "stockroom")}
    got = plan.propose(dict(with_refuge(state)), phases, prev, decisions={}, tinfo=tinfo, fort=fort)
    assert got["seasons"][1]["build"][len(prev["seasons"][1]["build"])] == {"tpl": "seal", "site": "S1",
                                                                            "p": {"at": "refuge"}}


def test_propose_drafts_the_refuge_first(save, base):
    prev, state = base
    phases = json.loads((FIX / "phases.json").read_text("utf-8"))
    tinfo = {t: {"params": {"stage": 1} if t == "fortcore" else {}, "about": ""}
             for t in ("fortcore", "tombs", "temple", "seal", "refuge_beds", "stockroom")}

    def new(doc):
        return doc["seasons"][1]["build"][len(prev["seasons"][1]["build"]):]

    fort = {"refuge": {"fortcore": True, "stage3": False, "beds": 0, "seal": False, "ents": 2}}
    doc = plan.propose(with_refuge(state, ex=0, sep=-1, beds=0), phases, prev, decisions={}, tinfo=tinfo, fort=fort)
    assert new(doc)[0] == STAGE3 and sum(b == STAGE3 for se in doc["seasons"] for b in se["build"]) == 1
    assert _ref(errs_of(doc, with_refuge(state, ex=0, sep=-1, beds=0), prev=prev, fort=fort)) == ([], [])
    beds = with_refuge(state, beds=8, need=28)
    doc = plan.propose(beds, phases, prev, decisions={}, tinfo=tinfo, fort=fort)
    assert new(doc)[0] == {"tpl": "refuge_beds", "site": "S1", "p": {"n": 20}}
    assert _ref(errs_of(doc, beds, prev=prev, fort=fort)) == ([], [])
    doc = plan.propose(with_refuge(state, beds=0, need=40), phases, prev, decisions={}, tinfo=tinfo, fort=fort)
    assert [b["p"]["n"] for b in doc["seasons"][1]["build"] + doc["seasons"][2]["build"]
            if b["tpl"] == "refuge_beds"] == [30, 10]
    doc = plan.propose(with_refuge(state, sep=0), phases, prev, decisions={}, tinfo=tinfo, fort=fort)
    assert new(doc)[0] == {"tpl": "seal", "site": "S1", "p": {"at": "last"}}
    # the audit's seal stays the very first build
    _audit(save, [BYPASS])
    both = dict(fort, audit=plan.fort_facts(save, state)["audit"])
    doc = plan.propose(beds, phases, prev, decisions={}, tinfo=tinfo, fort=both)
    assert new(doc)[:2] == [SEAL, {"tpl": "refuge_beds", "site": "S1", "p": {"n": 20}}]
    # nothing to draft: separated with beds; refuge beds under way; no fortcore to anchor stage 3 on; below P3
    for st, ft in ((with_refuge(state), fort), (beds, {"refuge": dict(fort["refuge"], beds=20)}),
                   (with_refuge(state, ex=0, sep=-1, beds=0), {"refuge": dict(fort["refuge"], fortcore=False)}),
                   (with_refuge(state, sep=0), {"refuge": dict(fort["refuge"], ents=0)})):
        got = [b for b in new(plan.propose(st, phases, prev, decisions={}, tinfo=tinfo, fort=ft)) if b != STAGE3]
        # (stage 3 is a P3 deliverable now, DECISIONS 1: the fixture state is at P3, so the draft brings it as well)
        assert got[0] == {"tpl": "tombs", "site": "S1"} and all(b["tpl"] not in ("refuge_beds", "seal") for b in got)
    early = copy.deepcopy(phases)
    for ph in early["phases"]:
        ph["approve"] = ph["id"] >= "P3"
    s1 = dict(beds, phase="P1")
    doc = plan.propose(s1, early, prev, decisions={}, tinfo=tinfo, fort=fort)
    # Run 11: from the fort's start the refuge pieces come before the P1/P2 work (old code: none below P3)
    assert doc["phase_target"] == "P2" and new(doc)[0] == {"tpl": "refuge_beds", "site": "S1", "p": {"n": 20}}
    assert _ref(errs_of(doc, s1, prev=prev, fort=fort)) == ([], [])
    nosite = {"refuge": dict(fort["refuge"], bed_site=False)}         # no refuge room yet: no refuge_beds, a warning
    doc = plan.propose(s1, early, prev, decisions={}, tinfo=tinfo, fort=nosite)
    assert not any(b["tpl"] == "refuge_beds" for se in doc["seasons"] for b in se["build"])
    assert _ref(errs_of(doc, s1, prev=prev, fort=nosite)) == ([], [
        "refuge: Tiefe+ has 8 beds < 28; no refuge room takes refuge_beds yet (fortcore stage 3 builds it; dfllm bp "
        "sites refuge_beds)"])
    # below P3 no refuge burrow is no gate (fortcore stage 3 belongs to P3, DECISIONS 1)
    none1 = dict(with_refuge(state, ex=0, sep=-1, beds=0), phase="P1")
    doc = plan.propose(none1, early, prev, decisions={}, tinfo=tinfo, fort=fort)
    assert STAGE3 not in [b for se in doc["seasons"] for b in se["build"]]
    assert _ref(errs_of(doc, none1, prev=prev, fort=fort)) == ([], [])
    # the open door of a current REFUGE_FAIL (Run 11: `Kern+: open to 1 entrance 127,121,143 Door`): the seal first
    opened = {"refuge": dict(fort["refuge"], open=["127,121,143 Door"], burrow="Kern+", seal_n=1)}
    doc = plan.propose(dict(with_refuge(state), phase="P1"), early, prev, decisions={}, tinfo=tinfo, fort=opened)
    assert new(doc)[0] == {"tpl": "seal", "site": "S1", "p": {"at": "last"}}


def test_refuge_gate_from_the_forts_start(base):
    """Run 11 (Kilrudrabed, y429, pop 54): the refuge stood open and short of beds while the plans went on with P1
    work. Below P3, once the refuge burrow exists, a plan that raises phase_target or adds builds is refused until its
    refuge pieces come no later than its first other new build (old code: no refuge check below P3)."""
    prev, state = base
    s1 = dict(with_refuge(state, sep=0), phase="P1")
    want = "the refuge comes first (Run 11): adding builds (dining) waits for it"
    doc = copy.deepcopy(prev)
    doc["phase_target"] = "P1"
    doc["seasons"][1]["build"].append({"tpl": "dining", "site": "S1"})
    seal_err = (f"refuge: an opening reaches Tiefe+ without a door (dfllm cmd inspect what=refuge: `open`); {want}: "
                'add {"tpl":"seal","site":"S1","p":{"at":"last"}} (doors on the open ways in) or wall it')
    assert _ref(errs_of(doc, s1, prev=prev)) == ([seal_err], [])
    nothing = copy.deepcopy(prev)
    nothing["phase_target"] = "P1"                                        # adds nothing, raises nothing: a warning
    (w,) = _ref(errs_of(nothing, s1, prev=prev))[1]
    assert w.startswith("refuge: an opening reaches Tiefe+ without a door") and "the refuge comes first (Run 11):" in w
    first = copy.deepcopy(doc)
    first["seasons"][1]["build"].insert(len(prev["seasons"][1]["build"]), {"tpl": "seal", "site": "S1"})
    assert _ref(errs_of(first, s1, prev=prev)) == ([], [])
    later = copy.deepcopy(doc)
    later["seasons"][2]["build"].append({"tpl": "seal", "site": "S1"})
    (e,), _ = _ref(errs_of(later, s1, prev=prev))
    assert e == seal_err + " (planned in seasons[2]: move it to seasons[1], before the other new builds)"
    audit_only = copy.deepcopy(doc)
    audit_only["seasons"][1]["build"].append({"tpl": "seal", "site": "S1", "p": {"at": "audit"}})
    assert _ref(errs_of(audit_only, s1, prev=prev))[0] == [seal_err]    # at=audit walls the audit's routes only
    assert _ref(errs_of(doc, s1, prev=prev, fort={"refuge": {"seal": True}})) == ([], [])   # one under way
    # `seal at=last` finds nothing to close now (pending, built, no closable tile): a warning, no build can fix it
    errs, warn = _ref(errs_of(doc, s1, prev=prev, fort={"refuge": {"seal_n": 0}}))
    assert errs == [] and warn == ["refuge: an opening reaches Tiefe+ without a door (dfllm cmd inspect what=refuge: "
                                   "`open`); `seal at=last` finds nothing to close now (pending, built or no closable "
                                   "tile: dfllm cmd inspect what=refuge, what=entrances)"]
    # one under way but `seal at=last` still finds openings it does not cover: a new seal
    assert _ref(errs_of(doc, s1, prev=prev, fort={"refuge": {"seal": True, "seal_n": 2}}))[0] == [seal_err]
    # a current REFUGE_FAIL names the open door of the alert's burrow (Tiefe+ itself separated)
    rf = {"refuge": {"open": ["127,121,143 Door"], "burrow": "Kern+", "seal_n": 1}}
    (e,), _ = _ref(errs_of(doc, dict(with_refuge(state), phase="P1"), prev=prev, fort=rf))
    assert e.startswith(f"refuge: Kern+ is open to 127,121,143 Door (REFUGE_FAIL); {want}: add ")
    # beds short: refuge_beds first, unless no refuge room takes them yet
    b1 = dict(with_refuge(state, beds=4, need=14), phase="P1")
    (e,), _ = _ref(errs_of(doc, b1, prev=prev))
    assert e == f'refuge: Tiefe+ has 4 beds < 14; {want}: add {{"tpl":"refuge_beds","site":"S1","p":{{"n":10}}}}'
    assert _ref(errs_of(doc, b1, prev=prev, fort={"refuge": {"bed_site": False}}))[0] == []
    beds = copy.deepcopy(doc)
    beds["seasons"][1]["build"].append({"tpl": "refuge_beds", "site": "S1", "p": {"n": 10}})
    assert _ref(errs_of(beds, b1, prev=prev)) == ([], [])
    # raising phase_target without builds is P1 work going on too
    up = copy.deepcopy(prev)
    up["phase_target"] = "P2"
    (e,), _ = _ref(errs_of(up, b1, prev=prev))
    assert "the refuge comes first (Run 11): raising phase_target P1 -> P2 waits for it" in e
    # P3+: the pieces may not come after the plan's other new builds either
    late = copy.deepcopy(prev)
    late["seasons"][1]["build"].append({"tpl": "temple", "site": "S1"})        # BUG-125: tombs/hospital/food never count
    late["seasons"][2]["build"].append({"tpl": "refuge_beds", "site": "S1", "p": {"n": 10}})
    (e,), _ = _ref(errs_of(late, with_refuge(state, beds=4, need=14), prev=prev))
    assert e.endswith("(planned in seasons[2]: move it to seasons[1], before the other new builds)")
