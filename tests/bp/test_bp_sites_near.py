"""FR-78 (Run 14 note 65): `bp sites` ranked automatically and could not be asked for a position or "beside building X".
`rank(near=, within=, at=)` and `dfllm bp sites <tpl> --near x,y,z [--within N] | --at x,y,z`."""
import pytest

from dfpilot.bp.sites import rank

from bp_fixtures import fort_world


@pytest.fixture(scope="module")
def fort():
    w, _ = fort_world(big=True)
    return w.snapshot(purpose="sites"), w.manifest


def test_near_keeps_the_sites_within_the_distance_nearest_first(fort):
    snap, man = fort
    plain = rank(snap, "bedrooms", {"n": 12}, manifest=man, n=12)
    pt = [67, 62, 5]                                         # the fort's far corner: plain S12 stands there
    got = rank(snap, "bedrooms", {"n": 12}, manifest=man, n=5, near=pt, within=15)
    assert got and got != plain[:len(got)], "old: the ranking ignored the point"
    assert [s["id"] for s in got] == [f"S{i + 1}" for i in range(len(got))]
    assert all("tiles from 67,62,5" in s["why"] for s in got)
    dist = [int(s["why"].rsplit(", ", 1)[1].split(" tiles")[0]) for s in got]
    assert dist == sorted(dist) and max(dist) <= 15, dist
    far = rank(snap, "bedrooms", {"n": 12}, manifest=man, n=12, near=pt, within=200)
    assert len(far) >= len(got)


def test_near_default_distance_and_the_refusal_names_the_nearest(fort):
    snap, man = fort
    with pytest.raises(ValueError) as e:
        rank(snap, "bedrooms", {"n": 12}, manifest=man, near=[500, 500, 120], within=5)
    msg = str(e.value)
    assert "no site within 5 tiles of 500,500,120" in msg and "the nearest candidate" in msg and "--within" in msg
    with pytest.raises(ValueError, match="within 12 tiles"):
        rank(snap, "bedrooms", {"n": 12}, manifest=man, near=[500, 500, 120])


def test_at_takes_the_exact_anchor_or_names_the_nearest_valid_one(fort):
    snap, man = fort
    plain = rank(snap, "bedrooms", {"n": 12}, manifest=man, n=12)
    a = plain[0]["anchor"]
    got = rank(snap, "bedrooms", {"n": 12}, manifest=man, at=a)
    assert got and all(s["anchor"] == a for s in got) and ", at " + ",".join(map(str, a)) in got[0]["why"]
    sx, sy = man["stairs"]["civ"][0][:2]           # BUG-157: the civilians' stair is no anchor
    with pytest.raises(ValueError) as e:
        rank(snap, "bedrooms", {"n": 12}, manifest=man, at=[sx, sy, a[2]])
    msg = str(e.value)
    assert f"{sx},{sy},{a[2]} is no valid anchor" in msg and "bp.place site=A" in msg, msg


def test_without_near_nothing_changes(fort):
    snap, man = fort
    assert rank(snap, "bedrooms", {"n": 12}, manifest=man, n=5) == rank(snap, "bedrooms", {"n": 12}, manifest=man, n=5,
                                                                         near=None, within=None, at=None)
    assert rank(snap, "tombs", {"n": 12}, manifest=man) == rank(snap, "tombs", {"n": 12}, manifest=man, within=3)
