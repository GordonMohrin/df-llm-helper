"""F12 scenarios (end-to-end), wake filter, pilot cycle, CLI."""
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

from conftest import FIX, set_age
from dfpilot.cli import main
from dfpilot.client import MockClient
from dfpilot.pilot import Pilot
from dfpilot.scenario import check_expectations, run_scenario
from dfpilot.store import Store
from dfpilot.toolsfs import ToolsDir
from dfpilot.wake import wake_check
from helpers import ROOT
from make_fixtures import build_scenarios, write_scenarios

SCEN = sorted((ROOT / "scenarios").glob("*.jsonl"))


def test_at_least_8_scenarios_and_generator_reproducible(tmp_path):
    assert len(SCEN) >= 8
    write_scenarios(tmp_path)
    for p in SCEN:
        assert (tmp_path / p.name).read_bytes() == p.read_bytes(), f"{p.name} outdated: python tests/make_fixtures.py"
    assert set(build_scenarios()) == {p.stem for p in SCEN}


@pytest.mark.parametrize("path", SCEN, ids=[p.stem for p in SCEN])
def test_scenario_end_to_end(path):
    res = run_scenario(path)
    assert check_expectations(res) == []


@pytest.mark.parametrize("path", SCEN[:4], ids=[p.stem for p in SCEN[:4]])
def test_scenario_deterministic(path):
    a, b = run_scenario(path), run_scenario(path)
    assert [(s.digest, s.commands, s.guard_kinds, s.diagnose) for s in a.steps] == \
           [(s.digest, s.commands, s.guard_kinds, s.diagnose) for s in b.steps]


def test_check_expectations_reports_failures():
    res = run_scenario(SCEN[0])
    res.meta["expect"] = {"commands_include": ["never"], "commands_exclude": ["claude/trinken"],
                          "digest_contains": ["NEVER"], "flag_exists_after": ["x"], "diagnose_includes": ["rbX"],
                          "file_after": {"a": "b"}, "events_contains": ["§1"], "guard_kinds_step0": ["zz"],
                          "commands_include_step0": ["q"], "digest_contains_step1": ["§2"], "warn_contains": ["§3"]}
    assert len(check_expectations(res)) == 11


# ---------------------------------------------------------------- Pilot
def test_pilot_cycle_with_fixtures(cfg, mock, clock):
    p = Pilot(cfg, mock, store=Store(), clock=clock)
    p.heartbeat()
    rep = p.cycle()
    assert "Status Y102" in rep.digest and rep.snapshot.fort == "Windrings"
    assert mock.write_calls == []          # quiet situation: no write action
    rep2 = p.cycle()
    assert rep2.digest.startswith("No change")
    assert p.digest(scope="militaer").startswith(("No change", "Status"))


def test_pilot_cycle_dry_run_and_new_game(cfg, mock, clock):
    p = Pilot(cfg, mock, store=Store(), clock=clock)
    p.cycle(dry_run=True)
    assert mock.write_calls == []
    p.store.set("game_id", "Altfort|90|1")
    rep = p.cycle()
    assert rep.new_game and "NEW GAME" in rep.digest


# ---------------------------------------------------------------- wake filter
def test_wake_baseline_dedupe_and_new_events(tmp_path, clock):
    tools = ToolsDir(tmp_path, clock)
    store = Store()
    tools.write_flag("caravan", "﻿17. Limestone, Jahr 102\r\n")
    tools.write_flag("migranten", "new citizens")
    assert wake_check(tools, store, clock) == []                      # legacy items = baseline
    assert wake_check(tools, store, clock) == []
    tools.write_flag("mood", "Mestthos Possessed")
    out = wake_check(tools, store, clock)
    assert out == ["WAKE mood: Mestthos Possessed -> dfpilot runbook show rb07_stimmung"]
    tools.write_flag("mood", "Mestthos Possessed")                  # same content written again
    assert wake_check(tools, store, clock) == []
    tools.delete_flag("mood")
    wake_check(tools, store, clock)
    tools.write_flag("mood", "Mestthos Possessed")                  # deleted and re-created = new event
    assert len(wake_check(tools, store, clock)) == 1
    tools.append_event("KRITISCH", "Goblin ambush!", "GUARD")
    tools.append_event("info", "whatever", "GUARD")
    out = wake_check(tools, store, clock)
    assert len(out) == 1 and "critical [GUARD]: Goblin ambush!" in out[0]
    store.warn(clock.now().epoch, "guard", "k1", "DEADMAN", "crit")
    store.warn(clock.now().epoch, "guard", "k2", "info only", "warn")
    out = wake_check(tools, store, clock)
    assert out == ["WAKE dfpilot: DEADMAN -> dfpilot digest"]
    assert len(store.take_warnings()) == 2                            # the digest still receives them


