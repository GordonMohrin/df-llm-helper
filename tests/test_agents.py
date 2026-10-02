"""Spec 10 subagents: prompt <= 1500 tokens with mandatory blocks, report linter, cost measurement (requestId dedupe),
comparison, task dedupe. Transcripts: fixtures/subagents (anonymized from real runs, only usage/block lengths)."""
import collections
import json
from pathlib import Path

import pytest

from conftest import FIX
from df_llm_helper.agents import (DEFAULTS, MARKER, AgentCost, TaskDedupe, build_prompt, compare, cost_report,
                            lint_report, parse_transcript, tokens)
from df_llm_helper.brief import SCOPES, build_brief, load_scopes
from df_llm_helper.clock import FakeClock
from df_llm_helper.config import DEFAULTS as CFG
from df_llm_helper.kb import KB
from df_llm_helper.store import Store
from helpers import ROOT, ctx_for

SUB = FIX.parent / "subagents"
SCOPES_DEF = load_scopes(ROOT / "data" / "scopes.yaml")
KB_ALL = KB.load_dir(ROOT / "data" / "kb", current_run=5, stale_before=4)
LONG_MEM = "\n".join(f"## Pass {i}\n- " + "Finding " * 40 for i in range(40))


@pytest.mark.parametrize("scope", sorted(SCOPES_DEF))
def test_prompt_all_scopes_within_1500_with_required_blocks(scope):
    """Acceptance 1 (all 12 scopes, also with a long memory)."""
    ctx, snap = ctx_for(drink_days=10)
    brief = build_brief(scope, scopes_def=SCOPES_DEF, ctx=ctx, snap=snap, kb=KB_ALL, memory_text=LONG_MEM,
                        inbox_lines=["- from bau: " + "x" * 200] * 6, th=CFG["thresholds"], budget=1500)
    p = build_prompt(scope, "Bring drinks above 30 days " * 30, brief, fort="Windrings")
    assert tokens(p) <= 1500, tokens(p)
    for block in (MARKER, "## Task", "## Briefing", "## Report format", "## Fair Play", "## Commands",
                  "Result:", "Measurements (before/after):", "Risk:"):
        assert block in p, block
    assert len(SCOPES_DEF) == 12


GOOD = """Result: Drinks 20 -> 64 days
Measurements (before/after): Drinks 120/380, idle 12/5
Changed: 2 brewing orders, barrels 6
Open: plants scarce
Risk: none"""
GOOD_DE = """Ergebnis: Getraenke 20 -> 64 Tage
Messwerte (vorher/nachher): Getraenke 120/380, Idle 12/5
Geaendert: 2 Brau-Auftraege, Faesser 6
Offen: Pflanzen knapp
Risiko: keins"""


def test_lint_report_positive_negative_and_truncation(tmp_path):
    """Acceptance 2."""
    assert lint_report(GOOD).ok
    assert lint_report(GOOD_DE).ok and lint_report(GOOD_DE.replace("Geaendert", "Geändert")).ok   # German names accepted
    r = lint_report(GOOD.replace("Risk: none", ""))
    assert not r.ok and "Risk" in r.problems[0]
    long = GOOD + "\n" + "\n".join(f"- Detail {i}" for i in range(20))
    r = lint_report(long, 12)
    assert not r.ok and "25 lines > 12" in r.problems[0] and r.truncated
    assert len(r.text.splitlines()) == 12 and "truncated" in r.text.splitlines()[-1]
    r = lint_report("Everything went great, lots done.")
    assert not r.ok and "Result" in r.problems[0]


def _reference(path: Path) -> dict:
    """Independent manual measurement: the last usage per requestId, sums."""
    last = {}
    for ln in path.read_text(encoding="utf-8").splitlines():
        d = json.loads(ln)
        if d.get("type") == "assistant":
            last[d["requestId"]] = d["message"]["usage"]
    s = collections.Counter()
    for u in last.values():
        for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens"):
            s[k] += u.get(k, 0)
    return {"calls": len(last), **s}


