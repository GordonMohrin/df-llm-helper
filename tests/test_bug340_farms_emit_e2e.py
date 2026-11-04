"""BUG-340 review (r15 famine verdict: every Python test of follow's farms fallback replaced `_send` by a mock; that the
real placement finds a site when the requested room has 0 ranked was unproven). End to end on the BUG-316 snapshot (live
Inkintense shape: no rock to dig a farm room, soil floor under open sky with trees cutting every 11-wide block): follow's
`_place_farms` with the real `cmd.send` / `emit_bp` tries the room at plots 2 and 1 (no site), then in PEACE the surface
farm, which `cmd.place` itself places with plots 1 (BUG-316); outside PEACE nothing is placed and the first error stands."""
from __future__ import annotations

import json

import pytest
from cli_v2_helpers import make_runtime, reset_paths
from test_bug316_surface_farm_emit import _man, _snap

from dfpilot import cmd, plan, wake


@pytest.fixture(autouse=True)
def _surface_core_on(monkeypatch):
    """BUG-413: surface farm plots are drafted/tried only with plan.surface_core true (default false); these tests are about them."""
    from dfpilot import plan as _plan
    monkeypatch.setattr(_plan, "surface_core_on", lambda: True)


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    snap, man = _snap(), _man()
    monkeypatch.setattr(cmd, "sites_snapshot", lambda _d: snap)
    monkeypatch.setattr(plan, "sites_snapshot", lambda _d: snap)
    monkeypatch.setattr(cmd, "fort_manifest", lambda _d: man)
    yield d
    reset_paths()


def put_mode(save, mode):
    for slot in "ab":
        p = save / f"state.{slot}.json"
        doc = json.loads(p.read_text("utf-8"))
        doc["mode"] = mode
        p.write_text(json.dumps(doc), encoding="utf-8")


def test_follow_places_a_surface_farm_through_the_real_emit(save):
    put_mode(save, "PEACE")
    f = wake.Follower(out=lambda s: None, clock=lambda: 1000.0)
    f.dir = save
    args = {"tpl": "farms", "site": "S1", "p": {"plots": 2}, "prio": 1}
    cid = f._place_farms(args, 1000.0, None)
    assert args["p"] == {"plots": 2, "surface": 1}
    doc = json.loads((save / "bp" / f"{cid}.json").read_text("utf-8"))
    assert doc["params"]["surface"] == 1 and doc["params"]["plots"] == 1, doc["params"]
    inbox = [json.loads(p.read_text("utf-8")) for p in (save / "inbox").glob("*.json")]
    assert any(m.get("verb") == "bp.place" and m.get("args", {}).get("p", {}).get("surface") == 1 for m in inbox), inbox
    log = (save / "cli.log").read_text("utf-8")
    assert "BUG-340" in log and "placed with" in log


def test_follow_outside_peace_places_nothing_through_the_real_emit(save):
    put_mode(save, "ALERT")
    f = wake.Follower(out=lambda s: None, clock=lambda: 1000.0)
    f.dir = save
    before = sorted(p.name for p in (save / "bp").glob("*.json") if not p.name.startswith(".")) if (save / "bp").exists() else []
    with pytest.raises(cmd.BpError, match="plots=2"):
        f._place_farms({"tpl": "farms", "site": "S1", "p": {"plots": 2}}, 1000.0, None)
    after = sorted(p.name for p in (save / "bp").glob("*.json") if not p.name.startswith(".")) if (save / "bp").exists() else []
    assert after == before, "no farms doc written outside PEACE"
