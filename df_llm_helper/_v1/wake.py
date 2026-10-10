"""Wake filter for the orchestrator (replacement for the monitor bash script).

Problem (Run 5 session, 08:19-09:01): 42 wake-ups in 41 min, >= 14 without need for action (legacy flags at
monitor start, mood.flag 3x, completion messages). Every wake-up costs a turn with ~700k context.

wake_check() reads ONLY files (no DF call): flags, events.log (CRITICAL/KRITISCH), df-llm-helper warnings (crit).
Prints one line per event 'WAKE <class>: <text> -> <next step>'; legacy items on the first run are remembered
as a baseline (not reported), identical content is suppressed within dedupe_min.
"""
from __future__ import annotations

import hashlib
import re
from pathlib import Path

__all__ = ["WAKE_FLAGS", "wake_check"]

# flag -> (class, next step). Not here: migranten/dig (they come bundled in the digest).
WAKE_FLAGS = {
    "alert": ("alarm", "python -m df_llm_helper digest; alarm procedure (project instructions: danger/combat)"),
    "siege": ("siege", "step mode: claude/advance N; python -m df_llm_helper runbook diagnose"),
    "caravan": ("caravan", "python -m df_llm_helper runbook show rb06_karawane"),
    "mood": ("mood", "python -m df_llm_helper runbook show rb07_stimmung"),
    "food": ("supplies", "python -m df_llm_helper digest --scope essen"),
    "notfall": ("emergency", "python -m df_llm_helper digest"),
    "wasser": ("flood", "python -m df_llm_helper water watch; python -m df_llm_helper runbook show rb21_flut (emergency wall)"),
    "pause.hold": ("pause", "a pause.hold in the runtime folder blocks the timestream: python -m df_llm_helper digest; delete it if stale"),
    "wirtschaft": ("workload", "Idle high: create new work (dig/build/stone/trade), then delete wirtschaft.flag"),
}


# BUG-116: matched with search() (NO_BREAK_GRIP contains BREAK_GRIP); VOMIT, RESOLVE_SHARED_ITEMS, DODGE_FLYING_OBJECT and
# MASTERPIECE_CRAFTED are no reason to wake the orchestrator (the old watcher marks them CRITICAL because the text
# contains 'goblin'). Unknown tags still wake (fail-safe deny list).
NOISE_TAGS = re.compile(r"COMBAT_|LOSE_HOLD_OF_ITEM|FALL_OVER|PAIN_KO|CONFLICT_CONVERSATION|CANCEL_JOB|EXHAUSTION|PET_DEATH|BREAK_GRIP|LOSE_HOLD|STAND_UP|GRAB|"
                        r"NOT_STUNNED|REGAIN_CONSCIOUSNESS|UNIT_PROJECTILE_SLAM|LOSE_EMOTION|VOMIT|RESOLVE_SHARED_ITEMS|"
                        r"DODGE_FLYING_OBJECT|MASTERPIECE_CRAFTED")
# harmless tags that are not even counted as combat noise
QUIET_TAGS = re.compile(r"VOMIT|RESOLVE_SHARED_ITEMS|MASTERPIECE_CRAFTED|DODGE_FLYING_OBJECT")


def _fix_mojibake(text: str) -> str:
    from .journal import fix_mojibake
    out = fix_mojibake(text)
    if out == text and "\u0393\u00ff" in text:          # 'Γÿ╝' = '☼' read as CP437 (no box char of the journal check)
        try:
            out = text.encode("cp437").decode("utf-8")
        except (UnicodeEncodeError, UnicodeDecodeError):
            out = text
    return out


def _h(text: str) -> str:
    return hashlib.sha1(re.sub(r"\d{1,2}:\d{2}(:\d{2})?", "", text).encode("utf-8")).hexdigest()[:10]


