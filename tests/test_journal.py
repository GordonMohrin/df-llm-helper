"""Spec 12 journal: chronicle recall on a real event log (run 3), lessons without duplicates, metrics header,
postmortem without inventions, write limits."""
import json
import re
from datetime import date
from pathlib import Path

import pytest

from conftest import FIX
from dfpilot.clock import FakeClock
from dfpilot.config import HOME
from dfpilot.fairplay import ExceptionRegistry
from dfpilot.journal import NOISE, Journal, classify_tag, fix_mojibake, is_chronicle_event, parse_events_log
from dfpilot.metrics import METRICS_HEADER, record_kpis
from dfpilot.store import Store
from dfpilot.toolsfs import read_text_tolerant
from helpers import snap_for

LOG = FIX.parent / "run5_live" / "events_run3.log"          # real tools/out/events-run3.log (3015 lines)


def _journal(store=None, **cfg):
    return Journal(store or Store(), cfg, HOME)


def test_chronik_recall_on_real_events_log():
    """Acceptance 1: all KRITISCH events (without combat/everyday noise) are in the chronicle draft, recall >= 90 %."""
    text = read_text_tolerant(LOG)
    krit = []
    for ln in text.splitlines():                            # independent count
        m = re.match(r"^﻿?KRITISCH\s+\S+\s+\[([A-Z_0-9]+)\]\s*(.*)$", ln.strip())
        if m and not NOISE.search(m.group(1)):
            krit.append(fix_mojibake(m.group(2).strip()))
    assert len(krit) > 200
    j = _journal()
    new, total = j.ingest_log(text, date(2026, 9, 30))
    assert new == total and total >= len(krit)
    lines = j.chronik()
    covered_texts = {e["text"] for c in j.clusters() for e in c["items"]}
    recall = sum(1 for t in krit if t in covered_texts) / len(krit)
    assert recall >= 0.90, recall
    assert len(lines) < 80 and all(len(x) <= 200 for x in lines)              # concise
    assert any("109 deaths" in x for x in lines) and any("Forgotten Beast" in x for x in lines)
    assert any("ôtthat" in x for x in lines) and not any("├" in x for x in lines)   # encoding repaired
    assert j.ingest_log(text, date(2026, 9, 30))[0] == 0                      # no double import


def test_parse_events_day_rollover_and_classes():
    evs = parse_events_log("KRITISCH 23:59:00 [CITIZEN_DEATH] A, Miner has been found dead.\n"
                           "info 00:01:00 [CARAVAN_ARRIVAL] x\ngarbage\n", date(2026, 10, 1))
    assert len(evs) == 2 and evs[1]["ts"] - evs[0]["ts"] == 120
    assert classify_tag("MEGABEAST_ARRIVAL") == "Attack" and classify_tag("CITIZEN_DEATH") == "Death"
    assert classify_tag("WEIRD", "info") == "Other" and classify_tag("WEIRD") == "Emergency"
    assert not is_chronicle_event("KRITISCH", "COMBAT_STRIKE_DETAILS") and is_chronicle_event("info", "CARAVAN_ARRIVAL")
    assert not is_chronicle_event("info", "MASTERPIECE_CRAFTED")


def test_lesson_two_mood_failures_wood_exactly_one():
    """Acceptance 2: 2x 'mood fails, wood 0' -> exactly one proposal, no duplicates."""
    st = Store()
    for uid, t in ((4197, 100.0), (3476, 200.0)):
        st.warn(t, "mood", f"mood:insane:{uid}", f"Mood {uid} FAILED (Berserk): berserk danger, "
                f"keep civilians away; gaps: wood missing 1 (need 1, free 0, bound 0)", "crit")
    st.warn(300.0, "mood", "mood:insane:9", "Mood 9 FAILED (Melancholy): berserk danger", "crit")
    j = _journal(st)
    assert j.ingest_warnings() == 3 and j.ingest_warnings() == 0
    ls = j.lessons()
    assert len(ls) == 1 and ls[0].key == "Mood failed | wood" and ls[0].count == 2
    j.mark_suggested(ls)
    assert j.lessons() == []                                                     # not again
    st.warn(400.0, "mood", "mood:insane:7", "Mood 7 FAILED (Fey): x; gaps: wood missing 2", "crit")
    j.ingest_warnings()
    assert j.lessons() == []                                                     # known pattern stays quiet


def test_lesson_accept_writes_only_kb_draft(tmp_path):
    st = Store()
    for i in range(2):
        st.warn(i, "mood", f"m{i}", f"Mood {i} FAILED (Fey): x; gaps: rough gems missing 1", "crit")
    j = Journal(st, {"kb_out": "kb.jsonl"}, tmp_path)
    j.ingest_warnings()
    p = j.accept(j.lessons()[0])
    e = json.loads(p.read_text(encoding="utf-8"))
    assert p == tmp_path / "kb.jsonl" and e["status"] == "unreviewed" and "rough" in e["title"]


