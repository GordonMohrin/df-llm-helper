"""Wake filter for the orchestrator (replacement for the monitor bash script).

Problem (Run 5 session, 08:19-09:01): 42 wake-ups in 41 min, >= 14 without need for action (legacy flags at
monitor start, mood.flag 3x, completion messages). Every wake-up costs a turn with ~700k context.

wake_check() reads ONLY files (no DF call): flags, events.log (CRITICAL/KRITISCH), dfpilot warnings (crit).
Prints one line per event 'WAKE <class>: <text> -> <next step>'; legacy items on the first run are remembered
as a baseline (not reported), identical content is suppressed within dedupe_min.
"""
from __future__ import annotations

import hashlib
import re

__all__ = ["WAKE_FLAGS", "wake_check"]

# flag -> (class, next step). Not here: migranten/dig (they come bundled in the digest).
WAKE_FLAGS = {
    "alert": ("alarm", "dfpilot digest; alarm procedure (project instructions: danger/combat)"),
    "siege": ("siege", "step mode: claude/advance N; dfpilot runbook diagnose"),
    "caravan": ("caravan", "dfpilot runbook show rb06_karawane"),
    "mood": ("mood", "dfpilot runbook show rb07_stimmung"),
    "food": ("supplies", "dfpilot digest --scope essen"),
    "notfall": ("emergency", "dfpilot digest"),
    "wasser": ("flood", "dfpilot water watch; dfpilot runbook show rb21_flut (emergency wall)"),
    "wirtschaft": ("workload", "Idle high: create new work (dig/build/stone/trade), then delete wirtschaft.flag"),
}


NOISE_TAGS = re.compile(r"COMBAT_|LOSE_HOLD_OF_ITEM|FALL_OVER|PAIN_KO|CONFLICT_CONVERSATION|CANCEL_JOB|EXHAUSTION|PET_DEATH|BREAK_GRIP|LOSE_HOLD|STAND_UP|GRAB|"
                        r"NOT_STUNNED|REGAIN_CONSCIOUSNESS|UNIT_PROJECTILE_SLAM|LOSE_EMOTION")

def _h(text: str) -> str:
    return hashlib.sha1(re.sub(r"\d{1,2}:\d{2}(:\d{2})?", "", text).encode("utf-8")).hexdigest()[:10]


def wake_check(tools, store, clock, *, dedupe_min: float = 10.0, emit_existing: bool = False) -> list[str]:
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

    # new CRITICAL/KRITISCH lines in events.log (remember the offset)
    lines = tools.events_lines(5000)
    off = int(st.get("events_n", 0))
    if off > len(lines):
        off = 0
    noise = 0
    for ln in lines[off:]:
        if ln.startswith(("KRITISCH", "CRITICAL")):
            m = re.match(r"(?:KRITISCH|CRITICAL) \S+ \[([^\]]+)\] (.*)", ln)
            tag, text = (m.group(1), m.group(2)) if m else ("?", ln)
            if NOISE_TAGS.match(tag):
                noise += 1                    # combat details/cancellations: report only as a sum (save tokens)
                continue
            emit(f"ev:{tag}", _h(text), f"WAKE critical [{tag}]: {text[:150]} -> dfpilot digest")
    if noise >= 3:
        emit("ev:noise", _h(str(noise // 10)), f"WAKE combat: {noise} combat/cancel lines -> dfpilot digest")
    st["events_n"] = len(lines)

    # critical dfpilot warnings (guard/autopilot), without consuming them for the digest
    rows = store.db.execute("SELECT id, key, text FROM warnings WHERE level='crit' AND id > ? ORDER BY id",
                            (int(st.get("warn_id", 0)),)).fetchall()
    for r in rows:
        emit(f"warn:{r['key']}", _h(r["text"]), f"WAKE dfpilot: {r['text'][:150]} -> dfpilot digest")
        st["warn_id"] = r["id"]

    st["initialized"] = True
    st["seen"] = {k: v for k, v in seen.items() if now - v.get("ts", 0) < 86400 or k.startswith("flag:")}
    store.set("wake.state", st)
    return out
