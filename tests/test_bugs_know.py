"""Regression tests for the knowledge / agents / reports / fair-play bug reports (Bugs/BUG-300..330)."""
import json
import shutil
from pathlib import Path

import pytest

from df_llm_helper.cli import main
from df_llm_helper.fairplay import ExceptionRegistry, FairPlayError, parse_expires
from helpers import ROOT

FIX = ROOT / "fixtures" / "run5"


@pytest.fixture
def env(tmp_path):
    """Isolated config: own data copy, scopes, tools, state.db, register."""
    data = tmp_path / "data"
    shutil.copytree(ROOT / "data", data, ignore=shutil.ignore_patterns("state.db*", "*.local.jsonl"))
    (tmp_path / "tools" / "scopes").mkdir(parents=True)
    c = tmp_path / "cfg.yaml"
    c.write_text(f"paths:\n  tools: {tmp_path / 'tools'}\n  scopes: {tmp_path / 'tools' / 'scopes'}\n"
                 f"  state_db: {tmp_path / 's.db'}\n  data: {data}\n  exceptions: {data / 'exceptions.jsonl'}\n"
                 f"  gamelog: {FIX / 'logs' / 'gamelog_selected.txt'}\n", encoding="utf-8")
    return tmp_path, str(c)


def run(capsys, *args):
    rc = main([str(a) for a in args])
    o = capsys.readouterr()
    return rc, o.out, o.err


# ---------------------------------------------------------------- BUG-315 / 316 / 317: exception register
def test_bug315_add_prints_the_entry_just_written(env, capsys):
    tmp, c = env
    (tmp / "data" / "exceptions.local.jsonl").write_text(
        '{"ts": "2026-10-02T06:35:42Z", "action": "FP10", "objects": ["189175", "3738"], "reason": "local", '
        '"player_consent": "synthetic quote", "max_uses": 5}\n', encoding="utf-8")
    rc, out, _ = run(capsys, "--config", c, "exception", "add", "FP08", "--objects", "187405, 187429",
                     "--reason", "E18 picks", "--ja", "yes, do it")
    assert rc == 0 and "Exception registered: FP08 ['187405', '187429'] (in exceptions.jsonl)" in out
    rc, out, _ = run(capsys, "--config", c, "exception", "add", "L31", "--reason", "dig", "--ja", "yes")
    assert rc == 0 and out.startswith("Exception registered: L31 []")


@pytest.mark.parametrize("bad", ["2026-13-45", "2026-02-30", "30.09.2026", "tomorrow", "2026-1-1"])
def test_bug316_invalid_expires_refused(tmp_path, bad):
    reg = ExceptionRegistry(tmp_path / "ex.jsonl")
    with pytest.raises(FairPlayError):
        reg.add("FP11", "r", "q", expires=bad)
    assert not (tmp_path / "ex.jsonl").exists()


def test_bug316_date_only_valid_through_end_of_day(tmp_path):
    p = tmp_path / "ex.jsonl"
    ExceptionRegistry(p).add("FP11", "r", "q", expires="2026-10-02")
    assert ExceptionRegistry(p, now_iso="2026-10-02T12:00:00Z").allows("FP11")
    assert ExceptionRegistry(p, now_iso="2026-10-02T23:59:59Z").allows("FP11")
    assert not ExceptionRegistry(p, now_iso="2026-10-03T00:00:00Z").allows("FP11")
    assert parse_expires("2026-10-02T10:00:00Z") < parse_expires("2026-10-02")


@pytest.mark.parametrize("rule", ["FP0", "L99", "FP14", "fp08", "FP08;rm", None, ""])
def test_bug316_unknown_rule_ids_refused(tmp_path, rule):
    with pytest.raises(FairPlayError):
        ExceptionRegistry(tmp_path / "ex.jsonl").add(rule, "r", "q")


def test_bug316_known_rule_ids_and_objects(tmp_path):
    reg = ExceptionRegistry(tmp_path / "ex.jsonl")
    for r in ("FP01", "FP13", "L01", "L30", "L31"):
        assert reg.add(r, "r", "q").action == r
    with pytest.raises(FairPlayError):
        reg.add("FP13", "r", "q", objects=[" ", "a b", "ä"])
    with pytest.raises(FairPlayError):
        reg.add("FP13", "r", "q", max_uses=0)
    assert reg.add("FP13", "r", "q", objects=[" 12 ", "34"]).objects == ["12", "34"]


def test_bug317_bad_lines_are_register_errors_not_crashes(tmp_path, capsys):
    p = tmp_path / "ex.jsonl"
    p.write_text('{"action":"FP08","reason":"ok line","player_consent":"yes"}\n[1,2]\n"just a string"\n', encoding="utf-8")
    reg = ExceptionRegistry(p)
    assert [e.action for e in reg.entries] == ["FP08"]
    assert sum("not a JSON object" in e for e in reg.errors) == 2
    p.write_bytes(b'\xef\xbb\xbf{"action":"FP08","reason":"BOM line","player_consent":"yes"}\n'
                  b'{"action":"L31","reason":"objects as a string","player_consent":"yes","objects":"123"}\n')
    reg = ExceptionRegistry(p)
    assert [e.action for e in reg.entries] == ["FP08"]                   # the BOM line is read
    assert any("objects must be a list" in e for e in reg.errors) and not reg.allows("L31")
    p.write_text('{"action":"L31","reason":"text","player_consent":"yes","max_uses":"2"}\n', encoding="utf-8")
    reg = ExceptionRegistry(p)
    assert reg.find("L31") is None and any("max_uses" in e for e in reg.errors)   # fail closed, no TypeError
