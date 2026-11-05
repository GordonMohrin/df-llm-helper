"""BUG-424 (Run 16a i1 Manorsubtle, Mansionlauded, Bachwald: a brook in a rock gully 8-15 tiles from the start, no bank floor, three
forts died of thirst): the cistern planner offers a sealed rock intake (shaft top and breach dug in rock by the template, the pipe
with its breaker, fortification and floodgate does the last tiles); no free digging at the water. Fails on 03f4c1a."""
import json

import pytest

from dfpilot import bp
from dfpilot.bp import sites
from dfpilot.bp.render import World

from test_bp_cistern import valley


def gully(walls_above=True, z_corridor=5):
    """valley(): rock walls on both sides of a river at the bank level z6 (x=10), nothing but rock beside it; the fort's corridor
    at z_corridor (x40-50, y15)."""
    snap, man = valley()
    w = World.from_snapshot(snap)
    for y in range(30):
        w.set(10, y, 5, "?")
        w.set(10, y, 6, "~")
        for x in list(range(4, 10)) + list(range(11, 17)):
            w.set(x, y, 6, "#")
            if walls_above:
                w.set(x, y, 7, "#")
    if z_corridor != 5:
        for y in range(30):
            for x in range(17, 60):
                w.set(x, y, 6, "?")                                                # rock round a corridor that lies on z6
        for x in range(40, 51):
            w.set(x, 15, 5, "?")
            w.set(x, 15, z_corridor, ".")
        man = {"v": 2, "zones": {"Z4": [[40, 15, z_corridor, 50, 15, z_corridor]]}}
    return w.snapshot(purpose="sites"), man


def test_a_gully_has_no_bank_intake_but_a_sealed_rock_one():
    snap, man = gully()
    with pytest.raises(ValueError):
        sites.plan_cistern(snap, man, "core", safe=False, rock=False)          # old behaviour: no bank floor beside the water
    plan = sites.plan_cistern(snap, man, "core", safe=False)                   # rock=None: the bank kind first, then the rock one
    assert plan["rock"] == 1 and "sealed rock intake" in plan["why"]
    p = plan["params"]
    assert p["water"] == "bank"
    doc = bp.emit("cistern", p, plan["site"])
    # the template does the digging: shaft, breach, pipe; the planner invents no tile of its own
    assert "breach" in [s["label"] for s in doc["stages"]] and "shaft" in [s["label"] for s in doc["stages"]]
    assert bp.rank(snap, "cistern", p, manifest=man)[0]["anchor"] == plan["site"]["anchor"]     # rank takes the same intake


def test_rock_intake_needs_rock_above_and_round_the_shaft_top():
    snap, man = gully(walls_above=False)                                          # open air over the gully walls
    with pytest.raises(ValueError):
        sites.plan_cistern(snap, man, "core", safe=False)
    snap, man = gully()
    w = World.from_snapshot(snap)
    for y in range(30):
        for x in (8, 12):
            w.set(x, y, 6, ".")                                                    # a floor tile at B's ring on both sides: not sealed
    for y in range(30):
        w.set(9, y, 6, "#")
        w.set(11, y, 6, "#")
    with pytest.raises(ValueError):
        sites.plan_cistern(w.snapshot(purpose="sites"), man, "core", safe=False)


def test_cistern_access_safe_plan_and_unsafe_flag():
    snap, man = gully()
    acc = sites.cistern_access(snap, man, near=[10, 15, 6], radius=20, level="core")
    assert acc["plan"] is not None and acc["unsafe"] is True                       # the river z6 lies above the well room z5
    assert acc["site"].startswith("A") and acc["site"].count("_") == 3
    snap, man = gully(z_corridor=6)                                               # well room one level up: not above it
    acc = sites.cistern_access(snap, man, near=[10, 15, 6], radius=20, level="core")
    assert acc["plan"] is not None and acc["unsafe"] is False
    assert json.dumps(acc["plan"]["params"])


def test_cistern_access_says_why_without_water():
    snap, man = valley()
    w = World.from_snapshot(snap)
    for y in range(30):
        w.set(10, y, 5, "?")                                                       # no water at all
    acc = sites.cistern_access(w.snapshot(purpose="sites"), man, near=[10, 15, 6], radius=20, level="core")
    assert acc["plan"] is None and "no revealed water" in acc["why"]
