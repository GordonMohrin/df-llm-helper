"""gallery_o1 (Run 10: the army waited in front of the raised O1 for weeks and nothing could hit it): the outward
crossbow gallery is sited from the fortcore manifest, builds without ever opening the fort, is reached only through
Z3, and the audit/validator reject a gallery that opens a way in, has no roof or faces nothing."""
import copy

import pytest

from dfpilot import bp, cmd, files
from dfpilot.bp import defense
from dfpilot.bp.primitives import Xform, merge_manifest

from bp_fixtures import FORTS, fort_docs, fort_world


def gallery_world(rot=0, stages=4):
    w, docs = fort_world(rot, stages=stages, big=True)
    snap = w.snapshot(purpose="sites")
    (site,) = bp.rank(snap, "gallery_o1", manifest=w.manifest)
    g = bp.emit("gallery_o1", {}, site)
    out = bp.as_built(g, base=snap)
    out.manifest = merge_manifest(w.manifest, g["manifest"])
    return out, docs, g, site


@pytest.mark.parametrize("rot", range(4))
def test_site_is_the_o1_frame_and_the_fort_stays_sealed(rot):
    w, docs, g, site = gallery_world(rot)
    X = Xform(FORTS[rot], rot)
    assert site["anchor"] == list(X.pos(0, 7, -2)) and site["rot"] == rot          # O1 footprint centre, same rot
    assert w.errors == []
    res = bp.audit(w.snapshot(), w.manifest)
    assert res["ok"] and res["fails"] == [] and res["min_traps"] == 35            # the hall still counts in full
    assert [str(f) for f in bp.validate(docs + [g])] == []
    (room,) = g["manifest"]["rooms"]
    assert room["tpl"] == "gallery_o1" and room["use"] == "utility"
    b = room["bbox"]
    gx, gy, gz = X.pos(3, 5, -2)                                                 # strip middle = the station
    assert b[0] <= gx <= b[3] and b[1] <= gy <= b[4] and b[2] == gz == b[5]
    assert (b[3] - b[0] + 1) * (b[4] - b[1] + 1) == 3
    # the fortifications face the tunnel in front of O1 and every strip tile sees one of them
    for u, v in defense.STRIP:
        assert w.get(*X.pos(u - 1, v + 7, -2)) == "F" and w.get(*X.pos(u - 2, v + 7, -2)) == "."
        assert w.get(*X.pos(u, v + 7, -1)) in "#?"                               # roofed by rock


def test_build_order_never_opens_the_fort():
    """Every prefix of the stages: no edge->Z3/Z4 path avoids the trap hall, nobody is shut in."""
    w0, docs = fort_world(0, big=True)
    snap = w0.snapshot(purpose="sites")
    g = bp.emit("gallery_o1", {}, bp.rank(snap, "gallery_o1", manifest=w0.manifest)[0])
    assert [s["label"] for s in g["stages"]] == ["g1.dig", "g1.build", "g2.dig", "g2.unburrow"]
    assert [s["mode"] for s in g["stages"]][:3] == ["dig", "build", "dig"]
    for k in range(1, len(g["stages"]) + 1):
        part = {**g, "stages": g["stages"][:k], "manifest": {"v": 2}}
        w = bp.as_built(part, base=snap)
        w.manifest = w0.manifest
        res = bp.audit(w.snapshot(), w.manifest)
        assert not res["bypass"] and res["ok"], (k, res["fails"])
    # the fortification line is built while the tiles behind it are still rock: builders stand in the tunnel
    first = bp.as_built({**g, "stages": g["stages"][:1], "manifest": {"v": 2}}, base=snap)
    X = Xform(FORTS[0], 0)
    for u, v in defense.FLINE:
        assert first.get(*X.pos(u, v + 7, -2)) == "." and first.get(*X.pos(u + 1, v + 7, -2)) in "#?"


def test_unburrow_covers_the_new_tiles():
    g = bp.emit("gallery_o1", {}, {"id": "S1", "anchor": [60, 60, 30], "rot": 0})
    st = next(s for s in g["stages"] if s["mode"] == "burrow")
    cells = [(ch["pos"], c) for ch in st["chunks"] for c in ch["cells"]]
    covered = set()
    for (px, py, pz), (dx, dy, dz, t) in cells:
        assert t.startswith("e(")                                                # erase from every burrow
        w, h = (int(a) for a in t[2:-1].split("x"))
        covered |= {(px + dx + i, py + dy + j) for i in range(w) for j in range(h)}
    assert {(60 + u, 60 + v) for u, v in defense.inside_tiles()} <= covered


