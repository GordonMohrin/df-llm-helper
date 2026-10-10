"""WP3 site finder: top 3 on revealed tiles only, placements that build and keep the fort sealed."""
import json

import pytest

from df_llm_helper import bp, schema as S
from df_llm_helper.bp import render
from df_llm_helper.bp.primitives import Xform, merge_manifest
from df_llm_helper.bp.render import World
from df_llm_helper.bp.sites import footprint
from df_llm_helper.bp.validate import _rooms

from bp_fixtures import fort_world, terrain

ROOMS = [t for t in sorted(bp.TEMPLATES) if t != "fortcore"]


@pytest.fixture(scope="module")
def land():
    return terrain().snapshot(purpose="sites")


@pytest.fixture(scope="module")
def fort():
    w, _ = fort_world(big=True)
    return w.snapshot(purpose="sites"), w.manifest


def _box_of(doc):
    xs, ys = [], []
    for st in doc["stages"]:
        for ch in st["chunks"]:
            for dx, dy, dz, t in ch["cells"]:
                xs.append(ch["pos"][0] + dx)
                ys.append(ch["pos"][1] + dy)
    return min(xs), min(ys), max(xs), max(ys)


def test_fortcore_sites(land):
    sites = bp.rank(land, "fortcore")
    assert [s["id"] for s in sites] == ["S1", "S2", "S3"]
    for s in sites:
        assert set(s) == {"id", "anchor", "rot", "score", "why"} and isinstance(s["score"], int)
        x, y, z = s["anchor"]
        assert z == 10 and land["rows"]["z10"][y][x] == "." and land["rows"]["z11"][y][x] == "_"
        docs = bp.emit_all("fortcore", {}, s)
        w = bp.as_built(docs, base=land)
        assert w.errors == []
        x0, y0, x1, y1 = _box_of(docs[0])
        assert x1 < 80 or x0 > 83                                     # never under the river
        assert bp.audit(w.snapshot(), w.manifest)["ok"]
    a, b = sites[0]["anchor"], sites[1]["anchor"]
    assert max(abs(a[0] - b[0]), abs(a[1] - b[1])) > 6                 # distinct sites


def test_fortcore_rejects_marks_and_water(land):
    best = bp.rank(land, "fortcore")[0]
    hub = list(Xform(best["anchor"], best["rot"]).pos(2, 45, -5))        # core hub tile of that site
    marked = {**land, "marks": {"damp": [hub]}}
    assert all(s["anchor"] != best["anchor"] or s["rot"] != best["rot"] for s in bp.rank(marked, "fortcore"))
    wet = World.from_snapshot(land)
    for yy in range(100):
        for xx in range(100):
            wet.set(xx, yy, 10, "~")
    assert bp.rank(wet.snapshot(), "fortcore") == []


def test_levels_below_the_snapshot_are_unknown_but_never_below_z0():
    shallow = terrain(z0=6, z1=12).snapshot(purpose="sites")      # snapshot stops 4 levels below the surface
    sites = bp.rank(shallow, "fortcore")
    assert sites and sites[0]["why"].endswith("5 levels below the snapshot")   # z5 core .. z1 refuge sump
    for s in sites:
        bp.emit("fortcore", {"stage": 3}, s)                       # still inside the map
    near_bottom = terrain(z0=0, z1=8, surf=6).snapshot(purpose="sites")
    assert bp.rank(near_bottom, "fortcore") == []                  # the refuge would fall below z 0


def test_fortcore_footprint_covers_all_stages():
    rects = footprint("fortcore", bp.check_params("fortcore", {}))
    assert (-4, 0, 6, 39) in rects[-1]                              # w=-1: entrance tunnel + stage-2 gallery
    assert min(rects) == -2 - 3 - 3 - 1                             # stage-3 refuge sump
    assert (-3, 42, -1, 44) in rects[-6]                            # the core well's sump beside the stair


def test_hidden_underground_is_unknown_not_open(land):
    """A fresh embark: everything below the surface is '?'. Sites exist; nothing hidden was read."""
    assert all(set(r) == {"?"} for r in land["rows"]["z5"])
    assert len(bp.rank(land, "fortcore")) == 3


