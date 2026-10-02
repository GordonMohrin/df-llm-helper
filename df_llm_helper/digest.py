"""F1 digest: compact status report with delta (<= 600 tokens, 'no change' <= 30 tokens).

Pure function build_digest(...) -> (text, new state); file/DB access is done by pilot.Pilot.
"""
from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass, field

from .snapshot import Snapshot

__all__ = ["Item", "tokens", "compute_alerts", "compute_trends", "inbox_items", "build_digest", "DigestState"]


def tokens(text: str) -> int:
    """Token approximation per SPEC 7: len(text)//3."""
    return len(text) // 3


RANK = {"crit": 0, "warn": 1, "trend": 2, "inbox": 3, "info": 4}
ICON = {"crit": "!!", "warn": "!", "trend": "~", "inbox": ">", "info": "-"}


@dataclass
class Item:
    level: str
    key: str
    label: str          # short name for "still open"/"resolved"
    text: str
    sig: str            # signature: if it changes, the item is reported again
    scopes: tuple = ()

    def line(self) -> str:
        return f"{ICON[self.level]} {self.text}"


@dataclass
class DigestState:
    game_id: str | None = None
    alerts: dict = field(default_factory=dict)       # key -> {"sig":..., "label":...}
    facts: dict = field(default_factory=dict)
    inbox_seen: list = field(default_factory=list)
    ts: float | None = None

    def to_dict(self) -> dict:
        return {"game_id": self.game_id, "alerts": self.alerts, "facts": self.facts,
                "inbox_seen": self.inbox_seen[-3000:], "ts": self.ts}

    @classmethod
    def from_dict(cls, d: dict | None) -> "DigestState":
        d = d or {}
        return cls(d.get("game_id"), dict(d.get("alerts") or {}), dict(d.get("facts") or {}),
                   list(d.get("inbox_seen") or []), d.get("ts"))


def _names(cs, attr: str, limit: int = 4) -> str:
    parts = [f"{c.name or '#'}{c.id}={getattr(c, attr) // 1000}k" for c in cs[:limit]]
    if len(cs) > limit:
        parts.append(f"+{len(cs) - limit}")
    return ", ".join(parts)


