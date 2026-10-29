"""BUG-319 (Run 15b Earthboat y385: three refuge_beds rooms and the drink store took every wall of the 7x9 refuge room,
`bp sites refuge_beds --fresh` and `bp.place refuge_drink` found no site): refuge-level rooms also dig off the floor of the
refuge's own rooms, ranked after the refuge room's anchors, and still open no way in. BUG-320 (y384s1b2 waited months
for its door): refuge_beds builds no door."""
import pytest

from dfpilot import bp
from dfpilot.bp import sites
from dfpilot.bp.primitives import merge_manifest
from dfpilot.bp.render import cell_rects
from dfpilot.bp.validate import _rooms

from bp_fixtures import fort_world


def _in(box, x, y, z):
    return box[0] <= x <= box[3] and box[1] <= y <= box[4] and box[2] <= z <= box[5]


@pytest.fixture(scope="module")
def crowded():
    """The big fort with refuge rooms dug off the refuge room until none of its own anchors is left (Earthboat)."""
    w, _ = fort_world(big=True)
    snap, man = w.snapshot(purpose="sites"), w.manifest
    ref = sites.refuge_rooms(man)[0]
    for _ in range(16):
        placed = False
        for tpl in ("refuge_beds", "refuge_drink"):
            try:
                ranked = bp.rank(snap, tpl, {"n": 6}, manifest=man, n=12)
            except ValueError:                             # refuge_drink says why it has no site
                ranked = []
            own = [s for s in ranked if _in(ref, *s["anchor"])]
            if not own:
                continue
            doc = bp.emit(tpl, {"n": 6}, own[0])
            w = bp.as_built(doc, base=snap)
            assert w.errors == [], w.errors[:3]
            man = merge_manifest(man, doc["manifest"])
            w.manifest = man
            snap = w.snapshot(purpose="sites")
            placed = True
        if not placed:
            break
    else:
        pytest.fail("the refuge room never filled up")
    return snap, man, ref


def test_refuge_grows_off_its_own_rooms_when_the_refuge_room_is_full(crowded):
    snap, man, ref = crowded
    ext = sites.refuge_ext(man)
    assert ext, "no refuge_beds room was placed"
    for tpl, p in (("refuge_beds", {"n": 6}), ("refuge_drink", {"n": 6})):
        ranked = bp.rank(snap, tpl, p, manifest=man)
        assert ranked, f"{tpl}: old code: no site once the refuge room's walls are taken"
        for s in ranked:
            assert any(_in(b, *s["anchor"]) for b in ext) and "BUG-319" in s["why"], s
            doc = bp.emit(tpl, p, s)
            w = bp.as_built(doc, base=snap)
            assert w.errors == [] and _rooms(w, doc["manifest"]) == [], (s, w.errors[:3])
            w.manifest = merge_manifest(man, doc["manifest"])
            res = bp.audit(w.snapshot(), w.manifest)
            assert res["ok"] and res["refuge_sep"] and not res["bypass"], (tpl, s, res["fails"])   # no new way in


def test_refuge_room_anchors_rank_before_its_rooms():
    w, _ = fort_world(big=True)
    snap, man = w.snapshot(purpose="sites"), w.manifest
    ref = sites.refuge_rooms(man)[0]
    (s1, *_) = bp.rank(snap, "refuge_beds", {"n": 6}, manifest=man)
    doc = bp.emit("refuge_beds", {"n": 6}, s1)
    w2 = bp.as_built(doc, base=snap)
    man2 = merge_manifest(man, doc["manifest"])
    ranked = bp.rank(w2.snapshot(purpose="sites"), "refuge_beds", {"n": 6}, manifest=man2, n=12)
    flags = [_in(ref, *s["anchor"]) for s in ranked]
    assert flags and flags[0] and flags == sorted(flags, reverse=True), ranked   # the refuge room's own first


def test_refuge_ext_lists_refuge_level_rooms_only():
    man = {"refuge": {"anchor": [10, 10, 5], "burrow": "Tiefe+"},
           "rooms": [{"id": "a", "tpl": "refuge_beds", "bbox": [1, 1, 5, 3, 3, 5]},
                     {"id": "b", "tpl": "refuge_drink", "bbox": [4, 4, 5, 6, 6, 5]},
                     {"id": "c", "tpl": "refuge_beds", "bbox": [1, 1, 6, 3, 3, 6]},       # another level
                     {"id": "d", "tpl": "bedrooms", "bbox": [1, 1, 5, 3, 3, 5]}]}
    assert sites.refuge_ext(man) == [[1, 1, 5, 3, 3, 5], [4, 4, 5, 6, 6, 5]]
    assert sites.refuge_ext({"rooms": man["rooms"]}) == []


def test_refuge_beds_build_no_door():
    doc = bp.emit("refuge_beds", {"n": 6}, {"id": "S1", "anchor": [70, 70, 100], "rot": 0})
    built = [k for st, k, _, *_ in cell_rects(doc) if st["mode"] == "build"]
    assert "d" not in built and built.count("b") == 6, built          # old code: a door in the doorway
    dug = [(k, x0, y0) for st, k, _, x0, y0, *_ in cell_rects(doc) if st["mode"] == "dig"]
    assert ("d", 70, 71) in dug                                        # the doorway is still dug
