"""stockroom (BUG-028, Run 10 y419: 60 days of drink inside the core, 3093 units outside O1): a food stockpile for
drink and food in barrels and pots plus an optional still, sited inside the core like every room."""
import pytest

from dfpilot import bp
from dfpilot.bp.primitives import merge_manifest
from dfpilot.bp.render import cell_rects
from dfpilot.bp.validate import _rooms

from bp_fixtures import fort_world


@pytest.fixture(scope="module")
def fort():
    w, _ = fort_world(big=True)
    return w.snapshot(purpose="sites"), w.manifest


def piles(doc):
    return [(k, props, (x1 - x0 + 1) * (y1 - y0 + 1)) for st, k, props, x0, y0, x1, y1, z in cell_rects(doc)
            if st["mode"] == "place"]


def test_stockroom_inside_the_core(fort):
    snap, man = fort
    (s, *_) = bp.rank(snap, "stockroom", manifest=man)
    doc = bp.emit("stockroom", {}, s)
    w = bp.as_built(doc, base=snap)
    assert w.errors == [] and _rooms(w, doc["manifest"]) == []
    w.manifest = merge_manifest(man, doc["manifest"])
    assert bp.audit(w.snapshot(), w.manifest)["ok"]                        # never opens the fort
    assert any(b[0] <= s["anchor"][0] <= b[3] and b[1] <= s["anchor"][1] <= b[4] and b[2] <= s["anchor"][2] <= b[5]
               for b in man["zones"]["Z4"])
    got = piles(doc)
    assert [k for k, _, _ in got] == ["f"] * 3
    for _, props, n in got:                                                # one barrel or pot per tile
        assert props == f"name=dfllm-stock barrels={n}"
    assert sum(n for *_, n in got) == 9 * 6 - 9                           # the still takes 3x3
    assert doc["manifest"]["workshops"][0]["type"] == "Still" and doc["materials"]["workshop"] == 1
    assert any(st["mode"] == "burrow" and "Kern+" in c[3] for st in doc["stages"] for ch in st["chunks"]
               for c in ch["cells"])


def test_stockroom_without_still_and_sizes():
    site = {"id": "S1", "anchor": [70, 70, 100], "rot": 0}
    doc = bp.emit("stockroom", {"still": 0, "w": 7, "h": 5, "barrels": 12}, site)
    assert piles(doc) == [("f", "name=dfllm-stock barrels=12", 35)] and "workshops" not in doc["manifest"]
    with pytest.raises(ValueError):
        bp.emit("stockroom", {"h": 3}, site)                               # h >= 4
