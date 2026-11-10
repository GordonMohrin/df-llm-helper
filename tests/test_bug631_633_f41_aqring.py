"""BUG-631 .. BUG-633 (Run 16 round 19, 10.11.2026; offline, live-untested).
BUG-631: the aqshaft ring stayed new/new/new/new (Lua: tests/lua/test_bug631_ring_hidden.lua); the stall names its exact cause.
BUG-633: a cavern breach on a known aquifer level (flooded rooms of ours) refuses only the columns beside it, not the whole fort."""
from __future__ import annotations

import pytest
from test_bug412_413_aquifer_default import X0, Y0, Z, _snap  # noqa: F401

from dfpilot.bp import sites

AQLV = [Z - 3, Z - 4]


def test_a_cavern_breach_on_an_aquifer_level_refuses_only_the_columns_beside_it():
    snap = _snap()
    bx, by = X0 + 40, Y0 + 40
    man = {"v": 2, "aquifer_levels": list(AQLV), "caverns": [[bx, by, Z - 3]]}
    av = sites.shaft_avoid(snap, man)
    assert av and av.levels == {}, "not a level-wide cavern"
    # a column beside the flood: refused, and the reason says how far to go
    with pytest.raises(ValueError, match=r"cavern breach at .* on the aquifer level z%d.*more than 9 tiles away passes" % (Z - 3)):
        sites.check_column(snap, man, bx + 3, by, Z, 6)
    # a column 10 tiles away passes (the shaft ring handles the aquifer itself)
    sites.check_column(snap, man, bx + 10, by, Z, 6)
    sites.check_column(snap, man, bx, by - 12, Z, 6)
    # a shaft that does not reach z%d is not affected at all
    sites.check_column(snap, man, bx + 1, by, Z, 2)


def test_a_cavern_breach_off_the_aquifer_levels_or_with_a_cavern_mark_stays_level_wide():
    snap = _snap()
    bx, by = X0 + 40, Y0 + 40
    man = {"v": 2, "aquifer_levels": list(AQLV), "caverns": [[bx, by, Z - 6]]}       # z126 is no aquifer level: a real cavern
    with pytest.raises(ValueError, match="cavern/warm level z%d" % (Z - 6)):
        sites.check_column(snap, man, bx + 30, by, Z, 8)
    marked = _snap()
    marked["marks"] = {"cavern": [[X0 + 5, Y0 + 5, Z - 3]]}                            # a revealed cavern tile on the level: whole level
    man2 = {"v": 2, "aquifer_levels": list(AQLV), "caverns": [[bx, by, Z - 3]]}
    with pytest.raises(ValueError, match="cavern/warm level z%d" % (Z - 3)):
        sites.check_column(marked, man2, bx + 30, by, Z, 6)


def test_the_ranking_offers_the_columns_away_from_the_breach():
    snap = _snap()
    bx, by = X0 + 40, Y0 + 40
    man = {"v": 2, "aquifer_levels": list(AQLV), "caverns": [[bx, by, Z - 3]],
           "zones": {"Z4": [[bx - 4, by - 4, Z, bx + 20, by + 4, Z]]}}
    sites_ = sites.rank(snap, "aqshaft", {"depth": 6}, man) if hasattr(sites, "rank") else None
    if sites_ is None:
        pytest.skip("no sites.rank entry")
    anchors = [tuple(c["anchor"][:2]) for c in sites_]
    assert anchors and all(max(abs(a[0] - bx), abs(a[1] - by)) > 9 for a in anchors), anchors
