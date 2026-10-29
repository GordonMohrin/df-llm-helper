"""BUG-165..169 (live test round 2, i2/i3): the foreign-line marker, the reflex boot, the TRANSFORM default, the record()
merge artifact and the lone-intruder kill order. The Lua side is in tests/lua/test_bug165_166_boot.lua,
test_bug167_transform.lua and test_bug169_kill_order.lua; this file checks the contracts and the Python readers."""
import re
from pathlib import Path

import pytest
from cli_v2_helpers import append_events, make_runtime, reset_paths

from dfpilot import files, schema, wake

ROOT = Path(__file__).resolve().parents[1]


def test_timeline_reset_kind_is_an_optional_string():
    d = {"n_alt": 32748, "tick_alt": 289621609, "tick_neu": 290707200}
    assert schema.validate_event_d("TIMELINE_RESET", d) == []
    assert schema.validate_event_d("TIMELINE_RESET", {**d, "kind": "foreign"}) == []
    assert schema.validate_event_d("TIMELINE_RESET", {**d, "kind": 3}) != []


def test_sortie_dead_lists_ids():
    d = {"phase": "abort", "squad": "A", "why": "mode", "units": [42739], "dead": [42713]}
    assert schema.validate_event_d("SORTIE", d) == []
    assert schema.validate_event_d("SORTIE", {**d, "dead": "42713"}) != []


def test_reflex_record_has_one_duplicate_check():
    src = (ROOT / "lua/dfllm/reflex.lua").read_text(encoding="utf-8")
    body = re.search(r"local function record\(K, n, etype, msg, u\)(.*?)\nend\n", src, re.S).group(1)
    assert body.count("if r.n == n then return end") == 1     # BUG-168: the merge left the loop twice


def _ev(n, typ, tick, msg="", d=None):
    return {"n": n, "tick": tick, "type": typ, "cls": schema.EVENTS[typ][0], "msg": msg, "d": d or {}}


@pytest.fixture
def save(tmp_path):
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def test_a_foreign_marker_keeps_the_folders_own_older_events_and_follow_logs_its_kind(save):
    """kind foreign: tick_neu is later than every event of this folder, so the marker drops nothing (follow's cursor
    already stands at the folder's last event); the follow log names the other line."""
    f = wake.Follower(out=lambda s: None, clock=lambda: 1_000_000.0)
    f.poll()
    append_events(save, [_ev(8813, "GATE_FAIL", 1_300_000, "own line", {"bridge": "B1", "why": "no_worker"}),
                         _ev(9500, "TIMELINE_RESET", 1_331_000, "save of another line loaded",
                             {"n_alt": 8813, "tick_alt": 1_300_000, "tick_neu": 1_331_000, "kind": "foreign"})])
    ns = [x["n"] for x in files.tail_events(save)]
    assert 8813 in ns and 9500 in ns
    f.poll()
    log = (save / "cli.log").read_text(encoding="utf-8")
    assert "save of another line loaded" in log
