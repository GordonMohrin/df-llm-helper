"""Run 11 (Kilrudrabed site98, y441 spring d23, siege 8: pop 52 -> 3): the way in 114,73,143 had no door and its seal
(c1a147c261), placed two days before the attack, was not finished. Python side of seal first and the rebuild policy:
event SEAL_STUCK (A), state sched and its status line, config/baseline.json "runner", the wake hint; `plan check` and
`plan propose` (seal first in the season, the warnings). Each test fails on 2f6ab27."""
import copy
import json

import pytest
from cli_v2_helpers import FIX, make_runtime, reset_paths

from dfpilot import brief, fairplay, files, plan, schema, wake

ROOT = FIX.parent.parent.parent
SEAL = "c1a147c261"


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


# ---------------------------------------------------------------- contracts
def test_seal_stuck_event_and_sched_state(save):
    e = {"n": 9100, "tick": 5, "type": "SEAL_STUCK", "cls": "A",
         "msg": f"{SEAL} (seal) built nothing for 3 days at seal.build: 1 piece open (door 114,73,143); the other "
                "projects run again",
         "d": {"proj": SEAL, "tpl": "seal", "stage": "seal.build", "days": 3, "n": 1, "pieces": ["door 114,73,143"],
               "mat": "no material for door: no rock, no logs", "blocked": "build_lost"}}
    assert schema.validate("event", e) == []
    assert schema.EVENTS["SEAL_STUCK"][:2] == ("A", "runner")
    assert schema.validate("event", dict(e, cls="B")) != []
    assert any("proj: missing" in x for x in schema.validate("event", dict(e, d={"n": 1})))
    assert schema.ACT["order_top"] == ["runner"] and schema.STATE_OWNERS["sched.*"] == "runner"
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    ok = {"seal": {"proj": SEAL, "n": 3, "paused": 2, "more": 0, "stuck": 0}, "rb": {"pop": 2, "lo": 10, "hi": 12,
                                                                                     "paused": 4}}
    assert schema.validate("state", dict(st, sched=ok)) == []
    for bad, needle in (({"seal": {"proj": SEAL, "n": 3}}, "paused: missing"),
                        ({"seal": dict(ok["seal"], stuck=2)}, "stuck"),
                        ({"rb": {"pop": 2, "paused": 1}}, "lo: missing")):
        errs = schema.validate("state", dict(st, sched=bad))
        assert any(needle in x for x in errs), (needle, errs)
    assert wake.NEXT["SEAL_STUCK"].startswith("tell Gordon")
    assert wake.PRIO.index("SEAL_STUCK") < wake.PRIO.index("PROJECT_BLOCKED")


def test_status_shows_the_open_seal_the_stuck_seal_and_the_rebuild(save):
    put_state(save, sched={"seal": {"proj": SEAL, "n": 3, "paused": 2, "more": 0, "stuck": 0}})
    out = brief.status_text(save)
    assert f"seal open: 3 pieces ({SEAL}), others paused" in out, out
    put_state(save, sched={"seal": {"proj": SEAL, "n": 1, "paused": 0, "more": 1, "stuck": 0}})
    assert f"seal open: 1 piece ({SEAL} +1 seal), runs first" in brief.status_text(save)
    put_state(save, sched={"seal": {"proj": SEAL, "n": 1, "paused": 0, "more": 0, "stuck": 1, "days": 3}})
    assert f"seal stuck 3 d: 1 piece ({SEAL}), others run (SEAL_STUCK)" in brief.status_text(save)
    put_state(save, sched={"rb": {"pop": 2, "lo": 10, "hi": 12, "paused": 4}})
    out = brief.status_text(save)
    assert "rebuild: pop 2 < 10, only seal/tombs/food/beds (4 paused, ends at 12)" in out, out
    assert len(out) // 4 <= brief.STATUS_TOKENS * 2
    assert "rebuild:" in brief.brief_text(save)
    put_state(save)
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    st.pop("sched", None)
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")
    out = brief.status_text(save)
    assert "seal open" not in out and "rebuild:" not in out


def test_runner_config_validates(tmp_path):
    cfg = json.loads((ROOT / "config" / "baseline.json").read_text(encoding="utf-8"))
    assert cfg["runner"] == {"seal_first": {"on": True, "stuck_days": 3, "food_d": 30, "drink_d": 30},
                             "rebuild": {"pop": 10, "off": 12}}
    assert fairplay.runner_errors() == []
    p = tmp_path / "baseline.json"
    p.write_text(json.dumps({"v": 2, "runner": {"seal_first": {"on": 1, "stuck_days": 0, "wait": 2},
                                                "rebuild": {"pop": 10, "off": 8}, "pause": {}}}), encoding="utf-8")
    assert fairplay.runner_errors(p) == [
        "config/baseline.json: runner.seal_first.on: true or false expected, got 1",
        "config/baseline.json: runner.seal_first.stuck_days: int 1..60 expected, got 0",
        "config/baseline.json: runner.seal_first.wait: unknown key",
        "config/baseline.json: runner.pause: unknown key",
        "config/baseline.json: runner.rebuild.off 8 < pop 10 (the policy would end at once; the kernel uses pop)"]
    p.write_text(json.dumps({"v": 2}), encoding="utf-8")
    assert fairplay.runner_errors(p) == [] and fairplay.runner_errors(tmp_path / "none.json") == []
    src = (ROOT / "lua" / "dfllm" / "runner.lua").read_text(encoding="utf-8")
    for k in ("seal_first = true", "seal_stuck_days = 3", "emerg_food_d = 30", "emerg_drink_d = 30",
              "rebuild_pop = 10", "rebuild_off = 12"):
        assert k in src, k


def test_rules_name_the_first_move():
    rules = (ROOT / "RULES.md").read_text(encoding="utf-8")
    assert "| SEAL_STUCK |" in rules and "**Rebuild (Run 11):**" in rules
    assert len(rules.splitlines()) <= 300
