"""F13 metrics/budget, M2 CLI (memory, bus, lint, budget, metrics)."""
import csv
import io
import shutil

import pytest

from conftest import FIX
from df_llm_helper.cli import main
from df_llm_helper.clock import FakeClock
from df_llm_helper.metrics import METRICS_HEADER, budget_report, budget_rows, export_csv, record_kpis, record_usage
from df_llm_helper.store import Store
from helpers import ROOT, snap_for


def test_usage_and_budget_numbers_match_synthetic_run():
    st = Store()
    now = 1_790_840_000.0
    for i in range(10):
        record_usage(st, now - 60 * i, "orchestrator", "digest", 0.5, 100, "x" * 300)   # 100 Tokens
    for i in range(4):
        record_usage(st, now - 60 * i, "trinken", "brief", 1.0, 50, "y" * 1500)         # 500 Tokens
    record_usage(st, now - 86400, "trinken", "brief", 1.0, 50, "y" * 3000)              # yesterday 1000
    rows = {r["scope"]: r for r in budget_rows(st, now)}
    assert rows["orchestrator"]["calls"] == 10 and rows["orchestrator"]["tokens"] == 1000
    assert rows["orchestrator"]["bytes_out"] == 3000 and rows["orchestrator"]["trend"] == "new"
    assert rows["trinken"]["tokens"] == 2000 and rows["trinken"]["tokens_yday"] == 1000
    assert rows["trinken"]["trend"] == "+100%"
    text, over = budget_report(st, now, 2500)
    assert over and "WARNING" in text and "Total today: 3000" in text
    text, over = budget_report(st, now, 10000)
    assert not over and "WARNING" not in text


def test_kpis_csv_export_loads_with_csv_module():
    st = Store()
    for i, dd in enumerate([80, 70, 60]):
        s = snap_for(drink_days=dd, pop=24 + i, enemies=i)
        assert record_kpis(st, 1_790_840_000 + 60 * i, s) >= 10
    out = export_csv(st)
    rows = list(csv.DictReader(io.StringIO(out), delimiter=";"))
    assert list(rows[0].keys()) == METRICS_HEADER
    assert [r["buerger"] for r in rows] == ["24", "25", "26"] and [r["feinde"] for r in rows] == ["0", "1", "2"]
    assert rows[0]["spieldatum"] == "12. Hematite, Jahr 102"
    # BUG-121: filled like lua/claude/report.lua (negative_gedanken_top, kadaver_tiere_in_festung; 0 if absent)
    assert (rows[0]["sawdeadbody"], rows[0]["death"], rows[0]["ghosthaunt"], rows[0]["tierkadaver"]) == ("88", "0", "0", "4")
    real = (ROOT / "fixtures" / "run5" / "logs" / "metrics_tail.csv").read_text().splitlines()[0].split(";")
    assert real == METRICS_HEADER


@pytest.fixture
def cfg2(tmp_path, tools_dir):
    shutil.copy(FIX / "scopes_sample" / "militaer.md", tools_dir / "scopes" / "militaer.md")
    c = tmp_path / "cfg.yaml"
    c.write_text(f"paths:\n  tools: {tools_dir}\n  scopes: {tools_dir / 'scopes'}\n  state_db: {tmp_path / 's.db'}\n"
                 f"  exceptions: {tmp_path / 'ex.jsonl'}\n  gamelog: {tmp_path / 'gl.txt'}\nmetrics:\n  daily_token_budget: 5\n",
                 encoding="utf-8")
    return str(c)


def run(capsys, *a):
    rc = main(list(a))
    o = capsys.readouterr()
    return rc, o.out, o.err


def test_cli_memory(cfg2, capsys, tools_dir):
    rc, out, _ = run(capsys, "--config", cfg2, "memory", "compact", "militaer", "--dry-run")
    assert "(dry-run) militaer.md: 16738 ->" in out
    rc, out, _ = run(capsys, "--config", cfg2, "memory", "compact", "militaer")
    assert "archive militaer." in out and (tools_dir / "scopes" / "archive").is_dir()
    rc, out, _ = run(capsys, "--config", cfg2, "memory", "restore", "militaer")
    assert "restored from" in out
    assert (tools_dir / "scopes" / "militaer.md").read_bytes() == (FIX / "scopes_sample" / "militaer.md").read_bytes()
    rc, out, err = run(capsys, "--config", cfg2, "memory", "compact", "doesnotexist")
    assert rc == 2
    rc, out, _ = run(capsys, "--config", cfg2, "memory", "compact", "all")
    assert "inbox-orchestrator.md" in out


