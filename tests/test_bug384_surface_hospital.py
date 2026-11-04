"""Run 16 (04.11.2026, fix round 20).
BUG-384: Run 16c i3 had 7 hurt citizens, a patient's thirst up to 23,500 and 'hospital: 0 sites without a fortcore': every
hospital site hung on the dug Z4 floor of a fortcore. The `hospital` template takes p.surface = 1 (a 7x5 block of open surface
floor, nothing dug, no door, no burrow, no well), its sites follow the accepted water like the dug hospital's, and
`plan propose` drafts it for a fort with patients, no hospital zone and no dug core."""
from __future__ import annotations

import copy
from pathlib import Path

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import bp, cmd, files, plan, schema


@pytest.fixture(autouse=True)
def _surface_core_on(monkeypatch):
    """BUG-413: the surface core and the surface room variants are drafted only with plan.surface_core true (default false); these
    tests are about those variants."""
    monkeypatch.setattr(plan, "surface_core_on", lambda: True)


X0, Y0, Z = 100, 100, 130
W, H = 40, 30


def _snap(far=(), sid="s384") -> dict:
    rows = [["." for _ in range(W)] for _ in range(H)]
    snap = {"v": 2, "id": sid, "tick": 1, "purpose": "sites", "bbox": [X0, Y0, Z - 1, X0 + W - 1, Y0 + H - 1, Z + 1],
            "rows": {f"z{Z - 1}": ["#" * W for _ in range(H)], f"z{Z}": ["".join(r) for r in rows],
                     f"z{Z + 1}": ["_" * W for _ in range(H)]}, "marks": {}}
    if far:
        wg = [list("1" * W) for _ in range(H)]
        for x, y in far:
            wg[y - Y0][x - X0] = "0"
        snap["wg"] = {"home": 7, "rows": {f"z{Z}": ["".join(r) for r in wg]}}
    return snap


def test_surface_hospital_template_digs_nothing_and_lists_a_hospital_room():
    doc = bp.emit("hospital", {"surface": 1}, {"id": "S1", "anchor": [110, 110, Z], "rot": 0})
    assert [st["mode"] for st in doc["stages"]] == ["build", "zone"] and doc["class"] == "living"
    cells = [c for st in doc["stages"] for ch in st["chunks"] for c in ch["cells"]]
    assert [c[3] for c in cells].count("b") == 4 and any("location=hospital" in str(c[3]) for c in cells)
    assert "zones" not in doc["manifest"], "no Z4: nothing is dug"
    room = doc["manifest"]["rooms"][0]
    assert room["tpl"] == "hospital" and room["bbox"] == [110, 110, Z, 116, 114, Z]
    assert schema.validate("bp", dict(doc, id="y1s0b3")) == [] and bp.validate(dict(doc, id="y1s0b3")) == []
    dug = bp.emit("hospital", {}, {"id": "S1", "anchor": [110, 110, Z], "rot": 0})
    assert any(st["mode"] == "dig" for st in dug["stages"]), "the dug hospital is unchanged"


def test_surface_hospital_sites_need_no_fortcore_but_accepted_water():
    snap = _snap()
    water = {"src": [[125, 112, Z]], "near": 30}
    found = bp.rank(snap, "hospital", {"surface": 1}, n=3, water=water)               # no manifest: a room template would raise
    assert found and "7x5 open surface floor for a hospital" in found[0]["why"] and found[0]["water"]["d"] <= 30
    with pytest.raises(ValueError, match="room sites need the fort manifest"):
        bp.rank(snap, "hospital", {}, n=3, water=water)                                # the dug hospital still needs Z4
    with pytest.raises(ValueError, match="no accepted water"):
        bp.rank(snap, "hospital", {"surface": 1}, n=3, water={"src": [], "near": 30})  # a dry hospital is worse than none
    far = [(x, y) for x in range(X0, X0 + W) for y in range(Y0, Y0 + H)]
    with pytest.raises(ValueError, match="no valid site"):                              # nothing the citizens reach
        bp.rank(_snap(far=far), "hospital", {"surface": 1}, n=3, water=water)
    assert "7x5 block of open surface floor" in cmd.no_site_hint(Path("."), "hospital", "s1", 0, [], {"surface": 1})


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    snap = _snap()
    monkeypatch.setattr(cmd, "sites_snapshot", lambda _d: snap)
    monkeypatch.setattr(plan, "sites_snapshot", lambda _d: snap)
    yield d
    reset_paths()


