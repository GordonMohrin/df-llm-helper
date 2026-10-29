"""BUG-193 (FR-95 live test 1, i4): the documented `bp.place {"tpl":"aqshaft","site":"S1","p":{"x":..,"y":..,"top":..}}`
was refused with `bp.sites.rank(aqshaft): no ranking` (cmd.place ranked before bp.emit applied anchor_of_params); only
the explicit label `A<x>_<y>_<z>_0` worked. A template that names its own anchor from its params skips the ranking.
Fails on 9da84d6."""
import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import cmd


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def test_aqshaft_s1_with_the_column_in_p_is_placed_without_a_ranking(save):
    doc = cmd.place(save, "aqshaft", {"x": 200, "y": 200, "top": 90}, "S1", "aq1")
    assert (doc["tpl"], doc["anchor"], doc["rot"], doc["site"], doc["id"]) == ("aqshaft", [200, 200, 90], 0, "S1", "aq1")
    assert doc["stages"][0]["chunks"][0]["pos"] == [200, 200, 90]
    # the explicit anchor label keeps working
    doc2 = cmd.place(save, "aqshaft", {}, "A200_200_90_0", "aq2")
    assert doc2["anchor"] == [200, 200, 90]
    assert cmd.resolve_site(save, "aqshaft", "S1", {"x": 210, "y": 211, "top": 80})["anchor"] == [210, 211, 80]


def test_aqshaft_column_path_keeps_the_checks(save):
    with pytest.raises(cmd.BpError, match="together"):
        cmd.place(save, "aqshaft", {"x": 200}, "S1", "aq1")              # only some of x, y, top
    with pytest.raises(cmd.BpError):
        cmd.place(save, "aqshaft", {}, "S1", "aq1")                     # no column: still no ranking for a shaft
    cmd.emit_bp(save, "aqshaft", {"x": 200, "y": 200, "top": 90}, "S1", "aq1")
    with pytest.raises(cmd.BpError, match="overlaps"):
        cmd.place(save, "aqshaft", {"x": 200, "y": 200, "top": 90}, "S1", "aq3")
    assert cmd.own_anchor("bedrooms", {"n": 4}) is None                 # every other template ranks as before
