"""refuge_beds (Run 10, 2026-10-16: Tiefe+ had 8 beds for 110 citizens, the civ alert refused it, and no template could
add beds there because every room stays off the refuge level): a dormitory dug from the fortcore refuge room into the
rock, in the refuge burrow, that opens no new way in."""
import pytest

from dfpilot import bp
from dfpilot.bp import rooms, sites
from dfpilot.bp.primitives import merge_manifest
from dfpilot.bp.render import cell_rects
from dfpilot.bp.validate import _rooms

from bp_fixtures import fort_world, set_tiles


@pytest.fixture(scope="module")
def fort():
    w, _ = fort_world(big=True)
    return w.snapshot(purpose="sites"), w.manifest


def keys(doc, mode):
    return [(k, props, (x0, y0, z, x1, y1)) for st, k, props, x0, y0, x1, y1, z in cell_rects(doc) if st["mode"] == mode]


def test_refuge_beds_sit_in_the_refuge_and_keep_it_sealed(fort):
    snap, man = fort
    ref = sites.refuge_rooms(man)[0]
    ranked = bp.rank(snap, "refuge_beds", {"n": 20}, manifest=man)
    assert len(ranked) >= 2
    for s in ranked:
        x, y, z = s["anchor"]
        assert ref[0] <= x <= ref[3] and ref[1] <= y <= ref[4] and z == ref[2], s   # a refuge floor tile
        doc = bp.emit("refuge_beds", {"n": 20}, s)
        w = bp.as_built(doc, base=snap)
        assert w.errors == [] and _rooms(w, doc["manifest"]) == [], (s, w.errors[:3])
        w.manifest = merge_manifest(man, doc["manifest"])
        res = bp.audit(w.snapshot(), w.manifest)
        assert res["ok"] and res["refuge_sep"] and not res["bypass"], (s, res["fails"])   # no new way in
        assert len([k for k, _, _ in keys(doc, "build") if k == "b"]) == 20
        assert all("name=Tiefe+" in props for k, props, _ in keys(doc, "burrow"))
        assert [k for k, _, _ in keys(doc, "zone")] == ["D"]
        assert "zones" not in doc["manifest"]                     # never Z4: the core -> refuge audit stays honest
        assert doc["manifest"]["rooms"][0]["tpl"] == "refuge_beds"


def test_refuge_beds_never_touch_an_open_tile(fort):
    """The footprint and its wall ring must be rock or unknown: a revealed cave beside the room rejects the site (a
    cave three tiles away does not)."""
    snap, man = fort
    (s1, *_) = bp.rank(snap, "refuge_beds", {"n": 8}, manifest=man)
    doc = bp.emit("refuge_beds", {"n": 8}, s1)
    dug = {(x, y, z) for st, k, _, x0, y0, x1, y1, z in cell_rects(doc) if st["mode"] == "dig"
           for x in range(x0, x1 + 1) for y in range(y0, y1 + 1)}
    xs, ys = [p[0] for p in dug], [p[1] for p in dug]
    z = s1["anchor"][2]
    ax, ay = s1["anchor"][:2]

    def beside(d):                            # the tile d beyond the room, farthest from the anchor
        ring = [(x, y) for x in range(min(xs) - d, max(xs) + d + 1) for y in range(min(ys) - d, max(ys) + d + 1)
                if not (min(xs) - d < x < max(xs) + d and min(ys) - d < y < max(ys) + d)]
        return max(ring, key=lambda q: (abs(q[0] - ax) + abs(q[1] - ay), q))

    for d, kept in ((1, False), (3, True)):
        cave = set_tiles(snap, [(*beside(d), z)], ".")
        again = bp.rank(cave, "refuge_beds", {"n": 8}, manifest=man, n=12)
        assert any((s["anchor"], s["rot"]) == (s1["anchor"], s1["rot"]) for s in again) is kept, (d, beside(d))


def test_refuge_beds_layout_and_params():
    site = {"id": "S1", "anchor": [70, 70, 100], "rot": 0}
    for n in (2, 6, 7, 30):
        doc = bp.emit("refuge_beds", {"n": n}, site)
        beds = [r for k, _, r in keys(doc, "build") if k == "b"]
        assert len(beds) == n
        assert all(r[0] != 70 for r in beds)                      # the centre column is the aisle from the door
    with pytest.raises(ValueError):
        bp.emit("refuge_beds", {"n": 31}, site)
    assert bp.check_params("refuge_beds", {})["burrow"] == "Tiefe+"
    assert bp.check_params("bedrooms", {})["burrow"] == "Kern+"
    assert "refuge_beds" in rooms.NO_THROUGH and "refuge_beds" in rooms.REFUGE_LEVEL


def test_refuge_beds_need_the_fortcore_refuge(fort):
    snap, man = fort
    no_ref = {k: v for k, v in man.items() if k != "refuge"}
    assert bp.rank(snap, "refuge_beds", {}, manifest=no_ref) == []
