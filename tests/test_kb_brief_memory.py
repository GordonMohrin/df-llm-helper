"""F4 KB, F5 briefings, F6 memory compactor."""
from pathlib import Path

import pytest

from conftest import FIX, REPO
from dfpilot import yamlmini
from dfpilot.brief import (FAIRPLAY_BLOCK, REPORT_FORMAT, SCOPES, BriefError, build_brief, load_scopes, shingles)
from dfpilot.config import DEFAULTS
from dfpilot.digest import tokens
from dfpilot.kb import KB, Entry, expand, format_entry, format_hits, import_markdown, tokenize, write_jsonl
from dfpilot.memory import classify, compact_file, compact_text, extract_for_brief, parse_sections, restore, shorten
from helpers import ROOT, ctx_for

KB_ALL = KB.load_dir(ROOT / "data" / "kb", current_run=5, stale_before=4)
QUERIES = yamlmini.load_file(ROOT / "tests" / "kb_queries.yaml")


# ---------------------------------------------------------------- KB
def test_kb_query_hit_rate_at_least_80_percent():
    assert len(QUERIES) == 20
    hits = 0
    misses = []
    for q in QUERIES:
        top = [h.entry.id for h in KB_ALL.search(q["q"], k=3)]
        if set(top) & set(q["soll"]):
            hits += 1
        else:
            misses.append((q["q"], top))
    assert hits / len(QUERIES) >= 0.8, misses


@pytest.mark.parametrize("q", [q["q"] for q in QUERIES])
def test_kb_answer_within_400_tokens(q):
    out = format_hits(KB_ALL.search(q, k=3), 5, 4, 400)
    assert tokens(out) <= 400


def test_kb_import_markdown_without_error(tmp_path):
    """Public version: import of the bundled docs (instead of the private learning journals)."""
    files = sorted((ROOT / "docs").glob("*.md"))
    total = 0
    for f in files:
        es = import_markdown(f)
        assert all(e.status == "unreviewed" and e.id and e.title for e in es)
        total += len(es)
        write_jsonl(es, tmp_path / f"{f.stem}.jsonl")
    assert total >= 20
    kb = KB.load_dir(tmp_path)
    assert len(kb.entries) == total


def test_kb_versioning_marks_old_runs():
    e = KB_ALL.get("flags_stale")
    assert e.run == 3
    txt = format_entry(e, 5, 4)
    assert "Run 3 - possibly outdated" in txt
    assert "outdated" not in format_entry(KB_ALL.get("e18_pick"), 5, 4)
    imp = Entry(id="x", title="t", body="b", status="unreviewed")
    assert "unreviewed" in format_entry(imp, 5, 4)


def test_kb_misc(tmp_path):
    assert tokenize("The Pickaxes!") == ["pickax"]
    assert "e18" in expand(tokenize("pick")) and "e18" in expand(tokenize("Spitzhacke"))
    assert KB_ALL.search("") == [] and "No hits" in format_hits([], 5, 4)
    long = Entry(id="x", title="t", fix="y" * 5000)
    assert tokens(format_entry(long, 5, 4, 400)) <= 400 and "kb get x" in format_entry(long, 5, 4, 400)
    (tmp_path / "a.yaml").write_text("- {id: a, title: t}\n- {id: a, title: u}\n")
    with pytest.raises(ValueError, match="duplicate"):
        KB.load_dir(tmp_path)
    (tmp_path / "a.yaml").write_text("- {id: a, title: t, boese: 1}\n")
    with pytest.raises(ValueError, match="unknown fields"):
        KB.load_dir(tmp_path)
    (tmp_path / "a.yaml").write_text("- {title: t}\n")
    with pytest.raises(ValueError, match="without id"):
        KB.load_dir(tmp_path)
    md = tmp_path / "x.md"
    md.write_text("# Run 2 Topic\n```\n# no title\n```\nText " + "z" * 60 + "\n## Subitem\nshort\n## Subitem\n" + "a" * 50
                  + "\n## Subitem\n" + "b" * 50 + "\n", encoding="utf-8")
    es = import_markdown(md)
    assert es[0].run == 2 and es[0].id == "x.run_2_topic"
    assert [e.id for e in es[1:]] == ["x.subitem", "x.subitem_2"]
    assert KB_ALL.search("pickaxe", include_unreviewed=False)[0].entry.status == "reviewed"


# ---------------------------------------------------------------- Briefings
SCOPES_DEF = load_scopes(ROOT / "data" / "scopes.yaml")
MEM = {"militaer": (FIX / "scopes_sample" / "militaer.md").read_text(encoding="utf-8"),
       "wirtschaft": (FIX / "scopes_sample" / "wirtschaft.md").read_text(encoding="utf-8")}
INBOX = [ln for ln in (FIX / "scopes_sample" / "inbox-orchestrator.md").read_text(encoding="utf-8").splitlines()
         if ln.startswith("- ")]


def _brief(scope, budget=1500, **kw):
    ctx, snap = ctx_for()
    return build_brief(scope, scopes_def=SCOPES_DEF, ctx=ctx, snap=snap, kb=KB_ALL,
                       memory_text=MEM.get(scope, MEM["militaer"]), inbox_lines=INBOX, th=DEFAULTS["thresholds"],
                       budget=budget, date_text="J102 Hematite 12", **kw)