def test_ranking_cannot_see_hidden_content(fort):
    """Two worlds that differ only behind unrevealed rock give byte-identical snapshots and rankings."""
    snap, man = fort
    w = World.from_snapshot(snap)
    hidden = [(x, y, 3) for x in range(0, 30) for y in range(80, 99) if w.get(x, y, 3) == "?"]
    assert hidden
    cave = World.from_snapshot(snap)
    for t in hidden:
        cave.set(*t, ".")           # the 'true' world holds a cave there ...
    seen = World.from_snapshot(cave.snapshot())
    for t in hidden:
        seen.set(*t, "?")           # ... but the exported snapshot shows unrevealed tiles as '?' only
    other = {**seen.snapshot(purpose="sites"), "bridges": snap["bridges"]}
    assert other == snap
    assert bp.rank(snap, "bedrooms", manifest=man) == bp.rank(other, "bedrooms", manifest=man)


@pytest.mark.parametrize("tpl", ROOMS)
def test_room_sites_build_inside_the_core(fort, tpl):
    snap, man = fort
    sites = bp.rank(snap, tpl, manifest=man)
    assert len(sites) == 3, tpl
    z4 = man["zones"]["Z4"]
    for s in sites:
        x, y, z = s["anchor"]
        assert any(b[0] <= x <= b[3] and b[1] <= y <= b[4] and b[2] <= z <= b[5] for b in z4)
        doc = bp.emit(tpl, {}, s)
        w = bp.as_built(doc, base=snap)
        assert w.errors == [], (tpl, s, w.errors[:3])
        assert _rooms(w, doc["manifest"]) == [], (tpl, s)
        w.manifest = merge_manifest(man, doc["manifest"])
        assert bp.audit(w.snapshot(), w.manifest)["ok"], (tpl, s)     # a new room never opens the fort


@pytest.mark.parametrize("tpl", ROOMS)
def test_room_sites_without_manifest_fail_closed(fort, tpl):
    """Without Z4 every revealed floor would be a candidate: the gallery corridor, the refuge level ..."""
    snap, man = fort
    for m in (None, {"v": 2}, {k: v for k, v in man.items() if k != "zones"}):
        with pytest.raises(ValueError, match="fort manifest"):
            bp.rank(snap, tpl, manifest=m)


def test_room_sites_prefer_stairs(fort):
    snap, man = fort
    sites = bp.rank(snap, "temple", manifest=man)
    assert len(sites) == 3 and sites[0]["score"] >= sites[1]["score"] >= sites[2]["score"]
    assert "steps to a stair" in sites[0]["why"]


def _near(box, b, margin=1, dz=0):
    return box[0] <= b[3] + margin and b[0] - margin <= box[3] and box[1] <= b[4] + margin and \
        b[1] - margin <= box[4] and box[2] <= b[5] + dz and b[2] - dz <= box[5]


@pytest.mark.parametrize("tpl", ROOMS)
def test_room_sites_keep_off_the_military_side_and_the_refuge(fort, tpl):
    snap, man = fort
    mil = [[s[0], s[1], s[2], s[0], s[1], s[3]] for s in man["stairs"]["mil"]]
    gal = man["stations"]["gallery"]
    attack = man["zones"]["Z1"] + man["zones"]["Z2"] + [k["bbox"] for k in man["killboxes"]]
    zr = man["refuge"]["anchor"][2]
    sites = bp.rank(snap, tpl, manifest=man, n=12)
    assert sites
    for s in sites:
        doc = bp.emit(tpl, {}, s)
        w = bp.as_built(doc, base=snap)
        dug = [(x, y, z) for x, y, z in _cells(doc)]
        box = (min(p[0] for p in dug), min(p[1] for p in dug), min(p[2] for p in dug),
               max(p[0] for p in dug), max(p[1] for p in dug), max(p[2] for p in dug))
        assert not any(_near(box, b) for b in mil + [[*gal, *gal]] + man["zones"]["Z3"]), (tpl, s)
        assert not any(_near(box, b, dz=1) for b in attack), (tpl, s)
        assert not box[2] <= zr <= box[5], (tpl, s)
        assert w.errors == []


