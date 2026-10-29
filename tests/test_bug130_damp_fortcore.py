"""BUG-130 (Run 9 site96 and the Run 14 replay y707 site90: "y707s0b1 (fortcore) blocked: breach:damp"): the fortcore's
dig met aquifer seepage, the project was parked for good and nothing re-sited it. Without O1/B1 readiness kept R0
no_outer/no_inner, every drill was refused and R2 and the military goals were out of reach for the rest of the run.
Now the kernel remembers every breach tile (manifest `breaches`), the fortcore ranking keeps a new fortcore away from
them, `plan propose` re-sites a fortcore stopped on a breach (fortcore stage 1 @S1, its later stages @same) or, with no
dry site left, closes the ways in by wall + door (`seal at=last`) and keeps the phase below P3, and `plan check` no longer
demands a stage on the parked anchor."""
import copy
import json
import sys
from pathlib import Path

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import bp, cmd, fairplay, files, plan, schema
from dfpilot.bp.primitives import Xform

sys.path.insert(0, str(Path(__file__).parent / "bp"))
from bp_fixtures import terrain  # noqa: E402

ROOT = fairplay.REPO
PID = "y707s0b1"
DAMP = [87, 59, 5]


@pytest.fixture(scope="module")
def land():
    return terrain().snapshot(purpose="sites")


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def _breach(pos, proj=PID, why="damp", tpl="fortcore"):
    return {"pos": list(pos), "why": why, "proj": proj, "tpl": tpl}


# ---------------------------------------------------------------- the contract
def test_the_manifest_carries_breaches():
    m = {"v": 2, "breaches": [_breach(DAMP)], "caverns": [[1, 2, 3]]}
    assert schema.validate("manifest", m) == []
    assert schema.validate("manifest", {"v": 2, "breaches": [{"pos": [1, 2]}]}) != []
    contracts = (ROOT / "docs" / "v2" / "CONTRACTS.md").read_text("utf-8")
    assert "| `breaches?` |" in contracts


# ---------------------------------------------------------------- the fortcore ranking
def test_the_fortcore_ranking_keeps_away_from_a_recorded_breach(land):
    best = bp.rank(land, "fortcore")[0]
    hub = list(Xform(best["anchor"], best["rot"]).pos(2, 45, -5))          # the core hub of the best site
    man = {"v": 2, "breaches": [_breach(hub)]}
    sites = bp.rank(land, "fortcore", manifest=man, n=10)
    assert sites, "other sites stay"
    assert all(s["anchor"] != best["anchor"] for s in sites)
    for s in sites:                                     # no candidate's dig comes within BREACH_R of the breach
        assert max(abs(s["anchor"][0] - hub[0]), abs(s["anchor"][1] - hub[1])) > 12
    # a breach on a level the dig never reaches (two above the surface entrance) keeps nothing out
    deep = {"v": 2, "breaches": [_breach([hub[0], hub[1], 12])]}
    assert bp.rank(land, "fortcore", manifest=deep)[0]["anchor"] == best["anchor"]


def test_no_dry_fortcore_site_is_named(land):
    pts = [_breach([x, y, 5], proj=f"p{x}x{y}") for x in range(0, 100, 15) for y in range(0, 100, 15)][:32]
    with pytest.raises(ValueError, match="no dry fortcore site"):
        bp.rank(land, "fortcore", manifest={"v": 2, "breaches": pts})


def test_two_damp_stops_on_one_level_make_it_a_wet_layer(land):
    one = {"v": 2, "breaches": [_breach([5, 5, 5], proj="a")]}
    assert bp.rank(land, "fortcore", manifest=one)                        # one pocket far away: sites stay
    two = {"v": 2, "breaches": [_breach([5, 5, 5], proj="a"), _breach([5, 95, 5], proj="b")]}
    with pytest.raises(ValueError, match="wet level z5"):
        bp.rank(land, "fortcore", manifest=two)                           # every core here digs through z5
    warm = {"v": 2, "breaches": [_breach([5, 5, 5], proj="a", why="warm"), _breach([5, 95, 5], proj="b", why="warm")]}
    assert bp.rank(land, "fortcore", manifest=warm)                       # warm stone is no water layer


