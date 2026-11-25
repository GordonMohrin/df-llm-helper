"""`dfllm wait --until-interrupt` and `dfllm ack` (FR-53): the interrupt channel of the kernel's reflex module.

The kernel writes <save>/alarm.txt in the step an interrupt (schema.INTERRUPTS) is emitted, and on every ack or DEFCON
change (rewritten in place):
    DEFCON <n> | mode <MODE> | unacked <k>[ (oldest <s> s)] | last <n> | ack <n> | lockdown <why (acts)|off>[ | eta ~<t> t]
    <n>\\t<wall>\\t<tick>\\t<TYPE>\\t<acked|unacked|default|far>\\t<msg>    (one line per recent interrupt, oldest first;
                                                                    far = no default: its unit is far, Run 11; a DEATHS_3PLUS at threat 0, BUG-108)
`wait` returns at once while interrupts stand unacked, else as soon as a new one appears (alarm.txt or, as a
fallback, an interrupt type in events.jsonl), so an LLM never sits in a long blocking call: keep --timeout short
(default 15 s) and call it again. `ack` sends the inbox verb `ack {n?}`; an interrupt left unacked for the kernel's
ack_timeout_s (config/reflex.json) gets its lockdown default from the kernel itself.

Neuausrichtung 1 / P3 (docs/v2/NEU1-wecken.md, BUG-792): `wait` returns on more than the interrupts (config/wake.json
`wait`, `act` true): on every class-A event except `quiet_types` and DECISION_NEEDED ids in `quiet_decisions` (unknown
ones wake: fail closed) newer than the cursor <save>/.wait.json (what an earlier wait has looked at: an event that came
while the player was busy is said at the next call), and on three reasons of its own: DEADMAN (the kernel paused the game,
no live session), FOLLOW_OFF, KERNEL_STALE. One key (type, decision id) wakes at most once per `repeat_s`. While it
blocks, `wait` refreshes the session heartbeat (dfpilot/session.py) every SESSION_EVERY_S.
"""
from __future__ import annotations

import re
import time
from pathlib import Path
from typing import Callable

from . import files, schema, session

ALARM = "alarm.txt"
WAIT_TIMEOUT_S = 15.0
CURSOR = ".wait.json"              # P3: {v, n: newest event n a wait has looked at, said: {key: wall}} (Python-private)
SESSION_EVERY_S = 10.0             # P3: a session blocked in `wait` is alive (<< deadman.max_ticks at 1000 t/s)
SYS_EVERY_S = 2.0                  # P3: how often the follow / kernel / pause checks run while waiting
SAID_KEEP_S = 86400                # P3: keys older than this leave the cursor (bounded file)
MAX_LINES = 8
_HEAD = re.compile(r"^DEFCON (\d)\b")
_ACK = re.compile(r"\| ack (\d+)\b")


def read_alarm(save_dir: Path, max_tick: int | None = None) -> dict | None:
    """{defcon, head, ack, items: [{n, wall, tick, type, status, msg}]} from <save>/alarm.txt; None if missing or torn.
    BUG-121: with max_tick, items stamped after it belong to a discarded timeline (an older save was loaded): they are left
    out and counted in `ignored`."""
    try:
        text = (Path(save_dir) / ALARM).read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    lines = text.split("\n")
    m = _HEAD.match(lines[0]) if lines else None
    if not m:
        return None
    a = _ACK.search(lines[0])
    items = []
    for ln in lines[1:]:
        parts = ln.split("\t", 5)
        if len(parts) == 6 and parts[0].isdigit():
            try:
                items.append({"n": int(parts[0]), "wall": int(parts[1]), "tick": int(parts[2]), "type": parts[3],
                              "status": parts[4], "msg": parts[5]})
            except ValueError:
                continue
    doc = {"defcon": int(m.group(1)), "head": lines[0], "ack": int(a.group(1)) if a else 0, "items": items}
    if max_tick is not None:
        keep = [it for it in items if it["tick"] <= max_tick]
        if len(keep) != len(items):
            doc["items"], doc["ignored"] = keep, len(items) - len(keep)
    return doc


