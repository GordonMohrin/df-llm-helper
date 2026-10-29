"""BUG-280 (Run 15 Inkintense y372): `audit` said 'fail: refuge: none (manifest refuge.anchor) or not walkable' right
after fortcore stage 1, while stages 2/3 were planned. The refuge comes with fortcore stage 3 (its manifest fragment
adds refuge.anchor): a manifest without a refuge is a stage still to come, no fail; refuge_sep stays false."""
import pytest

from dfpilot import bp

from bp_fixtures import fort_world


@pytest.fixture(scope="module")
def built():
    w, _ = fort_world()
    return w.snapshot(), w.manifest


def test_no_refuge_in_the_manifest_is_pending_not_a_fail(built):
    snap, man = built
    early = {k: v for k, v in man.items() if k != "refuge"}
    info: dict = {}
    res = bp.audit(snap, early, info=info)
    assert not any(f.startswith("refuge:") for f in res["fails"]), res["fails"]
    assert res["refuge_sep"] is False                                     # readiness R0 keeps asking for it
    assert info["pending"] == ["refuge: pending fortcore stage 3 (no refuge in the manifest yet)"]


def test_a_manifest_refuge_that_is_not_walkable_still_fails(built):
    snap, man = built
    bad = {**man, "refuge": {"anchor": [-500, -500, -500], "burrow": "Tiefe+"}}
    info: dict = {}
    res = bp.audit(snap, bad, info=info)
    assert "refuge: none (manifest refuge.anchor) or not walkable" in res["fails"]
    assert not res["ok"] and "pending" not in info