# ---------------------------------------------------------------- the save folder facts
def _damp_core(save, stage=1, pid=PID, anchor=(48, 30, 130)):
    doc = json.loads((save / "bp" / "y3s0b0.json").read_text("utf-8"))
    doc.update(id=pid, tpl="fortcore", site="S1", anchor=list(anchor), rot=0, params={"stage": stage},
               manifest={"v": 2})
    (save / "bp" / f"{pid}.json").write_text(json.dumps(doc), "utf-8")


def _state(save, row=None, phase="P0"):
    s = copy.deepcopy(files.read_state(save))
    s["phase"] = phase
    s["proj"] = [row or [PID, "s1.dig", 0, "parked: breach:damp"]]
    s["ready"] = {"lvl": 0, "fail": ["no_inner", "no_outer"]}
    s["bridges"] = {}
    return s


def test_core_breaches_from_the_manifest_the_state_and_the_events(save):
    _damp_core(save)
    st = _state(save)
    got = plan.core_breaches(save, st)
    assert [(b["proj"], b["stage"], b["why"]) for b in got] == [(PID, 1, "damp")]
    files.write_json_atomic(save / "manifest.json", {"v": 2, "breaches": [_breach(DAMP)]})
    got = plan.core_breaches(save, {**st, "proj": []})                     # the row cut off: the manifest says it
    assert [(b["proj"], b["why"], b["pos"]) for b in got] == [(PID, "damp", DAMP)]
    (save / "manifest.json").unlink()
    assert plan.core_breaches(save, {**st, "proj": []}) == []
    # a cancelled (retired: bp/.cancelled) project is no stopped fortcore any more (BUG-162: a bp file that is merely
    # missing while the kernel's manifest names the row still counts, see test_bug162_164_fortcore_resite.py)
    files.write_json_atomic(save / "manifest.json", {"v": 2, "breaches": [_breach(DAMP)]})
    assert cmd.retire(save, PID)
    assert plan.core_breaches(save, st) == []


def _facts(save, monkeypatch, st, sites=True):
    def fake(save_dir, tpl, params=None, snap=None, n=3, where=None, taken=None):
        assert tpl == "fortcore" and (params or {}).get("stage") == 1
        if sites is True:
            return [{"id": "S1", "anchor": [10, 10, 130], "rot": 0}], "c201", 3
        if sites is False:
            return [], "c201", 0
        raise cmd.BpError("bp.sites.rank(fortcore): fortcore: no dry fortcore site: every site lies within 10 tiles "
                          "of a recorded breach (damp 87,59,5 y707s0b1)")
    monkeypatch.setattr(cmd, "free_sites", fake)
    return plan.fort_facts(save, st)


def _builds(doc):
    return [b for se in doc["seasons"] for b in se["build"]]


def test_propose_resites_a_fortcore_stopped_on_damp(save, monkeypatch):
    _damp_core(save)
    st = _state(save)
    fort = _facts(save, monkeypatch, st)
    assert fort["core"]["resite"] is True and fort["core"]["ok"] is True
    doc = plan.propose(st, plan.load_phases(), None, decisions={}, applied=plan.applied_builds(save, st), fort=fort)
    cores = [b for b in _builds(doc) if b["tpl"] == "fortcore"]
    assert cores[0] == {"tpl": "fortcore", "site": "S1", "p": {"stage": 1}}, "stage 1 re-sited first"
    assert all(b["site"] == "same" for b in cores[1:]) and [b["p"]["stage"] for b in cores] == [1, 2, 3]
    assert "BUG-130" in doc["notes"] and f"bp.cancel proj={PID}" in doc["notes"] and "breach:damp" in doc["notes"]
    errs, warn = plan.check(doc, st, decisions={}, banned=plan.BANNED, fort=fort)
    assert not [e for e in errs if e.startswith("fortcore")], errs


