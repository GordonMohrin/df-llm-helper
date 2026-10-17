"""BUG-037 (Run 11, Kilrudrabed site98, y449 spring d46, kernel 784399f): bedrooms, a stockroom, a tavern, tombs and a
prio-2 depot stood 'queued' at 0 % for months while 15 of 27 adults had no job. Python side: state sched.q (who holds the
runner's slots), sched.run (no run ended for days), sched.pk (parked projects) and their status lines, PROJECT_BLOCKED
d.park and its wake hint, config/baseline.json runner.queue. Each test fails on 784399f."""
import json

import pytest
from cli_v2_helpers import FIX, make_runtime, reset_paths

from dfpilot import brief, fairplay, files, schema, wake

ROOT = FIX.parent.parent.parent


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def put_state(save, **keys):
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    st.update(keys)
    assert schema.validate("state", st) == [], schema.validate("state", st)
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")
    return st


Q = {"n": 6, "by": [["c1a148696a3d6da701", "seal", 0], ["depot7", "depot", 9], ["c1a14867db95857619", "tombs", 1]]}
RUN = {"d": 30, "i": 2, "n": 9, "task": "work c1a14831718f432f01", "sl": 900, "age": 30}


def test_sched_queue_run_and_park_state(save):
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    assert schema.validate("state", dict(st, sched={"q": Q, "run": RUN, "pk": 2})) == []
    assert schema.validate("state", dict(st, sched={"run": {"d": 3}})) == []
    for bad, needle in (({"q": {"by": []}}, "n: missing"),
                        ({"q": {"n": 1, "by": [["a", "seal"]]}}, "by"),
                        ({"run": {"i": 1}}, "d: missing"),
                        ({"pk": -1}, "pk")):
        errs = schema.validate("state", dict(st, sched=bad))
        assert any(needle in x for x in errs), (needle, errs)


def test_status_names_the_slot_holders_a_stopped_runner_and_the_parked(save):
    put_state(save, sched={"q": Q})
    out = brief.status_text(save)
    assert ("queued: 6 behind c1a148696a3d6da701 seal, depot7 depot 9 d no progress, c1a14867db95857619 tombs"
            in out), out
    put_state(save, sched={"run": RUN, "pk": 2})
    out = brief.status_text(save)
    assert ("runner: no run ended for 30 d (task 2/9 work c1a14831718f432f01, 900 slices): dfllm doctor, inspect "
            "modules" in out), out
    assert "2 parked (blocked for good: bp.cancel, PROJECT_BLOCKED)" in out
    assert len(out) // 4 <= brief.STATUS_TOKENS * 2
    put_state(save, sched={"q": Q})
    assert "queued: 6 behind c1a148696a3d6da701 seal" in brief.brief_text(save)


def test_parked_project_blocked_event_and_its_wake_hint():
    e = {"n": 9200, "tick": 5, "type": "PROJECT_BLOCKED", "cls": "A",
         "msg": "c1a145d32caa7c6f06 (farms) blocked 7500 d: build_lost at build; parked; cancel: dfllm cmd bp.cancel "
                "'{\"proj\":\"c1a145d32caa7c6f06\"}' (no undo: what it built stays)",
         "d": {"proj": "c1a145d32caa7c6f06", "tpl": "farms", "stage": "build", "why": "build_lost", "ticks": 9000000,
               "park": 7500}}
    assert schema.validate("event", e) == []
    assert schema.validate("event", dict(e, d=dict(e["d"], park="x"))) != []
    hint = wake.next_hint("PROJECT_BLOCKED", e)
    assert hint.startswith("tell Gordon; once he agrees: dfllm cmd bp.cancel '{\"proj\":\"c1a145d32caa7c6f06\"}' "
                           "(no undo)"), hint
    plain = dict(e, d={k: v for k, v in e["d"].items() if k != "park"})
    assert wake.next_hint("PROJECT_BLOCKED", plain) == wake.NEXT.get("PROJECT_BLOCKED", "dfllm brief")
    line = wake.wake_line({"PROJECT_BLOCKED": {"c": 1, "n0": 9200, "e": e}}, None)
    assert "bp.cancel" in line and len(line) // 4 <= wake.WAKE_TOKENS + 10


def test_runner_queue_config_validates(tmp_path):
    cfg = json.loads((ROOT / "config" / "baseline.json").read_text(encoding="utf-8"))
    assert cfg["runner"]["queue"] == {"yield_days": 7, "park_days": 30}
    assert fairplay.runner_errors() == []
    p = tmp_path / "baseline.json"
    p.write_text(json.dumps({"v": 2, "runner": {"queue": {"yield_days": 0, "park_days": 401, "slots": 4}}}),
                 encoding="utf-8")
    assert fairplay.runner_errors(p) == [
        "config/baseline.json: runner.queue.yield_days: int 1..60 expected, got 0",
        "config/baseline.json: runner.queue.park_days: int 1..400 expected, got 401",
        "config/baseline.json: runner.queue.slots: unknown key"]
    src = (ROOT / "lua" / "dfllm" / "runner.lua").read_text(encoding="utf-8")
    assert "yield_days = 7, park_days = 30" in src
    assert "nat(q.yield_days, 1, 60," in src and "nat(q.park_days, 1, 400," in src


def test_rules_name_parked_projects():
    rules = (ROOT / "RULES.md").read_text(encoding="utf-8")
    row = next(x for x in rules.splitlines() if x.startswith("| PROJECT_BLOCKED |"))
    assert "parked" in row and "bp.cancel" in row
    assert len(rules.splitlines()) <= 300
