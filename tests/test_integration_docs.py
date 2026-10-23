"""Integration audit I4: what the eleven packages of the first pass (BUG-044 .. BUG-075, FR-70 .. FR-78) must keep
together in the documents: the bug table, the contract tables, the phase table of RULES, no broken Markdown tables."""
import json
import re
from pathlib import Path

import pytest

from dfpilot import schema

ROOT = Path(__file__).resolve().parent.parent


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


def bug_rows() -> list[tuple[int, str, int]]:
    """(number, link target, columns) of every row of bugs/README.md's table."""
    out = []
    for line in read("bugs/README.md").splitlines():
        m = re.match(r"\| \[BUG-(\d+)\]\(([^)]+)\)", line)
        if m:
            out.append((int(m.group(1)), m.group(2), len(re.split(r"(?<!\\)\|", line)) - 2))
    return out


def test_bug_table_has_one_complete_row_per_file_in_order():
    rows = bug_rows()
    nums = [n for n, _, _ in rows]
    assert nums == sorted(nums), "the rows of bugs/README.md run in ascending order"
    assert len(nums) == len(set(nums)), "one row per bug"
    files = {int(p.name[4:7]): p.name for p in (ROOT / "bugs").glob("BUG-[0-9][0-9][0-9]-*.md")}
    assert set(nums) == set(files), "a row for every bug file and a file for every row"
    for n, target, cols in rows:
        assert target == files[n], f"BUG-{n:03d}: the link points at the file"
        assert cols == 5, f"BUG-{n:03d}: ID | Status | Severity | Title | Module (the row has {cols} columns)"


def test_first_pass_numbers_are_all_there():
    nums = {n for n, _, _ in bug_rows()}
    assert set(range(44, 76)) <= nums
    fr = read("docs/feature-requests/README.md")
    for n in range(70, 79):
        assert len(re.findall(rf"^\*\*FR-{n}\b", fr, re.M)) == 1, f"FR-{n}: exactly one entry"


def _expand(text: str) -> set[tuple[str, int]]:
    ids = set()
    for kind in ("BUG", "FR"):
        for m in re.finditer(rf"{kind}-(\d+)(?: to {kind}-(\d+)| \.\. {kind}-(\d+))?", text):
            lo = int(m.group(1))
            hi = int(m.group(2) or m.group(3) or lo)
            ids |= {(kind, n) for n in range(lo, hi + 1)}
    return ids


def test_changelog_names_every_bug_and_fr_of_the_first_pass_in_a_heading():
    heads = "\n".join(l for l in read("CHANGELOG.md").splitlines() if l.startswith("## "))
    want = {("BUG", n) for n in range(44, 76)} | {("FR", n) for n in range(70, 79)}
    assert sorted(want - _expand(heads)) == []


@pytest.mark.parametrize("rel", ["CHANGELOG.md", "RULES.md", "docs/v2/CONTRACTS.md", "docs/v2/DESIGN.md",
                                 "docs/v2/DECISIONS.md", "docs/v2/TRIAGE-run11-14.md", "bugs/README.md"])
def test_no_blank_line_inside_a_markdown_table(rel):
    lines = read(rel).split("\n")
    bad = []
    for i in range(1, len(lines) - 2):
        if lines[i] == "" and lines[i - 1].startswith("|") and lines[i + 1].startswith("|") \
                and not re.match(r"^\|[\s:|-]+\|?$", lines[i + 2]):
            bad.append(f"{rel}:{i + 1}: {lines[i - 1][:40]!r} / {lines[i + 1][:40]!r}")
    assert bad == []


def test_no_merge_markers_in_the_documents():
    for rel in ("CHANGELOG.md", "RULES.md", "bugs/README.md", "docs/v2/CONTRACTS.md", "docs/v2/DESIGN.md",
                "docs/v2/DECISIONS.md", "docs/feature-requests/README.md"):
        assert not re.search(r"^(<{7}|={7}|>{7})( |$)", read(rel), re.M), rel


def test_every_event_is_a_row_of_the_contracts_event_table():
    """CONTRACTS.md names every event of schema.EVENTS in a table row (the appendix lists the schemas, not the events)."""
    doc = read("docs/v2/CONTRACTS.md")
    rows = "\n".join(l.split("|")[1] for l in doc.splitlines() if l.startswith("| ") and l.count("|") > 3)
    missing = [t for t in schema.EVENTS if not re.search(rf"\b{t}\b", rows)]
    assert missing == []


def test_every_rules_section_7_row_names_events_that_exist():
    rules = read("RULES.md")
    sec = rules.split("## 7.")[1].split("## 8.")[0]
    synthetic = {"QUICKSAVE_FAILED"}                      # follow's own wake reasons (wake.SYNTH), not kernel events
    names = set()
    for line in sec.splitlines():
        if line.startswith("|") and not line.startswith("|---") and not line.startswith("| Event"):
            names |= set(re.findall(r"[A-Z][A-Z0-9_]{2,}", line.split("|")[1]))
    assert sorted(n for n in names if n not in schema.EVENTS and n not in synthetic) == []


def test_rules_phase_table_puts_fortcore_stage_3_where_plans_year1_does():
    """DECISIONS 1: stage 3 (O1, B2, the refuge) is a P3 build; RULES section 11 and DESIGN 5.12 say the same."""
    plan = json.loads(read("plans/year1.json"))
    phases = plan["phases"] if isinstance(plan, dict) else plan
    holder = [p["id"] for p in phases if {"k": "proj", "tpl": "fortcore", "stage": 3} in p["deliver"]]
    assert holder == ["P3"]
    for rel in ("RULES.md", "docs/v2/DESIGN.md"):
        rows = {m.group(1): m.group(2) for m in re.finditer(r"^\| (P\d)\b[^|]*\| (.*) \|$", read(rel), re.M)}
        assert "stage 3" in rows["P3"], rel
        assert "fortcore stage 3" not in rows["P5"], rel
