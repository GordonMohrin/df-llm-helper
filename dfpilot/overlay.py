"""F16 status overlay for the player: short text (<= 3 lines, <= 120 chars/line) for claude/schau say,
from the top messages of the digest, rate-limited (identical content is not re-sent within dedupe_min)."""
from __future__ import annotations

import hashlib
import re

__all__ = ["overlay_lines", "overlay_send"]


def _clean(line: str) -> str:
    line = re.sub(r"^(!!|!|~|>|-|ok)\s+", "", line.strip())
    line = re.sub(r"\[(guard|autopilot|trend|pilot)\]\s*", "", line)
    line = line.replace('"', "'")
    return line


def overlay_lines(digest: str, *, max_lines: int = 3, max_chars: int = 120) -> list[str]:
    """Critical first, then warnings; the status line only if nothing else is there."""
    rows = digest.splitlines()
    crit = [r for r in rows if r.startswith("!! ")]
    warn = [r for r in rows if r.startswith("! ")]
    pick = (crit + warn)[:max_lines]
    if not pick:
        lage = [r for r in rows if r.startswith("Status ")]
        pick = lage[:1] or rows[:1]
    out = []
    for r in pick:
        t = _clean(r)
        if len(t) > max_chars:
            t = t[: max_chars - 1].rstrip() + "…"
        if t:
            out.append(t)
    return out


def overlay_send(lines: list[str], store, client, now: float, *, dedupe_min: float = 10.0, prio: int = 3,
                 dry_run: bool = False) -> list[str]:
    """Sends 'claude/schau say "<text>" <prio>' per line - the same line at most every dedupe_min minutes."""
    sent = store.get("overlay.sent") or {}
    cmds = []
    for ln in lines:
        h = hashlib.sha1(ln.encode("utf-8")).hexdigest()[:12]
        if now - sent.get(h, -1e18) < dedupe_min * 60:
            continue
        cmd = f'claude/schau say "{ln}" {prio}'
        cmds.append(cmd)
        if not dry_run:
            client.run(cmd)
            sent[h] = now
    if not dry_run:
        store.set("overlay.sent", {k: v for k, v in sent.items() if now - v < 86400})
    return cmds