def test_propose_closes_the_ways_in_when_no_dry_site_is_left(save, monkeypatch):
    _damp_core(save)
    st = _state(save)
    fort = _facts(save, monkeypatch, st, sites=None)
    assert fort["core"]["ok"] is False and "no dry fortcore site" in fort["core"]["why"]
    fort["refuge"]["seal_n"] = 2                       # two ways in without a door
    doc = plan.propose(st, plan.load_phases(), None, decisions={}, applied=plan.applied_builds(save, st), fort=fort)
    b = _builds(doc)
    assert not [x for x in b if x["tpl"] == "fortcore"], "nothing on the damp anchor"
    assert {"tpl": "seal", "site": "S1", "p": {"at": "last"}} in b
    assert doc["phase_target"] < "P3", "no P3 without a refuge, and none can be built"
    assert "no_outer" in doc["notes"] and "seal at=last" in doc["notes"]
    errs, warn = plan.check(doc, st, decisions={}, banned=plan.BANNED, fort=fort)
    assert not [e for e in errs if "fortcore" in e], errs
    assert any(w.startswith("fortcore: no dry site") and "no_outer/no_inner" in w and "drill" in w for w in warn), warn


def test_check_refuses_a_stage_on_the_parked_anchor(save, monkeypatch):
    _damp_core(save)
    st = _state(save)
    fort = _facts(save, monkeypatch, st)
    doc = plan.propose(st, plan.load_phases(), None, decisions={}, applied=plan.applied_builds(save, st), fort=fort)
    for se in doc["seasons"]:                       # the stages @same without the re-sited stage 1 in front
        se["build"] = [x for x in se["build"] if not (x["tpl"] == "fortcore" and x["site"] == "S1")]
    errs, _ = plan.check(doc, st, decisions={}, banned=plan.BANNED, fort=fort)
    assert any(e.startswith(f"fortcore: {PID}") and "@same" in e and "re-site" in e for e in errs), errs


def test_a_parked_stage3_is_not_under_way(save, monkeypatch):
    _damp_core(save, stage=3, pid="y707s0b2")
    _damp_core(save)
    st = _state(save)
    st["proj"].append(["y707s0b2", "s3.dig", 0, "parked: breach:damp"])
    fort = _facts(save, monkeypatch, st)
    assert fort["refuge"]["stage3"] is False and fort["o1"] is False


def test_the_core_order_note_ignores_a_parked_core():
    doc = {"seasons": [{"build": [{"tpl": "farms", "site": "S1"}]}]}
    assert plan.core_order_note(doc, {"proj": [[PID, "s1.dig", 0, "parked: breach:damp"]]}) is None
    assert plan.core_order_note(doc, {"proj": [[PID, "s1.dig", 10, ""]]})


def test_rules_say_what_counts_for_the_gates():
    rules = (ROOT / "RULES.md").read_text("utf-8")
    assert "BUG-130" in rules and "breach:damp" in rules
    assert len(rules.splitlines()) <= 300


def test_an_applied_resite_is_never_drafted_again(save, monkeypatch):
    # review: the re-site was applied (a new fortcore stage 1 digs elsewhere) but the parked one is not cancelled yet:
    # propose must not draft a second fortcore stage 1 @S1, and check refuses one
    _damp_core(save)
    _damp_core(save, pid="y707s1b0", anchor=(10, 10, 130))
    st = _state(save)
    st["proj"].append(["y707s1b0", "s1.dig", 5, ""])
    fort = _facts(save, monkeypatch, st)
    assert fort["core"]["moved"]["proj"] == "y707s1b0"
    doc = plan.propose(st, plan.load_phases(), None, decisions={}, applied=plan.applied_builds(save, st), fort=fort)
    # BUG-163: its later stages are drafted at the moved core's explicit anchor, never a second stage 1
    assert not [b for b in _builds(doc) if plan._resite(b)], _builds(doc)
    assert f"bp.cancel proj={PID}" in doc["notes"]
    doc["seasons"][0]["build"].append({"tpl": "fortcore", "site": "S1", "p": {"stage": 1}})
    errs, _ = plan.check(doc, st, decisions={}, banned=plan.BANNED, fort=fort)
    assert any("second fortcore" in e for e in errs), errs
