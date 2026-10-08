"""Guard deadman: extra liveness globs besides heartbeat.txt (youngest signal wins, 'birth:' = creation time)."""
import copy
import os

from conftest import set_age
from df_llm_helper.config import DEFAULTS
from df_llm_helper.guard import GuardRunner
from df_llm_helper.store import Store
from df_llm_helper.toolsfs import ToolsDir
from helpers import snap_for


def _file(p, clock, minutes):
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text("x", encoding="utf-8")
    set_age(p, clock, minutes)
    return p


def test_liveness_youngest_wins(tmp_path, clock):
    tools = ToolsDir(tmp_path / "tools", clock)
    tools.touch_heartbeat()
    set_age(tools.heartbeat, clock, 900)
    _file(tmp_path / "proj" / "a.jsonl", clock, 95)
    _file(tmp_path / "proj" / "s1" / "subagents" / "agent-1.jsonl", clock, 3)
    pats = [str(tmp_path / "proj" / "**" / "*.jsonl")]
    assert round(tools.liveness_age_min(pats)) == 3
    assert round(tools.alive_age_min(pats)) == 3
    assert round(tools.alive_age_min([])) == 900          # default: heartbeat only (old behaviour)
    assert tools.liveness_age_min([str(tmp_path / "nothing" / "*.x")]) is None


def test_birth_prefix_uses_creation_time(tmp_path, clock):
    tools = ToolsDir(tmp_path / "tools", clock)
    out = _file(tmp_path / "tasks" / "loop.output", clock, 0)
    # creation time is "now" of the real clock; the fake clock lies in the past -> age 0 (clamped), mtime ignored
    os.utime(out, (clock.now().epoch - 600 * 60, clock.now().epoch - 600 * 60))
    assert tools.liveness_age_min(["birth:" + str(tmp_path / "tasks" / "*.output")]) == 0.0
    assert round(tools.liveness_age_min([str(tmp_path / "tasks" / "*.output")])) == 600


def test_guard_no_deadman_when_transcript_is_fresh(tmp_path, mock, clock):
    tools = ToolsDir(tmp_path / "tools", clock)
    tools.touch_heartbeat()
    set_age(tools.heartbeat, clock, 480)
    tools.set_last_report_id(5000)
    (tools.path / "events.log").write_text("", encoding="utf-8")
    _file(tmp_path / "proj" / "s.jsonl", clock, 2)
    cfg = copy.deepcopy(DEFAULTS)
    cfg["guard"]["liveness_globs"] = [str(tmp_path / "proj" / "*.jsonl")]
    r = GuardRunner(mock, Store(), tools, clock, cfg, probe=type("P", (), {"running": lambda self: True})())
    acts, st, info = r.cycle(snap_for(max_report_id=5000, timestream=False))
    assert not st.slowed and not any("DEADMAN" in str(a.arg) for a in acts)
    # without the glob the same files trigger the deadman (old behaviour)
    r2 = GuardRunner(mock, Store(), tools, clock, DEFAULTS, probe=type("P", (), {"running": lambda self: True})())
    _, st2, _ = r2.cycle(snap_for(max_report_id=5000, timestream=False))
    assert st2.slowed
