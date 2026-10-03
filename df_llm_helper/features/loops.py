"""FEATURE-006: `python -m df_llm_helper loops list|stop|clean|wrap` (registry: df_llm_helper/loops.py).

- list [--json]         every registered loop: pid, uptime, heartbeat age, marks OK/STALE/DEAD/DUPLICATE (exit 1 on a
                        problem)
- stop <name> [--pid N] [--kill] [--wait S]
                        stop request (stop file, the loop ends after its current pass); --kill terminates the process
                        when it does not end within --wait seconds (only when its command line still matches the lock)
- clean                 remove locks of processes that are gone
- wrap <name> [--interval S] --cmd "<command ...>"
                        run a foreign loop (e.g. holdguard.sh) under the registry: lock + heartbeat while the child
                        runs, `loops stop <name>` terminates the child
check hook: duplicate and hanging loops as warning lines (the digest and wake report them too).
Manages only helper-own processes; read only unless stop/clean/wrap is called.
"""
from __future__ import annotations

import json
import subprocess
import sys
import time

from .. import loops as L

KEY = "loops"
DEFAULTS = dict(L.DEFAULTS)

__all__ = ["KEY", "DEFAULTS", "register", "check_hook", "cmd_loops"]


def _cfg_tools(args):
    from ..config import load_config
    cfg = load_config(args.config)
    return cfg, cfg.path("tools"), {**DEFAULTS, **(cfg.get(KEY, {}) or {})}


def cmd_loops(args) -> int:
    cfg, tools, c = _cfg_tools(args)
    if args.action == "list":
        infos = L.scan(tools, c)
        now = time.time()
        if args.json:
            print(json.dumps({"loops": [i.to_dict() for i in infos], "problems": L.problems(infos)},
                             ensure_ascii=False))
        elif not infos:
            print(f"no registered loops ({L.loops_dir(tools)})")
        else:
            for i in infos:
                print(i.line(now))
            for p in L.problems(infos):
                print("! " + p)
        return 1 if any(i.marks for i in infos) else 0
    if args.action == "clean":
        out = L.clean(tools, c)
        print("\n".join(out) or "nothing to clean")
        return 0
    if not args.name:
        raise ValueError(f"loops {args.action} needs a loop name (see: python -m df_llm_helper loops list)")
    L.valid_name(args.name)
    if args.action == "stop":
        out = L.stop(tools, args.name, c, pid=args.pid, kill=args.kill, wait_s=args.wait)
        print("\n".join(out))
        return 1 if any("did not stop" in ln or "NOT killed" in ln for ln in out) else 0
    # wrap
    import os
    import shlex
    cmd = shlex.split(args.cmd or "", posix=os.name != "nt")
    if not cmd:
        raise ValueError('loops wrap needs a command: loops wrap <name> --cmd "<command ...>"')
    interval = float(args.interval)
    with L.LoopLock(tools, args.name, " ".join(cmd), interval_s=interval, cfg=c) as lk:
        for w in lk.warnings:
            print(w, file=sys.stderr, flush=True)
        child = subprocess.Popen(cmd)
        lk.child_pid = child.pid
        lk._last_beat = 0.0
        try:
            while child.poll() is None:
                if not lk.beat():
                    child.terminate()
                    try:
                        child.wait(10)
                    except subprocess.TimeoutExpired:
                        child.kill()
                    print(f"loop {args.name}: stop requested, child {child.pid} ended", flush=True)
                    return 0
                time.sleep(min(interval, 2.0))
        finally:
            if child.poll() is None:
                child.terminate()
        return int(child.returncode or 0)


def register(sub) -> None:
    import argparse
    s = sub.add_parser("loops", help="registry of background loops (lockfile + heartbeat): list|stop|clean|wrap",
                       description="Registry of the helper's background loops (FEATURE-006).",
                       epilog="examples:\n  python -m df_llm_helper loops list\n  python -m df_llm_helper loops list --json"
                              "\n  python -m df_llm_helper loops stop siege\n  python -m df_llm_helper loops stop wake "
                              "--pid 4711 --kill\n  python -m df_llm_helper loops wrap holdguard --cmd 'bash holdguard.sh'",
                       formatter_class=argparse.RawDescriptionHelpFormatter)
    s.add_argument("action", choices=["list", "stop", "clean", "wrap"])
    s.add_argument("name", nargs="?", help="stop/wrap: loop name (waechter, wake, autopilot, guard, caravan, siege, ...)")
    s.add_argument("--cmd", default=None, help="wrap: the command to run, one quoted string (e.g. \"bash holdguard.sh\")")
    s.add_argument("--json", action="store_true", help="list: JSON output")
    s.add_argument("--pid", type=int, default=None, help="stop: only this instance (duplicates)")
    s.add_argument("--kill", action="store_true", help="stop: terminate the process if it does not end in time")
    s.add_argument("--wait", type=float, default=None, help="stop: seconds to wait for the loop (default 10)")
    s.add_argument("--interval", type=float, default=30, help="wrap: heartbeat seconds (default 30)")
    s.set_defaults(fn=cmd_loops)


def check_hook(pilot, report, dry: bool) -> list[str]:
    c = {**DEFAULTS, **(pilot.cfg.get(KEY, {}) or {})}
    return [ln for ln in L.problems(L.scan(pilot.tools.path, c)) if " is gone" not in ln]