def wake_check(tools, store, clock, *, dedupe_min: float = 10.0, emit_existing: bool = False, sink=None,
               loops_cfg: dict | None = None, gamelog: str | None = None, rules_cfg: dict | None = None) -> list[str]:
    """`sink(line)` (optional) is called for every line BEFORE the state is stored: if printing fails, the events are
    not marked as seen and come again on the next call (BUG-112)."""
    now = clock.now().epoch
    st = store.get("wake.state") or {}
    first = not st.get("initialized")
    seen: dict = st.get("seen", {})          # key -> {"h": hash, "ts": epoch}
    out: list[str] = []

    def emit(key: str, h: str, line: str) -> None:
        prev = seen.get(key)
        if prev and prev.get("h") == h and now - prev.get("ts", 0) < dedupe_min * 60:
            return
        if prev and prev.get("h") == h and key.startswith("flag:"):
            return                            # never report an unchanged flag file again
        seen[key] = {"h": h, "ts": now}
        if first and not emit_existing:
            return                            # baseline: do not report legacy items
        out.append(line)

    for name, (klass, nxt) in WAKE_FLAGS.items():
        fi = tools.flag(name)
        if not fi.exists:
            seen.pop(f"flag:{name}", None)
            continue
        txt = re.sub(r"\s+", " ", fi.text.replace("﻿", "")).strip()[:140]
        if name == "notfall" and "HOSPITAL/REST" in txt:
            continue                          # known hospital care bottleneck (Run 5): do not wake every time
        if name == "wirtschaft":
            txt = "Workload low (wirtschaft.flag)"   # constant text: wake only once until the flag is deleted
        emit(f"flag:{name}", _h(txt), f"WAKE {klass}: {txt or name + '.flag'} -> {nxt}")

    # new CRITICAL/KRITISCH lines in events.log (remember the byte offset, BUG-100)
    pos = st.get("events_pos")
    if pos is None:
        pos = tools.events_offset_after(int(st["events_n"])) if "events_n" in st and int(st["events_n"]) < 5000 \
            else (0 if first else tools.events_offset_after(10 ** 9))
    lines, pos, head = tools.events_since(int(pos), st.get("events_head"))
    noise = 0
    for ln in lines:
        if ln.startswith(("KRITISCH", "CRITICAL")):
            m = re.match(r"(?:KRITISCH|CRITICAL) \S+ \[([^\]]+)\] (.*)", ln)
            tag, text = (m.group(1), m.group(2)) if m else ("?", ln)
            if NOISE_TAGS.search(tag):
                if not QUIET_TAGS.search(tag):
                    noise += 1                # combat details/cancellations: report only as a sum (save tokens)
                continue
            text = _fix_mojibake(text)
            emit(f"ev:{tag}", _h(text), f"WAKE critical [{tag}]: {text[:150]} -> python -m df_llm_helper digest")
    if noise >= 3:
        emit("ev:noise", _h(str(noise // 10)), f"WAKE combat: {noise} combat/cancel lines -> python -m df_llm_helper digest")
    st.pop("events_n", None)
    st["events_pos"], st["events_head"] = pos, head

    # critical df-llm-helper warnings (guard/autopilot), without consuming them for the digest
    rows = store.db.execute("SELECT id, key, text FROM warnings WHERE level='crit' AND id > ? ORDER BY id",
                            (int(st.get("warn_id", 0)),)).fetchall()
    for r in rows:
        emit(f"warn:{r['key']}", _h(r["text"]), f"WAKE df-llm-helper: {r['text'][:150]} -> python -m df_llm_helper digest")
        st["warn_id"] = r["id"]

    # configurable gamelog rules (wakerules.py): hard alarms, deaths/tantrums/moods, caravan, ghosts
    if gamelog and (rules_cfg or {}).get("enabled", True):
        try:
            from .wakerules import build_rules, gamelog_events
            gst = st.setdefault("gamelog", {})
            out.extend(gamelog_events(Path(gamelog), gst, build_rules(rules_cfg), now))
        except Exception:  # noqa: BLE001 - the wake filter must never die on a rule
            pass

    # FEATURE-006: duplicate or hanging background loops (lockfiles under tools/loops + PID check, no DF call)
    try:
        from .loops import wake_lines
        for key, text in wake_lines(tools.path, loops_cfg):
            emit(f"loop:{key}", _h(text), f"WAKE loops: {text}")
    except Exception:  # noqa: BLE001 - the wake filter must never die on the registry
        pass

    if sink is not None:
        for line in out:
            sink(line)
    st["initialized"] = True
    st["seen"] = {k: v for k, v in seen.items() if now - v.get("ts", 0) < 86400 or k.startswith("flag:")}
    store.set("wake.state", st)
    return out