def fmt_item(it: dict) -> str:
    return f"INTERRUPT #{it['n']} {it['type']} ({it.get('status', 'unacked')}): {it.get('msg', '')}"


def wait_interrupt(save_dir: Path, since: int | None = None, timeout: float = WAIT_TIMEOUT_S, poll: float = 0.2,
                   clock: Callable[[], float] = time.monotonic,
                   sleep: Callable[[float], None] = time.sleep) -> tuple[list[dict], dict | None]:
    """Interrupts with n > since (default: the kernel's acked n, else the newest event now) as soon as there are any,
    or [] after `timeout` seconds. Returns (items, alarm)."""
    save_dir = Path(save_dir)
    cap = files.tick_cap(save_dir)                         # BUG-121: nothing stamped after the clock
    alarm = read_alarm(save_dir, cap)
    base = since if since is not None else (alarm["ack"] if alarm else files.last_event_n(save_dir))
    tail = files.EventTail(save_dir, None, tick_fn=lambda: files.current_tick(save_dir))   # events from now on (the fallback channel)
    t0 = clock()
    while True:
        alarm = read_alarm(save_dir, files.tick_cap(save_dir))
        new = [it for it in (alarm["items"] if alarm else []) if it["n"] > base]
        seen = {it["n"] for it in new}
        for e in tail.poll():
            if e.get("type") in schema.INTERRUPTS and e.get("n", 0) > base and e["n"] not in seen:
                new.append({"n": e["n"], "wall": 0, "tick": e.get("tick", 0), "type": e["type"], "status": "unacked",
                            "msg": e.get("msg", "")})
        if new:
            return sorted(new, key=lambda it: it["n"]), alarm
        if clock() - t0 >= timeout:
            return [], alarm
        sleep(poll)


# ---------------------------------------------------------------- P3: the wake list
def acts(e: dict, cfg: dict) -> bool:
    """A class-A event the player can act on: not an interrupt (their own channel above), not a quiet type, not a quiet
    decision. Unknown types and decision ids wake (fail closed)."""
    if e.get("cls") != "A" or not isinstance(e.get("type"), str):
        return False
    t = e["type"]
    if t in schema.INTERRUPTS or t == files.TIMELINE_RESET or t in cfg["quiet_types"]:
        return False
    if t == "DECISION_NEEDED":
        d = e.get("d") if isinstance(e.get("d"), dict) else {}
        return d.get("id") not in cfg["quiet_decisions"]
    return True


def wake_key(e: dict) -> str:
    """The repeat key: the type, for a decision the type and its id; plus the units the event names (d.unit / d.units), so a
    second patient or thirsty dwarf within repeat_s wakes again while the same unit's repeat does not."""
    d = e.get("d") if isinstance(e.get("d"), dict) else {}
    k = str(e.get("type"))
    if e.get("type") == "DECISION_NEEDED" and isinstance(d.get("id"), str):
        k = f"DECISION_NEEDED:{d['id']}"
    units = d.get("units") if isinstance(d.get("units"), list) else [d.get("unit")]
    ids = sorted({u for u in units if isinstance(u, int) and not isinstance(u, bool)})
    if ids:
        k += "@" + ",".join(str(u) for u in ids[:8])
    return k


def read_cursor(save_dir: Path) -> dict:
    doc = files.read_json(Path(save_dir) / CURSOR, retry=False)
    if not isinstance(doc, dict) or doc.get("v") != 2:
        return {"v": 2, "n": None, "said": {}}
    n = doc.get("n")
    said = doc.get("said") if isinstance(doc.get("said"), dict) else {}
    return {"v": 2, "n": n if isinstance(n, int) and not isinstance(n, bool) else None,
            "said": {str(k): float(v) for k, v in said.items() if isinstance(v, (int, float)) and not isinstance(v, bool)}}


