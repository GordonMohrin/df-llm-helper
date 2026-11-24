"""NEU1 P2 Live-Rückmeldung: tools/live_status.py (verdicts from the players' logs into the `Live` column of
bugs/README.md and docs/v2/LIVE-STATUS.md) and the lint rule `live_expectation` (dfpilot/lint.py bug_files)."""
import importlib.util
import json
import re
import sys
from pathlib import Path

import pytest

from dfpilot import lint

ROOT = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("live_status_t", ROOT / "tools" / "live_status.py")
L = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = L
_spec.loader.exec_module(L)


def verdicts(line: str) -> dict[int, str]:
    return {h.bug: h.verdict for h in L.scan_text(line, "x.md")}


@pytest.mark.parametrize("line, want", [
    ("- OBS Drill y418: 'occupied:B1' (BUG-543 Fix wirkt)", {543: "pos"}),
    ("-> BUG-523 (Phasen ohne Fortkern) wirkt hier NICHT, P2 bleibt.", {523: "neg"}),
    ("- BUG-297 Oberflaechen-Farm: **FAIL (teilweise)**. Rest", {297: "neg"}),
    ("Fallback automatisch (BUG-340 greift nicht?).", {340: "unc"}),
    ("- Pop 87: BUG-327 Militaer scheint zu wirken (8 -> 14 sol).", {327: "unc"}),
    ("- BUG-305 Handel-Klick: nicht prüfbar, Karawane y377", {305: "unc"}),
    ("cistern abgelehnt (BUG-469), refuge_drink platziert", {469: "unc"}),
    ("surfacecore nicht im Entwurf (BUG-399-Guard Fehlalarm).", {399: "neg"}),
    ("Karawane GEHANDELT (BUG-488 wirkt: Totems -> Cloth, kein Stein)", {488: "pos"}),
    # the verdict of the next sentence does not count for this mention
    ("Hinweis BUG-543 beachtet. Danach alles OK.", {543: "unc"}),
])
def test_one_mention_one_verdict(line, want):
    assert verdicts(line) == want


def test_ranges_lists_and_suffixes():
    assert verdicts("- Phase (BUG-300..302): OK sichtbar") == {300: "pos", 301: "pos", 302: "pos"}
    assert verdicts("- BUG-328/329 wirken sichtbar: brief zeigt") == {328: "pos", 329: "pos"}
    assert verdicts("`resuspended 0`. BUG-004/005/009 confirmed for the old sites.") == \
        {4: "pos", 5: "pos", 9: "pos"}
    assert verdicts("- BUG-316/297b Oberflaechen-Farm: **OK**.") == {316: "pos"}, "297b is a new note, not BUG-297"
    assert set(verdicts("Bruecken (BUG-310..BUG-312): OK")) == {310, 311, 312}
    off = {h.bug for h in L.scan_text("(BUG-300..302): OK", "x.md", dict(L.DEFAULTS, ranges=False))}
    assert off == {300}


def test_each_mention_is_judged_up_to_the_next():
    assert verdicts("BUG-001 offen, dann BUG-002 wirkt.") == {1: "unc", 2: "pos"}


def test_status_of_bug():
    H = L.Hit
    assert L.status_of([]) == L.OPEN
    assert L.status_of([H(1, "f", 1, "unc", "")]) == L.OPEN, "uncertain never changes a status (fail closed)"
    assert L.status_of([H(1, "f", 1, "pos", "")]) == L.CONFIRMED
    assert L.status_of([H(1, "f", 1, "neg", ""), H(1, "f", 2, "unc", "")]) == L.REFUTED
    assert L.status_of([H(1, "f", 1, "pos", ""), H(1, "f", 2, "neg", "")]) == L.MIXED


README = """# Bugs

| ID | Status | Severity | Title | Module |
|----|--------|----------|-------|--------|
| [BUG-001](BUG-001-a.md) | fixed (offline, live-untested) | high | a \\| b | x.lua |
| [BUG-002](BUG-002-b.md) | open | low | c | y.lua |
"""


def test_readme_gets_a_live_column_and_stays_put():
    st = {1: L.CONFIRMED, 2: L.OPEN}
    once = L.rewrite_readme(README, st)
    assert "| ID | Status | Live | Severity | Title | Module |" in once
    assert "| [BUG-001](BUG-001-a.md) | fixed (offline, live-untested) | live bestaetigt | high | a \\| b | x.lua |" in once
    assert L.rewrite_readme(once, st) == once, "idempotent"
    merged = once + "| [BUG-003](BUG-003-c.md) | fixed (offline, live-untested) | medium | d | z.lua |\n"
    again = L.rewrite_readme(merged, {**st, 3: L.REFUTED})
    assert "| [BUG-003](BUG-003-c.md) | fixed (offline, live-untested) | live widerlegt | medium | d | z.lua |" in again


