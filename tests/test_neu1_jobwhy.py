"""NEU1 P8 (docs/v2/NEU1-jobfrage.md): `dfpilot why <key>` asks the kernel's job query (inspect what=why) and prints the
cause, the holders by status and the missing inputs; the ORDER_STUCK `cause` field and the config switch
economy.jobwhy are part of the contract and checked by lint --config. The query itself is tested in
tests/lua/test_neu1_jobwhy.lua."""
import json
from pathlib import Path

import pytest
from cli_v2_helpers import ev, make_runtime, reset_paths

from dfpilot import cli, cmd, fairplay, schema

ROOT = Path(__file__).resolve().parent.parent

RECORD = {"kind": "job", "id": 700, "job": "BREW_DRINK_FROM_PLANT", "cause": "burrow", "shop": 12, "at": [21, 21, 100],
          "text": "2 BREWER holders: 2 kept out by burrows",
          "workers": {"n": 2, "free": 0, "labor": "BREWER", "by": {"burrow": 2},
                      "who": [{"id": 1, "name": "Urist", "st": "burrow", "det": "his burrows"}]},
          "inputs": [{"idx": 0, "what": "plant (DRINK_MAT)", "need": 1, "match": 3, "free": 0, "forbid": 3, "claimed": 0, "far": 0}]}


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def test_inspect_why_and_the_cause_field_are_in_the_contract():
    assert schema.validate_args("inspect", {"what": "why", "key": "brew"}) == []
    assert schema.validate_args("inspect", {"what": "why", "key": 123}) == []
    e = ev(1, "ORDER_STUCK", "brewing stalled 6 days: ...", {"order": 0, "job": "BrewDrink", "why": "brew stall: burrow", "n": 5,
                                                             "days": 6, "dropped": 0, "kind": "worker", "cause": "burrow"})
    assert schema.validate("event", e) == []
    e["d"]["cause"] = 3
    assert schema.validate("event", e) != []


def test_the_jobwhy_switch_is_checked_by_lint_config(tmp_path):
    doc = json.loads((ROOT / "config" / "baseline.json").read_text("utf-8"))
    assert doc["economy"]["jobwhy"] == {"stall": True, "items_max": 4000}
    assert fairplay.economy_errors(ROOT / "config" / "baseline.json") == []
    doc["economy"]["jobwhy"] = {"stall": "yes", "items_max": 5, "bogus": 1}
    p = tmp_path / "baseline.json"
    p.write_text(json.dumps(doc), encoding="utf-8")
    errs = fairplay.economy_errors(p)
    assert any("jobwhy.stall" in x for x in errs) and any("jobwhy.items_max" in x for x in errs) \
        and any("jobwhy.bogus" in x for x in errs), errs


def test_why_lines_name_the_holders_and_the_inputs():
    lines = cli.why_lines(dict(RECORD, sub={"kind": "job", "id": 9, "job": "X", "cause": "no_labor"}))
    assert lines[0] == "  workers (BREWER): 2 holder(s): 2 burrow"
    assert lines[1] == "    Urist 1: burrow (his burrows)"
    assert lines[2] == "  input plant (DRINK_MAT) x1: 3 match, 0 free, 3 forbid, 0 claimed, 0 far"
    assert lines[3] == "  -> job 9 X: no_labor"


def test_dfpilot_why_sends_one_read_only_inspect_and_prints_the_answer(save, monkeypatch, capsys):
    sent = []

    def fake_send(save_dir, verb, args, by="cli", wait_s=5.0, **kw):
        sent.append((verb, args, by))
        return "c1", {"id": "c1", "ok": True, "msg": "job 700 BREW_DRINK_FROM_PLANT at 21,21,100: burrow: ...", "data": RECORD}

    monkeypatch.setattr(cmd, "send", fake_send)
    assert cli.main(["--save", str(save), "why", "brew"]) == 0
    out = capsys.readouterr().out
    assert sent == [("inspect", {"what": "why", "key": "brew"}, "cli")]
    assert out.startswith("why brew: job 700 BREW_DRINK_FROM_PLANT at 21,21,100: burrow")
    assert "workers (BREWER): 2 holder(s): 2 burrow" in out

    monkeypatch.setattr(cmd, "send", lambda *a, **k: ("c2", {"id": "c2", "ok": False, "msg": "no job 5"}))
    assert cli.main(["--save", str(save), "why", "job:5"]) == 1
    assert "why job:5: no job 5" in capsys.readouterr().out
