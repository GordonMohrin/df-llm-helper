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


# ---------------------------------------------------------------- BUG-318 / 319 / 320: linter
from df_llm_helper.lint import lint_command, lint_paths, lint_source  # noqa: E402


def _rules(src):
    return sorted({f.rule for f in lint_source(src)})


@pytest.mark.parametrize("src,rule", [
    ('local c = "reveal hell"\ndfhack.run_command(c)\n', "L04"),
    ("local border = u\nborder.pos.x = 5\n", "L08"),
    ("u.pos = {x=1, y=2, z=3}\n", "L08"),
    ("local tt = dfhack.maps.getTileType(1,2,3)\n" + "\n" * 40 + "local x = other_table.hidden\n", "L10"),
    ("blk.tiletype[1][1] = 5\n", "L17"),
    ("weapon.mat_type = 0\n", "L21"),
    ("dfhack.run_command('tiletypes-command', 'p any')\n", "L17"),
    ("dfhack.run_command('liquids')\n", "L18"),
    ("dfhack.run_command('cleaners')\n", "L25"),
    ("dfhack.run_command('teleport', '-x', '1')\n", "L08"),
])
def test_bug318_indirect_forms_detected(src, rule):
    assert rule in _rules(src)


@pytest.mark.parametrize("src", [
    "local teleporting_label = 1\n", "local tiletypes = {}\n", "local liquids = {}\n", "local cleaners = {}\n",
    "local recorder = {}\nrecorder.count = 1\n", "job.mat_type = 0\n",
    "local f = df.job_item:new()\nf.item_type = 1\nf.mat_type = -1; f.mat_index = -1\n",
])
def test_bug319_identifiers_not_reported(src):
    assert _rules(src) == []


def test_bug319_bare_command_lines_still_checked():
    assert [f.rule for f in lint_command("teleport -x 1")] == ["L08"]
    assert [f.rule for f in lint_command("tiletypes-here")] == ["L17"]
    assert [f.rule for f in lint_command("liquids")] == ["L18"]


def test_bug320_missing_path_and_utf16_are_errors(tmp_path, capsys):
    fs = lint_paths([tmp_path / "nonexist.lua", tmp_path / "nonexist_dir"])
    assert [f.level for f in fs] == ["error", "error"]
    u16 = tmp_path / "u16.lua"
    u16.write_bytes('dfhack.run_command("dig-now")\r\n'.encode("utf-16"))
    assert [f.rule for f in lint_paths([u16])] == ["L02"]
    nobom = tmp_path / "nobom.lua"
    nobom.write_bytes('dfhack.run_command("dig-now")'.encode("utf-16-le"))
    assert [(f.rule, f.level) for f in lint_paths([nobom])] == [("IO", "error")]
    assert main(["lint", str(tmp_path / "typo.lua")]) == 1


# ---------------------------------------------------------------- BUG-300 / 301 / 321 / 325: runbooks
def test_bug300_show_lists_params_preconditions_rollback(capsys):
    rc, out, _ = run(capsys, "--mock", FIX, "runbook", "show", "rb01_e18_pick")
    assert rc == 0
    assert "Params:\n  squad_id (required: --param squad_id=<value>)" in out
    assert "Preconditions:\n  not danger" in out and "Rollback:\n 1. cmd: claude/mil workmode {squad_id} off --apply" in out
    assert "rb01c_e18_release" not in out                                 # BUG-321: no such runbook


def test_bug300_consent_runbook_can_be_previewed_not_run(capsys):
    rc, out, _ = run(capsys, "--mock", FIX, "runbook", "run", "rb01b_e18_foreign", "--dry-run", "--param", "item_ids=1,2")
    assert rc == 0 and "NOT approved" in out and "dry-run: nothing executed" in out
    rc, out, _ = run(capsys, "--mock", FIX, "runbook", "run", "rb01b_e18_foreign", "--param", "item_ids=1,2")
    assert rc == 1 and "refused" in out


def test_bug301_runbook_argument_errors(capsys):
    rc, _, err = run(capsys, "--mock", FIX, "runbook", "run", "rb21_flut", "--dry-run", "--param", "x")
    assert rc == 2 and "--param expects name=value, got 'x'" in err
    rc, _, err = run(capsys, "--mock", FIX, "runbook", "show")
    assert rc == 2 and "Runbook id missing" in err and "None" not in err
    rc, _, err = run(capsys, "--mock", FIX, "runbook", "show", "nope")
    assert rc == 2 and "Unknown runbook: 'nope'" in err


def test_bug321_no_stale_watcher_references(capsys):
    rc, out, _ = run(capsys, "--mock", FIX, "runbook", "show", "rb05_waechter_blind")
    assert "waechter --loop" in out and "Restart unpause-guard" not in out
    for kid in ("waechter_blind", "guard_start"):
        rc, out, _ = run(capsys, "--mock", FIX, "kb", "get", kid)
        assert "waechter --loop" in out
    assert "autopilot log" not in (ROOT / "docs" / "manual-v3" / "05-tools.md").read_text(encoding="utf-8")


def test_bug325_bom_yaml_and_bad_runbook_isolated(env, capsys):
    tmp, c = env
    rb = tmp / "data" / "runbooks"
    src = (rb / "rb09_aquifer.yaml").read_text(encoding="utf-8").replace("id: rb09_aquifer", "id: rb98_bom", 1)
    (rb / "rb98_bom.yaml").write_bytes(b"\xef\xbb\xbf" + src.encode("utf-8"))
    (rb / "rb99_broken.yaml").write_text("id: rb99\ntitle: x\n", encoding="utf-8")
    rc, out, err = run(capsys, "--config", c, "--mock", FIX, "runbook", "list")
    assert rc == 0 and "rb98_bom" in out and "rb01_e18_pick" in out
    assert "Runbook skipped: rb99_broken.yaml" in err
    sc = tmp / "data" / "scopes.yaml"
    sc.write_bytes(b"\xef\xbb\xbf" + sc.read_bytes())
    rc, out, _ = run(capsys, "--config", c, "--mock", FIX, "brief", "bau")
    assert rc == 0 and out.startswith("# Briefing bau")
