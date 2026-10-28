"""FR-94 (Run 14 note 100): the verb `resume` and the wake PAUSED_BY_DF. The kernel side is tests/lua/test_resume.lua."""
import json
import re
from pathlib import Path

import pytest
from cli_v2_helpers import FakeKern, make_runtime, reset_paths

from dfpilot import fairplay, schema, wake
from dfpilot.cli import main
from dfpilot.events import est_tokens

ROOT = Path(__file__).resolve().parent.parent


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def test_verb_args_and_registry():
    assert schema.validate_args("resume", {}) == []
    assert schema.validate_args("resume", {"why": "save loaded paused"}) == []
    for bad in ({"ttl_s": 5}, {"why": 3}, {"force": True}):
        assert schema.validate_args("resume", bad), bad
    assert schema.VERBS["resume"] == ("arbiter", None, False)       # any mode: the pause is no mode matter


def test_the_cli_sends_resume_to_the_inbox(save):
    with FakeKern(save, lambda d: (True, "resumed: was pause:df, now running", {"was": "pause:df", "now": "running"})) as k:
        assert main(["--runtime", str(save.parent), "cmd", "resume", "--wait", "5"]) == 0
    assert k.seen[0]["verb"] == "resume" and k.seen[0]["args"] == {}


def test_contract_lua_and_schema_agree():
    lua = (ROOT / "lua" / "dfllm" / "util" / "contract.lua").read_text("utf-8")
    assert "['resume']       = {mod = 'arbiter'}" in lua
    assert "PAUSED_BY_DF = {cls = 'A', by = 'arbiter'}" in lua and "press_pause = {'arbiter'}" in lua
    assert schema.EVENTS["PAUSED_BY_DF"][:2] == ("A", "arbiter") and schema.ACT["press_pause"] == ["arbiter"]
    ok = {"n": 5, "tick": 9, "type": "PAUSED_BY_DF", "cls": "A", "msg": "PAUSED_BY_DF for 5 min: dfllm cmd resume",
          "d": {"by": "df", "min": 5}}
    assert schema.validate("event", ok) == []
    assert schema.validate("event", dict(ok, d={"by": "popup", "min": 6, "popup": "x", "deny": 1})) == []
    assert schema.validate("event", dict(ok, d={"by": "df"})) != []                        # min is required


def test_the_kernel_uses_the_key_and_no_state_write():
    """Fair play: the arbiter's resume path sends the key (act.press_pause) and never writes pause_state itself."""
    arb = (ROOT / "lua" / "dfllm" / "arbiter.lua").read_text("utf-8")
    verb = arb.split("M.verbs.resume = function")[1].split("\nend\n")[0]
    assert "K.act.press_pause()" in verb and "set_paused" not in verb
    assert not re.search(r"pause_state\s*=[^=]", verb)
    act = (ROOT / "lua" / "dfllm" / "act.lua").read_text("utf-8")
    body = act.split("function I.press_pause()")[1].split("\n  end\n")[0]
    assert "simulateInput(dfhack.gui.getDFViewscreen(true), 'D_PAUSE')" in body
    assert not re.search(r"pause_state\s*=[^=]", body)
    assert "df.global.pause_state ~= true then return false" in body        # the key toggles: never sent while running


def test_config_knob_and_its_lint():
    shipped = json.loads((ROOT / "config" / "reflex.json").read_text("utf-8"))
    assert shipped["resume"] == {"wake_min": 5}
    assert fairplay.reflex_errors() == []


def test_config_lint_rejects_bad_values(tmp_path):
    p = tmp_path / "reflex.json"
    p.write_text(json.dumps({"v": 2, "resume": {"wake_min": 0}}), encoding="utf-8")
    assert fairplay.reflex_errors(p) == []
    p.write_text(json.dumps({"v": 2, "resume": {"wake_min": 241, "gap_s": 5}}), encoding="utf-8")
    errs = fairplay.reflex_errors(p)
    assert any("resume.wake_min: int 0..240" in e for e in errs) and any("resume.gap_s: unknown key" in e for e in errs), errs
    p.write_text(json.dumps({"v": 2, "resume": {"wake_min": "5"}}), encoding="utf-8")
    assert any("resume.wake_min" in e for e in fairplay.reflex_errors(p))


