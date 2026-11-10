"""BUG-634 (Run 16d i4 Trumpetrealms y431-y437): the gate and perimeter leftovers.
- `bridge.rebuild` with no lost bridge waiting stored the answer and gave O1 one more loss (Lua: tests/lua/test_bridge_rebuild.lua);
- R0 `levers:O1` named no reason (gate.lever_why, ready.lw: tests/lua/test_bug634_levers_why.lua; the status line here);
- status 'perimeter open 37 d (levers lost O1)' beside `seal at=last` 'nothing to close': the open part is no way in;
- the perimeter 'wanders' (27 seals in a run): the seal answer offers constructed walls."""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent))

from cli_v2_helpers import append_events, ev, make_runtime, reset_paths       # noqa: E402

from dfpilot import brief, cmd, files, schema                                 # noqa: E402


@pytest.fixture
def rt(tmp_path, monkeypatch):
    monkeypatch.delenv("DFLLM_SAVE", raising=False)
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def _put_ready(save, **ready):
    st = files.read_state(save)
    st["ready"] = dict({"lvl": 0, "worn": 0, "cv": 3, "drill_age": -1, "audit": {"ok": 0, "age": 100, "min_traps": 0},
                        "fail": ["open_perimeter"]}, **ready)
    st["seq"] += 10
    files.write_json_atomic(save / "state.a.json", st)
    files.write_json_atomic(save / "state.b.json", dict(st, seq=st["seq"] - 1))
    return st


def test_ready_lw_is_in_the_state_schema():
    r = {"lvl": 0, "worn": 0, "cv": 0, "drill_age": -1, "audit": {"ok": 0, "age": 1, "min_traps": 0}, "fail": ["levers:O1"],
         "lw": "O1: 1 of 2 levers linked: lever 1,2,3 stands, not linked to this bridge (2 d, no link job)"}
    doc = {"v": 2, "ready": r}
    pruned, notes = schema.prune_state(doc)
    assert pruned is None or pruned.get("ready", {}).get("lw") == r["lw"], (pruned, notes)
    assert not [n for n in notes if "lw" in n], notes


def test_a_perimeter_open_by_levers_is_told_in_the_seal_answer(rt):
    """Old: 'seal: nothing to close (the last entrance check names no open way in)' while status said PERIMETER OPEN 37 d."""
    _put_ready(rt, open=0, pd=37, pw="levers lost: O1", fail=["open_perimeter", "levers:O1"],
               lw="O1: 1 of 2 levers linked: lever 1,2,3 is placed, not built (5 d); 0 mechanisms free (no stone)")
    with pytest.raises(cmd.SealClosed, match="nothing to close") as ei:       # still 'done': plan check passes it
        cmd.seal_openings(rt, "last")
    msg = str(ei.value)
    assert "not a way in but 'levers lost: O1'" in msg and "0 mechanisms free" in msg, msg
    assert "link the levers" in msg, msg
    # a perimeter that is open by ways in only keeps the old text
    _put_ready(rt, open=0, pd=3, pw="2 ways in", fail=["open_perimeter"])
    with pytest.raises(cmd.SealClosed) as ei:
        cmd.seal_openings(rt, "last")
    assert "not a way in" not in str(ei.value)


def test_status_line_names_what_the_levers_wait_for(rt):
    _put_ready(rt, open=0, fail=["levers:O1"], lw="O1: 0 of 2 levers linked: lever 5,5,5 stands, not linked to this bridge (2 d, no link job)")
    ctx = type("C", (), {})()
    ctx.s = files.read_state(rt)
    ctx.dir = rt
    line = brief.line_unready(ctx, cmds=False)
    assert "levers: O1: 0 of 2 levers linked" in line, line


def test_the_wandering_perimeter_is_told_and_offers_walls(rt):
    now = files.read_state(rt)["t"]["abs"]
    evs = [ev(9000 + i, "PROJECT_DONE", f"c{i} (seal) done", {"proj": f"c{i}", "tpl": "seal"}, tick=now - 1000 * (i + 1))
           for i in range(4)]
    append_events(rt, evs)
    _put_ready(rt, open=1, ents=["7,8,140 floor"])
    at, notes = cmd.seal_openings(rt, "last")
    assert at.startswith("7,8,140"), at
    assert any("the perimeter wanders: 4 seals finished" in n and "close=wall" in n for n in notes), notes
    # an explicit close= is the player's choice: no advice
    at, notes = cmd.seal_openings(rt, "last", close="wall")
    assert not any("wanders" in n for n in notes), notes


def test_three_seals_do_not_wander(rt):
    now = files.read_state(rt)["t"]["abs"]
    append_events(rt, [ev(9100 + i, "PROJECT_DONE", "x", {"proj": f"c{i}", "tpl": "seal"}, tick=now - 100 * (i + 1))
                       for i in range(3)])
    _put_ready(rt, open=1, ents=["7,8,140 floor"])
    _, notes = cmd.seal_openings(rt, "last")
    assert not any("wanders" in n for n in notes), notes
