"""BUG-722 (Run 16a i1 Basementflew: `bp sites hospital` answered 'no valid site on the snapshot' with accepted water in the fort, year after year,
and never said where the candidates fell out): the answer carries the funnel of the room search (anchor tiles, door tile, rock / liquid in the
room, keep-out boxes, refuge level)."""
import copy
import sys
from pathlib import Path

import pytest

from dfpilot.bp import sites

sys.path.insert(0, str(Path(__file__).resolve().parent / "bp"))
from bp_fixtures import fort_world  # noqa: E402

WELL = [137, 77, 143]


@pytest.fixture(scope="module")
def fort():
    w, _ = fort_world(big=True)
    return w.snapshot(purpose="sites"), w.manifest


def test_no_valid_site_names_where_the_candidates_fell_out(fort, monkeypatch):
    snap, man = fort
    man = copy.deepcopy(man)
    monkeypatch.setattr(sites, "_check", lambda *a, **k: None)                        # every room meets rock: no candidate
    with pytest.raises(ValueError) as e:
        sites.rank(snap, "hospital", manifest=man, water={"src": [WELL], "near": 30})
    msg = str(e.value)
    assert msg.startswith("hospital: no valid site on the snapshot ("), msg
    assert "anchor tile(s) on the Z4 floor" in msg and "nearest accepted water" in msg, msg
    assert "whose room meets rock" in msg, msg                                          # old: no funnel at all


def test_the_funnel_counts_a_floor_that_is_not_there(fort):
    snap, man = fort
    man = copy.deepcopy(man)
    man["zones"]["Z4"] = [[0, 0, 0, 1, 1, 0]]                                          # a box outside the snapshot's floor
    with pytest.raises(ValueError) as e:
        sites.rank(snap, "hospital", manifest=man, water={"src": [WELL], "near": 30})
    assert "no valid site on the snapshot (" in str(e.value) and "Z4" in str(e.value), str(e.value)
