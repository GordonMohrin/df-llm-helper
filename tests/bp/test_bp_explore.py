"""Run 10 (Handlelock: iron stuck at 8 bars for years, no ore found): the `explore` template (a stair shaft with side
tunnels below the core) and its site ranking on revealed tiles only."""
import pytest

from dfpilot import bp, schema
from dfpilot.bp import mine, sites
from dfpilot.bp.primitives import merge_manifest
from dfpilot.bp.render import World

from bp_fixtures import fort_docs, terrain


@pytest.fixture(scope="module")
def deep():
    """The fortcore on a 32-level map: the core (Z4) at z25..28, the refuge at z22, hidden rock down to z1."""
    w = bp.as_built(fort_docs(anchor=[50, 20, 30]), base=terrain(z0=1, z1=32, surf=30).snapshot())
    return w.snapshot(purpose="sites"), w.manifest


def _cells(doc):
    for st in doc["stages"]:
        for ch in st["chunks"]:
            for dx, dy, dz, t in ch["cells"]:
                yield (ch["pos"][0] + dx, ch["pos"][1] + dy, ch["pos"][2] + dz), t


def test_explore_shaft_and_tunnels():
    p = bp.check_params("explore", {})
    assert p == {"depth": 12, "arm": 6, "every": 3, "avoid": ""}
    d = bp.emit("explore", {}, {"id": "S1", "anchor": [70, 70, 100], "rot": 0})
    assert d["class"] == "infra" and d["materials"] == {} and "zones" not in d["manifest"]   # no Z4: not a room
    w = bp.as_built(d)
    assert w.errors == []
    assert [w.get(70, 71, z) for z in range(100, 87, -1)] == [">"] + ["X"] * 11 + ["<"]   # j .. i .. u (z88)
    assert mine.tunnel_levels(p) == [-3, -6, -9, -12]
    for z in (97, 94, 91, 88):                                      # W, E and S arms of 6 tiles on each tunnel level
        assert all(w.get(70 + du, 71, z) == "." for du in (-6, -1, 1, 6))
        assert w.get(70, 77, z) == "." and w.get(70, 78, z) == "#" and w.get(77, 71, z) == "#"
        assert w.get(70, 70, z) == "#"                               # nothing north of the shaft
    assert w.get(69, 71, 96) == "#" and w.get(71, 71, 96) == "#"     # only the shaft between tunnel levels
    assert [k for (x, y, z), k in _cells(d) if z == 100] == ["j"]    # nothing else on the anchor level
    assert mine.tunnel_levels({"depth": 7, "every": 3}) == [-3, -6, -7]


def test_explore_avoid_levels_parse_and_refuse():
    assert mine.parse_avoid("113, 95-97,") == {95, 96, 97, 113}
    assert mine.parse_avoid("") == set()
    for bad in ("x", "5-a", "-3", "1-900"):
        with pytest.raises(ValueError, match="explore.avoid"):
            bp.emit("explore", {"avoid": bad}, {"id": "S1", "anchor": [70, 70, 100], "rot": 0})


def test_explore_sites_below_the_core_never_from_the_refuge(deep):
    snap, man = deep
    zr = man["refuge"]["anchor"][2]
    sites = bp.rank(snap, "explore", {}, manifest=man)
    assert len(sites) == 3
    z4 = man["zones"]["Z4"]
    for s in sites:
        x, y, z = s["anchor"]
        assert any(b[0] <= x <= b[3] and b[1] <= y <= b[4] and b[2] <= z <= b[5] for b in z4)
        assert z > zr and "levels below the top of the core" in s["why"]
        doc = bp.emit("explore", {}, s)
        w = bp.as_built(doc, base=snap)
        assert w.errors == [], w.errors[:3]
        w.manifest = merge_manifest(man, doc["manifest"])
        assert bp.audit(w.snapshot(), w.manifest)["ok"]          # the shaft never opens the fort
        refuge = [r["bbox"] for r in man["rooms"] if r["id"].endswith("_refuge")]
        for (cx, cy, cz), _ in _cells(doc):                       # passes the refuge level, never next to the refuge
            assert not any(b[0] - 1 <= cx <= b[3] + 1 and b[1] - 1 <= cy <= b[4] + 1 and b[2] <= cz <= b[5]
                           for b in refuge)
    assert sites[0]["score"] >= sites[1]["score"] >= sites[2]["score"]
    with pytest.raises(ValueError, match="fort manifest"):
        bp.rank(snap, "explore", {}, manifest={"v": 2})


def test_explore_sites_keep_off_avoided_and_cavern_levels(deep):
    snap, man = deep
    with pytest.raises(ValueError, match=r"avoided level \(z20"):
        bp.rank(snap, "explore", {"avoid": "20"}, manifest=man)
    assert bp.rank(snap, "explore", {"avoid": "20", "depth": 2}, manifest=man)       # z25 -> z23: clear of z20
    cave = {**snap, "marks": {**snap.get("marks", {}), "cavern": [[10, 90, 16]]}}    # a revealed cavern tile at z16
    with pytest.raises(ValueError, match=r"avoided level \(z16"):
        bp.rank(cave, "explore", {}, manifest=man)
    assert [s["why"].split(", ")[2] for s in bp.rank(cave, "explore", {"depth": 6}, manifest=man)][0] == "shaft to z19"


def test_explore_sites_stop_above_a_recorded_cavern_breach(deep):
    """Run 11 (y432-433: explores kept breaking into the cavern lakes on z127, far below the sites snapshot): the
    kernel's manifest `caverns` (the tiles where a dig broke into a cavern) keeps every shaft above those levels, so
    `plan propose` (fit_explore) fits the depth above them."""
    snap, man = deep
    cav = {**man, "caverns": [[90, 10, 16]]}                   # a breach far from the core, below the snapshot
    assert schema.validate("manifest", cav) == []
    assert sites.avoid_levels(snap, {}, cav) == {16} and sites.avoid_levels(snap, {}) == set()
    with pytest.raises(ValueError, match=r"avoided level \(z16.*cavern breach"):
        bp.rank(snap, "explore", {}, manifest=cav)
    best = bp.rank(snap, "explore", {"depth": 6}, manifest=cav)
    assert best and all(int(s["why"].split("shaft to z")[1].split(",")[0]) > 16 for s in best)
    assert bp.rank(snap, "explore", {}, manifest=man)             # without the record depth 12 still fits


def test_explore_hidden_rock_is_diggable_revealed_space_is_not(deep):
    """Hidden rock is unknown, never open (fair play: no hidden tile is read); a revealed open tile beside a tunnel
    keeps that placement out (a tunnel must not break into a known space)."""
    snap, man = deep
    best = bp.rank(snap, "explore", {}, manifest=man)[0]
    assert int(best["why"].split(" unknown tiles")[0].rsplit(" ", 1)[1]) > 500
    doc = bp.emit("explore", {}, best)
    tun = [p for p, k in _cells(doc) if p[2] == best["anchor"][2] - 12 and k.startswith("d")][0]
    w = World.from_snapshot(snap)
    w.set(tun[0], tun[1] - 1 if tun[1] > 0 else tun[1] + 1, tun[2], ".")    # a revealed open tile beside a tunnel
    again = bp.rank(w.snapshot(purpose="sites") | {"bridges": snap["bridges"]}, "explore", {}, manifest=man)
    assert all((s["anchor"], s["rot"]) != (best["anchor"], best["rot"]) for s in again)