def test_a_surface_hospital_is_placed_without_any_fortcore(save):
    doc = cmd.emit_bp(save, "hospital", {"surface": 1}, "S1", "c1a1a6b000000000bb", write=True, snap=_snap())
    assert doc["tpl"] == "hospital" and doc["params"]["surface"] == 1 and doc["manifest"]["rooms"][0]["tpl"] == "hospital"


def _p0_state(save, patients=3, hosp=0):
    s = copy.deepcopy(files.read_state(save))
    s["phase"] = "P0"
    s["proj"] = []
    s["water"] = {"patients": patients, "hosp": hosp, "src": [[125, 112, Z]], "thirst_max": 23500}
    return s


def _builds(doc):
    return [b for se in doc["seasons"] for b in se["build"]]


def test_hospital_surface_due_wants_patients_no_zone_a_site_and_no_hospital_before(save):
    fort = {"hosp": {"surface": True, "site": [110, 110, Z], "rot": 0}}
    assert plan.hospital_surface_due(_p0_state(save), fort, set()) is True
    assert plan.hospital_surface_due(_p0_state(save, patients=0), fort, set()) is False          # nobody hurt
    assert plan.hospital_surface_due(_p0_state(save, hosp=1), fort, set()) is False              # a zone stands
    assert plan.hospital_surface_due(_p0_state(save), {"hosp": {"site": [1, 2, 3]}}, set()) is False   # a dug site, not ours
    assert plan.hospital_surface_due(_p0_state(save), {"hosp": {"surface": True}}, set()) is False      # no free site
    assert plan.hospital_surface_due(_p0_state(save), fort, {("hospital", None)}) is False       # drafted or applied before


def test_propose_drafts_the_surface_hospital_in_a_fort_without_a_dug_core(save):
    s = _p0_state(save)
    fort = {"z4": False, "core_any": False, "core_dig": False, "startup": True, "depot": True,
            "hosp": {"surface": True, "site": [110, 110, Z], "rot": 0, "wd": 12}}
    doc = plan.propose(s, plan.load_phases(), None, decisions={}, applied=set(), fort=fort)
    hos = [b for b in _builds(doc) if b["tpl"] == "hospital"]
    assert hos == [{"tpl": "hospital", "site": "S1", "p": {"surface": 1}}] and "BUG-384" in doc["notes"], doc["notes"]
    assert schema.validate("plan", doc) == []
    none = plan.propose(_p0_state(save, patients=0), plan.load_phases(), None, decisions={}, applied=set(), fort=fort)
    assert all(b["tpl"] != "hospital" for b in _builds(none))


def test_hospital_facts_offer_the_surface_site_when_no_dug_core_has_a_room_site(save, monkeypatch):
    monkeypatch.setattr(plan, "_has_z4", lambda _d: False)
    s = _p0_state(save)
    hf = plan.hospital_facts(save, s, [])
    assert hf.get("surface") is True and isinstance(hf.get("site"), list) and hf["site"][2] == Z, hf
    assert "why" not in hf and plan.hospital_water(s, {"hosp": hf})["ok"] is True
    monkeypatch.setattr(plan, "_has_z4", lambda _d: True)          # a dug core: the dug hospital's sites, never the surface one
    assert plan.hospital_facts(save, s, []).get("surface") is None