def _runs(tmp_path: Path) -> Path:
    runs = tmp_path / "game" / "runs"
    (runs / "run-16x").mkdir(parents=True)
    (runs / "run-16x" / "FR-BUGS.md").write_text(
        "- BUG-001 Fix wirkt: kein Absturz.\n- BUG-002 wirkt hier NICHT.\n- BUG-003 laeuft (check OK).\n",
        encoding="utf-8")
    return runs


def test_collect_with_curated_drop_and_add(tmp_path):
    runs = _runs(tmp_path)
    conf = dict(L.DEFAULTS, docs=[], status_line=False, found_line=False,
                drop=["runs/run-16x/FR-BUGS.md:3:BUG-003: the player's own check, no verdict on the fix"],
                add=[{"bug": 4, "file": "runs/run-16x/FR-BUGS.md", "line": 1, "verdict": "neg", "why": "same symptom"}])
    hits = L.collect(runs, conf, repo=tmp_path)
    st = L.statuses(hits, [1, 2, 3, 4, 5])
    assert st == {1: L.CONFIRMED, 2: L.REFUTED, 3: L.OPEN, 4: L.REFUTED, 5: L.OPEN}
    h3 = [h for h in hits if h.bug == 3][0]
    assert h3.verdict == "unc" and h3.why.startswith("curated:"), "a dropped match stays listed as uncertain"
    rep = L.report(hits, st, runs)
    assert "`runs/run-16x/FR-BUGS.md:2`" in rep and "BUG-003" in rep.split("## Unsichere Fundstellen")[1]


def test_found_line_without_a_verdict_word_is_uncertain(tmp_path):
    b = tmp_path / "bugs"
    b.mkdir()
    (b / "BUG-208-x.md").write_text("# BUG-208 x\nStatus: fixed\nFound: 2026-10-29, live test round 3 (BUG-174c "
                                    "re-check), kernel bd27973\n", encoding="utf-8")
    (b / "BUG-170-x.md").write_text("# BUG-170 x\nFound: 2026-10-29, live test round 2 (BUG-142 retest, NEW1), "
                                    "BUG-131b\n", encoding="utf-8")
    (b / "BUG-154-x.md").write_text("# BUG-154\nFound: live test i4 (M6-BUG-116, M6-BUG-117, new bug 2)\n",
                                    encoding="utf-8")
    (b / "BUG-195-x.md").write_text("# BUG-195\nFound: live test round 3 (finding BUG-162..164-live, skeptic)\n",
                                    encoding="utf-8")
    (b / "BUG-155-y.md").write_text("# BUG-155\nFound: live test i4 (M6-BUG-118 side note, new bug 3)\n",
                                    encoding="utf-8")
    (b / "BUG-072-z.md").write_text("# BUG-072\nFound: Run 11 y451 (BUG-039)\n", encoding="utf-8")
    hits = L.scan_found_lines(b)
    assert {(h.bug, h.verdict) for h in hits} == {(174, "unc"), (142, "unc"), (131, "unc"), (116, "unc"),
                                                  (117, "unc"), (162, "unc"), (163, "unc"), (164, "unc"),
                                                  (118, "unc")}
    st = L.statuses(hits, [174, 142, 116])
    assert set(st.values()) == {L.OPEN}, "an uncertain Found line never changes a status (fail closed)"


def test_found_line_with_a_verdict_word_refutes(tmp_path):
    b = tmp_path / "bugs"
    b.mkdir()
    (b / "BUG-187-x.md").write_text("# BUG-187\nFound: 2026-10-29, live test round 2, instance i4 (BUG-128d PARTIAL, "
                                    "NEW2), confirmed by the skeptic re-check\n", encoding="utf-8")
    (b / "BUG-163-x.md").write_text("# BUG-163\nFound: 2026-10-29, live test round 2 instance i3 (BUG-130 PARTIAL, "
                                    "finding NEW3, confirmed by the skeptic)\n", encoding="utf-8")
    (b / "BUG-300-x.md").write_text("# BUG-300\nFound: live test (BUG-201 retest, NEW1 failed later)\n",
                                    encoding="utf-8")
    got = {(h.bug, h.verdict) for h in L.scan_found_lines(b)}
    assert got == {(128, "neg"), (130, "neg"), (201, "unc")}, "the verdict word must follow that bug's own mention"


