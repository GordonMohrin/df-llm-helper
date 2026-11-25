"""BUG-262 (Run 15 Inkintense, Guildcleans: no brook, a light aquifer, 'hospital held back (BUG-034): no accepted water in
the fort' for good): a cistern with p.water = aquifer is an aquifer well. Its basin (one level below the well room) is dug
into a known aquifer level, it has no pond (no bucket loop), and bp sites puts it only where the basin level is an aquifer
level, the room level and the one above are dry, and no heavy aquifer was recorded there. Fails on 2b9c009 (water aquifer
was not a cistern water kind)."""
import pytest

from dfpilot import bp, schema
from dfpilot.bp import rooms, sites

from bp_fixtures import fort_world


@pytest.fixture(scope="module")
def fort():
    w, _ = fort_world(big=True)
    return w.snapshot(purpose="sites"), w.manifest


def _holes(d):
    """Channel tiles of the dig stage (cells 'h' or 'h(WxH)')."""
    n = 0
    for st in d["stages"]:
        for ch in st["chunks"]:
            for c in ch["cells"]:
                k = c[3]
                if st["label"] == "dig" and k.startswith("h"):
                    w, _, h = k[2:-1].partition("x") if "(" in k else ("1", "", "1")
                    n += int(w) * int(h)
    return n


def test_aquifer_cistern_document_has_no_pond_and_no_path():
    dry = bp.emit("cistern", {}, {"id": "S1", "anchor": [50, 50, 10], "rot": 0})
    aq = bp.emit("cistern", {"water": "aquifer"}, {"id": "S1", "anchor": [50, 50, 10], "rot": 0})
    assert "zone" in [s["label"] for s in dry["stages"]] and "zone" not in [s["label"] for s in aq["stages"]]
    assert _holes(dry) == 2                     # well hole + pond hole
    assert _holes(aq) == 1                      # the well hole only
    assert aq["params"]["water"] == "aquifer" and rooms.cistern_layout(aq["params"])["aquifer"] is True
    assert schema.validate("bp", {**aq, "id": "c1"}) == []
    with pytest.raises(ValueError, match="aquifer takes no path"):
        bp.emit("cistern", {"water": "aquifer", "path": "1,6;1,9;4,9"})


def test_aquifer_cistern_sites_put_the_basin_on_an_aquifer_level(fort):
    snap, man = fort
    best = bp.rank(snap, "cistern", {}, manifest=man)[0]
    z = best["anchor"][2]
    with pytest.raises(ValueError, match="no aquifer level known"):
        bp.rank(snap, "cistern", {"water": "aquifer"}, manifest=man)
    got = bp.rank(snap, "cistern", {"water": "aquifer"}, manifest={**man, "aquifer_levels": [z - 1]})
    assert got and all(s["anchor"][2] == z for s in got), got
    assert best["anchor"] in [s["anchor"] for s in got]
    assert "basin on aquifer level z%d" % (z - 1) in got[0]["why"]
    # the plain cistern keeps off the aquifer level right below its room (FR-95), the aquifer one needs it
    plain = bp.rank(snap, "cistern", {}, manifest={**man, "aquifer_levels": [z - 1]})
    assert all(s["anchor"][2] != z for s in plain)
    # the room level or the level above it an aquifer level: refused
    for lv in ([z - 1, z], [z - 1, z + 1]):
        with pytest.raises(ValueError, match="no site with its basin on an aquifer level"):
            bp.rank(snap, "cistern", {"water": "aquifer"}, manifest={**man, "aquifer_levels": lv})


def test_a_heavy_aquifer_is_refused_and_damp_marks_count(fort):
    snap, man = fort
    z = bp.rank(snap, "cistern", {}, manifest=man)[0]["anchor"][2]
    # BUG-872 verifier: a heavy stop is where ONE dig met visible water; a level with no stop nearby is untested, not light: the level is
    # refused as a whole, near or far from the stop
    for pos in ([50, 65, z - 1], [10, 10, z - 1], [200, 200, z - 1]):
        heavy = {**man, "aquifer_levels": [z - 1], "breaches": [{"pos": pos, "why": "heavy_aquifer"}]}
        with pytest.raises(ValueError, match=r"heavy \(refused, a level is heavy as a whole\): z%d" % (z - 1)):
            bp.rank(snap, "cistern", {"water": "aquifer"}, manifest=heavy)
    other = {**man, "aquifer_levels": [z - 1], "breaches": [{"pos": [10, 10, z - 3], "why": "heavy_aquifer"}]}
    assert bp.rank(snap, "cistern", {"water": "aquifer"}, manifest=other)       # a heavy stop on another level does not matter
    damp = {**snap, "marks": {**(snap.get("marks") or {}), "damp": [[0, 0, z - 1]]}}
    assert bp.rank(damp, "cistern", {"water": "aquifer"}, manifest=man)


def _with_tile(snap, x, y, z, ch):
    rows = {k: list(v) for k, v in snap["rows"].items()}
    r = rows[f"z{z}"]
    yy, xx = y - snap["bbox"][1], x - snap["bbox"][0]
    r[yy] = r[yy][:xx] + ch + r[yy][xx + 1:]
    return {**snap, "rows": rows}


@pytest.mark.parametrize("ch", ["~", "w", "%", "_"])
def test_aquifer_cistern_keeps_three_tiles_from_open_water_magma_and_drops(fort, ch):
    """hard rule: no digging within 3 tiles of open water, waterfalls or drops: water, magma and open space (a drop) within 3 tiles of the
    site refuse it (basin level or room level); 5 tiles off they do not."""
    snap, man = fort
    m = {**man, "aquifer_levels": [bp.rank(snap, "cistern", {}, manifest=man)[0]["anchor"][2] - 1]}
    best = bp.rank(snap, "cistern", {"water": "aquifer"}, manifest=m, n=50)[0]
    z = best["anchor"][2]
    ax, ay = best["anchor"][0], best["anchor"][1]
    for lz in (z - 1, z):                      # the anchor lies in the footprint: a tile 2 off it is within 3 tiles of the box
        near = _with_tile(snap, ax + 2, ay, lz, ch)
        got = bp.rank(near, "cistern", {"water": "aquifer"}, manifest=m, n=50)
        assert all(s["anchor"] != best["anchor"] or s["rot"] != best["rot"] for s in got), (ch, lz)
    far = _with_tile(snap, ax + 30, ay, z - 1, ch)
    got = bp.rank(far, "cistern", {"water": "aquifer"}, manifest=m, n=50)
    assert any(s["anchor"] == best["anchor"] and s["rot"] == best["rot"] for s in got)


def test_aquifer_well_error_names_the_hazard(fort):
    snap, man = fort
    z = bp.rank(snap, "cistern", {}, manifest=man)[0]["anchor"][2]
    cands = [{"anchor": [50, 50, z], "box": (50, 50, z, 52, 52, z), "why": "x", "rot": 0}]
    tile = _with_tile(snap, 53, 51, z - 1, "~")
    with pytest.raises(ValueError, match=r"1 site\(s\) refused for open water or a drop within 3 tiles"):
        sites.aquifer_well(cands, tile, {**man, "aquifer_levels": [z - 1]})


def test_no_accepted_water_names_the_aquifer_well():
    with pytest.raises(ValueError, match="dfllm bp sites cistern water=aquifer") as e:
        sites._near_water([], "hospital", {}, {"src": []})
    assert "a well fed only by its own pond is none" in str(e.value)
