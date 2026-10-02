"""Spec 12: chronicle and lessons writer (`python -m df_llm_helper journal`).

- ingest:     tools/events.log (watcher) + critical df-llm-helper warnings -> table 'events' in state.db
              (type, real time, game date from the nearest snapshot, participants, outcome), deduplicated
- chronik:    concise draft (date + fact), events per type summarized in 30-minute clusters;
              only with --append is it appended to the configured chronik.md
- lessons:    recurring causes (>= suggest_after_repeats) -> exactly one proposal per pattern (kv dedupe);
              memory/KB only after approval by the orchestrator (`--accept`, writes only data/kb/journal.jsonl)
- metrics:    metrics.csv-compatible, one line per game month
- postmortem: skeleton from state.db (timeline, causes of death, decisions, open items, key figures, exceptions)
Writes only to state.db and to the configured files (acceptance 5).
"""
from __future__ import annotations

import hashlib
import json
import re
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from pathlib import Path

__all__ = ["DEFAULTS", "NOISE", "TYPE_OF", "parse_events_log", "infer_first_day", "count_log_lines", "Journal", "is_chronicle_event", "classify_tag",
           "fix_mojibake"]

DEFAULTS = {"chronik": "../chronik.md", "metrics": "../metrics.csv", "append": False, "suggest_after_repeats": 2,
            "cluster_min": 30, "events_log": None, "kb_out": "data/kb/journal.jsonl"}
# combat/everyday noise (like wake.NOISE_TAGS) - does not count as a chronicle event
NOISE = re.compile(r"COMBAT_|LOSE_HOLD_OF_ITEM|FALL_OVER|PAIN_KO|CONFLICT_CONVERSATION|CANCEL_JOB|EXHAUSTION|"
                   r"PET_DEATH|BREAK_GRIP|LOSE_HOLD|STAND_UP|GRAB|RESOLVE_SHARED_ITEMS|VOMIT|MASTERPIECE|"
                   r"NOT_STUNNED|REGAIN_CONSCIOUSNESS|UNIT_PROJECTILE_SLAM|LOSE_EMOTION|BIRTH_(?:WILD_)?ANIMAL|"
                   r"DODGE|QUOTA_FILLED")


def _tok(alts: str) -> str:
    """Whole words of a tag (CITIZEN_DEATH, BUILDING_DESTROYED_OR_TOPPLED): FLOOD must not match FLOODGATE (BUG-310)."""
    return rf"(?:^|_)(?:{alts})(?:_|$)"


TYPE_OF = [  # (pattern on the tag only, type); first match wins
    (_tok("NAMED_ARTIFACT|FEATURE_DISCOVERY|DISCOVERY"), "Info"),
    (_tok("DEATH"), "Death"),
    (_tok("MEGABEAST|AMBUSH|SIEGE|INVADERS?|THIEF|SNATCHER|BEAST|NIGHT_CREATURE|TITAN|CAVE_DRAGON|ATTACK"), "Attack"),
    (_tok("ARTIFACT|MOOD|BERSERK|INSANE|MELANCHOLY"), "Mood"),
    (_tok("CARAVANS?|MERCHANTS?|LIAISON|DIPLOMAT"), "Caravan"),
    (_tok("BUILDING_DESTROYED|COLLAPSE|FLOOD|FLOODING|FIRE|NOTFALL|EMERGENCY"), "Emergency"),
    (_tok("MIGRANTS?|BIRTH|PEAK"), "Population"),
]
DEATH_CAUSE = re.compile(r"\b(dehydrated|starved|drowned|suffocated|struck down|burned|bled|crushed|fell|frozen|"
                         r"died of \w+)\b", re.I)
_LINE = re.compile(r"^\ufeff?(?P<lvl>\w+)\s+(?P<t>\d\d:\d\d:\d\d)\s+\[(?P<tag>[A-Z_0-9]+)\]\s*(?P<txt>.*)$")
_NAME = re.compile(r"^(?P<name>[^,]+), (?P<prof>.+?) (?P<rest>(?:has|was|is) .+?)\.?$")


def fix_mojibake(line: str) -> str:
    """The watcher log (PowerShell) contains UTF-8 read as CP437 ('Catten ├┤tthat' -> 'Catten ôtthat')."""
    if not any(ch in line for ch in "├┬┼╗║"):
        return line
    try:
        return line.encode("cp437").decode("utf-8")
    except (UnicodeEncodeError, UnicodeDecodeError):
        return line


def _is_crit(level: str) -> bool:
    """The watcher writes KRITISCH (legacy logs) or CRITICAL."""
    return level.upper().startswith(("KRIT", "CRIT"))


def classify_tag(tag: str, level: str = "KRITISCH") -> str:
    for pat, typ in TYPE_OF:
        if re.search(pat, tag):
            return typ
    return "Emergency" if _is_crit(level) else "Other"


