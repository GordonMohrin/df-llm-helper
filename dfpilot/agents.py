"""Spec 10: enforce the subagent briefing and measure costs (`dfpilot agents`).

- prompt:      complete agent prompt (briefing + task + report format + fair play + commands), <= 1500 tokens,
               marker MARKER for the cost evaluation; the same task within dedupe_s is not assigned twice.
- lint-report: mandatory fields (Result, Measurements, Changed, Open, Risk) and <= max_report_lines; reports that are
               too long are truncated, the original archived. The German field names are accepted too.
- cost:        evaluate Claude Code transcripts subagents/*.jsonl. IMPORTANT: every API response appears once per content
               block in the transcript (same requestId, same usage) -> count each requestId only once (naively ~2x).
"""
from __future__ import annotations

import hashlib
import json
import re
import statistics
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

__all__ = ["DEFAULTS", "MARKER", "REPORT_FIELDS", "build_prompt", "lint_report", "AgentCost", "parse_transcript",
           "cost_report", "compare", "TaskDedupe", "tokens"]

DEFAULTS = {"transcript_dir": "~/.claude/projects", "max_report_lines": 12, "warn_calls": 60, "warn_output_k": 40,
            "prompt_budget": 1500, "dedupe_s": 600, "archive_dir": "out/berichte"}
MARKER = "[dfpilot-brief v1]"
REPORT_FIELDS = ["Result", "Measurements", "Changed", "Open", "Risk"]
_FIELD_ALIASES = {"Result": ["Ergebnis"], "Measurements": ["Messwerte"], "Changed": ["Geaendert", "Geändert"],
                  "Open": ["Offen"], "Risk": ["Risiko"]}
_FIELD_RE = {f: re.compile(rf"^\s*[-*]?\s*\**(?:{'|'.join([f] + _FIELD_ALIASES[f])})\**\s*(\(.*?\))?\s*:", re.I | re.M)
             for f in REPORT_FIELDS}


def tokens(text: str) -> int:
    return (len(text) + 2) // 3                      # like digest.tokens (len/3, conservative)


HEAD = ("{marker} You are the scope agent {scope} (Dwarf Fortress, fortress {fort}). Working folder dfpilot "
        "(python -m dfpilot ...). Do NOT read any further files at the start; knowledge only via kb search/get.")
TASK = "## Task\n{task}"
FORMAT = ("## Report format (mandatory, <= {n} lines, otherwise truncated)\nResult: ...\nMeasurements (before/after): ...\n"
          "Changed: ...\nOpen: ...\nRisk: ...")
FAIRPLAY = ("## Fair Play\nPlayer-level operation only (orders, stockpiles, labors, squads, offices, quickfort with own rasters). "
            "Forbidden: createitem, dig-now, build-now, reveal, prospect all, changing units/items directly. Exceptions only "
            "with a register entry (the player's yes).")
COMMANDS = ("## Commands\nkb search \"<symptom>\" | runbook diagnose | runbook run <id> --dry-run | "
            "bus post \"<text>\" --from {scope} --to orchestrator | memory compact {scope}. One pass, <= 40 tool calls.")


def build_prompt(scope: str, task: str, brief_text: str, *, fort: str = "?", max_lines: int = 12,
                 budget: int = 1500) -> str:
    """Prompt from fixed mandatory blocks + briefing; the briefing is truncated until everything is <= budget tokens."""
    task = " ".join(task.split())[:400] or "One pass according to the briefing."
    fixed = [HEAD.format(marker=MARKER, scope=scope, fort=fort), TASK.format(task=task),
             FORMAT.format(n=max_lines), FAIRPLAY, COMMANDS.format(scope=scope)]
    room = budget - tokens("\n\n".join(fixed)) - tokens("\n\n## Briefing\n") - 2
    brief = brief_text.strip()
    if tokens(brief) > room:
        lines, keep = brief.splitlines(), []
        for ln in lines:
            if tokens("\n".join(keep + [ln, "(briefing truncated)"])) > room:
                break
            keep.append(ln)
        brief = "\n".join(keep + ["(briefing truncated)"])
    return "\n\n".join(fixed[:2] + ["## Briefing\n" + brief] + fixed[2:])


@dataclass
class ReportCheck:
    ok: bool
    problems: list
    text: str                # truncated if necessary
    truncated: bool = False


def lint_report(text: str, max_lines: int = 12) -> ReportCheck:
    lines = [ln for ln in (text or "").strip().splitlines() if ln.strip()]
    problems = []
    missing = [f for f in REPORT_FIELDS if not _FIELD_RE[f].search(text or "")]
    if missing:
        problems.append("Mandatory fields missing: " + ", ".join(missing))
    out, cut = "\n".join(lines), False
    if len(lines) > max_lines:
        problems.append(f"{len(lines)} lines > {max_lines}")
        out = "\n".join(lines[:max_lines - 1] + [f"(truncated: {len(lines) - max_lines + 1} lines in the archive)"])
        cut = True
    return ReportCheck(not problems, problems, out, cut)


def archive_report(text: str, scope: str, out_dir: Path, now: datetime) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    p = out_dir / f"{now:%Y%m%d-%H%M%S}-{scope}.md"
    p.write_text(text, encoding="utf-8")
    return p


@dataclass
class AgentCost:
    agent: str
    description: str = ""
    calls: int = 0              # unique API requests (requestId)
    lines: int = 0              # assistant lines in the transcript (for comparison, ~2x calls)
    input: int = 0
    cache_read: int = 0
    cache_write: int = 0
    output: int = 0
    duration_s: float = 0.0
    briefing: bool = False      # prompt contained MARKER
    tool_uses: int = 0
    out_est: int = 0            # output estimated from block lengths (chars/3): usage.output_tokens in the transcript
                                # is the value at stream start (often 2..8) and underestimates heavily
    warnings: list = field(default_factory=list)


