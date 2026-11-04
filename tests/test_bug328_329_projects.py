"""BUG-328 (Run 15c Inkintense: seal y374s0b0 stuck 900-1399 days holding a runner slot, aqshaft l0.dig 0 % for 62-176
days, 'runner: no run ended for 176 d'). Python side: state sched.ip (the projects set aside for want of progress), its
status line with the resume command, PROJECT_BLOCKED d.idle and its wake hint, the verb bp.resume, config
runner.queue.idle_days. BUG-329: SEAL_STUCK why 'no labor'. Each test fails on 9b6f614."""
import json

import pytest
from cli_v2_helpers import FIX, make_runtime, reset_paths

from dfpilot import brief, fairplay, files, schema, wake

ROOT = FIX.parent.parent.parent
IP = {"n": 2, "by": [["y374s0b0", "seal", 1069], ["c1a188b5f1ae45b201", "aqshaft", 62]]}


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def test_sched_ip_validates_and_status_names_the_resume_command(save):
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    assert schema.validate("state", dict(st, sched={"ip": IP})) == []
    assert any("n: missing" in x for x in schema.validate("state", dict(st, sched={"ip": {"by": []}})))
    st["sched"] = {"ip": IP}
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")
    out = brief.status_text(save)
    assert ("set aside (no progress): 2: y374s0b0 seal 1069 d, c1a188b5f1ae45b201 aqshaft 62 d; resume: dfllm cmd "
            "bp.resume proj=y374s0b0 or bp.cancel") in out, out


def test_idle_event_and_its_wake_hint():
    e = {"n": 2321, "tick": 5, "type": "PROJECT_BLOCKED", "cls": "A",
         "msg": "y374s0b0 (seal) stalled 30 d at seal.build 0%: set aside, no runner slot (the others go first); resume: "
                "dfllm cmd bp.resume '{\"proj\":\"y374s0b0\"}'; cancel: dfllm cmd bp.cancel '{\"proj\":\"y374s0b0\"}'",
         "d": {"proj": "y374s0b0", "tpl": "seal", "stage": "seal.build", "why": "stalled", "ticks": 36000, "idle": 30}}
    assert schema.validate("event", e) == []
    assert schema.validate("event", dict(e, d=dict(e["d"], idle="x"))) != []
    hint = wake.next_hint("PROJECT_BLOCKED", e)
    assert "dfllm cmd bp.resume '{\"proj\":\"y374s0b0\"}'" in hint and "bp.cancel" in hint, hint


def test_verb_bp_resume_and_the_queue_config():
    assert schema.validate_args("bp.resume", {"proj": "y374s0b0"}) == []
    assert schema.validate_args("bp.resume", {}) != []
    assert schema.VERBS["bp.resume"] == ("runner", None, False)
    src = (ROOT / "lua" / "dfllm" / "util" / "contract.lua").read_text(encoding="utf-8")
    assert "['bp.resume']    = {mod = 'runner'}" in src
    cfg = json.loads((ROOT / "config" / "baseline.json").read_text(encoding="utf-8"))
    assert cfg["runner"]["queue"]["idle_days"] == 30
    assert fairplay.RUNNER_LIM["queue"]["idle_days"] == (1, 400)
    rsrc = (ROOT / "lua" / "dfllm" / "runner.lua").read_text(encoding="utf-8")
    assert "task_days = 3, idle_days = 30" in rsrc and "nat(q.idle_days, 1, 400," in rsrc


def test_rules_name_the_set_aside_projects_and_no_labor():
    rules = (ROOT / "RULES.md").read_text(encoding="utf-8")
    row = next(x for x in rules.splitlines() if x.startswith("| PROJECT_BLOCKED |"))
    assert "set aside" in row and "bp.resume" in row
    assert "no labor" in next(x for x in rules.splitlines() if x.startswith("| SEAL_STUCK |"))
    assert len(rules.splitlines()) <= 300