def test_cli_bus(cfg2, capsys, tools_dir):
    rc, out, _ = run(capsys, "--config", cfg2, "bus", "post", "Storage", "full", "--from", "bau", "--to", "wirtschaft",
                     "--key", "lager", "--md")
    assert out.startswith("#1 to wirtschaft")
    assert "- from bau" in (tools_dir / "scopes" / "inbox-wirtschaft.md").read_text(encoding="utf-8")
    run(capsys, "--config", cfg2, "bus", "post", "Storage", "full", "--from", "bau", "--to", "wirtschaft", "--key", "lager")
    rc, out, _ = run(capsys, "--config", cfg2, "bus", "read", "--to", "wirtschaft")
    assert "(x2)" in out
    rc, out, _ = run(capsys, "--config", cfg2, "bus", "read", "--to", "wirtschaft")
    assert "no unread" in out
    rc, out, _ = run(capsys, "--config", cfg2, "bus", "ack", "--to", "wirtschaft")
    assert "1 done" in out
    rc, out, _ = run(capsys, "--config", cfg2, "bus", "import")
    assert "inbox-orchestrator.md: 24 new" in out


def test_cli_lint_budget_metrics(cfg2, capsys, tmp_path):
    rc, out, _ = run(capsys, "--config", cfg2, "lint", str(ROOT / "lua" / "pilot_wd.lua"), str(ROOT / "lua" / "pilot_batch.lua"))
    assert rc == 0 and "0 findings" in out
    rc, out, _ = run(capsys, "--config", cfg2, "lint", str(ROOT / "lua" / "pilot_caravan.lua"))
    assert rc == 1 and "L07" in out          # deliberate exception, only with register entry FP09
    rc, out, _ = run(capsys, "--config", cfg2, "lint", str(ROOT / "tests" / "lint_cases" / "L01_pos.lua"))
    assert rc == 1 and "L01" in out
    run(capsys, "--config", cfg2, "--mock", str(FIX), "digest")
    rc, out, _ = run(capsys, "--config", cfg2, "budget")
    assert rc == 1 and "WARNING" in out and "orchestrator" in out
    rc, out, _ = run(capsys, "--config", cfg2, "metrics")
    assert out.startswith("echtzeit;spieldatum;buerger") and "24" in out
    rc, out, _ = run(capsys, "--config", cfg2, "metrics", "--out", str(tmp_path / "m.csv"))
    assert (tmp_path / "m.csv").exists() and "1 rows" in out


def test_cli_plan(cfg2, capsys, tmp_path):
    import json as _json
    rc, out, _ = run(capsys, "plan", "blueprint", *map(str, sorted((ROOT / "fixtures" / "run5" / "blueprints_ok").glob("*.csv"))))
    assert rc == 0 and out.count(": ok") >= 5
    rc, out, _ = run(capsys, "plan", "blueprint", str(ROOT / "tests" / "blueprints_bad" / "bad_overlap_workshops.csv"))
    assert rc == 1 and "E_OVERLAP" in out
    t = tmp_path / "t.json"
    t.write_text(_json.dumps({"own": [{"id": "g1", "name": "Mug", "category": "crafts", "value": 100, "weight": 1, "qty": 10}],
                              "offer": [{"id": "w1", "name": "Wood", "category": "wood", "value": 20, "weight": 30, "qty": 20}],
                              "max_weight": 300}))
    rc, out, _ = run(capsys, "plan", "trade", "--json", str(t))
    assert rc == 0 and "buy" in out and "Wood" in out
    base = ["--config", cfg2, "--mock", str(FIX)]
    rc, out, _ = run(capsys, *base, "plan", "armor", "--bars", "iron=32,bronze=31")
    assert rc == 0 and out.startswith("Quota ")
    rc, out, _ = run(capsys, *base, "plan", "supply", "--prod", "drink=1")
    assert "drink: stock 109" in out
    rc, out, _ = run(capsys, *base, "plan", "dig", "--area-file", str(FIX / "area_z130.txt"), "--targets",
                     "100,103;101,103", "--picks", "2", "--csv")
    assert rc == 0 and ("Batch 1" in out or "unreachable" in out)