def _ts(s: str | None) -> datetime | None:
    try:
        return datetime.fromisoformat(str(s).replace("Z", "+00:00"))
    except ValueError:
        return None


def parse_transcript(path: Path, cfg: dict | None = None) -> AgentCost:
    c = {**DEFAULTS, **(cfg or {})}
    path = Path(path)
    meta = path.with_name(path.name.replace(".jsonl", ".meta.json"))
    desc = ""
    if meta.exists():
        try:
            desc = json.loads(meta.read_text(encoding="utf-8")).get("description", "")
        except (ValueError, OSError):
            desc = ""
    ac = AgentCost(path.stem, desc)
    usage: dict = {}
    first = last = None
    for ln in path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            d = json.loads(ln)
        except ValueError:
            continue
        t = _ts(d.get("timestamp"))
        if t:
            first = first or t
            last = t
        m = d.get("message") if isinstance(d.get("message"), dict) else {}
        if d.get("type") == "user" and not ac.briefing:
            content = m.get("content")
            text = content if isinstance(content, str) else json.dumps(content, ensure_ascii=False)
            ac.briefing = MARKER in text
        if d.get("type") != "assistant":
            continue
        ac.lines += 1
        rid = d.get("requestId") or m.get("id") or f"line{ac.lines}"
        if isinstance(m.get("usage"), dict):
            usage[rid] = m["usage"]
        for b in m.get("content") or []:
            if not isinstance(b, dict):
                continue
            ac.tool_uses += b.get("type") == "tool_use"
            if "chars" in b:                                   # anonymized fixture
                n = int(b.get("chars") or 0)
            else:
                n = len(b.get("text") or b.get("thinking") or (json.dumps(b.get("input"), ensure_ascii=False)
                                                                 if b.get("type") == "tool_use" else ""))
            ac.out_est += (n + 2) // 3
    for u in usage.values():
        ac.input += int(u.get("input_tokens") or 0)
        ac.cache_read += int(u.get("cache_read_input_tokens") or 0)
        ac.cache_write += int(u.get("cache_creation_input_tokens") or 0)
        ac.output += int(u.get("output_tokens") or 0)
    ac.calls = len(usage)
    if first and last:
        ac.duration_s = (last - first).total_seconds()
    if ac.calls > c["warn_calls"] or max(ac.output, ac.out_est) > c["warn_output_k"] * 1000:
        ac.warnings.append(f"{ac.agent}: {ac.calls} calls/~{max(ac.output, ac.out_est)} output - stuck? check the result, shrink the task")
    return ac


def cost_report(paths: list[Path], cfg: dict | None = None) -> tuple[list[AgentCost], list[str]]:
    rows = [parse_transcript(p, cfg) for p in sorted(paths)]
    out = [f"{'Agent':<28} {'Calls':>5} {'CacheRead':>11} {'CacheWr':>9} {'Out~':>7} {'Dur':>6}  Task"]
    for r in rows:
        out.append(f"{r.agent[:28]:<28} {r.calls:>5} {r.cache_read:>11} {r.cache_write:>9} {r.out_est:>7} "
                   f"{r.duration_s / 60:>5.1f}m  {('[B] ' if r.briefing else '') + r.description[:40]}")
    if rows:
        out.append(f"{'Total':<28} {sum(r.calls for r in rows):>5} {sum(r.cache_read for r in rows):>11} "
                   f"{sum(r.cache_write for r in rows):>9} {sum(r.out_est for r in rows):>7} "
                   f"{sum(r.duration_s for r in rows) / 60:>5.1f}m  ({len(rows)} agents, [B] = briefing prompt)")
    for r in rows:
        out += r.warnings
    return rows, out


def compare(rows: list[AgentCost]) -> str:
    """Briefing prompt vs. old prompt: mean output and cache read per run (acceptance 4 needs >= 3 per group)."""
    b = [r for r in rows if r.briefing]
    a = [r for r in rows if not r.briefing]
    if not b or not a:
        return f"Comparison not possible: {len(b)} runs with briefing, {len(a)} without"

    def mean(xs, k):
        return statistics.mean(getattr(x, k) for x in xs)
    d_out = (1 - mean(b, "out_est") / mean(a, "out_est")) * 100 if mean(a, "out_est") else 0.0
    d_cr = (1 - mean(b, "cache_read") / mean(a, "cache_read")) * 100 if mean(a, "cache_read") else 0.0
    note = "" if len(a) >= 3 and len(b) >= 3 else " (too few runs for acceptance 4: >= 3 each)"
    def pct(d: float) -> str:
        return f"{d:.0f} % smaller" if d >= 0 else f"{-d:.0f} % larger"
    return f"Briefing {len(b)} vs. old {len(a)}: output {pct(d_out)}, cache read {pct(d_cr)}" + note


class TaskDedupe:
    def __init__(self, store, clock, dedupe_s: int = 600):
        self.store, self.clock, self.dedupe_s = store, clock, dedupe_s

    def check_and_mark(self, scope: str, task: str) -> bool:
        """True = new (assigned), False = same task already assigned within dedupe_s."""
        key = hashlib.sha1(f"{scope}|{' '.join(task.lower().split())}".encode()).hexdigest()[:12]
        now = self.clock.now().epoch
        seen = {k: v for k, v in (self.store.get("agents.tasks") or {}).items() if now - v < self.dedupe_s}
        if key in seen:
            self.store.set("agents.tasks", seen)
            return False
        seen[key] = now
        self.store.set("agents.tasks", seen)
        return True
