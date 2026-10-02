"""BUG-104: remove snapshot/kpi rows that a `--mock` run wrote into the live state.db (before mock runs were isolated).

A mock run stores the facts of the fixture recording (`fixtures/run5`: Windrings, `12. Hematite, Jahr 102`, pop 24 ...)
with the real wall-clock time and the fort's real game_id, so there is no "source" column to tell them apart. A row is
removed only if BOTH hold:

1. its game_id and facts match a fixture fingerprint (`data/mock_fingerprints.json`, generated from the fixtures; a
   test keeps it in sync) on every fingerprint key (date, pop, drinks, meals, wealth, open jobs ...), and
2. it contradicts the time line of the same game: another snapshot of that game_id lies several game years away
   although it was stored only minutes apart (no real fort runs that fast - a replayed fixture does).

A real snapshot taken at the very moment the fixture was recorded keeps its place (condition 2 fails). The kpis of a
removed snapshot (same ts and game date) go with it. Idempotent; runs when the live state.db is opened.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

FINGERPRINT_FILE = Path(__file__).resolve().parent.parent / "data" / "mock_fingerprints.json"
FINGERPRINT_KEYS = ("fort", "date", "pop", "adults", "drink_days", "food_days", "drinks", "meals", "jobs_open",
                    "dig_jobs", "wealth")
SECONDS_PER_GAME_YEAR_MIN = 300.0      # faster than one game year per 5 real minutes is impossible for a real fort
KPI_TS_SLACK_S = 5.0
WINDOW_S = 86400.0                     # neighbours within a real day are enough to see an impossible jump
_YEAR = re.compile(r"(?:Jahr|Year)\s+(-?\d+)", re.I)


def load_fingerprints(path: Path = FINGERPRINT_FILE) -> list[dict]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    return [d for d in data.get("fingerprints", []) if isinstance(d, dict) and d.get("game_id") and d.get("facts")]


def fingerprint_from_snapshot(snap) -> dict:
    """Fingerprint of a snapshot (used to generate data/mock_fingerprints.json from a fixture directory)."""
    f = snap.facts()
    return {"game_id": snap.game_id, "facts": {k: f.get(k) for k in FINGERPRINT_KEYS}}


def _year(date_text) -> int | None:
    m = _YEAR.search(str(date_text or ""))
    return int(m.group(1)) if m else None


def _matches(game_id, facts: dict, fps: list[dict]) -> bool:
    return any(game_id == fp["game_id"] and all(facts.get(k) == v for k, v in fp["facts"].items()) for fp in fps)


def _contradicts_timeline(row: dict, others: list[dict]) -> bool:
    y = row["year"]
    if y is None:
        return False
    for o in others:
        if o["id"] == row["id"] or o["year"] is None:
            continue
        dy = abs(o["year"] - y)
        if dy >= 2 and abs(o["ts"] - row["ts"]) < (dy - 1) * SECONDS_PER_GAME_YEAR_MIN:
            return True
    return False


def _rows(db, sql: str, args: tuple) -> list[dict]:
    out = []
    for r in db.execute(sql, args).fetchall():
        try:
            facts = json.loads(r["facts"])
        except (TypeError, ValueError):
            continue
        if isinstance(facts, dict):
            out.append({"id": r["id"], "ts": float(r["ts"] or 0), "facts": facts, "year": _year(facts.get("date"))})
    return out


def purge_mock_rows(db, fingerprints: list[dict] | None = None) -> dict:
    """Deletes fixture snapshot rows (and their kpis) from a live state.db; returns {"snapshots": n, "kpis": m}."""
    fps = load_fingerprints() if fingerprints is None else fingerprints
    out = {"snapshots": 0, "kpis": 0}
    for gid in sorted({fp["game_id"] for fp in fps}):
        # cheap pre-filter on the stored JSON text: only rows with a fixture date are candidates
        dates = sorted({fp["facts"].get("date") for fp in fps if fp["game_id"] == gid and fp["facts"].get("date")})
        cand = []
        for d in dates:
            cand += _rows(db, "SELECT id, ts, facts FROM snapshots WHERE game_id=? AND facts LIKE ?",
                          (gid, "%" + json.dumps(d, ensure_ascii=False) + "%"))
        cand = [r for r in cand if _matches(gid, r["facts"], fps)]
        if not cand:
            continue
        lo, hi = min(r["ts"] for r in cand) - WINDOW_S, max(r["ts"] for r in cand) + WINDOW_S
        rows = _rows(db, "SELECT id, ts, facts FROM snapshots WHERE game_id=? AND ts BETWEEN ? AND ?", (gid, lo, hi))
        bad = [r for r in cand if _contradicts_timeline(r, rows)]
        for r in bad:
            db.execute("DELETE FROM snapshots WHERE id=?", (r["id"],))
            # the kpis are written right after the snapshot (own clock reading): same game date, ts within seconds
            cur = db.execute("DELETE FROM kpis WHERE ts BETWEEN ? AND ? AND game_date=?",
                             (r["ts"] - KPI_TS_SLACK_S, r["ts"] + KPI_TS_SLACK_S, r["facts"].get("date") or ""))
            out["snapshots"] += 1
            out["kpis"] += max(cur.rowcount, 0)
    return out
