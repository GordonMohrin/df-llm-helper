"""WP2 plan propose|check|apply: schema, semantic validators, fair play, pop_ceiling <= R-level cap."""
import copy
import json

import pytest
from cli_v2_helpers import FIX, FakeKern, inbox_docs, install_fake_bp, make_runtime, reset_paths

from df_llm_helper import files, plan, schema


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
def test_fixture_plan_passes(base):
    doc, state = base
    errs, warn = errs_of(doc, state, tpls=["workshops", "hospital", "bedrooms", "tavern"])
    assert errs == [] and warn == []


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
    assert doc["seasons"][1]["build"] == prev["seasons"][1]["build"] + [
        {"tpl": "tombs", "site": "S1"}, {"tpl": "temple", "site": "S1"},
        {"tpl": "fortcore", "site": "same", "p": {"stage": 3}}]
    assert doc["orders"]["import"] == ["library/furnace", "library/smelting", "library/military"]
    assert plan.stable_ids(doc, prev) == []
    # year 4: hospital (y3s0b1, running), bedrooms and tavern were applied in y3 -> never drafted again
    s4 = dict(state, t=dict(state["t"], y=4, season=0))
    for nxt in (plan.propose(s4, phases, prev, decisions={}, tinfo=tinfo),
                plan.propose(s4, phases, None, decisions={}, tinfo=tinfo, applied=plan.applied_builds(save, s4))):
        built = [b for se in nxt["seasons"] for b in se["build"]]
        assert nxt["year"] == 4 and built == [{"tpl": "tombs", "site": "S1"}, {"tpl": "temple", "site": "S1"},
                                              {"tpl": "fortcore", "site": "same", "p": {"stage": 3}}], built
    applied = plan.applied_builds(save, state)
    assert {("hospital", None), ("bedrooms", None), ("tavern", None), ("workshops", None)} <= applied
    assert ("fortcore", 2) in applied                     # proj 'fortcore' at s2.build (no bp file)
    assert doc["policy"] == {"option": "A", "pop_ceiling": 55, "beauty": "used_rooms"}
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
    pytest.importorskip("df_llm_helper.bp.sites")
    from df_llm_helper import cmd
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
    from df_llm_helper import cmd
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
        monkeypatch.setitem(sys.modules, f"df_llm_helper.bp.{m}", None)
    doc, _ = base
    doc["year"] = 4
    errs, _ = plan.apply(save, doc, wait_s=0)
    assert errs and "blueprint" in errs[0] and "not available" in errs[0]
    doc["seasons"] = [{"build": []} for _ in range(4)]
    errs, msg = plan.apply(save, doc, wait_s=0)                     # no builds: no bp needed
    assert errs == [] and "no reply yet" in msg and inbox_docs(save)[0]["verb"] == "plan.reload"


def test_plan_cli_propose_check_apply(save, monkeypatch, capsys):
    from df_llm_helper.cli import main
    install_fake_bp(monkeypatch)
    rt = str(save.parent)
    assert main(["--runtime", rt, "plan", "propose", "--phases", str(FIX / "phases.json")]) == 0
    out = capsys.readouterr().out
    assert "draft" in out and "target P5" in out and "dfllm plan check" in out
    assert (save / "plan.draft.json").exists()
    assert main(["--runtime", rt, "plan", "check"]) == 0
    out = capsys.readouterr().out
    assert "plan OK" in out and "tombs@S1 -> y3s1b1 at [" in out and "kept y3s0b0" in out   # placement dry run
    assert main(["--runtime", rt, "plan", "apply", "--dry-run"]) == 0
    assert "dry run ok: 3 blueprint(s)" in capsys.readouterr().out
    bad = json.loads((save / "plan.draft.json").read_text("utf-8"))
    bad["policy"]["pop_ceiling"] = 99
    files.write_json_atomic(save / "bad.json", bad)
    assert main(["--runtime", rt, "plan", "check", str(save / "bad.json")]) == 1
    out = capsys.readouterr().out
    assert "ERROR" in out and "REJECTED" in out