def test_status_line_counts_only_a_confirmed_fix(tmp_path):
    b = tmp_path / "bugs"
    b.mkdir()
    (b / "BUG-025-a.md").write_text("# a\nStatus: fixed and confirmed live (y415)\n", encoding="utf-8")
    (b / "BUG-042-b.md").write_text("# b\nStatus: fixed (the cause live confirmed y471; the fix offline, "
                                    "live-untested)\n", encoding="utf-8")
    assert [h.bug for h in L.scan_status_lines(b)] == [25]


def test_write_fails_closed_without_the_logs(tmp_path, monkeypatch):
    rd, rp = tmp_path / "README.md", tmp_path / "LIVE.md"
    rd.write_text(README, encoding="utf-8")
    monkeypatch.setattr(L, "README", rd)
    monkeypatch.setattr(L, "REPORT", rp)
    assert L.main(["--write", "--runs", str(tmp_path / "nope")]) == 1
    assert rd.read_text(encoding="utf-8") == README and not rp.exists()


def test_switch_off_writes_nothing(tmp_path, monkeypatch):
    rd, rp = tmp_path / "README.md", tmp_path / "LIVE.md"
    rd.write_text(README, encoding="utf-8")
    monkeypatch.setattr(L, "README", rd)
    monkeypatch.setattr(L, "REPORT", rp)
    monkeypatch.setattr(L, "load_config", lambda path=None: dict(L.DEFAULTS, on=False, docs=[]))
    assert L.main(["--write", "--runs", str(_runs(tmp_path))]) == 0
    assert rd.read_text(encoding="utf-8") == README and not rp.exists()


def test_config_errors(tmp_path):
    assert L.config_errors() == [], "config/process.json of the repository is valid"
    p = tmp_path / "process.json"
    p.write_text(json.dumps({"x": 1, "live_status": {"on": "yes", "drop": ["bad"], "add": [{"bug": 1}]},
                             "lint": {"live_expectation_from": 0}}), encoding="utf-8")
    errs = L.config_errors(p)
    assert len(errs) == 5, errs
    assert lint.process_errors(p) == errs


def test_repo_readme_and_report_agree():
    """The committed table and LIVE-STATUS.md come from one run of the tool (counts match)."""
    rows = [re.split(r"(?<!\\)\|", l)[3].strip() for l in (ROOT / "bugs/README.md").read_text("utf-8").splitlines()
            if l.startswith("| [BUG-")]
    rep = (ROOT / "docs/v2/LIVE-STATUS.md").read_text("utf-8")
    for s in L.STATUSES:
        m = re.search(rf"^\| {re.escape(s)} \| (\d+) \|$", rep, re.M)
        assert m and int(m.group(1)) == rows.count(s), s


# ------------------------------------------------------------------ lint: Live-Erwartung from BUG-783 on
def _bug(d: Path, n: int, body: str) -> None:
    (d / f"BUG-{n:03d}-x.md").write_text(f"# BUG-{n:03d} x\nStatus: fixed (offline, live-untested)\n{body}",
                                         encoding="utf-8")


def test_lint_wants_a_live_expectation_from_783(tmp_path):
    _bug(tmp_path, 782, "no section\n")
    _bug(tmp_path, 783, "## Cause\nx\n")
    _bug(tmp_path, 784, "## Live-Erwartung\n1. events show X\n")
    _bug(tmp_path, 785, "Live-Erwartung: kern.log names Y within 2 days\n")
    _bug(tmp_path, 786, "The Live-Erwartung is in the note.\n")      # a mention is no section
    conf = {"live_expectation": True, "live_expectation_from": 783}
    found = lint.bug_files(tmp_path, conf)
    assert [f["file"] for f in found] == ["bugs/BUG-783-x.md", "bugs/BUG-786-x.md"]
    assert {f["rule"] for f in found} == {"live_expectation"}
    assert lint.bug_files(tmp_path, {"live_expectation": False}) == []


def test_lint_default_run_includes_the_bug_files(monkeypatch, capsys):
    monkeypatch.setattr(lint, "lua", lambda paths: [])
    monkeypatch.setattr(lint, "bug_files", lambda: [{"file": "bugs/BUG-799-x.md", "line": 1,
                                                     "rule": "live_expectation", "msg": "m"}])
    assert lint.main([]) == 1
    assert "live_expectation" in capsys.readouterr().out
    assert lint.main(["lua/dfllm/act.lua"]) == 0, "an explicit Lua path lints Lua only"
    assert lint.main(["--bugs"]) == 1


def test_process_conf_fails_closed(tmp_path):
    bad = tmp_path / "p.json"
    bad.write_text("{", encoding="utf-8")
    assert lint.process_conf(bad)["live_expectation"] is True
    assert lint.process_conf(tmp_path / "missing.json")["live_expectation_from"] == 783
