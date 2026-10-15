"""FR-36/49/51/52/53/55: the files the real kernel writes with the reflex module validate against dfpilot.schema,
and `dfllm status` / `wait` read them.

tests/lua/reflex_scenario.lua boots lua/dfllm/kern.lua (real act.lua: door forbid, lever pulls, civ alert, FPS cap,
popup dismissal) on k_mock's fake DF without a fort manifest (Run 9) and drives an arrival popup, a siege, an ack,
RECOVERY, PEACE and an unacked DEATHS_3PLUS into a temp DF folder.
"""
import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
LUA_TESTS = ROOT / "tests" / "lua"
sys.path.insert(0, str(ROOT / "tools"))
import luahost  # noqa: E402

from dfpilot import alarm, brief, schema  # noqa: E402

pytestmark = pytest.mark.skipif(not luahost.available(), reason="lua53.dll not found")


@pytest.fixture(scope="module")
def run(tmp_path_factory):
    out = tmp_path_factory.mktemp("reflex")
    r = luahost.run_file(LUA_TESTS / "reflex_scenario.lua", [str(out)], timeout=180, paths=[LUA_TESTS])
    assert r.ok, f"exit {r.code}\n{r.out}\n{r.err}"
    assert "scenario done" in r.out
    return out


def sd(out: Path) -> Path:
    return out / "dfllm-runtime" / "region1"


def events(out: Path) -> list[dict]:
    return [json.loads(x) for x in (sd(out) / "events.jsonl").read_text(encoding="utf-8").splitlines()]


def test_every_event_validates_and_the_alarm_types_are_there(run):
    evs = events(run)
    for ev in evs:
        assert schema.validate("event", ev) == [], ev
    by = {}
    for e in evs:
        by.setdefault(e["type"], []).append(e)
    for t in ("ARRIVAL", "INTRUDER", "SIEGE_START", "LOCKDOWN", "LOCKDOWN_END", "SIEGE_END", "DEATHS_3PLUS"):
        assert t in by, t
    assert "KERN_FAULT" not in by and "ACT_FAIL" not in by, [e["msg"] for e in by.get("ACT_FAIL", [])]
    arr = by["ARRIVAL"][0]
    assert arr["cls"] == "A" and arr["d"]["kind"] == "siege" and arr["d"]["src"] == "popup"
    assert arr["d"]["raised"] == 3 and arr["d"]["doors"] == 1 and arr["d"]["clock"] == 30
    assert arr["d"]["alert"] == "on Kern+"
    assert by["SIEGE_START"][0]["cls"] == "A"
    lock = by["LOCKDOWN"][0]
    assert lock["d"]["why"] == "ack_timeout" and lock["d"]["type"] == "DEATHS_3PLUS"
    assert "kernel applied its default" in lock["msg"]
    end = by["SIEGE_END"][0]
    assert end["d"]["sealed_ticks"] > 9000, end            # Run 9: "sealed 0 ticks" without a manifest
    # the arrival came before the siege and long before anyone could be inside
    assert arr["n"] < by["SIEGE_START"][0]["n"]


def test_state_slots_carry_clock_alarm_lever(run):
    docs = [json.loads((sd(run) / f"state.{s}.json").read_text(encoding="utf-8")) for s in "ab"]
    for d in docs:
        assert schema.validate("state", d) == [], d
        assert len(json.dumps(d, separators=(",", ":"))) <= 4096
    best = max(docs, key=lambda d: d["seq"])
    assert best["clock"]["cap"] == 30 and best["clock"]["held"] == 1 and best["owners"]["tempo"] == "clock"
    assert best["alarm"]["lock"] == 1 and best["alarm"]["unacked"] == 1
    out = brief.status_text(sd(run))
    assert out.startswith("DEFCON 3 | region1") and "clock: held 30 t/s, reason unacked:DEATHS_3PLUS" in out


def test_alarm_txt_and_wait(run):
    a = alarm.read_alarm(sd(run))
    assert a is not None and a["head"].startswith("DEFCON 3 | mode PEACE | unacked 1")
    kinds = [(i["type"], i["status"]) for i in a["items"]]
    assert ("ARRIVAL", "acked") in kinds and ("INTRUDER", "acked") in kinds and kinds[-1] == ("DEATHS_3PLUS", "default")
    items, _ = alarm.wait_interrupt(sd(run), timeout=0)
    assert [i["type"] for i in items] == ["DEATHS_3PLUS"]


def test_restore_json_back_to_the_original_cap(run):
    r = json.loads((run / "dfllm-runtime" / "restore.json").read_text(encoding="utf-8"))
    assert schema.validate("restore", r) == []
    assert r["active"] == 0 and r["orig"]["fps_cap"] == 250


def test_commands_log_has_the_ui_actions(run):
    log = (sd(run) / "commands.log").read_text(encoding="utf-8")
    assert "\treflex\tact.door_forbid\t[501,true]\tok" in log
    assert "\treflex\tact.door_forbid\t[501,false]\tok" in log
    assert "\tarbiter\tact.dismiss_popup\t" in log and "\tgate\tact.pull\t" in log