def is_chronicle_event(level: str, tag: str) -> bool:
    """CRITICAL (KRITISCH) without noise + important info events (caravan, mood, population)."""
    if NOISE.search(tag):
        return False
    if _is_crit(level):
        return True
    return classify_tag(tag, level) in ("Caravan", "Mood", "Population", "Attack", "Death")


def parse_events_log(text: str, day0: date) -> list[dict]:
    """Lines 'LEVEL HH:MM:SS [TAG] text'; time of day jumps back -> next day."""
    out, day, prev = [], day0, None
    for ln in text.splitlines():
        m = _LINE.match(fix_mojibake(ln.strip()))
        if not m:
            continue
        t = datetime.strptime(m.group("t"), "%H:%M:%S").time()
        if prev is not None and (datetime.combine(day0, t) < datetime.combine(day0, prev) - timedelta(hours=1)):
            day = day + timedelta(days=1)
        prev = t
        out.append({"ts": datetime.combine(day, t).timestamp(), "level": m.group("lvl"), "tag": m.group("tag"),
                    "text": m.group("txt").strip()})
    return out


def count_log_lines(text: str) -> tuple[int, int]:
    """(non-empty lines, lines in the watcher format) - 0 recognised = wrong file or encoding (BUG-330)."""
    lines = [ln for ln in text.splitlines() if ln.strip()]
    return len(lines), sum(1 for ln in lines if _LINE.match(fix_mojibake(ln.strip())))


def infer_first_day(text: str, last_day: date) -> date:
    """The watcher log only has times of day. The last line belongs to `last_day` (log file mtime); every jump back in
    the time of day (> 1 h) before it is a day change -> the first line lies that many days earlier."""
    prev, jumps = None, 0
    for ln in text.splitlines():
        m = _LINE.match(fix_mojibake(ln.strip()))
        if not m:
            continue
        t = datetime.strptime(m.group("t"), "%H:%M:%S").time()
        if prev is not None and (datetime.combine(last_day, t) < datetime.combine(last_day, prev) - timedelta(hours=1)):
            jumps += 1
        prev = t
    return last_day - timedelta(days=jumps)


@dataclass
class Lesson:
    key: str
    count: int
    text: str


SCHEMA = """CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, game_date TEXT, typ TEXT,
tag TEXT, text TEXT, who TEXT, outcome TEXT, cause TEXT, source TEXT, h TEXT UNIQUE)"""