def write_cursor(save_dir: Path, cur: dict, now: float) -> None:
    doc = {"v": 2, "n": cur.get("n"), "said": {k: v for k, v in (cur.get("said") or {}).items() if now - v < SAID_KEEP_S}}
    try:
        files.write_json_atomic(Path(save_dir) / CURSOR, doc)
    except OSError:
        pass


_POPUP_SEEN: dict[str, float] = {}      # NEU7 BUG-859: save dir -> wall time this process first saw the popup pause


def _popup_text(save_dir: Path) -> str:
    """The newest popup text the kernel logged (PAUSED_BY_DF / POPUP_GONE), '' when none (a courtesy to the wake line)."""
    try:
        for e in reversed(files.tail_events(save_dir, 0, limit=3, types={"PAUSED_BY_DF", "POPUP_GONE"})):
            d = e.get("d") if isinstance(e.get("d"), dict) else {}
            t = d.get("popup") or d.get("text")
            if isinstance(t, str) and t:
                return f': "{t[:60]}"'
    except Exception:                                      # noqa: BLE001
        pass
    return ""


def sys_reasons(save_dir: Path, cfg: dict, now: float) -> list[dict]:
    """P3: the wake reasons `wait` sees itself (not kernel events): KERNEL_STALE (the kernel heartbeat is old: DF hangs or is
    closed), DEADMAN (the game stands paused by the dead-man switch), FOLLOW_OFF (follow does not beat for this save)."""
    hb, age = files.read_heartbeat(save_dir, now)
    if age is None or age > cfg["kernel_stale_s"]:
        why = "no kernel heartbeat" if age is None else f"kernel heartbeat {int(age)} s old"
        return [{"type": "KERNEL_STALE", "key": "KERNEL_STALE", "n": 0,
                 "msg": why + ": DF hangs, is closed or the fort is not loaded"}]   # a dead kernel says nothing else
    out = []
    state = files.read_state(save_dir) or {}
    owners = state.get("owners") if isinstance(state.get("owners"), dict) else {}
    if owners.get("pause") == "deadman" and (hb or {}).get("paused"):
        out.append({"type": "DEADMAN", "key": "DEADMAN", "n": 0,
                    "msg": "the game stands paused by the dead-man switch (no live session for a while)"})
    # NEU7 BUG-859 (Run 17 i2: a noble-claim popup paused the game for 3 real minutes and `wait` slept on): the game stands paused by a POPUP
    # (state owners.pause == popup) for popup_s real seconds in this process -> one POPUP_PAUSE wake (0 = at once; popup_s from config wake.json)
    key = str(save_dir)
    if owners.get("pause") == "popup" and (hb or {}).get("paused"):
        since = _POPUP_SEEN.setdefault(key, now)
        if now - since >= cfg.get("popup_s", 20):
            out.append({"type": "POPUP_PAUSE", "key": "POPUP_PAUSE", "n": 0,
                        "msg": f"the game stands paused by a popup ({int(now - since)} s seen)" + _popup_text(save_dir)})
    else:
        _POPUP_SEEN.pop(key, None)
    if cfg["follow_check"]:
        off = files.follow_off(save_dir, now)
        if off and "OFF" in off:
            out.append({"type": "FOLLOW_OFF", "key": "FOLLOW_OFF", "n": 0, "msg": off})
    return out


SYS_NEXT = {"DEADMAN": "dfllm cmd resume; then dfllm brief",
            "POPUP_PAUSE": "dfllm cmd resume (the reply names the popup it read; it refuses threat or curse popups: then tell Gordon); then dfllm status", "KERNEL_STALE": "dfllm doctor",
            "FOLLOW_OFF": "dfllm follow --takeover (in the background); then dfllm status"}


