"""Neuausrichtung 1 (P3, docs/v2/NEU1-wecken.md): the live player session's heartbeat and the knobs of config/wake.json.

<save>/session.json = {v: 2, wall: epoch s, by: the command, pid}. The session commands (SESSION_CMDS: wait, brief, cmd,
ack, plan, next) write it; the kernel's arbiter pauses the game when it is older than reflex.json `deadman.timeout_s`
(the dead-man switch: pause only, never unpause). Background processes (follow, supervise) and a supervisor's look
(status, events, doctor) never write it; DFLLM_NO_SESSION=1 suppresses it for any command.
"""
from __future__ import annotations

import copy
import os
import time
from pathlib import Path

from . import files, paths

SESSION_FILE = "session.json"
SESSION_CMDS = ("wait", "brief", "cmd", "ack", "plan", "next")
NO_SESSION_ENV = "DFLLM_NO_SESSION"

# config/wake.json defaults (a missing or bad file / key = these; fairplay.wake_errors lints the file)
QUIET_TYPES = ("AQ_HEAVY", "AQ_RING_STOP", "AUTOLABOR_LEGACY", "CAVERN_PLUG", "CAVERN_SWEEP_END", "DEPOT_MISSING",
               "DRILL_FAIL", "GATE_FORCED", "GHOSTS", "KERN_FAULT", "LOCKDOWN_PARTIAL", "ORDER_BAD", "PERF_DEGRADED",
               "PROJECT_BLOCKED", "SEAL_STUCK", "SIEGE_END", "SIEGE_UNREADY", "TOOL_BLOCKED")
QUIET_DECISIONS = ("seal_stalled", "no_hard_stone", "metal", "steel", "defense_gap", "refuge_dry", "refuge_levers",
                   "bridge_levers", "project_released", "caravan_stale", "manager_office", "manager_absent",
                   "trade_screen", "coffin_space", "coffin_material", "squads", "preventblocking", "trap_friendly",
                   "piece_missing", "gate_traffic", "berserk")
DEFAULTS: dict = {
    "wait": {"act": True, "repeat_s": 300, "backlog": 2000, "kernel_stale_s": 120, "follow_check": True,
             "quiet_types": list(QUIET_TYPES), "quiet_decisions": list(QUIET_DECISIONS)},
    "session": {"on": True},
    "follow": {"restart": True, "max_rss_mb": 400, "max_hours": 12},
}
# key -> (lo, hi) for ints, "bool", "types" / "ids" for the lists
LIMITS: dict = {
    "wait": {"act": "bool", "repeat_s": (0, 86400), "backlog": (10, 1000000), "kernel_stale_s": (30, 86400),
             "follow_check": "bool", "quiet_types": "types", "quiet_decisions": "ids"},
    "session": {"on": "bool"},
    "follow": {"restart": "bool", "max_rss_mb": (50, 64000), "max_hours": (1, 720)},
}


def _ok(v, lim) -> bool:
    if lim == "bool":
        return isinstance(v, bool)
    if lim in ("types", "ids"):
        return isinstance(v, list) and len(v) <= 200 and all(isinstance(x, str) and 0 < len(x) <= 40 for x in v)
    return isinstance(v, int) and not isinstance(v, bool) and lim[0] <= v <= lim[1]


def config(path: Path | None = None) -> dict:
    """config/wake.json merged over DEFAULTS; a bad value keeps its default (fail safe: every switch stays ON)."""
    out = copy.deepcopy(DEFAULTS)
    doc = files.read_json(Path(path) if path else paths.config_dir() / "wake.json", retry=False)
    if not isinstance(doc, dict) or doc.get("v") != 2:
        return out
    for blk, lims in LIMITS.items():
        sec = doc.get(blk)
        if not isinstance(sec, dict):
            continue
        for k, lim in lims.items():
            if k in sec and _ok(sec[k], lim):
                out[blk][k] = sec[k]
    return out


def enabled(cfg: dict | None = None) -> bool:
    if os.environ.get(NO_SESSION_ENV, "") not in ("", "0"):
        return False
    return bool((cfg or config())["session"]["on"])


def touch(save_dir: Path | None, by: str, now: float | None = None, cfg: dict | None = None) -> bool:
    """Write <save>/session.json (the dead-man's heartbeat). False when off or the write failed (never raises)."""
    if save_dir is None or not enabled(cfg):
        return False
    doc = {"v": 2, "wall": int(time.time() if now is None else now), "by": str(by)[:24], "pid": os.getpid()}
    try:
        files.write_json_atomic(Path(save_dir) / SESSION_FILE, doc)
        return True
    except OSError:
        return False


def read(save_dir: Path, now: float | None = None) -> tuple[dict | None, float | None]:
    """(session.json or None, its age in s from `wall`; None when missing or malformed)."""
    doc = files.read_json(Path(save_dir) / SESSION_FILE, retry=False)
    w = doc.get("wall") if isinstance(doc, dict) else None
    if not isinstance(w, int) or isinstance(w, bool):
        return None, None
    return doc, max(0.0, (time.time() if now is None else now) - w)