def test_wake_emit_existing(tmp_path, clock):
    tools = ToolsDir(tmp_path, clock)
    tools.write_flag("alert", "Enemy")
    assert len(wake_check(tools, Store(), clock, emit_existing=True)) == 1


# ---------------------------------------------------------------- CLI
@pytest.fixture
def cli_cfg(tmp_path, tools_dir):
    c = tmp_path / "cfg.yaml"
    c.write_text(f"paths:\n  tools: {tools_dir}\n  scopes: {tools_dir / 'scopes'}\n  state_db: {tmp_path / 's.db'}\n"
                 f"  gamelog: {FIX / 'logs' / 'gamelog_selected.txt'}\n  exceptions: {tmp_path / 'ex.jsonl'}\n",
                 encoding="utf-8")
    return str(c)


def run_cli(capsys, *args):
    rc = main(list(args))
    out = capsys.readouterr()
    return rc, out.out, out.err


def test_cli_digest_runbook_kb_brief(cli_cfg, capsys):
    base = ["--config", cli_cfg, "--mock", str(FIX)]
    rc, out, _ = run_cli(capsys, *base, "digest")
    assert rc == 0 and "Status Y102" in out and "Cancel loop Make bed" in out
    rc, out, _ = run_cli(capsys, *base, "digest")
    assert out.startswith("No change")
    rc, out, _ = run_cli(capsys, *base, "runbook", "diagnose")
    assert "rb16_abbruchschleife" in out
    rc, out, _ = run_cli(capsys, *base, "runbook", "run", "rb01_e18_pick", "--dry-run", "--param", "squad_id=32")
    assert rc == 0 and "claude/mil workmode 32 on --apply" in out
    rc, out, _ = run_cli(capsys, *base, "runbook", "show", "rb06_karawane")
    assert "quicksave" in out
    rc, out, _ = run_cli(capsys, *base, "runbook", "list")
    assert "rb01b_e18_foreign [player consent]" in out
    rc, _, err = run_cli(capsys, *base, "runbook", "run", "nothing")
    assert rc == 2
    rc, out, _ = run_cli(capsys, "--config", cli_cfg, "kb", "search", "Koks", "refined", "coal")
    assert out.startswith("[koks_brennstoff]")
    rc, out, _ = run_cli(capsys, "--config", cli_cfg, "kb", "get", "e18_pick")
    assert "E18" in out
    rc, _, _ = run_cli(capsys, "--config", cli_cfg, "kb", "get", "nothing")
    assert rc == 2
    rc, out, _ = run_cli(capsys, "--config", cli_cfg, "kb", "list")
    assert "e18_pick" in out
    rc, out, _ = run_cli(capsys, *base, "brief", "trinken")
    assert "# Briefing trinken" in out and "Fair Play" in out


