"""FR-69 refuge drink store (Run 11, Kilrudrabed y477: Tiefe+ held 0 of the fort's 1493 drinks, 1199 of them lay in
the one Kern+ stockpile `dfllm-stock`, readiness stayed R0 refuge_dry and `bp sites cistern` offered only sites far from
the refuge): a small room dug off the fortcore refuge room into the rock, a food stockpile for drink only (quickfort
`:=booze`) with barrels that takes from `dfllm-stock`, in the refuge burrow. Its only opening is the doorway into the
refuge room, so it adds no way in (the refuge's separation and the deep defense stay as they were)."""
import pytest

from dfpilot import bp
from dfpilot.bp import rooms, sites
from dfpilot.bp.primitives import cell_cfg, merge_manifest, parse_cell
from dfpilot.bp.render import cell_rects
from dfpilot.bp.validate import _rooms, check_doc

from bp_fixtures import fort_world, set_tiles

SITE = {"id": "S1", "anchor": [70, 70, 100], "rot": 0}


@pytest.fixture(scope="module")
def fort():
    w, _ = fort_world(big=True)
    return w.snapshot(purpose="sites"), w.manifest


def cells(doc, mode):
    return [(k, props, (x0, y0, z, x1, y1)) for st, k, props, x0, y0, x1, y1, z in cell_rects(doc) if st["mode"] == mode]


def texts(doc, mode):
    return [c[3] for st in doc["stages"] if st["mode"] == mode for ch in st["chunks"] for c in ch["cells"]]


def test_size_follows_the_citizens():
    """Barrels = the drink the kernel wants in the refuge (citizens x seal's drink_per_cit, the refuge_dry rule) or the
    citizens' drink for breach_days (7) at economy's rate (53/1000 a day), whichever is more, at 5 drinks a barrel (one
    brew job's yield: DF adds later brews to a barrel, so it holds at least that), 2..24."""
    assert rooms.refuge_drink_n(52) == 11                      # Run 11 y477: 52 units > 7 x 52 x 0.053 = 20
    assert rooms.refuge_drink_n(1) == 2 and rooms.refuge_drink_n(0) == 2
    assert rooms.refuge_drink_n(60) == 12
    assert rooms.refuge_drink_n(250) == rooms.REFUGE_DRINK_MAX == 24
    assert rooms.refuge_drink_n(52, days=60, milli=200) == 24           # 624 units at 5 a barrel, capped
    assert rooms.refuge_drink_n(10, days=30, milli=1000) == 24 and rooms.refuge_drink_n(10, days=7, milli=500) == 7
    assert (rooms.DRINKS_PER_BARREL, rooms.DRINK_PER_CIT, rooms.DRINK_MILLI, rooms.BREACH_DAYS) == (5, 1, 53, 7)


def test_layout_a_drink_only_pile_with_barrels_in_the_refuge_burrow():
    doc = bp.emit("refuge_drink", {"n": 11}, SITE)
    assert check_doc(doc) == [] and doc["class"] == "infra"
    (pile,) = texts(doc, "place")
    # a food stockpile set to drink only (quickfort `:=booze`, stockpiles library), one barrel per tile, taking from the
    # core stockroom's pile (a missing name only prints a quickfort error: the pile is made all the same)
    assert pile == "f{name=dfllm-drink barrels=11 take_from=dfllm-stock}:=booze(5x3)" and len(pile) <= 64
    assert parse_cell(pile) == ("f", "name=dfllm-drink barrels=11 take_from=dfllm-stock", (5, 3), None)
    assert cell_cfg(pile) == "=booze"
    assert {(k, r) for k, _, r in cells(doc, "burrow")} == {("a", (68, 72, 100, 72, 74)), ("a", (70, 71, 100, 70, 71))}
    assert all("name=Tiefe+" in p for _, p, _ in cells(doc, "burrow"))
    assert texts(doc, "build") == [] and texts(doc, "zone") == []          # no door, no zone
    assert "zones" not in doc["manifest"]                                  # never Z4: the refuge stays its own
    (room,) = doc["manifest"]["rooms"]
    assert (room["tpl"], room["use"], room["bbox"]) == ("refuge_drink", "utility", [68, 72, 100, 72, 74, 100])
    small = bp.emit("refuge_drink", {"n": 6, "take": ""}, SITE)
    assert texts(small, "place") == ["f{name=dfllm-drink barrels=6}:=booze(3x2)"]
    assert [len(texts(bp.emit("refuge_drink", {"n": n}, SITE), "place")) for n in (2, 9, 10, 24)] == [1] * 4
    assert texts(bp.emit("refuge_drink", {"n": 24}, SITE), "place")[0].endswith("(5x5)")
    for bad in ({"n": 1}, {"n": 25}, {"take": "a b"}, {"take": "x" * 12}):     # 12 chars: the cell > 64 bytes
        with pytest.raises(ValueError):
            bp.emit("refuge_drink", bad, SITE)
    assert "refuge_drink" in rooms.REFUGE_LEVEL and sites.on_refuge("refuge_drink", {})
    assert bp.check_params("refuge_drink", {}) == {"n": 12, "take": "dfllm-stock", "burrow": "Tiefe+"}


