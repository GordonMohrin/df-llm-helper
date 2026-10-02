"""F7 event bus instead of inbox markdown: SQLite table messages (store), dedupe, priorities, import/export.

post(): same dedupe_key (per recipient, not done) -> one message, counter +1.
read(): only unread ones of the recipient, crit first, truncated; marks them as read.
ack():  marks done (all of a recipient's, too).
"""
from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from pathlib import Path

__all__ = ["Message", "Bus", "PRIO", "guess_prio", "parse_inbox_line"]

PRIO = {"crit": 0, "warn": 1, "info": 2}
_CRIT = re.compile(r"KRITISCH|CRITICAL|\bROT\b|\bRED\b|sofort|immediately|urgent|dringend|!!|Tote?\b|\bdead\b|stirbt|dies\b|verhungert|starves|verdurstet|dies of thirst|Belagerung|siege", re.I)
_WARN = re.compile(r"WICHTIG|IMPORTANT|Engpass|bottleneck|Entscheidung|decision|blockiert|blocked|fehlt|missing|knapp|scarce|< ?50 ?%|player", re.I)
_LINE = re.compile(r"^- (?:von|from) ([^,]+),\s*(.*?):\s+(.*)$")


def guess_prio(text: str) -> str:
    if _CRIT.search(text):
        return "crit"
    if _WARN.search(text):
        return "warn"
    return "info"


def parse_inbox_line(line: str) -> tuple[str, str, str] | None:
    """'- from bau, 01.10. 09:25 (Y100 Opal 12): text' -> (bau, '01.10. 09:25 (J100 Opal 12)', Text)."""
    m = _LINE.match(line.strip())
    if not m:
        return None
    return m.group(1).strip(), m.group(2).strip(), m.group(3).strip()


@dataclass
class Message:
    id: int
    ts: float
    sender: str
    recipient: str
    prio: str
    topic: str
    text: str
    status: str
    count: int

    def line(self, width: int = 160) -> str:
        cnt = f" (x{self.count})" if self.count > 1 else ""
        t = re.sub(r"\s+", " ", self.text)
        if len(t) > width:
            t = t[: width - 1] + "…"
        mark = {"crit": "!!", "warn": "!", "info": "-"}[self.prio if self.prio in PRIO else "info"]
        return f"{mark} #{self.id} {self.sender}{(' [' + self.topic + ']') if self.topic else ''}{cnt}: {t}"


class Bus:
    def __init__(self, store, clock):
        self.store = store
        self.db = store.db
        self.clock = clock

    def post(self, sender: str, recipient: str, text: str, *, prio: str | None = None, topic: str = "",
             dedupe_key: str | None = None, ts: float | None = None) -> int:
        prio = prio or guess_prio(text)
        if prio not in PRIO:
            raise ValueError(f"prio must be one of {sorted(PRIO)}")
        ts = self.clock.now().epoch if ts is None else ts
        self.db.execute("BEGIN IMMEDIATE")
        try:
            row = None
            if dedupe_key:
                row = self.db.execute("SELECT id, status, prio FROM messages WHERE recipient=? AND dedupe_key=?",
                                      (recipient, dedupe_key)).fetchone()
            if row and row["status"] != "done":
                keep = min(prio, row["prio"], key=lambda p: PRIO.get(p, 9))   # the higher priority stays
                self.db.execute("UPDATE messages SET count=count+1, ts=?, text=?, status='new', prio=? WHERE id=?",
                                (ts, text, keep, row["id"]))
                mid = row["id"]
            else:
                if row:   # done -> release the old key, new message
                    self.db.execute("UPDATE messages SET dedupe_key=NULL WHERE id=?", (row["id"],))
                cur = self.db.execute("INSERT INTO messages(ts, sender, recipient, prio, topic, text, status, dedupe_key)"
                                      " VALUES(?,?,?,?,?,?, 'new', ?)", (ts, sender, recipient, prio, topic, text,
                                                                         dedupe_key))
                mid = cur.lastrowid
            self.db.execute("COMMIT")
        except Exception:
            self.db.execute("ROLLBACK")
            raise
        return mid

    def _rows(self, where: str, args: tuple) -> list[Message]:
        rows = self.db.execute(f"SELECT * FROM messages WHERE {where}", args).fetchall()
        msgs = [Message(r["id"], r["ts"], r["sender"], r["recipient"], r["prio"], r["topic"] or "", r["text"],
                        r["status"], r["count"]) for r in rows]
        msgs.sort(key=lambda m: (PRIO.get(m.prio, 9), m.ts, m.id))
        return msgs

    def read(self, recipient: str, *, limit: int = 20, mark: bool = True) -> list[Message]:
        msgs = self._rows("recipient=? AND status='new'", (recipient,))[:limit]
        if mark and msgs:
            self.db.execute(f"UPDATE messages SET status='read' WHERE id IN ({','.join('?' * len(msgs))})",
                            tuple(m.id for m in msgs))
        return msgs

    def pending(self, recipient: str) -> list[Message]:
        return self._rows("recipient=? AND status!='done'", (recipient,))

    def ack(self, recipient: str, ids: list[int] | None = None) -> int:
        if ids:
            cur = self.db.execute(f"UPDATE messages SET status='done' WHERE recipient=? AND id IN "
                                  f"({','.join('?' * len(ids))})", (recipient, *ids))
        else:
            cur = self.db.execute("UPDATE messages SET status='done' WHERE recipient=? AND status!='done'", (recipient,))
        return cur.rowcount

    def count(self, recipient: str | None = None) -> int:
        if recipient:
            return self.db.execute("SELECT COUNT(*) FROM messages WHERE recipient=?", (recipient,)).fetchone()[0]
        return self.db.execute("SELECT COUNT(*) FROM messages").fetchone()[0]

    # ---- backwards compatibility: markdown inboxes
    def import_inbox(self, path: Path, recipient: str | None = None) -> tuple[int, int]:
        """Reads all '- von/from ...' lines; returns (new, skipped). Idempotent via dedupe_key=hash."""
        from .toolsfs import read_text_tolerant
        recipient = recipient or Path(path).stem.removeprefix("inbox-")
        new = skipped = 0
        for line in read_text_tolerant(Path(path)).splitlines():
            if not line.startswith("- "):
                continue
            p = parse_inbox_line(line)
            sender, when, text = p if p else ("?", "", line[2:].strip())
            key = "md:" + hashlib.sha1(line.strip().encode("utf-8")).hexdigest()[:16]
            exists = self.db.execute("SELECT 1 FROM messages WHERE recipient=? AND dedupe_key=?",
                                     (recipient, key)).fetchone()
            if exists:
                skipped += 1
                continue
            self.post(sender, recipient, text, topic=when[:40], dedupe_key=key)
            new += 1
        return new, skipped

    def export_line(self, msg: Message) -> str:
        return f"- from {msg.sender}, {msg.topic or self.clock.now().local().strftime('%d.%m. %H:%M')}: {msg.text}"

    def export_to_inbox(self, path: Path, msg: Message) -> None:
        with Path(path).open("a", encoding="utf-8") as f:
            f.write(self.export_line(msg) + "\n")
