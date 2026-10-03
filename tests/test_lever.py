"""BUG-427: `lever list` shows the REAL bridge state (gate_flags of the bridge), `lever set` pulls only when needed.
Lua side under the mock: tests/test_lua_claude.py (test_bug427_*). Fixtures are SYNTHETIC."""
import json

from df_llm_helper.client import MockClient, is_write
from df_llm_helper.clock import FakeClock
from df_llm_helper.features import defense as D
from df_llm_helper.features import lever as L
from df_llm_helper.store import Store


def _lever(state="lowered", jobs=0, second=None):
    t = [{"id": 4406, "type": "Bridge", "state": state, "field": "gate_flags.raised", "x": 90, "y": 100, "z": 133}]
    if second:
        t.append(second)
    return {"id": 4407, "x": 95, "y": 101, "z": 133, "lever_state": 1, "pull_jobs": jobs, "targets": t}


def test_bug427_list_lines_show_the_real_state():
    lines = L.lever_lines({"ok": True, "levers": [_lever("lowered")]})
    assert lines[1] == "  lever #4407 (95,101,z133): Bridge #4406 lowered (gate_flags.raised)"
    assert "raised" in L.lever_lines({"ok": True, "levers": [_lever("raised", jobs=1)]})[1]
    assert "1 pull queued" in L.lever_lines({"ok": True, "levers": [_lever("raised", jobs=1)]})[1]
    assert L.lever_lines({"ok": True, "levers": {}}) == ["Levers: none"]
    assert L.bridge_states({"levers": [_lever("lowered")]}) == {4406: "lowered"}


def test_bug427_set_decision_mirrors_the_lua_rule():
    assert L.set_decision(_lever("raised"), "raised") == (False, "already raised")
    assert L.set_decision(_lever("lowered"), "raised")[0] is True
    assert L.set_decision(_lever("lowered", jobs=1), "raised") == (False, "pull already queued")
    assert L.set_decision(_lever("moving"), "raised")[1] == "target moving or state unreadable"
    assert L.set_decision(_lever("lowered"), "closed")[1] == "no linked target with state closed"
    two = _lever("lowered", second={"id": 9, "type": "Bridge", "state": "raised"})
    assert L.set_decision(two, "raised") == (False, "linked targets disagree (a pull flips all of them)")
    assert L.set_decision(_lever(), "up")[0] is False


def _cli(monkeypatch, responses):
    import df_llm_helper.cli as cli
    from df_llm_helper.config import load_config
    from df_llm_helper.pilot import Pilot
    clock = FakeClock(1_790_840_000.0)
    m = MockClient(responses, clock=clock)
    monkeypatch.setattr(cli, "_pilot", lambda args: Pilot(load_config(overrides={}), m, store=Store(), clock=clock))
    return cli, m


def test_bug427_cli_list_set_pull(monkeypatch, capsys):
    lst = json.dumps({"ok": True, "levers": [_lever("lowered")]})
    cli, m = _cli(monkeypatch, {
        "claude/pilot_lever list": lst,
        "claude/pilot_lever set 4407 lowered": json.dumps({"ok": True, "pulled": False, "reason": "already lowered",
                                                           "lever": _lever("lowered")}),
        "claude/pilot_lever pull 4407": json.dumps({"ok": True, "pulled": True, "lever": _lever("lowered", jobs=1)})})
    assert cli.main(["lever", "list"]) == 0
    out = capsys.readouterr().out
    assert "Bridge #4406 lowered" in out and "#4406 raised" not in out
    assert cli.main(["lever", "set", "--id", "4407", "--state", "lowered"]) == 0
    assert "not pulled - already lowered" in capsys.readouterr().out
    assert cli.main(["lever", "pull", "--id", "4407"]) == 0
    assert "pull queued" in capsys.readouterr().out
    assert cli.main(["lever", "set", "--id", "4407"]) == 2               # --state missing
    assert cli.main(["lever", "pull"]) == 2                              # --id missing
    assert any("claude/pilot_lever set 4407 lowered" in str(c) for c in m.calls)
    assert not is_write("claude/pilot_lever list") and is_write("claude/pilot_lever pull 4407")


def test_bug427_cli_list_from_file(tmp_path, capsys):
    import df_llm_helper.cli as cli
    f = tmp_path / "levers.json"
    f.write_text(json.dumps({"ok": True, "levers": [_lever("raised")]}), encoding="utf-8")
    assert cli.main(["lever", "list", "--file", str(f)]) == 0
    assert "Bridge #4406 raised (gate_flags.raised)" in capsys.readouterr().out


def test_bug427_defense_status_shows_the_bridge_state(monkeypatch, capsys):
    status = json.dumps({"ok": True, "traps": [{"kind": "stone", "loaded": True, "x": 1, "y": 1, "z": 1}],
                         "jobs": {}, "stock": {}})
    cli, _ = _cli(monkeypatch, {D.STATUS_CMD: status,
                                "claude/pilot_lever list": json.dumps({"ok": True, "levers": [_lever("lowered")]})})
    assert cli.main(["defense", "status"]) == 0
    assert "Bridges: #4406 lowered" in capsys.readouterr().out


def test_bug427_defense_status_without_pilot_lever_is_unchanged(monkeypatch, capsys):
    status = json.dumps({"ok": True, "traps": [], "jobs": {}, "stock": {}})
    cli, _ = _cli(monkeypatch, {D.STATUS_CMD: status})
    cli.main(["defense", "status"])
    assert "Bridges" not in capsys.readouterr().out
