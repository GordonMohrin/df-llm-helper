"""Configurable gamelog rules for `wake` (replacement for the four inline Claude shell monitors).

Source: gamelog.txt (DF writes every announcement there, also the UI messages of `world.status.reports`). The file is
read incrementally (byte offset + hash of the first line; rotation or truncation -> read from the start); the first
run only sets the baseline (no replay of old history). Every rule turns matching lines into ONE line for the monitor
stream:  `WAKE <category>: <name/text> -> <next step>`.

A rule (dict, see DEFAULT_RULES):
  name       unique id (used to disable / tune it in config.yaml)
  category   shown in the WAKE line
  pattern    regex (case-insensitive, `search`) on the gamelog line
  kinds      optional {kind: regex}: first matching kind is appended to the category (`death`, `tantrum`, ...)
  name_re    optional regex with group 'name' (who / which civ); default: text before the matched phrase
  next       next step for the orchestrator
  cooldown_s rate limit; 0 = none
  dedupe     'category' (one line per category+kind and cooldown, the rest is counted: "(+3 suppressed)") or 'line' (identical
             line is suppressed within the cooldown)
  key        optional shared rate-limit key (default: category); several rules may share one key

config.yaml:
  wake:
    gamelog_rules:
      enabled: true
      rules:                      # per rule name: any field of the rule, `enabled: false` switches it off
        ghost: {cooldown_s: 1800}
        alarm_hard: {enabled: false}
      extra: [{name: x, category: x, pattern: 'some text', next: 'look', cooldown_s: 60}]
"""
from __future__ import annotations

import copy
import hashlib
import re
from pathlib import Path

__all__ = ["DEFAULT_RULES", "build_rules", "read_since", "match_line", "gamelog_events"]

_DIGEST = "python -m df_llm_helper digest"

DEFAULT_RULES: list[dict] = [
    # (b) deaths / tantrum / berserk / moods
    {"name": "death_tantrum_mood", "category": "unit",
     "pattern": r"has been found dead|has been struck down|is throwing a tantrum|has gone berserk|\bberserk\b|"
                r"stark raving|has been taken by a (?:fey|secretive|possessed|macabre|fell|melancholy|insane|"
                r"raving|berserk)\w* mood|drained of blood",
     "kinds": {"death": r"found dead|struck down|drained of blood", "tantrum": r"tantrum",
               "berserk": r"berserk|stark raving", "mood": r"\bmood\b"},
     "name_re": r"^(?P<name>.+?)(?:,\s*[^,]*?)?,?\s+(?:has been|is throwing|has gone|has taken|is stark)",
     "next": f"{_DIGEST}; python -m df_llm_helper runbook show rb07_stimmung (mood) / care (wounded)",
     "cooldown_s": 600, "dedupe": "line"},
    # (a) hard alarms (siege/ambush/beast/megabeast/forgotten beast); the alert flag and pause.hold are flags (WAKE_FLAGS)
    {"name": "alarm_hard", "category": "alarm",
     "pattern": r"vile force of darkness|\bsiege\b|ambush|forgotten beast|megabeast|\btitan\b|unfriendly creature|"
                r"\bbeast\b.*(has come|have come|arrived)|(has come|have come).*\bbeast\b",
     "kinds": {"siege": r"vile force of darkness|\bsiege\b", "ambush": r"ambush",
               "forgotten-beast": r"forgotten beast", "megabeast": r"megabeast|\btitan\b", "beast": r"beast"},
     "next": f"{_DIGEST}; alarm procedure (claude/mil, runbook diagnose)", "cooldown_s": 300, "dedupe": "category"},
    # (c) caravan: first message, not "Merchants have arrived"
    {"name": "caravan", "category": "caravan",
     "pattern": r"caravan from|merchants have arrived|merchants from .* have arrived",
     "name_re": r"caravan from (?:the )?(?P<name>.+?)(?: has| have| is| are|[.!,]|$)",
     "next": "python -m df_llm_helper runbook show rb06_karawane", "cooldown_s": 3600, "dedupe": "category"},
    # (d) ghosts
    {"name": "ghost", "category": "ghost", "pattern": r"ghost|haunt|restless",
     "next": "claude/gesund slabs; memorial slabs (python -m df_llm_helper digest)", "cooldown_s": 900, "dedupe": "category"},
]


