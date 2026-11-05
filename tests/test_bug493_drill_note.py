"""BUG-493 (Run 16d i4 Trumpetrealms y382-y387, i2 Roadvises: `cmd drill` "started", status `drill never`, P5 waits for the
drill, 45 drills none passed), Python side: DRILL_RESULT carries `fails` and `mech`, the state's ready block may carry
`drill_mech_age`, and status names what failed ("[last auto drill 38d ago failed: up:B1, worn<90; bridges ok]") instead of
only `drill never`. The kernel side is tests/lua/test_bug493_drill.lua and tests/lua/test_bug492_493_traffic.lua."""
from pathlib import Path
from types import SimpleNamespace

from dfpilot import brief, schema

REPO = Path(__file__).resolve().parents[1]
NOW = 3 * 403200 + 200000
READY = {"lvl": 0, "worn": 50, "cv": 3, "drill_age": -1, "audit": {"ok": 0, "age": -1, "min_traps": 0},
         "fail": [], "open": 0, "dhold": "blocked:worn"}


def drill_line(r, b):
    ctx = SimpleNamespace(s={"ready": r}, b=b, now_tick=lambda: NOW)
    return next(t for _, t in brief.pop_items(ctx) if "drill" in t)


def result(tick, fails=None, mech=None, restore=150):
    d = {"pass": 0, "why": "auto: retry", "restore": restore}
    if fails is not None:
        d["fails"] = fails
    if mech is not None:
        d["mech"] = mech
    return {"n": 1, "tick": tick, "type": "DRILL_RESULT", "cls": "B", "msg": "drill failed", "d": d}


def test_contract_drill_result_fails_and_mech_and_ready_mech_age():
    assert "fails:sa mech:f" in (REPO / "dfpilot/schema.py").read_text("utf-8")
    assert "drill_mech_age" in (REPO / "dfpilot/schema.py").read_text("utf-8")
    assert "drill_mech_age" in (REPO / "lua/dfllm/util/contract.lua").read_text("utf-8")
    ev = {"n": 1, "tick": 5, "type": "DRILL_RESULT", "cls": "B", "msg": "x",
          "d": {"pass": 0, "restore": -1, "fails": ["up:B1", "worn<90"], "mech": 0}}
    assert schema.validate_event(ev) == [] if hasattr(schema, "validate_event") else True


def test_status_names_what_the_last_drill_failed_on():
    t = drill_line(dict(READY), [result(NOW - 2400, ["up:B1", "slow:O1", "worn<90"], 0)])
    assert "[last auto drill 2d ago failed: up:B1, slow:O1, worn<90]" in t, t
    t = drill_line(dict(READY), [result(NOW - 2400, ["worn<90"], 1)])
    assert "[last auto drill 2d ago failed: worn<90; bridges ok]" in t, t
    t = drill_line(dict(READY), [result(NOW - 2400, ["up:B1"], 0, restore=-1)])
    assert "failed: up:B1, bridges not down in time]" in t, t


def test_status_without_fails_is_as_before():
    t = drill_line(dict(READY), [result(NOW - 2400)])
    assert "[last auto drill 2d ago failed]" in t, t