@pytest.mark.parametrize("edit,code", [
    (lambda w, X: w.set(*X.pos(2, 5, -2), "."), "reachable without passing Z3"),      # a fortification dug out
    (lambda w, X: w.set(*X.pos(2, 5, -2), "+"), "reachable without passing Z3"),      # a door to the outside
    (lambda w, X: w.set(*X.pos(3, 5, -1), "_"), "not roofed"),
    (lambda w, X: [w.set(*X.pos(2, v, -2), "#") for v in (4, 5, 6)], "no fortification faces the O1 approach"),
])
def test_audit_rejects_a_bad_gallery(edit, code):
    w, docs, g, _ = gallery_world(0)
    w = copy.deepcopy(w)
    edit(w, Xform(FORTS[0], 0))
    res = bp.audit(w.snapshot(), w.manifest)
    assert any(f.startswith("gallery_o1: " + code) for f in res["fails"]), res["fails"]
    assert not res["ok"]


def test_validator_flags_a_way_in_through_the_gallery():
    docs = fort_docs(0)
    X = Xform(FORTS[0], 0)
    g = bp.emit("gallery_o1", {}, {"id": "S1", "anchor": list(X.pos(0, 7, -2)), "rot": 0})
    assert [str(f) for f in bp.validate(docs + [g])] == []
    bad = copy.deepcopy(g)
    for st in bad["stages"]:
        if st["mode"] == "build":                       # the fortifications never built: dug holes into the tunnel
            for ch in st["chunks"]:
                ch["cells"] = [c for c in ch["cells"] if not c[3].startswith("CF")] or [[0, 0, 0, "CF"]]
    bad["stages"] = [s for s in bad["stages"] if s["mode"] != "build"]
    got = {f.code for f in bp.validate(docs + [bad]) if f.level == "error"}
    assert {"bypass", "gallery_o1"} <= got, got


def test_rank_needs_the_fortcore_manifest():
    w, _ = fort_world(0, stages=1, big=True)
    with pytest.raises(ValueError, match="inner gallery station"):
        bp.rank(w.snapshot(purpose="sites"), "gallery_o1", manifest=w.manifest)
    w, _ = fort_world(0, stages=2, big=True)                                    # stage 2: no O1 yet is fine
    assert len(bp.rank(w.snapshot(purpose="sites"), "gallery_o1", manifest=w.manifest)) == 1
    snap = w.snapshot(purpose="sites")
    X = Xform(FORTS[0], 0)
    hole = copy.deepcopy(w)
    hole.set(*X.pos(8, 15, -2), ".")                                            # revealed open tile on the corridor
    with pytest.raises(ValueError, match="not rock"):
        bp.rank(hole.snapshot(purpose="sites"), "gallery_o1", manifest=w.manifest)
    undug = copy.deepcopy(w)
    undug.set(*X.pos(5, 26, -2), "#")                                           # inner gallery north end not dug
    with pytest.raises(ValueError, match="inner gallery is not dug"):
        bp.rank(undug.snapshot(purpose="sites"), "gallery_o1", manifest=w.manifest)
    assert snap                                                                 # (fixture sanity)


def test_place_ignores_the_fortcore_tiles_it_is_built_against(tmp_path):
    """cmd.place: the gallery touches the fortcore tunnel and inner gallery by design (bp.emit.ATTACHED); any other
    project still clashes."""
    w, docs = fort_world(0, big=True)
    save = tmp_path / "save"
    for i, d in enumerate(docs):
        cmd.write_bp(save, {**d, "id": f"y1s{i}b0", "site": "S1"})
    files.write_json_atomic(save / "snap" / "c1.json", {**w.snapshot(purpose="sites"), "id": "c1"})
    doc = cmd.place(save, "gallery_o1", {}, "S1", "c9")
    assert doc["anchor"] == list(Xform(FORTS[0], 0).pos(0, 7, -2)) and doc["tpl"] == "gallery_o1"
    occ = cmd.occupancy(save)
    assert occ.clash(doc) == []
    other = {**doc, "id": "c8", "tpl": "tombs"}                                 # the same tiles as a room: clash
    assert occ.clash(other)
