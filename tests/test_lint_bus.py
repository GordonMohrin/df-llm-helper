"""F9 linter (rules, cases, allowlist, gate), F7 bus (dedupe, priority, import, concurrency)."""
import multiprocessing as mp
from pathlib import Path

import pytest

from conftest import FIX
from df_llm_helper.bus import Bus, guess_prio, parse_inbox_line
from df_llm_helper.client import RealClient
from df_llm_helper.clock import FakeClock
from df_llm_helper.fairplay import ExceptionRegistry
from df_llm_helper.lint import RULES, gate_command, lint_command, lint_file, lint_paths, lint_source
from df_llm_helper.store import Store
from helpers import ROOT

CASES = ROOT / "tests" / "lint_cases"


def test_at_least_25_rules_each_with_cases():
    ids = [r.id for r in RULES]
    assert len(ids) >= 25 and len(set(ids)) == len(ids)
    for rid in ids:
        assert (CASES / f"{rid}_pos.lua").exists() and (CASES / f"{rid}_neg.lua").exists(), rid


@pytest.mark.parametrize("rid", [r.id for r in RULES])
def test_rule_positive_and_negative(rid):
    pos = [f.rule for f in lint_file(CASES / f"{rid}_pos.lua")]
    neg = [f.rule for f in lint_file(CASES / f"{rid}_neg.lua")]
    assert rid in pos, (rid, pos)
    assert rid not in neg, (rid, neg)


def test_bundled_lua_scripts_linted_without_crash():
    """All bundled Lua (pilot_*.lua + companion scripts lua/claude/): every finding must be documented in
    docs/LINT-FINDINGS.md (file + rule; line numbers may move)."""
    import re
    fs = lint_paths([ROOT / "lua", ROOT / "does-not-exist.lua"])
    assert all(":" in str(f) for f in fs)
    assert any(f.rule == "IO" for f in fs)
    known = set(re.findall(r"\| (\S+?):\d+ (L\d+) \|", (ROOT / "docs" / "LINT-FINDINGS.md").read_text(encoding="utf-8")))
    for f in fs:
        if f.rule != "IO":
            assert (Path(f.file).name, f.rule) in known, f"undocumented finding: {f}"


def test_allowlist_via_register(tmp_path):
    src = "df.item.find(187405).flags.foreign = false\n"
    assert [f.rule for f in lint_source(src)] == ["L06"]
    reg = ExceptionRegistry(tmp_path / "ex.jsonl")
    reg.add("L06", "E18", "yes, foreign=false for the picks")
    assert lint_source(src, registry=reg) == []


def test_lint_command_variants(tmp_path):
    assert [f.rule for f in lint_command('lua "df.item.find(1).flags.foreign=false"')] == ["L06"]
    assert [f.rule for f in lint_command('lua -e "u.pos.x = 5"')] == ["L08"]
    f = tmp_path / "x.lua"
    f.write_text("dfhack.run_command('reveal')\n")
    assert [x.rule for x in lint_command(f"lua -f {f}")] == ["L04"]
    assert lint_command("lua -f /does/not/exist.lua") == []
    assert lint_command("claude/status") == []
    assert [x.rule for x in lint_command("teleport -x 1")] == ["L08"]
    assert lint_command('lua "unbalanced') is not None


def test_real_client_refuses_lint_failures(tmp_path):
    rc = RealClient(tmp_path / "dfhack-run.exe", lint=gate_command(None))
    r = rc.run('lua "u.counters2.thirst_timer = 0"')
    assert not r.ok and "Lint refused" in r.stderr and "L15" in r.stderr
    r = rc.run("claude/status")
    assert not r.ok and "dfhack-run not found" in r.stderr
    reg = ExceptionRegistry(tmp_path / "ex.jsonl")
    reg.add("L15", "Test", "yes")
    rc2 = RealClient(tmp_path / "dfhack-run.exe", lint=gate_command(reg))
    assert "not found" in rc2.run('lua "u.counters2.thirst_timer = 0"').stderr
    assert gate_command(None)('lua "local t = dfhack.maps.getTileType(1,1,1)"') == []   # a warning does not block


# ---------------------------------------------------------------- Bus
def bus():
    return Bus(Store(":memory:"), FakeClock(1000))


