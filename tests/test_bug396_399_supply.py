"""Run 16 (04.11.2026, fix round 21).
BUG-396: no office for 294 days (i1 Bachwald): the manager validated nothing, 7 brews unvalidated, drink 0. The `office` template
takes p.surface = 1 (a 3x3 block of open surface floor, nothing dug), `plan propose` drafts it for a fort without an office and
without a dug core, the kernel asks for it (PROJECT_REQUEST office why=office) and follow places it.
BUG-399: `bp sites depot` 0 sites for years (i3 Yawninggilt): the sites snapshot ended at the surface level, so the sky check
of the surface templates had no row above the floor it looked at."""
from __future__ import annotations

import copy
from pathlib import Path

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import bp, cmd, files, plan, schema
from dfpilot.bp import sites as bp_sites

X0, Y0, Z = 100, 100, 130
W, H = 40, 30


def _snap(top_sky=True, sid="s396") -> dict:
    """An open surface at Z. top_sky False: the snapshot ends at Z (the old sites box), True: Z + 1 is a row of open sky."""
    rows = {f"z{Z - 1}": ["#" * W for _ in range(H)], f"z{Z}": ["." * W for _ in range(H)]}
    if top_sky:
        rows[f"z{Z + 1}"] = ["_" * W for _ in range(H)]
    return {"v": 2, "id": sid, "tick": 1, "purpose": "sites",
            "bbox": [X0, Y0, Z - 1, X0 + W - 1, Y0 + H - 1, Z + (1 if top_sky else 0)], "rows": rows, "marks": {}}


# ---------------------------------------------------------------- BUG-396: the surface office
def test_surface_office_template_digs_nothing_and_zones_the_block_for_the_manager():
    doc = bp.emit("office", {"surface": 1}, {"id": "S1", "anchor": [110, 110, Z], "rot": 0})
    # merge21: the BUG-387 surface room (constructed walls, nothing dug) replaced the zone-only block
    assert all(st["mode"] != "dig" for st in doc["stages"]), "nothing is dug"
    cells = [c for st in doc["stages"] for ch in st["chunks"] for c in ch["cells"]]
    assert {"c", "t"} <= {c[3] for c in cells} and any("assigned_unit=manager" in str(c[3]) for c in cells)
    assert "zones" not in doc["manifest"], "no Z4: nothing is dug"
    room = doc["manifest"]["rooms"][0]
    assert room["tpl"] == "office"
    assert schema.validate("bp", dict(doc, id="y1s0b3")) == [] and bp.validate(dict(doc, id="y1s0b3")) == []
    dug = bp.emit("office", {}, {"id": "S1", "anchor": [110, 110, Z], "rot": 0})
    assert any(st["mode"] == "dig" for st in dug["stages"]), "the dug office is unchanged"
    other = bp.emit("office", {"surface": 1, "role": "bookkeeper"}, {"id": "S1", "anchor": [110, 110, Z], "rot": 0})
    assert any("assigned_unit=bookkeeper" in str(c[3]) for st in other["stages"] for ch in st["chunks"] for c in ch["cells"])


def test_surface_office_sites_need_no_fortcore_manifest():
    found = bp.rank(_snap(), "office", {"surface": 1}, n=3)             # no manifest: a room template would raise
    assert found and "open surface floor for a surface office" in found[0]["why"]
    with pytest.raises(ValueError, match="room sites need the fort manifest"):
        bp.rank(_snap(), "office", {}, n=3)


def test_surface_office_is_a_supply_build_no_seal_pauses():
    assert plan.build_kind({"tpl": "office", "site": "S1", "p": {"surface": 1}}) == "supply"
    assert plan.build_kind({"tpl": "office", "site": "S1"}) == "work", "the dug office is room work as before"


def test_office_surface_due_wants_a_site_and_no_office_before():
    fort = {"office": {"have": False, "site": [110, 110, Z]}}
    assert plan.office_surface_due(fort, set()) is True
    assert plan.office_surface_due({"office": {"have": True, "site": [1, 2, 3]}}, set()) is False       # an office stands or is planned
    assert plan.office_surface_due({"office": {"have": False, "site": None}}, set()) is False           # no free site
    assert plan.office_surface_due(fort, {("office", None)}) is False                                    # drafted or applied before
    assert plan.office_surface_due({}, set()) is False


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    snap = _snap()
    monkeypatch.setattr(cmd, "sites_snapshot", lambda _d: snap)
    monkeypatch.setattr(plan, "sites_snapshot", lambda _d: snap)
    yield d
    reset_paths()


def _builds(doc):
    return [b for se in doc["seasons"] for b in se["build"]]


def test_propose_drafts_the_surface_office_in_a_fort_without_a_dug_core(save):
    s = copy.deepcopy(files.read_state(save))
    s["phase"], s["proj"] = "P0", []
    fort = {"z4": False, "core_any": False, "core_dig": False, "startup": True, "depot": True,
            "office": {"have": False, "site": [110, 110, Z]}}
    doc = plan.propose(s, plan.load_phases(), None, decisions={}, applied=set(), fort=fort)
    off = [b for b in _builds(doc) if b["tpl"] == "office"]
    assert off == [{"tpl": "office", "site": "S1", "p": {"surface": 1}}] and "BUG-396" in doc["notes"], doc["notes"]
    assert schema.validate("plan", doc) == []
    have = dict(fort, office={"have": True, "site": None})
    none = plan.propose(s, plan.load_phases(), None, decisions={}, applied=set(), fort=have)
    assert all(b["tpl"] != "office" for b in _builds(none))


def test_office_facts_offer_the_surface_site_only_without_an_office_and_a_dug_core(save, monkeypatch):
    monkeypatch.setattr(plan, "_has_z4", lambda _d: False)
    of = plan.office_facts(save, [], [])
    assert of["have"] is False and isinstance(of["site"], list) and of["site"][2] == Z, of
    assert plan.office_facts(save, [{"tpl": "office"}], [])["site"] is None, "an office room stands"
    assert plan.office_facts(save, [], [("office", None)])["have"] is True, "an office project is applied"
    monkeypatch.setattr(plan, "_has_z4", lambda _d: True)          # a dug core: the dug office, never the surface one
    assert plan.office_facts(save, [], [])["site"] is None


# ---------------------------------------------------------------- BUG-399: the surface level at the top of the snapshot
def test_a_snapshot_that_ends_at_the_surface_says_why_it_has_no_depot_site():
    assert bp.rank(_snap(top_sky=True), "depot", {}, n=1), "the sky row above the floor: a depot site"
    with pytest.raises(ValueError, match="no level above it to show open sky.*BUG-399"):
        bp.rank(_snap(top_sky=False), "depot", {}, n=1)
    assert bp_sites.surface_top_floor(_snap(top_sky=False)) == W * H
    assert bp_sites.surface_top_floor({"bbox": [0, 0, 0, 1, 1, 0], "rows": {}}) == 0
    for tpl, prm in (("workshops", {"surface": 1}), ("office", {"surface": 1})):
        with pytest.raises(ValueError, match="BUG-399"):
            bp.rank(_snap(top_sky=False), tpl, prm, n=1)


def test_no_site_hint_for_the_depot_names_the_sky_levels():
    assert "sky levels" in cmd.no_site_hint(Path("."), "depot", "s1", 0, [], {})