def test_cli_guard_autopilot_cycle_wake_heartbeat(cli_cfg, capsys, tools_dir):
    base = ["--config", cli_cfg, "--mock", str(FIX)]
    rc, out, _ = run_cli(capsys, "--config", cli_cfg, "heartbeat")
    assert (tools_dir / "heartbeat.txt").exists()
    rc, out, _ = run_cli(capsys, *base, "guard", "--dry-run")
    assert "Target fps" in out
    rc, out, _ = run_cli(capsys, *base, "guard", "ack-gate", "60")
    assert "acknowledged" in out
    rc, out, _ = run_cli(capsys, *base, "autopilot", "--dry-run")
    assert rc == 0
    rc, out, _ = run_cli(capsys, *base, "autopilot", "rules")
    assert "stale_alert_flag" in out
    rc, out, _ = run_cli(capsys, *base, "autopilot", "conflicts")
    assert rc == 0 and "declared" in out
    rc, out, _ = run_cli(capsys, *base, "autopilot", "enable", "fps_drift")
    assert "active again" in out
    rc, out, _ = run_cli(capsys, *base, "cycle", "--dry-run")
    assert "Status" in out
    rc, out, _ = run_cli(capsys, "--config", cli_cfg, "wake")
    assert rc == 0


def test_cli_exception_record_replay(cli_cfg, capsys, tmp_path):
    rc, out, _ = run_cli(capsys, "--config", cli_cfg, "exception", "add", "FP08", "--objects", "187405",
                         "--reason", "E18", "--ja", "yes, go ahead")
    assert "registered" in out
    rc, out, _ = run_cli(capsys, "--config", cli_cfg, "exception", "list")
    assert "FP08" in out and "yes, go ahead" in out
    rc, _, err = run_cli(capsys, "--config", cli_cfg, "exception", "add", "FP09", "--reason", "x")
    assert rc == 3 and "FAIR PLAY" in err
    rec = tmp_path / "rec.jsonl"
    rc, out, _ = run_cli(capsys, "--config", cli_cfg, "--mock", str(FIX), "--record", str(rec), "record",
                         "claude/status", "claude/report")
    assert rc == 0 and len(rec.read_text().splitlines()) == 2
    rc, out, _ = run_cli(capsys, "--config", cli_cfg, "--replay-file", str(rec), "digest")
    assert "Status" in out
    rc, out, _ = run_cli(capsys, "--config", cli_cfg, "--mock", str(FIX), "record")
    assert rc == 2
    rc, out, _ = run_cli(capsys, "replay", str(SCEN[0]), "-v")
    assert rc == 0 and "OK" in out


def test_cli_real_client_without_df(cli_cfg, capsys):
    rc, out, _ = run_cli(capsys, "--config", cli_cfg, "digest")
    assert rc == 0 and "Query failed" in out     # no DF: clear message instead of a crash


def test_module_entrypoint():
    r = subprocess.run([sys.executable, "-m", "dfpilot", "kb", "search", "E18"], cwd=ROOT, capture_output=True,
                       text=True, timeout=60)
    assert r.returncode == 0 and "e18" in r.stdout


def test_selftest_quick(capsys):
    from dfpilot.selftest import LineTracer, core_files, main as st_main, quick_checks
    assert all(ok for _, ok, _ in quick_checks())
    assert st_main(["--quick"]) == 0
    assert "GREEN" in capsys.readouterr().out
    files = core_files()
    assert {f.stem for f in files} >= {"digest", "rules", "runbooks", "kb", "brief", "guard"}
    tr = LineTracer([files[0]])
    with tr:
        from dfpilot.digest import tokens
        tokens("abc")
    rep = tr.report()
    assert 0 < rep[files[0].stem] <= 100


def test_cli_check_and_bus_in_digest(cli_cfg, capsys, tools_dir):
    base = ["--config", cli_cfg, "--mock", str(FIX)]
    rc, out, _ = run_cli(capsys, "--config", cli_cfg, "bus", "post", "Mood", "without", "wood", "--from", "gesundheit",
                         "--prio", "crit")
    rc, out, _ = run_cli(capsys, *base, "check")
    assert rc == 0 and "Status Y102" in out and "> gesundheit: [CRIT] Mood without wood" in out
    assert (tools_dir / "heartbeat.txt").exists()
    rc, out, _ = run_cli(capsys, *base, "check")
    assert out.startswith("No change")
