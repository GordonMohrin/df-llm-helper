"""Regression tests for the bug reports whose open questions the player delegated to us (BUG-104, BUG-220, BUG-319,
BUG-418, BUG-421)."""
from __future__ import annotations

import json
import stat
import sys
from pathlib import Path

import pytest

from df_llm_helper.client import MAX_REPORT_ID_CMD, MockClient, RealClient, Result
from df_llm_helper.clock import FakeClock
from df_llm_helper.config import DEFAULTS, load_config
from df_llm_helper.store import Store

HERE = Path(__file__).resolve().parent
HOME = HERE.parent
FIX = HOME / "fixtures" / "run5"
EVID = HOME / "Bugs" / "evidence"


# ---------------------------------------------------------------- BUG-104 mock rows in the live state.db
def _fixture_facts() -> tuple[str, dict]:
    from df_llm_helper.pilot import Pilot
    p = Pilot(load_config(None), MockClient.from_fixture_dir(FIX), store=Store())
    snap = p.snapshot()
    return snap.game_id, snap.facts()


def test_bug104_fingerprints_match_fixtures():
    """data/mock_fingerprints.json must describe what `--mock fixtures/run5` really writes (regenerate on change)."""
    from df_llm_helper.mockrows import FINGERPRINT_KEYS, load_fingerprints
    gid, facts = _fixture_facts()
    fps = load_fingerprints()
    assert any(fp["game_id"] == gid and fp["facts"] == {k: facts.get(k) for k in FINGERPRINT_KEYS} for fp in fps)


def _seed(db_path: Path, gid: str, mock: dict) -> None:
    """The live state.db of BUG-104 (Bugs/evidence/BUG-104/live_state_db_readonly_queries.txt): ids 1 and 4 are the
    fixture, the others real Y116/Y118 rows of the same game."""
    real116 = {**mock, "date": "26. Opal, Jahr 116", "pop": 176, "drink_days": 62, "jobs_open": 237, "wealth": 900000}
    real118 = {**mock, "date": "27. Granite, Jahr 118", "pop": 174, "drink_days": 49, "jobs_open": 101,
               "wealth": 950000}
    t0 = 1_790_840_000.0
    rows = [(t0, mock), (t0 + 13, real116), (t0 + 23, real116), (t0 + 1304, mock), (t0 + 13564, real118)]
    st = Store(":memory:")
    st.db.execute(f"ATTACH DATABASE '{db_path}' AS live")
    st.db.executescript("CREATE TABLE IF NOT EXISTS live.snapshots (id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, "
                        "game_id TEXT, facts TEXT); CREATE TABLE IF NOT EXISTS live.kpis (id INTEGER PRIMARY KEY "
                        "AUTOINCREMENT, ts REAL, game_date TEXT, name TEXT, value REAL);")
    for ts, f in rows:
        st.db.execute("INSERT INTO live.snapshots(ts, game_id, facts) VALUES(?,?,?)", (ts, gid, json.dumps(f)))
        for k in ("pop", "drink_days"):
            st.db.execute("INSERT INTO live.kpis(ts, game_date, name, value) VALUES(?,?,?,?)",
                          (ts + 0.002, f["date"], k, f[k]))      # own clock reading right after the snapshot
    st.close()


def test_bug104_live_db_mock_rows_removed_real_rows_kept(tmp_path):
    gid, mock = _fixture_facts()
    db = tmp_path / "data" / "state.db"
    db.parent.mkdir()
    _seed(db, gid, mock)
    st = Store(db)                                   # opening the live db runs the cleanup
    assert st.purged == {"snapshots": 2, "kpis": 4}
    dates = [s["facts"]["date"] for s in st.snapshots()]
    assert dates == ["26. Opal, Jahr 116"] * 2 + ["27. Granite, Jahr 118"]
    assert {r[0] for r in st.db.execute("SELECT game_date FROM kpis")} == {"26. Opal, Jahr 116", "27. Granite, Jahr 118"}
    assert st.get("migration.mock_rows_purged") == {"snapshots": 2, "kpis": 4}
    st.close()
    st2 = Store(db)                                  # idempotent
    assert st2.purged == {"snapshots": 0, "kpis": 0} and len(st2.snapshots()) == 3


def test_bug104_real_snapshot_at_the_fixture_moment_is_kept(tmp_path):
    """A real row with the fixture's facts but a consistent time line (the fort was really at Y102 then) stays."""
    gid, mock = _fixture_facts()
    db = tmp_path / "state.db"
    st = Store(db)
    st.add_snapshot(1_000.0, gid, mock)
    st.add_snapshot(1_000.0 + 86400 * 3, gid, {**mock, "date": "26. Opal, Jahr 116"})    # 14 years in 3 real days
    st.add_snapshot(5_000.0, "Other|1|2", {**mock, "fort": "Other"})                      # other game: untouched
    st.close()
    st = Store(db)
    assert st.purged["snapshots"] == 0 and len(st.snapshots()) == 3


def test_bug104_no_cleanup_in_mock_db_or_mock_run(tmp_path, monkeypatch):
    from df_llm_helper import config as C
    gid, mock = _fixture_facts()
    monkeypatch.setattr(C, "RUNTIME", tmp_path / "rt")
    mdb = tmp_path / "rt" / "mock" / "state.db"
    mdb.parent.mkdir(parents=True)
    _seed(mdb, gid, mock)
    assert Store(mdb).purged["snapshots"] == 0       # the isolated mock db keeps its fixture rows
    live = tmp_path / "live.db"
    _seed(live, gid, mock)
    monkeypatch.setattr(C, "_FORCED", {"paths": {}})  # during a --mock run nothing is deleted
    assert Store(live).purged["snapshots"] == 0
    monkeypatch.setattr(C, "_FORCED", {})
    assert Store(live).purged["snapshots"] == 2