def test_bus_dedupe_and_counter():
    b = bus()
    a = b.post("bau", "orchestrator", "Lager voll", dedupe_key="lager")
    c = b.post("bau", "orchestrator", "Lager voll (2)", dedupe_key="lager", prio="crit")
    assert a == c and b.count("orchestrator") == 1
    m = b.read("orchestrator")[0]
    assert m.count == 2 and m.text == "Lager voll (2)" and m.prio == "crit" and "(x2)" in m.line()
    b.post("bau", "orchestrator", "Lager voll", dedupe_key="lager", prio="info")
    assert b.pending("orchestrator")[0].prio == "crit"      # the higher priority stays
    b.ack("orchestrator")
    d = b.post("bau", "orchestrator", "Lager voll", dedupe_key="lager")
    assert d != a and b.count("orchestrator") == 2           # new message after completion
    with pytest.raises(ValueError):
        b.post("x", "y", "z", prio="mittel")


def test_bus_priorities_unread_ack():
    b = bus()
    b.post("a", "o", "info only", prio="info")
    b.post("b", "o", "Achtung", prio="warn")
    b.post("c", "o", "Feind!", prio="crit")
    b.post("d", "other", "not for o", prio="crit")
    msgs = b.read("o")
    assert [m.prio for m in msgs] == ["crit", "warn", "info"]
    assert b.read("o") == []                                 # unread only
    assert len(b.pending("o")) == 3
    assert b.ack("o", [msgs[0].id]) == 1 and len(b.pending("o")) == 2
    assert b.read("other", mark=False)[0].text == "not for o"
    long = b.post("x", "o", "y" * 500)
    assert len(b.read("o")[0].line(80)) <= 100


def test_bus_import_orchestrator_inbox_completely(tmp_path):
    b = bus()
    src = FIX / "scopes_sample" / "inbox-orchestrator.md"
    n_lines = sum(1 for ln in src.read_text(encoding="utf-8").splitlines() if ln.startswith("- "))
    new, skipped = b.import_inbox(src)
    assert new == n_lines == b.count("orchestrator") and skipped == 0
    assert b.import_inbox(src) == (0, n_lines)              # idempotent
    msgs = b.read("orchestrator", limit=100)
    assert {m.sender for m in msgs} >= {"auslastung", "erkundung", "infra", "bau"}
    assert any(m.prio == "crit" for m in msgs)
    out = tmp_path / "inbox-x.md"
    b.export_to_inbox(out, msgs[0])
    assert parse_inbox_line(out.read_text(encoding="utf-8").strip())[0] == msgs[0].sender


def test_guess_prio_and_parse():
    assert guess_prio("CRITICAL: enemy") == "crit" and guess_prio("bottleneck wood") == "warn"
    assert guess_prio("all good") == "info"
    assert parse_inbox_line("- from bau, 01.10. 09:25 (Y100 Opal 12): DECISION: x") == \
        ("bau", "01.10. 09:25 (Y100 Opal 12)", "DECISION: x")
    assert parse_inbox_line("no format") is None


def _writer(db_path: str, n: int, who: int) -> None:
    from df_llm_helper.bus import Bus
    from df_llm_helper.clock import FakeClock
    from df_llm_helper.store import Store
    b = Bus(Store(db_path), FakeClock(1000 + who))
    for i in range(n):
        b.post(f"p{who}", "orchestrator", f"Nachricht {who}-{i}", prio="info")
        if i % 5 == 0:
            b.post(f"p{who}", "orchestrator", "gemeinsam", dedupe_key="shared", prio="info")


def test_bus_concurrent_writers_no_loss(tmp_path):
    db = str(tmp_path / "bus.db")
    Store(db).close()
    ctx = mp.get_context("spawn")
    procs = [ctx.Process(target=_writer, args=(db, 25, w)) for w in range(4)]
    for p in procs:
        p.start()
    for p in procs:
        p.join(60)
        assert p.exitcode == 0
    b = Bus(Store(db), FakeClock(0))
    rows = b.db.execute("SELECT text, count FROM messages").fetchall()
    singles = [r for r in rows if r["text"] != "gemeinsam"]
    shared = [r for r in rows if r["text"] == "gemeinsam"]
    assert len(singles) == 100 and len(shared) == 1 and shared[0]["count"] == 20
