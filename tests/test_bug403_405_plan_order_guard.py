"""Run 16 round 22 (04.11.2026).
BUG-403: `plan propose` drafted fortcore stage 3 before stage 2 (i1 Bachwald plan-y372c: seasons[2] st3, seasons[3] st2, ERROR BUG-164): the
fortcore builds of the draft, kept seasons of the same year included, run in ascending stage order.
BUG-404: the BUG-399 guard ('no level above it to show open sky') fired on a snapshot whose surface lies below the box's top level
(i2 Ostgate: surface z131, top z138 a peak), refusing the surface core, bedrooms, dining and tavern; it fires only when the snapshot shows
no open sky above any floor.
BUG-405 (Lua): a stranger's corpse on a construction site is unforbidden and dumped, tests/lua/test_economy_sites.lua."""
import copy
import json

import pytest
from cli_v2_helpers import FIX, make_runtime, reset_paths

from dfpilot import bp, files, plan
from dfpilot.bp import sites as bp_sites


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def _fc(k):
    return {"tpl": "fortcore", "site": "same", "p": {"stage": k}}


def _st(seasons):
    return [(b["tpl"], plan._stage_of(b.get("p") or {})) for se in seasons for b in se["build"]]


def test_core_stage_order_sorts_the_new_slots_by_stage_across_seasons():
    seasons = [{"build": [_fc(3), {"tpl": "seal", "site": "S1"}]}, {"build": []}, {"build": [_fc(2)]}, {"build": [_fc(4)]}]
    plan.core_stage_order(seasons, [0, 0, 0, 0])
    st = _st(seasons)
    assert st == [("fortcore", 2), ("seal", None), ("fortcore", 3), ("fortcore", 4)], st
    ok = [{"build": [_fc(2), _fc(3)]}]
    plan.core_stage_order(ok, [0])
    assert _st(ok) == [("fortcore", 2), ("fortcore", 3)]
    retro = [{"build": [{"tpl": "fortcore", "site": "S1", "p": {"stage": 3, "retrofit": 1}}, _fc(2)]}]
    plan.core_stage_order(retro, [0])
    assert plan._stage_of(retro[0]["build"][0]["p"]) == 3, "a retrofit build is not moved"
    kept = [{"build": [_fc(3)]}, {"build": [_fc(2)]}]                     # the first build of season 0 was kept: it stays put
    plan.core_stage_order(kept, [1, 0])
    assert _st(kept) == [("fortcore", 3), ("fortcore", 2)]


def test_propose_keeps_the_added_core_stages_in_order(save):
    s = copy.deepcopy(files.read_state(save))
    s["phase"] = "P5"
    prev = json.loads((save / "plan.json").read_text("utf-8"))
    prev["seasons"] = [{"build": []} for _ in range(4)]
    phases = json.loads((FIX / "phases.json").read_text("utf-8"))
    tinfo = {t: {"params": {"stage": 1} if t == "fortcore" else {}, "about": ""} for t in ("fortcore", "seal", "bedrooms", "tombs")}
    doc = plan.propose(s, phases, prev, decisions={}, tinfo=tinfo,
                       fort={"core_any": True, "core_dig": False, "core": None}, applied={("fortcore", 1)})
    fc = [k for t, k in _st(doc["seasons"]) if t == "fortcore"]
    assert fc == sorted(fc), fc
    assert plan.core_order_gate(doc) == []


W, H, X0, Y0, Z = 40, 30, 100, 100, 130


def _peak_snap(sky_over_floor=True) -> dict:
    """Surface at Z (floor under sky), a mountain peak above it: the top level Z+7 holds 25+ floor tiles but the sky shows at Z+1."""
    rows = {f"z{Z - 1}": ["#" * W for _ in range(H)], f"z{Z}": ["." * W for _ in range(H)]}
    for z in range(Z + 1, Z + 7):
        rows[f"z{z}"] = ["_" * W for _ in range(H)] if sky_over_floor else ["." * W for _ in range(H)]
    rows[f"z{Z + 7}"] = ["." * 30 + "_" * (W - 30) for _ in range(H)]                  # the peak: floor, no level above it
    return {"v": 2, "id": "s404", "tick": 1, "purpose": "sites", "bbox": [X0, Y0, Z - 1, X0 + W - 1, Y0 + H - 1, Z + 7],
            "rows": rows, "marks": {}}


def test_sky_over_floor_reads_the_snapshot():
    assert bp_sites.sky_over_floor(_peak_snap()) is True
    assert bp_sites.sky_over_floor({"bbox": [0, 0, 0, 1, 1, 1], "rows": {}}) is False
    assert bp_sites.sky_over_floor({}) is False


def test_guard_does_not_fire_when_the_surface_lies_below_the_top_level():
    snap = _peak_snap()
    assert bp_sites.surface_top_floor(snap) >= bp_sites.SURFACE_TOP_MIN
    # the surface core / bedrooms may find no site (too big for the open floor): then the plain 'no valid site' error, not BUG-399
    snap["rows"][f"z{Z}"] = ["." * 3 + "#" * (W - 3) for _ in range(H)]
    snap["rows"][f"z{Z - 1}"] = ["#" * W for _ in range(H)]
    for tpl, prm in (("surfacecore", {}), ("bedrooms", {"surface": 1, "n": 10})):
        try:
            bp.rank(snap, tpl, prm, n=1)
        except ValueError as e:
            assert "BUG-399" not in str(e) and "no level above it" not in str(e), e


def test_guard_still_fires_when_the_box_ends_at_the_surface():
    rows = {f"z{Z - 1}": ["#" * W for _ in range(H)], f"z{Z}": ["." * W for _ in range(H)]}
    snap = {"v": 2, "id": "s", "tick": 1, "purpose": "sites", "bbox": [X0, Y0, Z - 1, X0 + W - 1, Y0 + H - 1, Z],
            "rows": rows, "marks": {}}
    with pytest.raises(ValueError, match="BUG-399"):
        bp.rank(snap, "depot", {}, n=1)