class Journal:
    def __init__(self, store, cfg: dict | None = None, home: Path | None = None, registry=None):
        self.store = store
        self.cfg = {**DEFAULTS, **(cfg or {})}
        self.home = Path(home) if home else Path(".")
        self.registry = registry
        self.store.db.execute(SCHEMA)

    # ------------------------------------------------------------------ events
    def _game_date(self, ts: float, max_gap_s: float = 1800.0) -> str | None:
        """Game date of the nearest snapshot - only if it was taken within max_gap_s of the event (otherwise the date
        of an old event would show today's game date)."""
        r = self.store.db.execute("SELECT ts, facts FROM snapshots ORDER BY ABS(ts - ?) LIMIT 1", (ts,)).fetchone()
        if not r or abs(r["ts"] - ts) > max_gap_s:
            return None
        return json.loads(r["facts"]).get("date")

    def add(self, ts: float, typ: str, tag: str, text: str, *, who: str = "", outcome: str = "", cause: str = "",
            source: str = "") -> bool:
        h = hashlib.sha1(f"{ts:.0f}|{tag}|{text}".encode()).hexdigest()[:16]
        cur = self.store.db.execute("INSERT OR IGNORE INTO events(ts, game_date, typ, tag, text, who, outcome, cause, "
                                    "source, h) VALUES(?,?,?,?,?,?,?,?,?,?)",
                                    (ts, self._game_date(ts), typ, tag, text, who, outcome, cause, source, h))
        return cur.rowcount > 0

    def ingest_log(self, text: str, day0: date) -> tuple[int, int]:
        """-> (newly ingested, chronicle events in the log)."""
        new = total = 0
        for e in parse_events_log(text, day0):
            if not is_chronicle_event(e["level"], e["tag"]):
                continue
            total += 1
            typ = classify_tag(e["tag"], e["level"])
            who, outcome = "", ""
            if typ == "Death":
                m = _NAME.match(e["text"])
                if m:
                    who, outcome = m.group("name").strip(), m.group("rest").strip()
            new += self.add(e["ts"], typ, e["tag"], e["text"], who=who, outcome=outcome, source="events.log")
        return new, total

    def ingest_warnings(self) -> int:
        """Take over critical df-llm-helper warnings (spec 01..11) as events."""
        typ = {"siege": "Attack", "mood": "Mood", "water": "Emergency", "care": "Emergency", "caravan": "Caravan",
               "reboot": "Emergency", "forecast": "Emergency", "bottleneck": "Emergency"}
        n = 0
        for r in self.store.db.execute("SELECT ts, source, key, text FROM warnings WHERE level = 'crit' ORDER BY id"):
            t = typ.get(r["source"], "Emergency")
            cause, outcome = "", ""
            if r["source"] == "mood" and ("FAILED" in r["text"] or "GESCHEITERT" in r["text"]):
                outcome = "failed"
                m = re.search(r"(?:gaps|Luecken): ([^;)]+)", r["text"])
                cause = (m.group(1).split()[0] if m else "unknown").lower()
            n += self.add(r["ts"], t, f"HELPER_{str(r['source']).upper()}", r["text"], outcome=outcome, cause=cause,
                          source="df-llm-helper")
        return n

    def events(self) -> list[dict]:
        return [dict(r) for r in self.store.db.execute("SELECT * FROM events ORDER BY ts, id")]

    # ------------------------------------------------------------------ chronicle
    def clusters(self) -> list[dict]:
        """Summarize events per type into clusters (gap < cluster_min)."""
        gap = float(self.cfg["cluster_min"]) * 60
        out: list[dict] = []
        open_by: dict = {}
        for e in self.events():
            c = open_by.get(e["typ"])
            if c and e["ts"] - c["end"] <= gap:
                c["items"].append(e)
                c["end"] = e["ts"]
            else:
                c = {"typ": e["typ"], "start": e["ts"], "end": e["ts"], "items": [e]}
                open_by[e["typ"]] = c
                out.append(c)
        out.sort(key=lambda c: (c["start"], c["typ"]))
        return out

    @staticmethod
    def _summary(c: dict) -> str:
        it = c["items"]
        if c["typ"] == "Death":
            names = [e["who"] or e["text"].split(",")[0] for e in it]
            causes = Counter(e["outcome"] or "?" for e in it)
            return (f"{len(it)} deaths: " + ", ".join(names[:5]) + (f" +{len(names) - 5}" if len(names) > 5 else "")
                    + " (" + ", ".join(f"{k} {v}x" for k, v in causes.most_common(2)) + ")")
        texts = list(dict.fromkeys(re.sub(r"\s+", " ", e["text"]).replace("[B]", " ")[:90] for e in it))
        more = f" (+{len(texts) - 2} more)" if len(texts) > 2 else ""
        return "; ".join(texts[:2]) + more

    def chronik(self) -> list[str]:
        lines = []
        for c in self.clusters():
            dt = datetime.fromtimestamp(c["start"])
            gd = c["items"][0].get("game_date")
            ln = f"- {dt:%m-%d %H:%M}" + (f" ({gd})" if gd else "") + f" {c['typ']}: {self._summary(c)}"
            lines.append(ln if len(ln) <= 200 else ln[:197] + "...")
        return lines

    def coverage(self) -> float:
        """Share of events contained in a chronicle line (acceptance 1)."""
        evs = self.events()
        covered = sum(len(c["items"]) for c in self.clusters())
        return covered / len(evs) if evs else 1.0

    def append_chronik(self, lines: list[str]) -> tuple[Path, int]:
        """Appends only lines that are not in the file yet (BUG-309: a retry must not duplicate the chronicle)."""
        from .toolsfs import read_text_tolerant
        p = (self.home / self.cfg["chronik"]).resolve()
        have = {ln.strip() for ln in read_text_tolerant(p).splitlines()} if p.is_file() else set()
        new = [ln for ln in dict.fromkeys(lines) if ln.strip() not in have]
        if new:
            with p.open("a", encoding="utf-8", newline="\n") as f:
                f.write("\n" + "\n".join(new) + "\n")
        return p, len(new)

    # ------------------------------------------------------------------ lessons
    def lessons(self) -> list[Lesson]:
        """Same cause >= suggest_after_repeats -> exactly one proposal per pattern (not ones already proposed)."""
        cnt: Counter = Counter()
        for e in self.events():
            outcome, cause = e["outcome"], e["cause"]
            if e["typ"] == "Death" and outcome and not cause:
                m = DEATH_CAUSE.search(outcome)
                if m:
                    outcome, cause = "died", m.group(1).lower().replace(" ", "_")
                    if cause in ("struck_down", "bled", "crushed", "fell"):
                        cause = "combat"
            if outcome and cause:
                cnt[f"{e['typ']} {outcome} | {cause}"] += 1
        done = set(self.store.get("journal.lessons") or [])
        out = []
        for key, n in sorted(cnt.items()):
            if n >= int(self.cfg["suggest_after_repeats"]) and key not in done:
                typ, cause = key.split(" | ")
                out.append(Lesson(key, n, f"{n}x {typ} (cause {cause}): raise reserve/precaution for '{cause}', "
                                          f"check the rule in the scope"))
        return out

    def mark_suggested(self, lessons: list[Lesson]) -> None:
        self.store.set("journal.lessons", sorted(set(self.store.get("journal.lessons") or []) |
                                                 {x.key for x in lessons}))

    def accept(self, lesson: Lesson) -> Path:
        """Approved lesson as a KB draft (status unreviewed) in data/kb/journal.jsonl."""
        p = self.home / self.cfg["kb_out"]
        p.parent.mkdir(parents=True, exist_ok=True)
        slug = re.sub(r"[^a-z0-9]+", "_", lesson.key.lower()).strip("_")[:50]
        entry = {"id": f"journal.{slug}", "title": lesson.key, "body": lesson.text, "status": "unreviewed",
                 "quelle": "python -m df_llm_helper journal", "symptom_keywords": [w for w in re.findall(r"\w+", lesson.key.lower())
                                                                      if len(w) > 3][:6]}
        with p.open("a", encoding="utf-8") as f:
            f.write(json.dumps(entry, ensure_ascii=False, sort_keys=True) + "\n")
        return p

    # ------------------------------------------------------------------ metrics
    def monthly_metrics(self) -> str:
        """metrics.csv format (same header), latest measurement per game month."""
        from .metrics import METRICS_HEADER, export_csv
        text = export_csv(self.store)
        rows = text.splitlines()
        header, body = rows[0], rows[1:]
        idx = METRICS_HEADER.index("spieldatum")
        by_month: dict = {}
        for r in body:
            gd = r.split(";")[idx]
            m = re.search(r"([A-Za-z]+), (?:Jahr|Year) (\d+)", gd) or re.search(r"J(\d+)\s+([A-Za-z]+)", gd)
            key = (m.group(0) if m else gd)
            by_month[key] = r                        # the latest measurement of the month wins
        return "\n".join([header] + list(by_month.values())) + "\n"

    # ------------------------------------------------------------------ postmortem
    def postmortem(self, fort: str = "") -> str:
        evs = self.events()
        deaths = [e for e in evs if e["typ"] == "Death"]
        snaps = [dict(r) for r in self.store.db.execute("SELECT ts, facts FROM snapshots ORDER BY id")]
        first = json.loads(snaps[0]["facts"]) if snaps else {}
        last = json.loads(snaps[-1]["facts"]) if snaps else {}
        out = [f"# POSTMORTEM {fort or last.get('fort') or ''}".rstrip(), "",
               "Skeleton from state.db (python -m df_llm_helper journal postmortem). Measured data only; add the assessment by hand.", "",
               "## Timeline"]
        out += self.chronik() or ["- (no events in state.db)"]
        out += ["", "## Causes of death"]
        if deaths:
            for cause, n in Counter(e["outcome"] or "unknown" for e in deaths).most_common():
                out.append(f"- {cause}: {n}")
        else:
            out.append("- no deaths in the event log")
        out += ["", "## Decisions with outcome (action log)"]
        acts = Counter()
        fails = Counter()
        for r in self.store.db.execute("SELECT source, action, ok FROM actions WHERE dry_run = 0"):
            acts[(r["source"], r["action"])] += 1
            fails[(r["source"], r["action"])] += 0 if r["ok"] else 1
        out += [f"- {s}/{a}: {n}x" + (f", {fails[(s, a)]} failed" if fails[(s, a)] else "")
                for (s, a), n in acts.most_common(15)] or ["- no actions logged"]
        out += ["", "## Open items (critical warnings of the last 24 h)"]
        now = snaps[-1]["ts"] if snaps else 0
        crit = [dict(r) for r in self.store.db.execute(
            "SELECT text FROM warnings WHERE level = 'crit' AND ts >= ? ORDER BY id DESC LIMIT 10", (now - 86400,))]
        out += [f"- {c['text'][:140]}" for c in crit] or ["- none"]
        out += ["", "## Key figures (first -> last snapshot)"]
        for k in ("date", "pop", "idle_pct", "food_days", "drink_days", "jobs_open", "squad_members", "wealth"):
            if first.get(k) is not None or last.get(k) is not None:
                out.append(f"- {k}: {first.get(k)} -> {last.get(k)}")
        out += ["", "## Fair-play exceptions (register)"]
        if self.registry is not None and self.registry.entries:
            for x in self.registry.entries:
                yes = getattr(x, "player_consent", "")
                out.append(f"- {x.action} {x.ts}: {x.reason}; objects {x.objects or '-'}; the player: \"{yes}\"")
        else:
            out.append("- no entries")
        out += ["", "## References", "- chronik.md, metrics.csv, ERFAHRUNGEN.md; KB: python -m df_llm_helper kb search \"<topic>\""]
        return "\n".join(out) + "\n"
