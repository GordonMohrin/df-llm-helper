"""BUG-686 (Run 16a i1 Basementflew, 16d i4 Trumpetrealms: new floor ways in on the rim every season, each sealed by hand): follow places
the seal at=last itself in PEACE when the state's ready.ents names a way in without a door; never in a siege, never with --no-auto, never
twice within PERIM_COOLDOWN_S, never when nothing is open or a seal builds those tiles; a placement that finds nothing to close is no AUTO_FAIL."""
import json

import pytest
from cli_v2_helpers import append_events, inbox_docs, make_runtime, reset_paths

from dfpilot import files, wake

TICK = 100_000
ENT = "100,127,122 floor"


@pytest.fixture
def save(tmp_path):
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


class Clock:
    def __init__(self, t=1_000_000.0):
        self.t = t

    def __call__(self):
        return self.t


def _state(save, mode="PEACE", ents=(ENT,), open_n=None):
    p = save / "state.b.json"
    st = json.loads(p.read_text("utf-8"))
    st["mode"] = mode
    ready = dict(st.get("ready") or {})
    ready["ents"], ready["open"] = list(ents), (len(ents) if open_n is None else open_n)
    if not ents:
        ready.pop("ents")
    st["ready"] = ready
    p.write_text(files.dumps(st), encoding="utf-8")


def _follow(clock, **kw):
    out = []
    f = wake.Follower(out=out.append, clock=clock, **kw)
    return f, out


def _answer_snapshot(save, f):
    (snap_cmd,) = inbox_docs(save)
    assert snap_cmd["verb"] == "snapshot" and snap_cmd["args"] == {"purpose": "sites"}
    for p in (save / "inbox").glob("*.json"):
        p.unlink()
    sid = snap_cmd["id"]
    snap = json.loads((save / "snap" / "c201.json").read_text("utf-8"))
    snap["id"] = sid
    files.write_json_atomic(save / "snap" / f"{sid}.json", snap)
    append_events(save, [{"n": 9100, "tick": TICK, "type": "SNAPSHOT_READY", "cls": "C", "msg": "",
                          "d": {"id": sid, "path": f"snap/{sid}.json", "purpose": "sites"}}])
    f.poll()


def test_follow_seals_the_open_rim_in_peace_once(save):
    pytest.importorskip("dfpilot.bp.sites")
    c = Clock()
    f, out = _follow(c)
    f.poll()
    _state(save)
    c.t += wake.PERIM_CHECK_EVERY_S + 1
    f.poll()
    _answer_snapshot(save, f)
    (place,) = inbox_docs(save)
    assert place["verb"] == "bp.place" and place["by"] == "follow"
    assert place["args"] == {"tpl": "seal", "site": "S1", "p": {"at": "ents"}}
    bp = json.loads((save / "bp" / f"{place['id']}.json").read_text("utf-8"))
    assert bp["tpl"] == "seal" and bp["params"]["at"].startswith("100,127,122 floor")
    assert "auto:perim" in (save / "cli.log").read_text("utf-8")
    for p in (save / "inbox").glob("*.json"):
        p.unlink()
    c.t += wake.PERIM_CHECK_EVERY_S + 1                       # the next look: a seal project builds the tile, nothing to place
    f.poll()
    assert inbox_docs(save) == [] and out == []
    c.t += wake.PERIM_COOLDOWN_S + 1
    f.poll()
    assert inbox_docs(save) == []                             # still: the project covers the tile (seal_openings leaves it out)


def test_follow_places_no_perimeter_seal_in_a_siege_without_auto_or_with_nothing_open(save):
    pytest.importorskip("dfpilot.bp.sites")
    for mode, kw, ents in (("SIEGE", {}, (ENT,)), ("BREACH", {}, (ENT,)), ("PEACE", {"auto": False}, (ENT,)), ("PEACE", {}, ())):
        _state(save, mode=mode, ents=ents)
        c = Clock()
        f, out = _follow(c, **kw)
        f.poll()
        c.t += wake.PERIM_CHECK_EVERY_S + 1
        f.poll()
        assert inbox_docs(save) == [], (mode, kw, ents)
        assert out == []


def test_follow_waits_between_two_perimeter_looks(save):
    pytest.importorskip("dfpilot.bp.sites")
    c = Clock()
    f, _ = _follow(c)
    f.poll()
    _state(save)
    c.t += 5                                                  # under PERIM_CHECK_EVERY_S: no look yet
    f.poll()
    assert inbox_docs(save) == []
    c.t += wake.PERIM_CHECK_EVERY_S
    f.poll()
    assert [d["verb"] for d in inbox_docs(save)] == ["snapshot"]


def test_a_placement_that_finds_nothing_to_close_is_no_auto_fail(save, monkeypatch):
    pytest.importorskip("dfpilot.bp.sites")
    from dfpilot import cmd
    c = Clock()
    f, out = _follow(c)
    f.poll()
    _state(save)
    c.t += wake.PERIM_CHECK_EVERY_S + 1
    f.poll()
    # a door appeared between the check and the snapshot: seal_openings refuses with SealClosed at place time
    def closed(*a, **k):
        raise cmd.SealClosed("seal: nothing to close (the snapshot shows a door there)")
    monkeypatch.setattr(cmd, "seal_openings", closed)
    _answer_snapshot(save, f)
    assert inbox_docs(save) == []
    assert not any("AUTO_FAIL" in ln for ln in out), out
    assert "nothing to place" in (save / "cli.log").read_text("utf-8")


def test_at_ents_seals_only_the_confirmed_ways_in_not_a_leak_or_an_unconfirmed_tile(save):
    """BUG-686 (verifier): follow's seal is at=ents: the tiles of the entrance check's ents, never a SEAL_LEAK tile nor a refuge tile."""
    pytest.importorskip("dfpilot.bp.sites")
    from dfpilot import cmd
    _state(save)
    append_events(save, [{"n": 9200, "tick": TICK, "type": "SEAL_LEAK", "cls": "B", "msg": "leak via a floor",
                          "d": {"pos": [50, 60, 122], "bld": "floor"}}])
    both = cmd.current_openings(save)
    assert {e["src"] for e in both} >= {"ents", "leak"}, both
    at_last, _ = cmd.seal_openings(save, "last")
    assert "50,60,122" in at_last and "100,127,122" in at_last
    at_ents, _ = cmd.seal_openings(save, "ents")
    assert "100,127,122" in at_ents and "50,60,122" not in at_ents, at_ents