def compute_alerts(snap: Snapshot, th: dict, flags: dict | None = None, prev_facts: dict | None = None,
                   cancels: list | None = None, hint=None) -> list[Item]:
    """All threshold violations/anomalies (without the delta filter)."""
    out: list[Item] = []
    add = out.append
    # supplies
    for key, val, crit, warn, label, scope in (
            ("drink_days", snap.drink_days, th["drink_days_crit"], th["drink_days_warn"], "Drinks", "trinken"),
            ("food_days", snap.food_days, th["food_days_crit"], th["food_days_warn"], "Food", "essen")):
        if val is None:
            continue
        if val < crit:
            add(Item("crit", key, label, f"{label} {val} days (<{crit})", f"c{val // 5}", (scope,)))
        elif val < warn:
            add(Item("warn", key, label, f"{label} {val} days (<{warn})", f"w{val // 10}", (scope,)))
    hungry = sorted(snap.hungry(th["hunger_crit"]), key=lambda c: -c.hunger)
    if hungry:
        add(Item("crit", "hunger", "Hunger", f"Hunger>{th['hunger_crit'] // 1000}k: {_names(hungry, 'hunger')}",
                 ",".join(str(c.id) for c in hungry), ("essen", "gesundheit")))
    thirsty = sorted(snap.thirsty(th["thirst_crit"]), key=lambda c: -c.thirst)
    if thirsty:
        add(Item("crit", "thirst", "Thirst", f"Thirst>{th['thirst_crit'] // 1000}k: {_names(thirsty, 'thirst')}",
                 ",".join(str(c.id) for c in thirsty), ("trinken", "gesundheit")))
    # danger
    a = snap.alerts
    if (a.enemies or 0) > 0 or (a.danger_alarm or 0) > 0 or a.threats:
        bits = []
        if a.enemies:
            bits.append(f"{a.enemies} enemies on map")
        if a.danger_alarm:
            bits.append(f"danger alarm {a.danger_alarm}")
        if a.threats:
            bits.append("Threat: " + "; ".join(a.threats[:2])[:80])
        add(Item("crit", "danger", "Danger", ", ".join(bits), f"{a.enemies}|{a.danger_alarm}|{len(a.threats)}",
                 ("verteidigung", "militaer")))
    if a.civ_alert:
        add(Item("warn", "civ_alert", "Civilian alert", "Civilian alert active", "1", ("verteidigung",)))
    if a.refuge_ok is False:
        add(Item("warn", "refuge", "Refuge", "Refuge burrow not ok (claude/gefahr status)", "0",
                 ("verteidigung",)))
    # deaths/population
    if prev_facts and prev_facts.get("pop") is not None and snap.pop_total is not None \
            and snap.pop_total < prev_facts["pop"]:
        d = prev_facts["pop"] - snap.pop_total
        add(Item("crit", "pop_loss", "Losses", f"Population -{d} ({prev_facts['pop']}->{snap.pop_total}): deaths?",
                 str(snap.pop_total), ("gesundheit",)))
    if (a.corpses_unburied or 0) > 0:
        add(Item("warn", "corpses", "Corpses", f"{a.corpses_unburied} dwarf corpses unburied (ghosts!)",
                 str(a.corpses_unburied), ("gesundheit",)))
    # moods
    if a.moods_active:
        gaps = ("; gaps: " + ", ".join(snap.stocks.mood_gaps[:4])) if snap.stocks.mood_gaps else ""
        add(Item("crit", "mood", "Mood", f"Mood active: {', '.join(map(str, a.moods_active))[:60]}{gaps}",
                 "|".join(map(str, a.moods_active)), ("gesundheit",)))
    ip = snap.idle_pct
    if ip is not None and ip >= th.get("idle_pct_warn", 40):
        add(Item("warn", "idle_high", "Idle", f"Idle {ip:.0f}% ({snap.idle} of {snap.adults} adults)",
                 str(int(ip // 10)), ("auslastung", "wirtschaft")))
    if (a.stress_high or 0) >= th.get("stress_high_warn", 1):
        add(Item("warn", "stress", "Stress", f"{a.stress_high} dwarves with high stress", str(a.stress_high),
                 ("gesundheit",)))
    # caravan
    for c in a.caravans:
        if c.state in ("Left", "Leaving", ""):
            continue
        tr = f", {c.time_remaining} ticks" if c.time_remaining is not None else ""
        add(Item("warn", f"caravan:{c.name}", "Caravan", f"Caravan {c.name}: {c.state}{tr} (prepare trade)",
                 c.state, ("handel",)))
    # guard flags
    for name, fi in sorted((flags or {}).items()):
        if not fi.exists:
            continue
        age = f"{int(fi.age_min)} min" if fi.age_min is not None else "?"
        txt = re.sub(r"\s+", " ", fi.text)[:60]
        lvl = "crit" if name in ("alert", "siege") else "warn"
        add(Item(lvl, f"flag:{name}", f"{name} flag", f"{name}.flag open ({age}): {txt}".rstrip(": "),
                 fi.text[:40], ("orchestrator",)))
    # cancel loops (gamelog)
    for c in cancels or []:
        h = hint(c) if hint else ""
        add(Item("warn", f"cancel:{c.job}:{c.reason}"[:80], "Cancel loop",
                 f"Cancel loop {c.job}: {c.reason} {c.count}x ({c.who} dwarves){(' -> ' + h) if h else ''}",
                 str(len(str(c.count))), ("wirtschaft", "auslastung")))
    core_failed = [f for f in snap.failed if f.startswith(("claude/status", "claude/report"))]
    if core_failed:
        add(Item("crit", "fetch", "Query", f"Query failed: {core_failed[0][:80]} (check DF/dfhack-run)",
                 str(len(core_failed)), ("infra",)))
    if snap.errors:
        add(Item("warn", "parse", "Parser", f"Parser: {len(snap.errors)} problem(s): {snap.errors[0][:70]}",
                 str(len(snap.errors)), ("infra",)))
    return out


def compute_trends(f: dict, prev: dict, th: dict) -> list[Item]:
    if not prev:
        return []
    out: list[Item] = []

    def num(k):
        return f.get(k), prev.get(k)

    cur, old = num("pop")
    if cur is not None and old is not None and cur > old:
        out.append(Item("trend", "pop_up", "Population", f"Population +{cur - old} ({old}->{cur})", str(cur)))
    cur, old = num("idle_pct")
    if cur is not None and old is not None and abs(cur - old) >= th["idle_pct_delta"]:
        out.append(Item("trend", "idle", "Idle", f"Idle {old:.0f}%->{cur:.0f}% ({f.get('idle')} dwarves)", f"{cur:.0f}",
                        ("auslastung",)))
    cur, old = num("jobs_open")
    if cur is not None and old:
        if abs(cur - old) * 100 >= th["jobs_open_delta_pct"] * old:
            out.append(Item("trend", "jobs", "Jobs", f"Open jobs {old}->{cur}", str(cur), ("auslastung",)))
    cur, old = num("dig_jobs")
    if cur is not None and old is not None and abs(cur - old) >= th["dig_jobs_delta"]:
        out.append(Item("trend", "dig", "Dig jobs", f"Dig jobs {old}->{cur} (diggers: {f.get('diggers')})", str(cur),
                        ("bau", "erkundung")))
    for k, label in (("drink_days", "Drink days"), ("food_days", "Food days")):
        cur, old = num(k)
        if cur is not None and old is not None and old - cur >= 15:
            out.append(Item("trend", f"{k}_fall", label, f"{label} falling {old}->{cur}", str(cur // 5),
                            ("trinken" if k == "drink_days" else "essen",)))
    cur, old = num("squad_members")
    if cur is not None and old is not None and cur != old:
        out.append(Item("trend", "squad", "Squad", f"Soldiers {old}->{cur}", str(cur), ("militaer",)))
    return out


_INBOX = re.compile(r"^- (?:von|from) ([^,]+),\s*(.*?):\s+(.*)$")


def _norm(s: str) -> str:
    return re.sub(r"[^a-z0-9äöüß]+", " ", s.lower()).strip()


def inbox_items(lines: list[str], seen: set, max_lines: int, width: int) -> tuple[list[Item], list[str], int]:
    """New inbox lines (deduplicated, truncated). Returns: items, new hashes, number omitted."""
    items: list[Item] = []
    new_hashes: list[str] = []
    seen_text: set = set()
    skipped = 0
    fresh: list[tuple[str, str]] = []
    for ln in lines:
        h = hashlib.sha1(ln.encode("utf-8")).hexdigest()[:12]
        if h in seen or h in new_hashes:
            continue
        new_hashes.append(h)
        fresh.append((h, ln))
    for h, ln in reversed(fresh):  # newest first
        m = _INBOX.match(ln)
        if m:
            who, when, text = m.group(1).strip(), m.group(2), m.group(3)
            t = re.search(r"\b(\d{1,2}:\d{2})\b", when)
            head = f"{who} {t.group(1) if t else ''}".strip()
        else:
            head, text = "", ln[2:]
        text = re.sub(r"\*\*|`", "", text)
        dk = _norm(text)[:60]
        if dk in seen_text:
            continue
        seen_text.add(dk)
        if len(items) >= max_lines:
            skipped += 1
            continue
        body = f"{head}: {text}" if head else text
        if len(body) > width:
            body = body[:width - 1].rstrip() + "…"
        items.append(Item("inbox", f"inbox:{h}", "Inbox", body, h))
    return items, new_hashes, skipped


def status_line(snap: Snapshot) -> str:
    f = snap.facts()
    parts = [f"Status {snap.date.text() if snap.date else (f['date'] or '?')}"]
    if f["pop"] is not None:
        ip = f" ({f['idle']} idle {f['idle_pct']:.0f}%)" if f["idle"] is not None and f["idle_pct"] is not None else ""
        parts.append(f"Pop {f['pop']}{ip}")
    if f["drink_days"] is not None or f["food_days"] is not None:
        parts.append(f"Drinks {f['drink_days']}d Food {f['food_days']}d")
    if f["jobs_open"] is not None:
        parts.append(f"Jobs {f['jobs_open']} (dig {f['dig_jobs']}, {f['diggers']} digging)")
    if f["fps"] is not None:
        parts.append(f"fps {f['fps']:.0f}" + (" TS" if f["timestream"] else ""))
    if f["paused"]:
        parts.append("PAUSE")
    return " | ".join(parts)


def build_digest(snap: Snapshot, state: DigestState, *, th: dict, max_tokens: int = 600,
                 flags: dict | None = None, inbox: list[str] | None = None, warnings: list[dict] | None = None,
                 scope: str | None = None, now_hhmm: str = "", inbox_max: int = 6, inbox_width: int = 110,
                 since_last: bool = True, cancels: list | None = None, hint=None) -> tuple[str, DigestState]:
    new_game = state.game_id is not None and snap.game_id is not None and snap.game_id != state.game_id
    if new_game:
        state = DigestState()
    prev_facts = state.facts if since_last else {}
    alerts = compute_alerts(snap, th, flags, prev_facts, cancels, hint)
    facts = snap.facts()
    trends = compute_trends(facts, prev_facts, th)
    for w in warnings or []:
        lvl = w.get("level") if w.get("level") in ("crit", "warn") else "warn"
        alerts.append(Item(lvl, f"w:{w.get('key')}", w.get("source", "df-llm-helper"), f"[{w.get('source')}] {w.get('text')}",
                           f"{w.get('ts')}", ("orchestrator",)))
    if scope and scope != "orchestrator":
        alerts = [a for a in alerts if scope in a.scopes]
        trends = [t for t in trends if scope in t.scopes]
    seen = set(state.inbox_seen)
    ib, new_hashes, skipped = inbox_items(inbox or [], seen, inbox_max, inbox_width)

    prev_alerts = state.alerts if since_last else {}
    fresh = [a for a in alerts if a.key not in prev_alerts or prev_alerts[a.key].get("sig") != a.sig]
    still = [a for a in alerts if a not in fresh]
    resolved = [v.get("label", k) for k, v in sorted(prev_alerts.items()) if k not in {a.key for a in alerts}
                and not k.startswith("w:")]

    fresh.sort(key=lambda i: (RANK[i.level], i.key))
    trends.sort(key=lambda i: i.key)
    header = []
    if new_game:
        header.append(f"NEW GAME detected ({snap.fort}): counters/caches reset.")

    if not (fresh or trends or ib or resolved or new_game):
        open_labels = sorted({a.label for a in still})
        txt = f"No change since {now_hhmm or 'last check'}"
        if open_labels:
            txt += f" ({len(open_labels)} open: {', '.join(open_labels)[:40]})"
        text = txt + "."
    else:
        lines = header + [status_line(snap)]
        body = [i.line() for i in fresh if i.level == "crit"]  # critical: always
        optional = [i.line() for i in fresh if i.level != "crit"] + [t.line() for t in trends]
        if resolved:
            optional.append("ok resolved: " + ", ".join(sorted(set(resolved)))[:100])
        if still:
            optional.append("still open: " + ", ".join(sorted({a.label for a in still}))[:100])
        optional += [i.line() for i in ib]
        if skipped:
            optional.append(f"> +{skipped} more inbox lines (python -m df_llm_helper bus read)")
        lines += body
        dropped = 0
        for ln in optional:
            if tokens("\n".join(lines + [ln])) + 8 <= max_tokens:
                lines.append(ln)
            else:
                dropped += 1
        if dropped:
            lines.append(f"(+{dropped} truncated)")
        text = "\n".join(lines)
        if tokens(text) > max_tokens:   # only possible with an extreme number of critical items: hard truncate, with a note
            text = text[:max_tokens * 3 - 20].rstrip() + "\n(truncated)"

    new_state = DigestState(game_id=snap.game_id or state.game_id,
                            alerts={a.key: {"sig": a.sig, "label": a.label, "level": a.level, "text": a.text}
                                    for a in alerts if not a.key.startswith("w:")},   # level/text: dashboard (Spec 11)
                            facts=facts, inbox_seen=list(state.inbox_seen) + new_hashes, ts=state.ts)
    return text, new_state
