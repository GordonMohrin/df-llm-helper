"""Levers and what they move (`python -m df_llm_helper lever list|pull|set`), BUG-427.

- list: `claude/pilot_lever list` (read only): every lever with the REAL state of the linked buildings, read from the
        target building itself (bridge `gate_flags.raised` -> raised/lowered, floodgate/door/hatch -> closed/open).
        The earlier lever list printed "raised" for every bridge; the night of the second invasion depended on it.
- pull: queues one PullLever job (what the player does with "Pull the lever"). A pull TOGGLES the linked buildings;
        refused while a pull is already queued.
- set:  `--state raised|lowered|open|closed`: pulls only when a linked target is not in that state (no pull when it
        already is, while a pull is queued, while a bridge moves, or when linked targets disagree).
`--file` reads a recorded `pilot_lever list` JSON instead of the game (list only). No check_hook (needs a DF call).
"""
from __future__ import annotations

import json
from pathlib import Path

__all__ = ["KEY", "DEFAULTS", "LIST_CMD", "target_text", "lever_lines", "bridge_states", "set_decision", "register"]

KEY = "lever"
DEFAULTS = {"in_check": False}
LIST_CMD = "claude/pilot_lever list"
STATES = ("raised", "lowered", "open", "closed")
GATES = {"Floodgate", "Door", "Hatch"}


def target_text(t: dict) -> str:
    field = f" ({t['field']})" if t.get("field") else ""
    return f"{t.get('type', '?')} #{t.get('id', '?')} {t.get('state', '?')}{field}"


def lever_lines(data: dict) -> list[str]:
    levers = data.get("levers") or []
    if isinstance(levers, dict):              # an empty Lua table may arrive as {}
        levers = list(levers.values())
    if not levers:
        return ["Levers: none"]
    out = [f"Levers: {len(levers)}"]
    for lv in levers:
        tg = lv.get("targets") or []
        if isinstance(tg, dict):
            tg = list(tg.values())
        linked = ", ".join(target_text(t) for t in tg) or "nothing linked"
        q = f"; {lv['pull_jobs']} pull queued" if int(lv.get("pull_jobs") or 0) else ""
        out.append(f"  lever #{lv.get('id')} ({lv.get('x')},{lv.get('y')},z{lv.get('z')}): {linked}{q}")
    return out


def bridge_states(data: dict) -> dict:
    """{bridge id: state} over all levers (for defense/status readers)."""
    out = {}
    for lv in data.get("levers") or []:
        for t in lv.get("targets") or []:
            if t.get("type") == "Bridge":
                out[t.get("id")] = t.get("state")
    return out


def set_decision(lever: dict, want: str) -> tuple[bool, str]:
    """Python mirror of `pilot_lever set`: (pull?, reason). Pure, for tests and dry runs."""
    if want not in STATES:
        return False, f"unknown state {want!r}"
    if int(lever.get("pull_jobs") or 0):
        return False, "pull already queued"
    kind = "Bridge" if want in ("raised", "lowered") else "gate"
    match = [t for t in lever.get("targets") or []
             if (kind == "Bridge" and t.get("type") == "Bridge") or (kind == "gate" and t.get("type") in GATES)]
    if not match:
        return False, f"no linked target with state {want}"
    if any(t.get("state") in ("moving", "?") for t in match):
        return False, "target moving or state unreadable"
    differ = [t for t in match if t.get("state") != want]
    if not differ:
        return False, f"already {want}"
    if len(differ) < len(match):
        return False, "linked targets disagree (a pull flips all of them)"
    return True, f"pull: {', '.join(target_text(t) for t in differ)} -> {want}"


def _cmd(args) -> int:
    if args.file:
        try:
            data = json.loads(Path(args.file).read_text(encoding="utf-8-sig"))
        except (OSError, ValueError) as e:
            print(f"lever: --file not readable ({e})")
            return 2
        if args.action != "list":
            print("lever: --file only works with list")
            return 2
        print("\n".join(lever_lines(data)))
        return 0
    from ..cli import _pilot          # lazy: no cli import at module level (import cycles)
    from ..client import register_read
    client = _pilot(args).client
    if args.action == "list":
        register_read(LIST_CMD)
        r = client.run(LIST_CMD)
        data = r.json if r.ok and isinstance(r.json, dict) else None
        if not data or not data.get("ok"):
            print(f"lever: {LIST_CMD} not readable (pilot_lever installed?)")
            return 2
        print("\n".join(lever_lines(data)))
        return 0
    if args.id is None:
        print(f"lever {args.action} needs --id <lever building id>")
        return 2
    if args.action == "set" and args.state not in STATES:
        print("lever set needs --state raised|lowered|open|closed")
        return 2
    cmd = f"claude/pilot_lever pull {args.id}" if args.action == "pull" else \
        f"claude/pilot_lever set {args.id} {args.state}"
    r = client.run(cmd)
    j = r.json if r.ok and isinstance(r.json, dict) else None
    if not j:
        print(f"lever: {cmd} failed ({(r.stderr or 'no answer').strip()[:80]})")
        return 2
    lv = j.get("lever") or {}
    tg = ", ".join(target_text(t) for t in lv.get("targets") or []) or "nothing linked"
    if j.get("pulled"):
        print(f"Lever #{args.id}: pull queued ({tg}) - the linked buildings toggle when a dwarf pulls it")
        return 0
    print(f"Lever #{args.id}: not pulled - {j.get('reason') or j.get('error') or '?'} ({tg})")
    return 0 if j.get("ok") else 1


def register(sub) -> None:
    s = sub.add_parser("lever", help="levers: list (real bridge/floodgate/door state), pull, set --state (BUG-427)")
    s.add_argument("action", nargs="?", default="list", choices=["list", "pull", "set"])
    s.add_argument("--id", type=int, default=None, help="pull/set: lever building id")
    s.add_argument("--state", default=None, help="set: raised|lowered (bridges) or open|closed (floodgates/doors)")
    s.add_argument("--file", default=None, help="list: recorded pilot_lever list JSON instead of the game")
    s.set_defaults(fn=_cmd)
