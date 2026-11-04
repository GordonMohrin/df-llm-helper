"""Run 15b Earthboat y387 (i3, pop 92 -> 1): BUG-336 the refuge hatch 55,82,133 stalled 911 days, the refuge was still the
civilians' burrow (5 trolls walked down the open stair after them); BUG-337 SIEGE_DEEP called a refuge closed only by a hatch
'the separated refuge' with building destroyers in sight. The kernel behaviour is tested in tests/lua/test_seal_refuge.lua,
tests/lua/test_intake.lua and tests/lua/test_bug336_seal_escalate.lua; here the Python side of the contract."""
import json
from pathlib import Path

from dfpilot import brief, fairplay, schema, wake

ROOT = Path(__file__).resolve().parents[1]


def test_bug336_brief_says_the_open_refuge_is_not_used_in_a_fight():
    al = {"burrow": "Kern+", "tiles": 900, "inside": 40, "ok": 1, "want": "Kern+",
          "ref": {"ex": 1, "sep": 1, "beds": 20, "need": 21, "tr": 0, "trw": "no hatch at 55,82,133", "op": 1}}
    txt = brief.line_alert(al)
    assert "refuge NOT TRUSTED: no hatch at 55,82,133" in txt
    assert "REFUGE OPEN: not used in a siege or breach" in txt and "bp.place tpl=seal at=refuge" in txt
    del al["ref"]["op"]
    assert "REFUGE OPEN" not in brief.line_alert(al)


def test_bug336_state_and_events_carry_the_new_fields():
    assert "op" in schema.STATE.opt["alert"].opt["ref"].opt
    assert schema.validate_event_d("SIEGE_DEEP", {"why": ["destroyers"], "ropen": "open: no hatch at 55,82,133",
                                                  "soft": "hatch"}) == []
    assert schema.validate_event_d("DECISION_NEEDED", {"id": "seal_stalled", "q": "seal y384s1b0: hatch 55,82,133 open",
                                                       "n": 30, "mat": "hatch 55,82,133", "proj": "y384s1b0",
                                                       "cmd": "dfllm cmd bp.cancel ..."}) == []
    contract = (ROOT / "lua" / "dfllm" / "util" / "contract.lua").read_text(encoding="utf-8")
    assert "op = FLAG}" in contract


def test_bug336_esc_days_is_known_to_the_config_lint(tmp_path):
    p = tmp_path / "baseline.json"
    p.write_text(json.dumps({"runner": {"seal_first": {"esc_days": 20}}}), encoding="utf-8")
    assert fairplay.runner_errors(p) == []
    p.write_text(json.dumps({"runner": {"seal_first": {"esc_days": 61}}}), encoding="utf-8")
    assert any("esc_days" in e for e in fairplay.runner_errors(p))
    base = json.loads((ROOT / "config" / "baseline.json").read_text(encoding="utf-8"))
    assert base["runner"]["seal_first"]["esc_days"] == 30
    lua = (ROOT / "lua" / "dfllm" / "runner.lua").read_text(encoding="utf-8")
    assert "seal_esc_days = 30," in lua


def test_bug336_wake_hint_tells_gordon_with_the_command():
    d = {"id": "seal_stalled", "proj": "y384s1b0", "mat": "hatch 55,82,133", "n": 30,
         "cmd": "build it by hand in DF, or dfllm cmd bp.cancel '{\"proj\":\"y384s1b0\"}' then dfllm cmd bp.place "
                "'{\"tpl\":\"seal\",\"at\":\"refuge\"}'"}
    h = wake.next_hint("DECISION_NEEDED", {"d": d})
    assert h.startswith("tell Gordon: seal y384s1b0 (hatch 55,82,133) has built nothing for 30 days")
    assert '"at":"refuge"' in h and "that way in is open" in h