def test_metrics_export_same_header_as_metrics_csv():
    """Acceptance 3: same header as the existing metrics.csv (run 5), one line per game month."""
    real_header = (FIX.parent / "run5_live" / "metrics_run5.csv").read_text(encoding="utf-8").splitlines()[0]
    st = Store()
    for i, (day, mon) in enumerate([(3, "Granite"), (20, "Granite"), (5, "Slate"), (27, "Slate"), (1, "Felsite")]):
        snap = snap_for(pop=20 + i)
        snap.date_text = f"{day}. {mon}, Jahr 102"
        record_kpis(st, 1000.0 + i, snap)
    out = _journal(st).monthly_metrics()
    rows = out.splitlines()
    assert rows[0] == real_header == ";".join(METRICS_HEADER)
    assert len(rows) == 4 and rows[1].split(";")[1] == "20. Granite, Jahr 102" and rows[2].split(";")[2] == "23"


def test_postmortem_only_real_data():
    """Acceptance 4: timeline + causes of death from state.db, nothing invented."""
    st = Store()
    snap = snap_for()
    st.add_snapshot(1.0, snap.game_id, snap.facts())
    st.log_action(2.0, "siege", "siege", "kill", "siege", "claude/pilot_siege kill 33 5000", False, True, "")
    st.log_action(3.0, "mood", "mood", "release-cutgems", "jobs", "x", False, False, "")
    j = _journal(st)
    j.ingest_log("KRITISCH 10:00:00 [CITIZEN_DEATH] Urvad Rith, Miner has been found dead, dehydrated.\n"
                 "KRITISCH 10:05:00 [CITIZEN_DEATH] Rovod Kib, Mason has been struck down.\n"
                 "KRITISCH 10:06:00 [MEGABEAST_ARRIVAL] The Forgotten Beast Neca has come!\n", date(2026, 10, 1))
    reg = ExceptionRegistry(None)
    j.registry = reg
    pm = j.postmortem()
    for sec in ("## Timeline", "## Causes of death", "## Decisions with outcome", "## Key figures",
                "## Fair-play exceptions"):
        assert sec in pm
    assert "has been found dead, dehydrated: 1" in pm and "has been struck down: 1" in pm
    assert "2 deaths: Urvad Rith, Rovod Kib" in pm and "Forgotten Beast Neca" in pm
    assert "mood/release-cutgems: 1x, 1 failed" in pm and "siege/kill: 1x" in pm
    assert f"- pop: {snap.pop_total} -> {snap.pop_total}" in pm
    empty = _journal().postmortem()
    assert "no deaths" in empty and "no events" in empty and "no entries" in empty


def test_write_targets_restricted(tmp_path, tools_dir, capsys):
    """Acceptance 5: only dfpilot/ and configured files."""
    from dfpilot.cli import main
    chron = tmp_path / "chronik.md"
    chron.write_text("# Chronik\n", encoding="utf-8")
    c = tmp_path / "c.yaml"
    c.write_text(f"paths:\n  tools: {tools_dir}\n  scopes: {tools_dir / 'scopes'}\n  state_db: {tmp_path / 's.db'}\n"
                 f"  gamelog: {tmp_path / 'g'}\njournal:\n  chronik: {chron}\n  metrics: {tmp_path / 'm.csv'}\n"
                 f"  postmortem: {tmp_path / 'pm.md'}\n  events_log: {LOG}\n", encoding="utf-8")
    assert main(["--config", str(c), "--mock", str(FIX), "journal", "ingest", "--date", "2026-09-30"]) == 0
    assert "318 chronicle events" in capsys.readouterr().out
    assert main(["--config", str(c), "--mock", str(FIX), "journal", "chronik", "--append"]) == 0
    assert "deaths" in chron.read_text(encoding="utf-8")
    assert main(["--config", str(c), "--mock", str(FIX), "journal", "postmortem", "--out", str(tmp_path / "pm.md")]) == 0
    assert (tmp_path / "pm.md").exists()
    with pytest.raises(SystemExit, match="refused"):
        main(["--config", str(c), "--mock", str(FIX), "journal", "postmortem", "--out", str(tmp_path / "anders.md")])
    with pytest.raises(SystemExit, match="refused"):
        main(["--config", str(c), "--mock", str(FIX), "journal", "metrics", "--out", "/etc/x.csv"])
    assert main(["--config", str(c), "--mock", str(FIX), "journal", "metrics", "--out", str(tmp_path / "m.csv")]) == 0
    assert main(["--config", str(c), "--mock", str(FIX), "journal", "lessons"]) == 0
    assert "suggestions" in capsys.readouterr().out        # run 3 log: repeated dehydration deaths are a lesson
