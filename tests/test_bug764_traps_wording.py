"""BUG-764 (Run 16a i1 Basementflew y525: the brief said 'traps 3/3', status 'traps 0 of 3 armed'): both lines count the same three armed traps; the
first number of the unready line is the cheapest route's, the second the armed count of the traps line. The words now say which is which, and the
audit's trap note no longer reads 'hall of armed'."""
import json

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import brief, files, wake


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def _ready(save, traps):
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    st["ready"] = {"lvl": 0, "worn": 0, "cv": 3, "drill_age": -1, "audit": {"ok": 0, "age": 9000, "min_traps": 0},
                   "fail": ["bypass"], "open": 0}
    st["traps"] = traps
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")


def test_the_two_trap_lines_name_the_same_three_armed_traps(save):
    _ready(save, {"m": 3, "n": 3})
    out = brief.status_text(save)
    assert "traps 3/3" in out, out
    assert "traps 0 on the cheapest route, 3 of 3 armed in all (a bypass skips the hall)" in out, out
    assert "traps 0 of 3 armed" not in out, out
    _ready(save, {"m": 5, "n": 3})                                   # two of five listed are re-arming or lost: 3 of 5
    assert "3 of 5 armed in all" in brief.status_text(save)


def test_the_audit_note_puts_the_armed_count_first():
    note = wake.trap_note({"traps": {"hall": 0, "armed": 3, "any_route": 0}}, {"min_traps": 0})
    assert note == " (3 armed traps, 0 of them in the trap hall)", note