def build_rules(cfg: dict | None) -> list[dict]:
    """Default rules + overrides/extras from config (`wake.gamelog_rules`). Disabled rules are dropped."""
    cfg = cfg or {}
    rules = copy.deepcopy(DEFAULT_RULES)
    over = cfg.get("rules") or {}
    for r in rules:
        o = over.get(r["name"])
        if isinstance(o, dict):
            r.update(o)
    for x in cfg.get("extra") or []:
        if isinstance(x, dict) and x.get("name") and x.get("pattern"):
            rules.append({"category": x["name"], "next": _DIGEST, "cooldown_s": 300, "dedupe": "category", **x})
    out = []
    for r in rules:
        if r.get("enabled") is False:
            continue
        try:
            r["_re"] = re.compile(r["pattern"], re.I)
            r["_kinds"] = {k: re.compile(v, re.I) for k, v in (r.get("kinds") or {}).items()}
            r["_name"] = re.compile(r["name_re"], re.I) if r.get("name_re") else None
        except re.error:
            continue                                  # a broken user pattern must not kill the wake loop
        out.append(r)
    return out


def _decode(chunk: bytes, first: bool) -> str:
    for enc in ("utf-8-sig" if first else "utf-8", "cp437"):
        try:
            return chunk.decode(enc)
        except UnicodeDecodeError:
            continue
    return chunk.decode("latin-1")


def read_since(path: Path, pos: int | None, head: str | None, max_bytes: int = 2_000_000):
    """Complete new lines of the gamelog after byte offset `pos`.

    pos None = first call: baseline at the end of the file (nothing reported). A shorter file or a different first
    line (rotation: DF renames gamelog.txt at game start) -> read from the start. Returns (lines, new_pos, head)."""
    try:
        with Path(path).open("rb") as f:
            first = f.readline(4096)
            size = f.seek(0, 2)
            h = hashlib.sha1(first.rstrip(b"\r\n")).hexdigest()[:10] if first.endswith(b"\n") else ""
            if pos is None:
                return [], size, h
            if pos < 0 or pos > size or (head and h and head != h):
                pos = 0
            if size - pos > max_bytes:
                pos = size - max_bytes
            f.seek(pos)
            data = f.read()
    except OSError:
        return [], (pos or 0), (head or "")
    end = data.rfind(b"\n")
    if end < 0:
        return [], pos, h or (head or "")
    text = _decode(data[:end + 1], pos == 0)
    return [ln.strip() for ln in text.splitlines() if ln.strip()], pos + end + 1, h


def _clean(line: str) -> str:
    line = line.replace("﻿", "").replace("Γÿ", "")
    return re.sub(r"\s+", " ", line).strip()


def match_line(line: str, rules: list[dict]):
    """First matching rule -> (rule, kind, name, text) or None."""
    text = _clean(line)
    for r in rules:
        if not r["_re"].search(text):
            continue
        kind = next((k for k, rx in r["_kinds"].items() if rx.search(text)), "")
        name = ""
        if r["_name"]:
            m = r["_name"].search(text)
            if m:
                name = (m.groupdict().get("name") or "").strip(" ,.")
        return r, kind, name, text
    return None


def gamelog_events(path: Path, state: dict, rules: list[dict], now: float) -> list[str]:
    """Run the rules over the new gamelog lines. `state` (JSON dict) keeps offset, head and the rate-limit table."""
    lines, pos, head = read_since(path, state.get("pos"), state.get("head"))
    state["pos"], state["head"] = pos, head
    rate: dict = state.setdefault("rate", {})
    out: list[str] = []
    for ln in lines:
        m = match_line(ln, rules)
        if not m:
            continue
        r, kind, name, text = m
        cat = f"{r['category']}/{kind}" if kind else r["category"]
        cool = float(r.get("cooldown_s", 0))
        rkey = f"{r.get('key') or r['category']}/{kind}" if r.get("dedupe", "category") == "category" else \
            f"{r['name']}:{hashlib.sha1(re.sub(r'[0-9]+', '', text).encode()).hexdigest()[:10]}"
        st = rate.get(rkey)
        if st and cool and now - st["ts"] < cool:
            st["suppressed"] = st.get("suppressed", 0) + 1
            continue
        extra = f" (+{st['suppressed']} suppressed)" if st and st.get("suppressed") else ""
        rate[rkey] = {"ts": now, "suppressed": 0}
        what = f"{name} | {text[:130]}" if name else text[:150]
        out.append(f"WAKE {cat}: {what}{extra} -> {r.get('next', _DIGEST)}")
    for k in [k for k, v in rate.items() if now - v["ts"] > 86400]:
        del rate[k]
    return out
