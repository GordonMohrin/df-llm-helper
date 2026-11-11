"""BUG-770 (Run 16a i1 Basementflew y540: `bp sites hospital --fresh` 'no valid site (3965 no door tile, 1015 rock/water, 0 fit)' beside a compact room
fallback that found no site either; two patients died of thirst with GiveWater jobs running): when no dug room fits the rock (7x5 or compact), the
ranking goes on by itself to the hospital on open surface floor (`surface` = 1, nothing dug): the sites carry `surface` = 1 and say so,
cmd.site_params puts it into the document; p.surface = 0 and a given p.compact forbid it; a dug room is always preferred."""
import sys
from pathlib import Path

import pytest

from dfpilot import cmd
from dfpilot.bp import sites

sys.path.insert(0, str(Path(__file__).resolve().parent / "bp"))
from bp_fixtures import fort_world  # noqa: E402

WELL = [90, 66, 5]


@pytest.fixture(scope="module")
def fort():
    w, _ = fort_world(big=True)
    return w.snapshot(purpose="sites"), w.manifest


def test_a_dug_room_is_preferred_over_the_open_floor(fort):
    snap, man = fort
    got = sites.rank(snap, "hospital", manifest=man, water={"src": [WELL], "near": 30}, n=3)
    assert got and not any(s.get("surface") for s in got), got
    assert not any("OPEN SURFACE" in s["why"] for s in got)


def test_nothing_fits_the_rock_the_open_floor_is_ranked_and_says_so(fort, monkeypatch):
    snap, man = fort
    monkeypatch.setattr(sites, "_check", lambda *a, **k: None)                        # no dug room fits, the compact one included
    got = sites.rank(snap, "hospital", manifest=man, water={"src": [WELL], "near": 30}, n=3)
    assert got and all(s.get("surface") == 1 for s in got), got
    assert "HOSPITAL ON OPEN SURFACE FLOOR" in got[0]["why"] and "BUG-770" in got[0]["why"], got[0]["why"]
    assert "nothing dug" in got[0]["why"], got[0]["why"]
    assert cmd.site_params("hospital", {"beds": 6}, got[0]) == {"beds": 6, "surface": 1}, "the document is the surface hospital"
    assert cmd.site_params("hospital", {"surface": 0}, got[0]) == {"surface": 0}, "p.surface given stays"
    assert cmd.site_params("hospital", None, {"anchor": [1, 2, 3]}) is None, "a dug site changes nothing"


def test_the_player_can_forbid_it(fort, monkeypatch):
    snap, man = fort
    monkeypatch.setattr(sites, "_check", lambda *a, **k: None)
    for params in ({"surface": 0}, {"compact": 0}, {"compact": 1}):
        with pytest.raises(ValueError):
            sites.rank(snap, "hospital", params, manifest=man, water={"src": [WELL], "near": 30})


def test_no_water_no_hospital_even_on_the_open_floor(fort, monkeypatch):
    snap, man = fort
    monkeypatch.setattr(sites, "_check", lambda *a, **k: None)
    with pytest.raises(ValueError, match="no accepted water"):
        sites.rank(snap, "hospital", manifest=man, water={"src": [], "near": 30})


def test_the_refusal_without_any_open_floor_still_names_the_funnel(fort, monkeypatch):
    snap, man = fort
    monkeypatch.setattr(sites, "_check", lambda *a, **k: None)
    monkeypatch.setattr(sites, "_surface_shops", lambda *a, **k: [])
    with pytest.raises(ValueError) as e:
        sites.rank(snap, "hospital", manifest=man, water={"src": [WELL], "near": 30})
    assert "no valid site on the snapshot" in str(e.value) and "also tried" in str(e.value), str(e.value)