@pytest.mark.parametrize("name", ["agent-anon1", "agent-anon2"])
def test_cost_reproduces_reference_sums(name):
    """Acceptance 3: +-1 % (exact here); a naive sum would be ~2x."""
    p = SUB / f"{name}.jsonl"
    ref = _reference(p)
    ac = parse_transcript(p)
    assert ac.calls == ref["calls"]
    assert abs(ac.cache_read - ref["cache_read_input_tokens"]) <= 0.01 * ref["cache_read_input_tokens"]
    assert abs(ac.cache_write - ref["cache_creation_input_tokens"]) <= 0.01 * ref["cache_creation_input_tokens"]
    assert ac.output == ref["output_tokens"] and ac.input == ref["input_tokens"]
    assert ac.lines > ac.calls                                         # the transcript counts blocks multiple times
    assert ac.description and ac.duration_s > 60 and ac.out_est > ac.output


def test_cost_values_run_and_compare(tmp_path):
    rows, lines = cost_report(sorted(SUB.glob("*.jsonl")))
    assert [r.calls for r in rows] == [47, 56] and [r.cache_read for r in rows] == [8728163, 14968099]
    assert lines[-1].startswith("agent-anon1:") and "stuck" in lines[-1]                  # ~51k output > 40k
    assert "Total" in lines[3] and "103" in lines[3]
    assert compare(rows).startswith("Comparison not possible: 0 runs with briefing")
    # Acceptance 4 (mechanics): 3 briefing runs vs. 3 old ones -> percent smaller
    mk = lambda o, b: AgentCost("x", out_est=o, cache_read=o * 100, briefing=b)
    c = compare([mk(1000, False), mk(1200, False), mk(800, False), mk(600, True), mk(700, True), mk(500, True)])
    assert c.startswith("Briefing 3 vs. old 3: output 40 % smaller") and "too few" not in c
    assert "too few" in compare([mk(1000, False), mk(500, True)])
    # marker in the first prompt -> briefing detected
    f = tmp_path / "agent-b.jsonl"
    f.write_text(json.dumps({"type": "user", "message": {"content": MARKER + " You are ..."}}) + "\n"
                 + json.dumps({"type": "assistant", "requestId": "r1", "message": {"usage": {"output_tokens": 5},
                              "content": [{"type": "text", "text": "x" * 30}]}}) + "\nbroken\n")
    ac = parse_transcript(f)
    assert ac.briefing and ac.calls == 1 and ac.out_est == 10


def test_task_dedupe_10_min():
    clock = FakeClock(0)
    td = TaskDedupe(Store(), clock, 600)
    assert td.check_and_mark("trinken", "Check  drinks")
    assert not td.check_and_mark("trinken", "check drinks")
    assert td.check_and_mark("essen", "Check drinks")
    clock.advance(601)
    assert td.check_and_mark("trinken", "Check drinks")


def test_cli_agents(tmp_path, tools_dir, capsys):
    from df_llm_helper.cli import main
    c = tmp_path / "c.yaml"
    c.write_text(f"paths:\n  tools: {tools_dir}\n  scopes: {tools_dir / 'scopes'}\n  state_db: {tmp_path / 's.db'}\n"
                 f"  gamelog: {tmp_path / 'g'}\n", encoding="utf-8")
    assert main(["--config", str(c), "--mock", str(FIX), "agents", "prompt", "trinken", "--task", "Barrels"]) == 0
    out = capsys.readouterr().out
    assert out.startswith(MARKER) and tokens(out) <= 1500
    assert main(["--config", str(c), "--mock", str(FIX), "agents", "prompt", "trinken", "--task", "Barrels"]) == 1
    assert "< 10 min ago" in capsys.readouterr().out
    rep = tmp_path / "r.md"
    rep.write_text(GOOD + "\n" + "\n".join(f"- {i}" for i in range(20)), encoding="utf-8")
    assert main(["--config", str(c), "agents", "lint-report", str(rep), "--scope", "trinken"]) == 1
    out = capsys.readouterr().out
    assert "Original archived" in out and list((tools_dir / "out" / "berichte").glob("*-trinken.md"))
    assert main(["--config", str(c), "agents", "cost", "--dir", str(SUB), "--compare"]) == 0
    assert "agent-anon1" in capsys.readouterr().out
    assert main(["--config", str(c), "agents", "cost", "--dir", str(tmp_path / "empty")]) == 1