def _ev(n, d, msg="PAUSED_BY_DF for 5 min: dfllm cmd resume"):
    return {"n": n, "tick": 100, "type": "PAUSED_BY_DF", "cls": "A", "msg": msg, "d": d}


STATE = {"t": {"y": 3, "tick": 123456, "season": 1, "tps": 0, "paused": True}, "mode": "PEACE"}


def test_wake_line_names_the_command():
    assert "PAUSED_BY_DF" in wake.WAKE_TYPES and "PAUSED_BY_DF" in wake.PRIO
    e = _ev(7, {"by": "df", "min": 5})
    assert wake.next_hint("PAUSED_BY_DF", e).startswith("dfllm cmd resume")
    line = wake.wake_line({"PAUSED_BY_DF": {"c": 1, "n0": 7, "e": e}}, STATE)
    assert "| PAUSED_BY_DF for 5 min: dfllm cmd resume" in line, line
    assert "PAUSED_BY_DF: PAUSED_BY_DF" not in line, "the type is not said twice"
    assert "next: dfllm cmd resume" in line
    assert est_tokens(line) <= wake.WAKE_TOKENS


def test_wake_line_with_a_popup_and_with_a_deny_popup():
    e = _ev(8, {"by": "popup", "min": 5, "popup": "brawling under the influence"},
            'PAUSED_BY_DF for 5 min: dfllm cmd resume (popup "brawling under the influence")')
    line = wake.wake_line({"PAUSED_BY_DF": {"c": 1, "n0": 8, "e": e}}, STATE)
    assert 'popup "brawling under the influence"' in line and "next: dfllm cmd resume" in line
    deny = _ev(9, {"by": "popup", "min": 6, "popup": "Oddom has been cursed by Ok!", "deny": 1},
               'PAUSED_BY_DF for 6 min: popup "Oddom has been cursed by Ok!" has a threat or curse word, resume refuses it')
    hint = wake.next_hint("PAUSED_BY_DF", deny)
    assert hint.startswith("tell Gordon at once") and "resume refuses it" in hint
    line = wake.wake_line({"PAUSED_BY_DF": {"c": 1, "n0": 9, "e": deny}}, STATE)
    assert "cursed" in line and "tell Gordon at once" in line and est_tokens(line) <= wake.WAKE_TOKENS


def test_other_wake_lines_keep_their_type_prefix():
    e = {"n": 3, "tick": 1, "type": "PLAN_EXHAUSTED", "cls": "A", "msg": "PLAN_EXHAUSTED in P0", "d": {"phase": "P0"}}
    line = wake.wake_line({"PLAN_EXHAUSTED": {"c": 1, "n0": 3, "e": e}}, STATE)
    assert "PLAN_EXHAUSTED in P0" in line


def test_the_gate_lets_the_event_through():
    g = wake.WakeGate()
    g.add(_ev(11, {"by": "df", "min": 5}), 0)
    assert "PAUSED_BY_DF" in g.flush(30)


def test_rules_name_the_verb_the_event_and_stay_short():
    text = (ROOT / "RULES.md").read_text("utf-8")
    assert len(text.splitlines()) <= 300
    row = next(ln for ln in text.splitlines() if ln.startswith("| `pause` / `unpause` / `resume`"))
    assert "pause:df" in row and "pause:popup" in row and "60 s" in row and "DENY" in row
    sec7 = text.split("## 7.")[1].split("## 8.")[0]
    assert any(ln.startswith("|") and "PAUSED_BY_DF" in ln.split("|")[1] for ln in sec7.splitlines())
    assert "pause_state = false" not in text.split("## 2.")[0], "rule 1.3 names the verb, not a state write"
    assert re.search(r"resume it with `dfllm cmd resume`", text)