def _cells(doc):
    for st in doc["stages"]:
        for ch in st["chunks"]:
            for dx, dy, dz, t in ch["cells"]:
                yield ch["pos"][0] + dx, ch["pos"][1] + dy, ch["pos"][2] + dz


def test_twelve_rooms_in_sequence():
    """The fort grows room by room: every room joins Z4, later rooms open from its public tiles (corridors,
    halls, stair levels), the fort stays sealed and the manifest stays small (inspect reply <= 8 KB)."""
    w, _ = fort_world(big=True)
    man = w.manifest
    seq = [("dining", {})] + [("bedrooms", {"n": 20})] * 5 + [("tombs", {}), ("hospital", {}), ("temple", {}),
                                                              ("tavern", {}), ("workshops", {}), ("farms", {})]
    private = []                    # bedroom zones and tombs/hospital/temple interiors: never a new doorway
    for tpl, p in seq:
        snap = w.snapshot(purpose="sites")
        sites = bp.rank(snap, tpl, p, manifest=man)
        assert sites, f"no site for {tpl} after {len(man.get('rooms', []))} rooms"
        for s in sites:
            assert not any(_near(s["anchor"] * 2, b, margin=0) for b in private), (tpl, s)
        doc = bp.emit(tpl, p, sites[0])
        private += [[x0, y0, z, x1, y1, z] for st, k, _, x0, y0, x1, y1, z in render.cell_rects(doc)
                    if st["mode"] == "zone" and k == "b"]
        private += [r["bbox"] for r in doc["manifest"].get("rooms", [])
                    if r["tpl"] in ("tombs", "hospital", "temple")]
        w = bp.as_built(doc, base=snap)
        assert w.errors == [], (tpl, w.errors[:3])
        assert _rooms(w, doc["manifest"]) == [], tpl
        man = merge_manifest(man, doc["manifest"])
        w.manifest = man
        res = bp.audit(w.snapshot(), man)
        assert res["ok"], (tpl, res["fails"])
    assert S.validate("manifest", man) == []
    assert len(man["zones"]["Z4"]) <= 50 and len(json.dumps(man, separators=(",", ":"))) < 8192
    assert set(bp.MOODABLE_TYPES) <= {ws["type"] for ws in man["workshops"]}      # P3: all 12 moodable
    assert sum(r["tpl"] == "bedrooms" for r in man["rooms"]) == 5


def test_farms_prefer_soil_then_shallow_levels(fort):
    snap, man = fort
    plain = bp.rank(snap, "farms", manifest=man)
    assert plain and "soil unknown" in plain[0]["why"]
    top = max(b[5] for b in man["zones"]["Z4"])
    assert plain[0]["anchor"][2] == top                             # shallowest Z4 level first
    deep = [s for s in bp.rank(snap, "farms", manifest=man, n=40) if s["anchor"][2] < top]
    assert deep
    doc = bp.emit("farms", {}, deep[0])
    plots = [(x, y, z) for st, k, _, x0, y0, x1, y1, z in render.cell_rects(doc) if k == "p"
             for x in range(x0, x1 + 1) for y in range(y0, y1 + 1)]
    soiled = {**snap, "marks": {"soil": [list(t) for t in plots]}}
    best = bp.rank(soiled, "farms", manifest=man)[0]
    assert (best["anchor"], best["rot"]) == (deep[0]["anchor"], deep[0]["rot"]) and "soil 70/70" in best["why"]
    assert bp.as_built(bp.emit("farms", {}, best), base=soiled).warnings == []


def test_rank_is_deterministic_and_respects_n(fort):
    snap, man = fort
    a = bp.rank(snap, "tombs", {"n": 12}, manifest=man, n=5)
    assert a == bp.rank(snap, "tombs", {"n": 12}, manifest=man, n=5) and len(a) == 5
    with pytest.raises(ValueError):
        bp.rank(snap, "tombs", {"n": 99})
