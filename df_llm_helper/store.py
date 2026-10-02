"""SQLite state (state.db): snapshots, actions, rule state, warnings, KV, messages, metrics.

WAL mode + busy_timeout for parallel processes.
"""
from __future__ import annotations

import json
import sqlite3
from pathlib import Path
from typing import Any

SCHEMA = """
CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS snapshots (id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, game_id TEXT, facts TEXT);
CREATE TABLE IF NOT EXISTS actions (id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, source TEXT, rule TEXT,
    action TEXT, resource TEXT, cmd TEXT, dry_run INTEGER, ok INTEGER, detail TEXT);
CREATE TABLE IF NOT EXISTS rule_state (rule TEXT PRIMARY KEY, last_fire REAL, disabled INTEGER DEFAULT 0,
    reason TEXT, verify_fail INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS warnings (id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, source TEXT, key TEXT,
    level TEXT, text TEXT, shown INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS messages (id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, sender TEXT, recipient TEXT,
    prio TEXT, topic TEXT, text TEXT, status TEXT DEFAULT 'new', dedupe_key TEXT, count INTEGER DEFAULT 1);
CREATE UNIQUE INDEX IF NOT EXISTS messages_dedupe ON messages(recipient, dedupe_key) WHERE dedupe_key IS NOT NULL;
CREATE TABLE IF NOT EXISTS usage (id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, scope TEXT, command TEXT,
    duration_s REAL, bytes_in INTEGER, bytes_out INTEGER, tokens INTEGER);
CREATE TABLE IF NOT EXISTS kpis (id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, game_date TEXT, name TEXT, value REAL);
"""


class Store:
    def __init__(self, path: str | Path = ":memory:"):
        self.path = str(path)
        if self.path != ":memory:":
            Path(self.path).parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(self.path, timeout=30, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        if self.path != ":memory:":
            self.db.execute("PRAGMA journal_mode=WAL")
        self.db.execute("PRAGMA busy_timeout=30000")
        self.db.executescript(SCHEMA)

    def close(self) -> None:
        self.db.close()

    # ---- KV
    def get(self, key: str, default: Any = None) -> Any:
        row = self.db.execute("SELECT value FROM kv WHERE key=?", (key,)).fetchone()
        return json.loads(row["value"]) if row else default

    def set(self, key: str, value: Any) -> None:
        self.db.execute("INSERT INTO kv(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                        (key, json.dumps(value, ensure_ascii=False, sort_keys=True)))

    def delete_prefix(self, prefix: str) -> None:
        self.db.execute("DELETE FROM kv WHERE key LIKE ?", (prefix + "%",))

    # ---- Snapshots
    def add_snapshot(self, ts: float, game_id: str | None, facts: dict) -> None:
        self.db.execute("INSERT INTO snapshots(ts, game_id, facts) VALUES(?,?,?)",
                        (ts, game_id, json.dumps(facts, ensure_ascii=False, sort_keys=True)))

    def last_snapshot(self) -> dict | None:
        row = self.db.execute("SELECT * FROM snapshots ORDER BY id DESC LIMIT 1").fetchone()
        if not row:
            return None
        return {"ts": row["ts"], "game_id": row["game_id"], "facts": json.loads(row["facts"])}

    def snapshots(self, limit: int = 1000) -> list[dict]:
        rows = self.db.execute("SELECT * FROM snapshots ORDER BY id DESC LIMIT ?", (limit,)).fetchall()
        return [{"ts": r["ts"], "game_id": r["game_id"], "facts": json.loads(r["facts"])} for r in reversed(rows)]

    # ---- actions
    def log_action(self, ts: float, source: str, rule: str, action: str, resource: str, cmd: str,
                   dry_run: bool, ok: bool, detail: str = "") -> None:
        self.db.execute("INSERT INTO actions(ts, source, rule, action, resource, cmd, dry_run, ok, detail) "
                        "VALUES(?,?,?,?,?,?,?,?,?)", (ts, source, rule, action, resource, cmd, int(dry_run), int(ok), detail))

    def count_actions(self, rule: str, action_key: str, since: float, *, include_dry: bool = False) -> int:
        q = "SELECT COUNT(*) FROM actions WHERE rule=? AND action=? AND ts>=?"
        if not include_dry:
            q += " AND dry_run=0"
        return self.db.execute(q, (rule, action_key, since)).fetchone()[0]

    def actions(self, limit: int = 50) -> list[dict]:
        rows = self.db.execute("SELECT * FROM actions ORDER BY id DESC LIMIT ?", (limit,)).fetchall()
        return [dict(r) for r in reversed(rows)]

    # ---- rule state
    def rule_state(self, rule: str) -> dict:
        row = self.db.execute("SELECT * FROM rule_state WHERE rule=?", (rule,)).fetchone()
        return dict(row) if row else {"rule": rule, "last_fire": None, "disabled": 0, "reason": None, "verify_fail": 0}

    def update_rule(self, rule: str, **fields) -> None:
        st = self.rule_state(rule)
        st.update(fields)
        self.db.execute("INSERT INTO rule_state(rule, last_fire, disabled, reason, verify_fail) VALUES(?,?,?,?,?) "
                        "ON CONFLICT(rule) DO UPDATE SET last_fire=excluded.last_fire, disabled=excluded.disabled, "
                        "reason=excluded.reason, verify_fail=excluded.verify_fail",
                        (rule, st["last_fire"], int(st["disabled"]), st["reason"], int(st["verify_fail"])))

    # ---- warnings (for the digest)
    def warn(self, ts: float, source: str, key: str, text: str, level: str = "warn") -> None:
        row = self.db.execute("SELECT id FROM warnings WHERE key=? AND shown=0", (key,)).fetchone()
        if row:
            self.db.execute("UPDATE warnings SET ts=?, text=?, level=? WHERE id=?", (ts, text, level, row["id"]))
        else:
            self.db.execute("INSERT INTO warnings(ts, source, key, level, text) VALUES(?,?,?,?,?)",
                            (ts, source, key, level, text))

    def take_warnings(self) -> list[dict]:
        rows = self.db.execute("SELECT * FROM warnings WHERE shown=0 ORDER BY id").fetchall()
        if rows:
            self.db.execute("UPDATE warnings SET shown=1 WHERE shown=0")
        return [dict(r) for r in rows]

    # ---- reset (new game)
    def reset_game_state(self) -> None:
        for t in ("snapshots", "rule_state", "warnings"):
            self.db.execute(f"DELETE FROM {t}")
        self.delete_prefix("digest.")
        self.delete_prefix("guard.")
        self.delete_prefix("autopilot.")
