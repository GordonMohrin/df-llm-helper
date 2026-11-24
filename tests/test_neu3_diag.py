"""NEU3 (docs/v2/NEU3-diagnose.md): diagnostics first. `inspect what=raw` / `dfpilot why <key> --raw` are part of the contract, the acting cures
of the 'fass' round are config switches (economy.diag) that default OFF and are checked by lint --config. The dumps themselves are tested in
tests/lua/test_neu3_diag.lua."""
import json
from pathlib import Path

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import cli, cmd, fairplay, schema

ROOT = Path(__file__).resolve().parent.parent


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def test_inspect_raw_is_in_the_contract():
    for key in ("brew", "order:12", "job:1430329", "items:logs", "items:plants", "items:barrels", "manager", "ws:17697", 12):
        assert schema.validate_args("inspect", {"what": "raw", "key": key}) == [], key
    assert schema.validate_args("inspect", {"what": "rawx", "key": "brew"}) != []


def test_the_acting_cures_default_and_the_switches_are_linted(tmp_path):
    doc = json.loads((ROOT / "config" / "baseline.json").read_text("utf-8"))
    # NEU4 (BUG-844): the container cure is on, gated by DF's own cancel reason (economy.cancel); the other two stay off
    assert doc["economy"]["diag"] == {"cx_cure": True, "mgr_chores": False, "still_pin": False, "stall_line": True}
    assert doc["economy"]["cancel"] == {"days": 7, "cx_min_n": 5, "cx_pile_days": 14, "gamelog": True, "gamelog_bytes": 131072}
    assert fairplay.economy_errors(ROOT / "config" / "baseline.json") == []
    doc["economy"]["diag"] = {"cx_cure": "yes", "bogus": 1}
    p = tmp_path / "baseline.json"
    p.write_text(json.dumps(doc), encoding="utf-8")
    errs = fairplay.economy_errors(p)
    assert any("diag.cx_cure" in x for x in errs) and any("diag.bogus" in x for x in errs), errs


def test_why_raw_sends_inspect_raw_and_prints_the_kernels_lines_unchanged(save, monkeypatch, capsys):
    sent = []
    lines = ["order 5 job_type=3(CustomReaction) status=[active,validated]", "  shops for this order: workshop:Still"]

    def fake_send(save_dir, verb, args, by="cli", wait_s=5.0, **kw):
        sent.append((verb, args, by))
        return "c1", {"id": "c1", "ok": True, "msg": lines[0], "data": {"kind": "order", "key": "order:5", "lines": lines, "n": 2, "clipped": False}}

    monkeypatch.setattr(cmd, "send", fake_send)
    assert cli.main(["--save", str(save), "why", "order:5", "--raw"]) == 0
    assert sent == [("inspect", {"what": "raw", "key": "order:5"}, "cli")]
    assert capsys.readouterr().out.splitlines() == lines
    assert cli.main(["--save", str(save), "why", "brew"]) == 0           # without --raw the old query
    assert sent[-1][1]["what"] == "why"
