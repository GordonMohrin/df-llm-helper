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
"""
from __future__ import annotations

import re
import time
from pathlib import Path
from typing import Callable

from . import files, schema

ALARM = "alarm.txt"
WAIT_TIMEOUT_S = 15.0
_HEAD = re.compile(r"^DEFCON (\d)\b")
_ACK = re.compile(r"\| ack (\d+)\b")


def read_alarm(save_dir: Path) -> dict | None:
    """{defcon, head, ack, items: [{n, wall, tick, type, status, msg}]} from <save>/alarm.txt; None if missing or torn."""
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
    return {"defcon": int(m.group(1)), "head": lines[0], "ack": int(a.group(1)) if a else 0, "items": items}


def fmt_item(it: dict) -> str:
    return f"INTERRUPT #{it['n']} {it['type']} ({it.get('status', 'unacked')}): {it.get('msg', '')}"


def wait_interrupt(save_dir: Path, since: int | None = None, timeout: float = WAIT_TIMEOUT_S, poll: float = 0.2,
                   clock: Callable[[], float] = time.monotonic,
                   sleep: Callable[[float], None] = time.sleep) -> tuple[list[dict], dict | None]:
    """Interrupts with n > since (default: the kernel's acked n, else the newest event now) as soon as there are any,
    or [] after `timeout` seconds. Returns (items, alarm)."""
    save_dir = Path(save_dir)
    alarm = read_alarm(save_dir)
    base = since if since is not None else (alarm["ack"] if alarm else files.last_event_n(save_dir))
    tail = files.EventTail(save_dir, None)                 # events from now on (the fallback channel)
    t0 = clock()
    while True:
        alarm = read_alarm(save_dir)
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


def run_wait(args, save_dir: Path) -> int:
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
