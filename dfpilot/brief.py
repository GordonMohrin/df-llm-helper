"""F5 briefing generator: one package <= budget tokens for a scope agent.

Parts (by priority): mission, situation in numbers (KPIs), fair-play block, report format (mandatory),
then open tasks/insights from the memory, situation alerts (digest items of the scope), new inbox lines,
known traps (KB), commands. Deterministic; no duplicates (shingle overlap).
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

from . import yamlmini
from .digest import compute_alerts, tokens
from .expr import ExprError, evaluate
from .kb import KB
from .memory import compact_text, extract_for_brief, shorten

__all__ = ["BriefError", "FAIRPLAY_BLOCK", "REPORT_FORMAT", "load_scopes", "build_brief", "shingles", "SCOPES"]

SCOPES = ["trinken", "essen", "bau", "erkundung", "wirtschaft", "auslastung", "material", "militaer",
          "verteidigung", "gesundheit", "handel", "infra"]

FAIRPLAY_BLOCK = ("Fair play: player actions only (dig/build/zones/stockpiles/orders/squads/offices/trade, quickfort "
                  "own grids). Forbidden: createitem, dig-now, build-now, reveal, prospect all, direct unit/item "
                  "edits. Exceptions only with the player's yes.")
REPORT_FORMAT = ("Report <= 10 lines: 1) KPIs before->after 2) done (command -> effect) 3) blocked/needs "
                 "4) messages to scopes (dfpilot bus post) 5) next pass. Update the memory.")
REQUIRED = ("mission", "kpis", "commands", "kb_query")


class BriefError(ValueError):
    pass


def load_scopes(path: Path) -> dict:
    data = yamlmini.load_file(path) or {}
    if not isinstance(data, dict):
        raise BriefError(f"{path}: must be a mapping scope -> definition")
    return data


def shingles(text: str, n: int = 5) -> set:
    w = re.findall(r"\w+", text.lower())
    return {" ".join(w[i:i + n]) for i in range(max(0, len(w) - n + 1))}


@dataclass
class _Section:
    title: str
    lines: list
    required: bool = False
    prio: int = 5


def _fmt(v) -> str:
    if v is None:
        return "?"
    if isinstance(v, float):
        return f"{v:.0f}" if v.is_integer() else f"{v:.1f}"
    if isinstance(v, (list, tuple)):
        return "[" + ", ".join(map(str, v[:6])) + ("…" if len(v) > 6 else "") + "]"
    return str(v)


def build_brief(scope: str, *, scopes_def: dict, ctx: dict, snap, kb: KB | None, memory_text: str | None,
                inbox_lines: list[str] | None, th: dict, budget: int = 1500, date_text: str = "") -> str:
    if scope not in scopes_def:
        raise BriefError(f"Scope '{scope}' unknown. Known: {', '.join(sorted(scopes_def))}")
    d = scopes_def[scope] or {}
    missing = [k for k in REQUIRED if not d.get(k)]
    if missing:
        raise BriefError(f"Scope '{scope}': missing required fields in data/scopes.yaml: {', '.join(missing)}")

    kpi_parts = []
    for k in d["kpis"]:
        if not isinstance(k, dict) or "name" not in k or "expr" not in k:
            raise BriefError(f"Scope '{scope}': KPI needs name and expr: {k!r}")
        try:
            v = evaluate(str(k["expr"]), ctx)
        except ExprError as e:
            raise BriefError(f"Scope '{scope}': KPI {k['name']}: {e}") from None
        kpi_parts.append(f"{k['name']} {_fmt(v)} (target {k.get('target', k.get('ziel', '-'))})")

    sections: list[_Section] = [
        _Section("Mission", [str(d["mission"]).strip()], True, 0),
        _Section("Situation " + (date_text or ""), ["; ".join(kpi_parts)], True, 0),
    ]
    # Alerts of this scope (from the digest rules)
    alerts = [a for a in compute_alerts(snap, th, None, None, ctx.get("_cancels")) if scope in a.scopes]
    if alerts:
        sections.append(_Section("Alerts", [a.line() for a in sorted(alerts, key=lambda a: (a.level, a.key))], False, 1))
    # Memory (condensed)
    if memory_text:
        mem = extract_for_brief(compact_text(memory_text))
        if mem["offen"]:
            sections.append(_Section("Open (memory)", [shorten(x, 160) for x in mem["offen"]], False, 1))
        if mem["status"]:
            sections.append(_Section("Last state", [shorten(x, 160) for x in mem["status"][:8]], False, 3))
        if mem["erkenntnis"]:
            sections.append(_Section("Insights", [shorten(x, 160) for x in mem["erkenntnis"][:8]], False, 4))
    if inbox_lines:
        ib = [shorten(re.sub(r"\*\*|`", "", x), 150) for x in inbox_lines[-6:]]
        sections.append(_Section("Inbox (latest)", ib, False, 2))
    # Known traps
    if kb is not None:
        ids = list(d.get("kb_ids") or [])
        hits = [kb.get(i) for i in ids if kb.get(i)]
        for h in kb.search(str(d["kb_query"]), k=4, include_unreviewed=False):
            if h.entry not in hits:
                hits.append(h.entry)
        traps = [f"[{e.id}] {e.title}: {shorten(e.fix or e.body, 150)}" for e in hits[:5]]
        if traps:
            sections.append(_Section("Known traps (dfpilot kb get <id>)", traps, False, 2))
    sections.append(_Section("Commands", ["; ".join(map(str, d["commands"]))], False, 3))
    sections.append(_Section("Fair Play", [FAIRPLAY_BLOCK], True, 0))
    sections.append(_Section("Report", [REPORT_FORMAT], True, 0))

    # Remove duplicates (shingle overlap > 50 % with what is already included)
    seen: set = set()
    for s in sorted(sections, key=lambda s: s.prio):
        kept = []
        for ln in s.lines:
            sh = shingles(ln)
            if sh and not s.required and len(sh & seen) > 0.5 * len(sh):
                continue
            seen |= sh
            kept.append(ln)
        s.lines = kept
    sections = [s for s in sections if s.lines]

    head = f"# Briefing {scope}"

    def render(secs) -> str:
        order = sorted(secs, key=lambda s: (0 if s.title.startswith(("Mission", "Situation")) else 2 if s.required else 1))
        blocks = []
        for s in order:
            body = "\n".join(x if s.required else f"- {x}" for x in s.lines)
            blocks.append(f"## {s.title.strip()}\n{body}")
        return head + "\n" + "\n".join(blocks)

    text = render(sections)
    # Budget: trim optional sections from the back (lowest priority first)
    while tokens(text) > budget:
        opt = [s for s in sections if not s.required and s.lines]
        if not opt:
            break
        victim = max(opt, key=lambda s: (s.prio, len(s.lines)))
        victim.lines.pop()
        sections = [s for s in sections if s.lines or s.required]
        text = render(sections)
    if tokens(text) > budget:
        raise BriefError(f"Scope '{scope}': the mandatory parts alone exceed the budget {budget} (shorten the mission)")
    return text
