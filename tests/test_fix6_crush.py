"""BUG-251..254 (Run 15b Earthboat y374: soldier 24165 crushed by B1 going down after an automatic drill), Python side:
the contract of GATE_CRUSH_RISK and the new DRILL_RESULT fields, and BUG-254: status said 'drill never (auto: retry
wait)' right after an automatic drill had run, so the player could not tell the drill caused the lowering. The kernel side
is tests/lua/test_drill_restore.lua and tests/lua/test_gate_crush.lua."""
import json
from pathlib import Path
from types import SimpleNamespace

import pytest
from cli_v2_helpers import append_events, ev, make_runtime, reset_paths

from dfpilot import brief, schema

REPO = Path(__file__).resolve().parents[1]
NOW = 3 * 403200 + 200000
READY = {"lvl": 0, "worn": 100, "cv": 3, "drill_age": -1, "audit": {"ok": 0, "age": -1, "min_traps": 0},
         "fail": [], "open": 0, "dhold": "retry wait"}


def drill_line(r, b):
    ctx = SimpleNamespace(s={"ready": r}, b=b, now_tick=lambda: NOW)
    return next(t for _, t in brief.pop_items(ctx) if "drill" in t)


def result(tick, ok=0, why="auto: retry", restore=150):
    return {"n": 1, "tick": tick, "type": "DRILL_RESULT", "cls": "B", "msg": "drill failed",
            "d": {"pass": ok, "why": why, "restore": restore}}


def test_contract_gate_crush_risk_and_drill_result_fields():
    assert schema.EVENTS["GATE_CRUSH_RISK"][:2] == ("B", "gate")
    d = {"bridge": "B1", "unit": 24165, "k": "soldier", "to": "down", "pull": 150984669, "pos": [67, 82, 138]}
    assert schema.validate_event({"n": 1, "tick": 1, "type": "GATE_CRUSH_RISK", "cls": "B", "msg": "x", "d": d}) == [] \
        if hasattr(schema, "validate_event") else True
    assert "why:s restore:i" in (REPO / "dfpilot/schema.py").read_text("utf-8")
    assert "GATE_CRUSH_RISK = {cls = 'B', by = 'gate'}" in (REPO / "lua/dfllm/util/contract.lua").read_text("utf-8")


def test_bug254_status_names_the_failed_automatic_drill_behind_drill_never():
    t = drill_line(dict(READY), [result(NOW - 2400)])
    assert "drill never (auto: retry wait; run dfllm cmd drill) [last auto drill 2d ago failed]" in t, t
    t = drill_line(dict(READY), [result(NOW - 2400, why="inbox:llm", restore=-1)])
    assert "[last drill 2d ago failed, bridges not down in time]" in t, t


def test_bug254_no_note_for_a_pass_or_a_failure_older_than_the_last_pass():
    assert "[last" not in drill_line(dict(READY), [result(NOW - 2400, ok=1)])
    assert "[last" not in drill_line(dict(READY), [])
    r = dict(READY, drill_age=1200, dhold="passed")
    assert "[last" not in drill_line(r, [result(NOW - 2400)])          # failed before the newer pass
    t = drill_line(dict(READY, drill_age=36000), [result(NOW - 2400)])  # failed after an older pass
    assert t.startswith("R0 UNREADY") and "drill 30d [last auto drill 2d ago failed]" in t, t


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def test_bug254_status_scans_the_event_log_for_the_newest_drill_result(save):
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    st["ready"] = dict(READY)
    (save / "state.b.json").write_text(json.dumps(st), encoding="utf-8")
    now = brief.Ctx(save, full=False).now_tick()
    last = 0
    for ln in (save / "events.jsonl").read_text("utf-8").splitlines():
        try:
            last = max(last, json.loads(ln)["n"])
        except ValueError:                                  # (the fixture ends with a torn line)
            pass
    append_events(save, [ev(last + 1, "DRILL_RESULT", "drill failed: raised -1", {"pass": 0, "why": "auto: retry",
                                                                                  "restore": 120}, tick=now - 2400)])
    out = brief.status_text(save)
    assert "[last auto drill 2d ago failed]" in out, out