def wait_wake(save_dir: Path, timeout: float = WAIT_TIMEOUT_S, poll: float = 0.2, since: int | None = None,
              cfg: dict | None = None, clock: Callable[[], float] = time.monotonic, wall: Callable[[], float] = time.time,
              sleep: Callable[[float], None] = time.sleep) -> tuple[list[dict], dict | None]:
    """P3: (items, alarm). Items: unacked interrupts (kind 'interrupt', as wait_interrupt), class-A events the player can act
    on newer than the cursor (kind 'act', at most one per key and repeat_s) and the wait's own reasons (kind 'sys'). Returns
    as soon as there are any, or ([], alarm) after `timeout` seconds; the cursor moves past every event looked at."""
    save_dir = Path(save_dir)
    full = session.config()
    cfg = cfg or full["wait"]
    t0 = clock()
    session.touch(save_dir, "wait", wall(), full)
    beat, sys_t = t0, -1e18
    cap = files.tick_cap(save_dir)
    alarm = read_alarm(save_dir, cap)
    base = since if since is not None else (alarm["ack"] if alarm else files.last_event_n(save_dir))
    cur = read_cursor(save_dir)
    tail = files.EventTail(save_dir, None, tick_fn=lambda: files.current_tick(save_dir))   # new events from now on
    last = files.last_event_n(save_dir)
    start = cur["n"]
    if start is None or start > last or last - start > cfg["backlog"]:
        start = last                                       # first use, an older save loaded, or far behind: no replay
    backlog = [e for e in files.tail_events(save_dir, since_n=start, cls="A", max_tick=cap) if e["n"] <= last]
    cur["n"] = last
    while True:
        now = wall()
        alarm = read_alarm(save_dir, files.tick_cap(save_dir))
        items = [dict(it, kind="interrupt") for it in (alarm["items"] if alarm else []) if it["n"] > base]
        seen = {it["n"] for it in items}
        evs, backlog = backlog + tail.poll(), []
        for e in evs:
            if e.get("type") in schema.INTERRUPTS and e.get("n", 0) > base and e["n"] not in seen:
                items.append({"n": e["n"], "wall": 0, "tick": e.get("tick", 0), "type": e["type"], "status": "unacked",
                              "msg": e.get("msg", ""), "kind": "interrupt"})
                seen.add(e["n"])
            cur["n"] = max(cur["n"] or 0, e.get("n", 0))
        if cfg["act"]:
            for e in evs:
                k = wake_key(e)
                if not acts(e, cfg) or now - cur["said"].get(k, -1e18) < cfg["repeat_s"]:
                    continue
                cur["said"][k] = now
                items.append({"n": e["n"], "tick": e.get("tick", 0), "type": e["type"], "msg": e.get("msg", ""),
                              "kind": "act", "e": e, "key": k})
            if clock() - sys_t >= SYS_EVERY_S:
                sys_t = clock()
                for r in sys_reasons(save_dir, cfg, now):
                    if now - cur["said"].get(r["key"], -1e18) >= cfg["repeat_s"]:
                        cur["said"][r["key"]] = now
                        items.append(dict(r, kind="sys"))
        if items or clock() - t0 >= timeout:
            if cfg["act"]:
                write_cursor(save_dir, cur, now)
            return items, alarm
        if clock() - beat >= SESSION_EVERY_S:
            beat = clock()
            session.touch(save_dir, "wait", now, full)
        sleep(poll)


def fmt_wake(it: dict, save_dir: Path | None = None) -> str:
    """One line per wake reason: the interrupt line as before, `WAKE #n TYPE: msg | next: ...` for the rest."""
    if it.get("kind") == "interrupt":
        return fmt_item(it)
    if it.get("kind") == "sys":
        return f"WAKE {it['type']}: {it['msg']} | next: {SYS_NEXT.get(it['type'], 'dfllm brief')}"
    from .events import clip
    try:
        from .wake import next_hint
        hint = next_hint(it["type"], it.get("e") or {}, save_dir)
    except Exception:                                      # noqa: BLE001 - a hint must never lose the wake
        hint = "dfllm brief"
    return clip(f"WAKE #{it['n']} {it['type']}: {it.get('msg', '')} | next: {hint}", 150)