@pytest.mark.parametrize("scope", SCOPES)
def test_brief_all_scopes_within_budget_with_required_blocks(scope):
    b = _brief(scope)
    assert tokens(b) <= 1500
    assert FAIRPLAY_BLOCK in b and REPORT_FORMAT in b and "## Situation" in b and "target" in b
    assert tokens(FAIRPLAY_BLOCK) <= 80
    assert b == _brief(scope)          # deterministic


@pytest.mark.parametrize("scope", ["militaer", "wirtschaft", "handel"])
def test_brief_no_duplicates(scope):
    b = _brief(scope)
    lines = [ln for ln in b.splitlines() if ln.startswith("- ")]
    for i, a in enumerate(lines):
        for c in lines[i + 1:]:
            sa, sc = shingles(a), shingles(c)
            if sa and sc:
                assert len(sa & sc) <= 0.5 * min(len(sa), len(sc)), (a, c)


def test_brief_small_budget_and_errors():
    b = _brief("militaer", budget=300)
    assert tokens(b) <= 300 and FAIRPLAY_BLOCK in b
    with pytest.raises(BriefError, match="budget"):
        _brief("militaer", budget=60)
    with pytest.raises(BriefError, match="unknown"):
        _brief("zauberei")
    bad = {"x": {"mission": "m", "kpis": [], "commands": ["c"]}}
    ctx, snap = ctx_for()
    with pytest.raises(BriefError, match="missing required fields.*kpis.*kb_query"):
        build_brief("x", scopes_def=bad, ctx=ctx, snap=snap, kb=None, memory_text=None, inbox_lines=None,
                    th=DEFAULTS["thresholds"])
    bad = {"x": {"mission": "m", "kpis": [{"name": "a"}], "commands": ["c"], "kb_query": "q"}}
    with pytest.raises(BriefError, match="KPI needs"):
        build_brief("x", scopes_def=bad, ctx=ctx, snap=snap, kb=None, memory_text=None, inbox_lines=None,
                    th=DEFAULTS["thresholds"])
    bad = {"x": {"mission": "m", "kpis": [{"name": "a", "expr": "a.__b"}], "commands": ["c"], "kb_query": "q"}}
    with pytest.raises(BriefError, match="KPI a"):
        build_brief("x", scopes_def=bad, ctx=ctx, snap=snap, kb=None, memory_text=None, inbox_lines=None,
                    th=DEFAULTS["thresholds"])


def test_brief_contains_scope_alerts():
    ctx, snap = ctx_for(drink_days=10)
    b = build_brief("trinken", scopes_def=SCOPES_DEF, ctx=ctx, snap=snap, kb=KB_ALL, memory_text=None,
                    inbox_lines=None, th=DEFAULTS["thresholds"])
    assert "Drinks 10 days" in b and "getraenke_wueste" in b


# ---------------------------------------------------------------- Memory
SAMPLES = sorted((FIX / "scopes_sample").glob("*.md"))


@pytest.mark.parametrize("path", SAMPLES, ids=[p.name for p in SAMPLES])
def test_compact_reduces_40_percent_idempotent_and_target(path):
    t = path.read_text(encoding="utf-8")
    c = compact_text(t)
    assert len(c.encode()) <= 0.6 * len(t.encode())
    assert compact_text(c) == c
    if "inbox" not in path.name:
        assert len(c.encode()) <= 6000


@pytest.mark.parametrize("path", [p for p in SAMPLES if "inbox" not in p.name], ids=lambda p: p.name)
def test_compact_never_loses_open_tasks_or_insights(path):
    t = path.read_text(encoding="utf-8")
    c = compact_text(t)
    for s in parse_sections(t):
        if classify(s) in ("offen", "erkenntnis"):
            for ln in s.lines:
                if ln.strip():
                    assert ln in c, ln[:60]


def test_compact_file_archive_byte_identical_and_restore(tmp_path):
    src = FIX / "scopes_sample" / "militaer.md"
    p = tmp_path / "militaer.md"
    p.write_bytes(src.read_bytes())
    res = compact_file(p, stamp="20261001T1000")
    assert res["changed"] and res["after"] < res["before"]
    assert Path(res["archive"]).read_bytes() == src.read_bytes()
    res2 = compact_file(p, stamp="20261001T1001")
    assert not res2["changed"] and "archive" not in res2
    assert restore(p) and p.read_bytes() == src.read_bytes()
    assert restore(tmp_path / "gibtsnicht.md") is None
    dry = compact_file(p, stamp="x", dry_run=True)
    assert dry["changed"] and p.read_bytes() == src.read_bytes()


def test_memory_helpers():
    assert shorten("kurz") == "kurz"
    s = shorten("- " + "Satz eins. " + "x" * 300)
    assert s == "- Satz eins.…" and shorten(s) == s
    ex = extract_for_brief(MEM["militaer"])
    assert ex["offen"] and ex["offen"][0].startswith("1. Waffen") and ex["status"][0].startswith("(")
    assert compact_text("# t\nkurz\n") == "# t\nkurz\n"
