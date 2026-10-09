"""Owner and expiry rules of `tools/pause.hold` (BUG-223, BUG-224).

`pause.hold` means "keep the game paused": the watcher (waechter.py) lifts a pause only without it, and the fort's
own pause guard pauses a running game again while it exists. The file text starts with the reason (first word); the
reasons are shared with the Lua companion scripts and stay German where they come from there:

  alarm     watcher: real enemies (waechter.py)            gefahr   claude/gefahr.lua (text 'gefahr HH:MM:SS')
  karawane  watcher / claude/watchdog.lua: caravan arrived trade    trade automaton (trade_flow.py, BUG-223)

The age is the file's mtime. A hold is *stale* when it is older than the limit of its reason and nothing justifies it
any more: no active danger (siege.flag, a fresh alert.flag) for alarm/gefahr, no running trade for karawane/trade.
`guard` (in `check`) reports a stale hold once as a critical warning; the watcher releases it (`holds.auto_release`).
Trade commands `HELPER hold trade` / `HELPER release_hold` are executed locally by run_helper (never sent to the game).
"""
from __future__ import annotations

from dataclasses import dataclass

__all__ = ["HoldInfo", "DEFAULTS", "TRADE_REASONS", "DANGER_REASONS", "HOLD_CMD", "RELEASE_CMD", "hold_reason",
           "hold_info", "write_hold", "release_hold", "danger_reason", "trade_active", "stale_hold", "stale_text", "handel_aktiv",
           "run_helper"]

TRADE_REASONS = ("trade", "karawane", "caravan")   # holds the trade automaton owns (it may delete them)
DANGER_REASONS = ("alarm", "gefahr")          # holds written because of enemies (never deleted by the trade)
HOLD_CMD = "HELPER hold trade"
RELEASE_CMD = "HELPER release_hold"
DEFAULTS = {
    "max_age_min": {"alarm": 15, "gefahr": 20, "karawane": 10, "caravan": 10, "trade": 30},
    "default_max_age_min": 30,      # reasons not in the table (hand-written holds, 'test', ...)
    "alert_active_min": 5,          # alert.flag younger than this = danger still active
    "trade_active_max_min": 60,     # a running trade protects its hold at most this long (abandoned flow)
    "auto_release": True,           # watcher deletes stale holds
    "squads_close_s": 30,           # watcher: Squads window open + game paused this long -> close it (BUG-224)
    "handel_aktiv_max_min": 5,      # claude/handelauto: handel_aktiv.flag younger than this protects its trade hold
}
_ACTIVE_TRADE = ("PAUSE", "SAVE", "BROKER", "MARK", "OPEN", "SELECT_DRY", "REVIEW", "WAIT", "SELECT_LIVE", "CONFIRM",
                 "FINISH", "RELEASE", "RESUME")


def _cfg(cfg: dict | None) -> dict:
    c = {**DEFAULTS, **(cfg or {})}
    c["max_age_min"] = {**DEFAULTS["max_age_min"], **((cfg or {}).get("max_age_min") or {})}
    return c


def hold_reason(text: str) -> str:
    """First word of the hold text, lower case ('gefahr 12:01:02' -> 'gefahr'; empty file -> '')."""
    parts = (text or "").strip().split()
    return parts[0].lower() if parts else ""


@dataclass
class HoldInfo:
    exists: bool
    reason: str = ""
    text: str = ""
    age_min: float | None = None
    max_age_min: float | None = None


def hold_info(tools, cfg: dict | None = None) -> HoldInfo:
    f = tools.flag("pause.hold")
    if not f.exists:
        return HoldInfo(False)
    c = _cfg(cfg)
    r = hold_reason(f.text)
    return HoldInfo(True, r, f.text, f.age_min, float(c["max_age_min"].get(r, c["default_max_age_min"])))


def write_hold(tools, reason: str) -> None:
    """Write pause.hold with `reason` - but never replace a danger hold (alarm/gefahr) with a weaker reason."""
    cur = tools.flag("pause.hold")
    if cur.exists and hold_reason(cur.text) in DANGER_REASONS and reason not in DANGER_REASONS:
        return
    tools.write_flag("pause.hold", reason)