def run_wait(args, save_dir: Path) -> int:
    cfg = session.config()["wait"]
    if not cfg["act"]:
        return run_wait_interrupts(args, save_dir)
    items, alarm = wait_wake(save_dir, timeout=max(0.0, args.timeout), since=args.since, cfg=cfg)
    head = alarm["head"] if alarm else "DEFCON ? (no alarm.txt: kernel reflex module not running)"
    if not items:
        print(f"no interrupt in {args.timeout:g} s | {head}")
        return 1
    order = {"sys": 0, "interrupt": 1, "act": 2}
    items.sort(key=lambda it: (order.get(it.get("kind"), 3), it.get("n", 0)))
    for it in items[:MAX_LINES]:
        print(fmt_wake(it, save_dir))
    if len(items) > MAX_LINES:
        ns = [it["n"] for it in items[MAX_LINES:] if it.get("n")]
        print(f"+{len(items) - MAX_LINES} more" + (f": dfllm events --cls A --since {min(ns) - 1}" if ns else ""))
    print(head)
    ints = [it for it in items if it.get("kind") == "interrupt"]
    if ints:
        print(f"next: dfllm ack (up to #{ints[-1]['n']}); dfllm status. Unacked interrupts get the kernel's lockdown "
              "default after its ack timeout")
    files.log_cli(save_dir, "cli", "wait", {"timeout": args.timeout},
                  "woke: " + ", ".join(f"{it['type']}#{it.get('n', 0)}" for it in items[:12]))
    return 0


def run_wait_interrupts(args, save_dir: Path) -> int:
    """The FR-53 wait (config/wake.json wait.act false): interrupts only."""
    items, alarm = wait_interrupt(save_dir, since=args.since, timeout=max(0.0, args.timeout))
    head = alarm["head"] if alarm else "DEFCON ? (no alarm.txt: kernel reflex module not running)"
    if not items:
        print(f"no interrupt in {args.timeout:g} s | {head}")
        return 1
    for it in items:
        print(fmt_item(it))
    print(head)
    print(f"next: dfllm ack (up to #{items[-1]['n']}); dfllm status. Unacked interrupts get the kernel's lockdown "
          "default after its ack timeout")
    return 0


def run_ack(args, save_dir: Path) -> int:
    from .cmd import EXIT_NOREPLY, EXIT_OK, EXIT_REFUSED, fmt_reply, send
    a = {"n": args.n} if args.n is not None else {}
    try:
        cmd_id, reply = send(save_dir, "ack", a, by=args.by, wait_s=args.wait)
    except schema.SchemaError as e:
        print("refused (not sent): " + "; ".join(e.errors[:5]))
        return 2
    print(fmt_reply(cmd_id, "ack", reply, save_dir))
    if reply is None:
        return EXIT_NOREPLY if args.wait > 0 else EXIT_OK
    return EXIT_OK if reply.get("ok") else EXIT_REFUSED


def add_parsers(sub) -> None:
    p = sub.add_parser("wait", help="block until an interrupt (FR-53) or --timeout; returns at once while some stand "
                                    "unacked")
    p.add_argument("--until-interrupt", action="store_true", default=True,
                   help="the only wait mode (kept explicit in scripts and prompts)")
    p.add_argument("--timeout", type=float, default=WAIT_TIMEOUT_S, help="seconds (default 15; keep calls short)")
    p.add_argument("--since", type=int, help="report interrupts with event n > N (default: everything not acked)")
    p = sub.add_parser("ack", help="acknowledge interrupts up to --n (default: all) so the kernel keeps its hands off")
    p.add_argument("--n", type=int, help="highest interrupt event number seen (default: the newest)")
    p.add_argument("--by", default="cli", choices=["cli", "llm", "gordon"])
    p.add_argument("--wait", type=float, default=5.0, help="seconds to wait for the kernel's reply")
