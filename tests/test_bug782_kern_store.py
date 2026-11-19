"""BUG-782 (Run 16a i1 Basementflew y543: `bp.place refuge_drink` refused 'no refuge in the fort manifest', the pop ceiling held on refuge_dry;
Run 16b i2 Whirledrampart y451: no cistern route): with no refuge room in the manifest the refuge_drink store is ranked off a Kern+ fortcore room,
and `p.burrow=Kern+` makes it join the core (Z4) like any room. With no Kern+ room either the refusal stays, and names the kernel's own pile."""
import pytest

from dfpilot import bp
from dfpilot.bp import sites

from bp_fixtures import fort_world


@pytest.fixture(scope="module")
def fort():
    w, _ = fort_world(big=True)
    return w.snapshot(purpose="sites"), w.manifest


def test_ranks_off_a_kern_room_when_the_manifest_has_no_refuge(fort):
    snap, man = fort
    no_ref = {k: v for k, v in man.items() if k != "refuge"}
    assert sites.kern_rooms(no_ref), "the fixture has a Kern+ fortcore room"
    assert sites.kern_store("refuge_drink", no_ref) and not sites.kern_store("refuge_drink", man)
    assert not sites.kern_store("refuge_beds", no_ref)
    ranked = bp.rank(snap, "refuge_drink", {"n": 6}, manifest=no_ref)
    assert ranked, "sites exist off the Kern+ rooms"
    kern = sites.kern_rooms(no_ref)
    for c in ranked:
        ax, ay, az = c["anchor"]
        assert any(b[0] <= ax <= b[3] and b[1] <= ay <= b[4] and b[2] <= az <= b[5] for b in kern), c
        assert "BUG-319" not in c["why"], "no refuge room: no 'dug off a refuge-level room' malus"


def test_burrow_kern_store_joins_the_core_but_the_refuge_store_never_does(fort):
    snap, man = fort
    no_ref = {k: v for k, v in man.items() if k != "refuge"}
    c = bp.rank(snap, "refuge_drink", {"n": 6}, manifest=no_ref)[0]
    site = {"id": "S1", "anchor": c["anchor"], "rot": c["rot"]}
    kern = bp.emit("refuge_drink", {"n": 6, "burrow": "Kern+"}, site)
    assert kern["manifest"]["zones"]["Z4"], "p.burrow=Kern+: the room joins Z4"
    refuge = bp.emit("refuge_drink", {"n": 6}, site)
    assert "zones" not in refuge["manifest"], "the refuge store stays out of Z4"


def test_no_kern_room_no_refuge_keeps_the_refusal_and_names_the_pile(fort):
    snap, man = fort
    bare = {k: v for k, v in man.items() if k != "refuge"}
    bare["rooms"] = [r for r in bare.get("rooms", []) if r.get("tpl") != "fortcore"]
    with pytest.raises(ValueError) as e:
        bp.rank(snap, "refuge_drink", {}, manifest=bare)
    msg = str(e.value)
    assert "no refuge in the fort manifest" in msg and "no Kern+ fortcore room" in msg and "dfllm-drink pile" in msg, msg