def release_hold(tools, reasons=TRADE_REASONS) -> bool:
    """Delete pause.hold only if its reason is one of `reasons` (the trade must never lift an alarm hold)."""
    cur = tools.flag("pause.hold")
    if not cur.exists or hold_reason(cur.text) not in reasons:
        return False
    return tools.delete_flag("pause.hold")


def danger_reason(tools, cfg: dict | None = None) -> str:
    """Why the game is in a danger state ('' = none): danger hold, siege.flag or a fresh alert.flag."""
    c = _cfg(cfg)
    h = tools.flag("pause.hold")
    if h.exists and hold_reason(h.text) in DANGER_REASONS:
        return f"pause.hold '{h.text[:30]}'"
    if tools.flag("siege").exists:
        return "siege.flag"
    a = tools.flag("alert")
    if a.exists and (a.age_min is None or a.age_min < float(c["alert_active_min"])):
        return "alert.flag"
    return ""


def handel_aktiv(tools, cfg: dict | None = None) -> bool:
    """Companion trade automaton `claude/handelauto` (Lua) runs: `handel_aktiv.flag` in the tools folder, refreshed every
    20 s, younger than holds.handel_aktiv_max_min. Its trade hold is then never stale (it deletes it itself)."""
    c = _cfg(cfg)
    f = tools.flag("handel_aktiv")
    return bool(f.exists and f.age_min is not None and f.age_min < float(c["handel_aktiv_max_min"]))


def trade_active(store) -> bool:
    """A trade automaton (manual `trade` or the caravan autopilot) is between IDLE and its end."""
    states = [(store.get("trade.flow") or {}).get("state"),
              ((store.get("caravan.state") or {}).get("flow") or {}).get("state")]
    return any(s in _ACTIVE_TRADE for s in states)


def stale_hold(tools, store=None, *, danger: bool = False, cfg: dict | None = None) -> HoldInfo | None:
    """The hold if it is stale, else None. `danger` = the caller's own danger signal (e.g. snapshot.danger); siege.flag
    and a fresh alert.flag count as danger as well. The hold itself never counts as its own justification."""
    c = _cfg(cfg)
    h = hold_info(tools, c)
    if not h.exists or h.age_min is None or h.age_min <= (h.max_age_min or 0):
        return None
    if h.reason in TRADE_REASONS and handel_aktiv(tools, c):
        return None
    if h.reason in DANGER_REASONS:
        a = tools.flag("alert")
        if danger or tools.flag("siege").exists or \
                (a.exists and a.age_min is not None and a.age_min < float(c["alert_active_min"])):
            return None
    if h.reason in TRADE_REASONS and store is not None and trade_active(store) and \
            h.age_min <= float(c["trade_active_max_min"]):
        return None
    return h


def stale_text(h: HoldInfo, paused: bool | None = None) -> str:
    why = "no active danger" if h.reason in DANGER_REASONS else (
        "no running trade" if h.reason in TRADE_REASONS else "no owner")
    tail = " - game is frozen" if paused is not False else " - the pause guard keeps pausing the game"
    return (f"pause.hold stale (age {int(h.age_min or 0)} min, reason \"{h.reason or '?'}\", {why}){tail}; "
            f"delete tools/pause.hold if nothing needs the pause")


def run_helper(cmd: str, tools) -> tuple[bool, str]:
    """Execute a local trade command ('HELPER hold trade' / 'HELPER release_hold'). Returns (ok, text)."""
    parts = cmd.split()
    if parts[:2] == ["HELPER", "hold"] and len(parts) == 3:
        write_hold(tools, parts[2])
        h = tools.flag("pause.hold")
        return True, f"pause.hold '{h.text}'"
    if parts == ["HELPER", "release_hold"]:
        done = release_hold(tools)
        h = tools.flag("pause.hold")
        return True, ("pause.hold deleted" if done else
                      (f"pause.hold '{h.text}' kept (not owned by the trade)" if h.exists else "no pause.hold"))
    return False, f"unknown helper command: {cmd}"