def test_quickfort_stockpile_configuration_only_in_place_mode():
    """The `:<op><preset>` part of a cell (quickfort-user-guide `Stockpile configuration`, `f:=booze(5x4)`) is a
    #place feature; anywhere else, or malformed, the validator rejects it."""
    assert parse_cell("f:=booze(5x4)") == ("f", None, (5, 4), None) and cell_cfg("f:=booze(5x4)") == "=booze"
    assert parse_cell("p{name=W}:-cat_weapons/other/(7x3)")[3] is None
    assert cell_cfg("f{name=x}(2x2)") is None
    doc = bp.emit("refuge_drink", {}, SITE)
    for st in doc["stages"]:
        if st["mode"] == "burrow":
            st["chunks"][0]["cells"][0][3] = st["chunks"][0]["cells"][0][3].replace("(", ":=booze(", 1)
    assert [f.code for f in check_doc(doc)] == ["cell"]
    doc = bp.emit("refuge_drink", {}, SITE)
    for st in doc["stages"]:
        if st["mode"] == "place":
            st["chunks"][0]["cells"][0][3] = "f{name=dfllm-drink}:=(3x3)"
    assert [f.code for f in check_doc(doc)] == ["cell"]


def test_sites_in_the_refuge_room_keep_the_refuge_sealed(fort):
    snap, man = fort
    ref = sites.refuge_rooms(man)[0]
    ranked = bp.rank(snap, "refuge_drink", {"n": 11}, manifest=man)
    assert len(ranked) >= 2
    for s in ranked:
        x, y, z = s["anchor"]
        assert ref[0] <= x <= ref[3] and ref[1] <= y <= ref[4] and z == ref[2], s     # a refuge floor tile
        doc = bp.emit("refuge_drink", {"n": 11}, s)
        w = bp.as_built(doc, base=snap)
        assert w.errors == [] and _rooms(w, doc["manifest"]) == [], (s, w.errors[:3])
        w.manifest = merge_manifest(man, doc["manifest"])
        res = bp.audit(w.snapshot(), w.manifest)
        assert res["ok"] and res["refuge_sep"] and not res["bypass"], (s, res["fails"])   # no new way in
        assert all("name=Tiefe+" in props for _, props, _ in cells(doc, "burrow"))
        assert "zones" not in doc["manifest"]


def _ring(snap, man, d):
    """Open (revealed floor) every tile at Chebyshev distance d from the refuge room on its level."""
    x0, y0, z, x1, y1, _ = sites.refuge_rooms(man)[0]
    ring = [(x, y, z) for x in range(x0 - d, x1 + d + 1) for y in range(y0 - d, y1 + d + 1)
            if max(x0 - x, x - x1, y0 - y, y - y1) == d]
    return set_tiles(snap, ring, ".")


def test_no_site_says_why_and_names_a_smaller_store_that_fits(fort):
    """A cramped refuge (Run 11's Tiefe+ is a 212-tile shaft): the ranking says so instead of an empty list, and names
    the largest smaller store that still has a site beside the refuge room."""
    snap, man = fort
    cramped = _ring(snap, man, 5)                    # a 5x3 store needs 5 rows of rock beyond the wall, a 3x2 one 4
    with pytest.raises(ValueError) as e:
        bp.rank(cramped, "refuge_drink", {"n": 11}, manifest=man)
    msg = str(e.value)
    assert msg.startswith("refuge_drink: no site for 11 barrels (5x3) beside the refuge room ")
    assert "a smaller store fits: n=6 (3x2): dfllm bp sites refuge_drink n=6" in msg, msg
    assert bp.rank(cramped, "refuge_drink", {"n": 6}, manifest=man)
    with pytest.raises(ValueError) as e:
        bp.rank(_ring(snap, man, 3), "refuge_drink", {"n": 11}, manifest=man)
    assert "not even a 3x1 store (2 barrels)" in str(e.value), str(e.value)
    assert "a well or cistern of its own" in str(e.value)
    no_ref = {k: v for k, v in man.items() if k != "refuge"}
    with pytest.raises(ValueError, match="no refuge in the fort manifest"):
        bp.rank(snap, "refuge_drink", {}, manifest=no_ref)
