"""Drive the in-game embark helper tools/embark/embark.lua (before `dfllm adopt`).

    python tools/embark/embark.py state | check | screen [NAME] | status | stop
    python tools/embark/embark.py newgame [--world Zilirr]
    python tools/embark/embark.py scan WX,WY[,LX,LY] ...
    python tools/embark/embark.py embark WX,WY[,LX,LY] [--waive ID ...] [--play-now] [--allow-unspent]
    python tools/embark/embark.py prep [--play-now] [--allow-unspent]

A run costs ONE dfhack-run call (`embark.lua run <spec>`); afterwards only
<DF>/dfllm-runtime/embark/status.json is read. Stdlib only. Env DFLLM_DF = DF folder.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
LUA = HERE / "embark.lua"
DEFAULT_DF = Path(r"E:\Program Files (x86)\Steam\steamapps\common\Dwarf Fortress")
ORDER = {"ok": 0, "review": 1, "reject": 2}
# criteria that may be 'unknown' and waived one by one (= checklist.lua C.WAIVABLE)
WAIVABLE = ("old_sites", "dark_fortress", "evil", "savagery", "trees", "water", "aquifer", "soil",
            "temperature", "size")


def df_dir() -> Path:
    return Path(os.environ.get("DFLLM_DF") or DEFAULT_DF)


def out_dir(df: Path | None = None) -> Path:
    return (df or df_dir()) / "dfllm-runtime" / "embark"


def dfhack_cmd(args: list[str], df: Path | None = None) -> list[str]:
    return [str((df or df_dir()) / "hack" / "dfhack-run.exe"), "lua", "-f", LUA.as_posix(), *args]


def call(args: list[str], df: Path | None = None, timeout: float = 60) -> str:
    r = subprocess.run(dfhack_cmd(args, df), capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        raise SystemExit(f"dfhack-run failed ({r.returncode}): {r.stderr.strip() or r.stdout.strip()}")
    return r.stdout


def parse_site(text: str) -> list[int]:
    """'26,10' or '26,10,6,6' -> ints (world tile, optional local tile 0-15)."""
    parts = [int(p) for p in text.split(",")]
    if len(parts) not in (2, 4) or any(p < 0 for p in parts) or (len(parts) == 4 and max(parts[2:]) > 15):
        raise ValueError(f"site must be WX,WY or WX,WY,LX,LY with LX,LY 0-15: {text!r}")
    return parts


def make_spec(mode: str, *, run_id: str | None = None, world: str | None = None, cands=None, site=None,
              waive=(), play_now: bool = False, allow_unspent: bool = False,
              now: float | None = None) -> dict:
    spec = {"v": 2, "id": run_id or f"{mode}{int(now if now is not None else time.time())}", "mode": mode}
    if mode == "newgame":
        spec["world"] = world or "Zilirr"
    elif mode == "scan":
        if not cands:
            raise ValueError("scan needs at least one site")
        spec["cands"] = [list(c) for c in cands]
    elif mode == "embark":
        bad = sorted(set(waive) - set(WAIVABLE))
        if bad:
            raise ValueError(f"cannot waive {bad}; known: {list(WAIVABLE)}")
        spec["site"] = list(site)
        spec["waive"] = sorted(set(waive))
    elif mode != "prep":
        raise ValueError(f"unknown mode {mode}")
    if mode in ("embark", "prep"):
        spec.update(play_now=play_now, allow_unspent=allow_unspent)
    return spec


def write_spec(spec: dict, out: Path) -> Path:
    out.mkdir(parents=True, exist_ok=True)
    final = out / f"spec-{spec['id']}.json"
    tmp = out / f".spec-{spec['id']}.json.tmp"
    tmp.write_text(json.dumps(spec), encoding="utf-8")
    os.replace(tmp, final)
    return final


def read_status(out: Path) -> dict | None:
    """status.json is rewritten in place by Lua; a torn read is retried once (CONTRACTS 8)."""
    for attempt in range(2):
        try:
            return json.loads((out / "status.json").read_text(encoding="utf-8"))
        except FileNotFoundError:
            return None
        except (OSError, ValueError):
            if attempt == 0:
                time.sleep(0.05)
    return None


def wait(run_id: str, out: Path, timeout_s: float, poll_s: float = 1.0,
         clock=time.monotonic, sleep=time.sleep, echo=print) -> dict | None:
    """Poll status.json until run_id is no longer running; echo each new step once."""
    end, last = clock() + timeout_s, None
    while True:
        doc = read_status(out)
        if doc and doc.get("id") == run_id:
            step = (doc.get("step"), doc.get("state"))
            if step != last:
                echo(f"  [{doc.get('i')}/{doc.get('n')}] {doc.get('step')} ({doc.get('live')}) {doc.get('msg', '')}")
                last = step
            if doc.get("state") != "running":
                return doc
        if clock() >= end:
            return doc
        sleep(poll_s)


def summarize(doc: dict | None) -> list[str]:
    if not doc:
        return ["no status (is DF running and the run started?)"]
    lines = [f"{doc['id']}: {doc['state']} at {doc.get('step') or '-'} ({doc.get('i')}/{doc.get('n')}) {doc.get('msg', '')}"]
    rows = sorted(doc.get("results") or [], key=lambda r: (ORDER.get(r.get("verdict"), 3), -r.get("score", 0)))
    for r in rows:
        w, e, s = r.get("world") or ["?", "?"], r.get("emb") or ["?", "?"], r.get("size") or ["?", "?"]
        lines.append(f"  {r['tag']}: world {w[0]},{w[1]} rect {e[0]},{e[1]} {s[0]}x{s[1]} -> {r['verdict']} {r.get('score')}"
                     f" fail={','.join(r.get('fails') or []) or '-'} warn={','.join(r.get('warns') or []) or '-'}"
                     f" unknown={','.join(r.get('unknown') or []) or '-'}")
    for w in doc.get("warnings") or []:
        lines.append(f"  warning: {w}")
    return lines


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="vanilla-UI embark helper (see tools/embark/README.md)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("state", "check", "status", "stop"):
        sub.add_parser(name)
    sp = sub.add_parser("screen")
    sp.add_argument("name", nargs="?")
    sp = sub.add_parser("newgame")
    sp.add_argument("--world", default="Zilirr", help="ASCII part of the world name (accents read as '?')")
    sp = sub.add_parser("scan")
    sp.add_argument("sites", nargs="+", type=parse_site)
    for name in ("embark", "prep"):
        sp = sub.add_parser(name)
        if name == "embark":
            sp.add_argument("site", type=parse_site)
            sp.add_argument("--waive", action="append", default=[], choices=WAIVABLE, metavar="ID",
                            help="accept this one criterion although the panel did not show it (checked by eye); "
                                 "repeatable; " + ", ".join(WAIVABLE))
        sp.add_argument("--play-now", action="store_true", help="fallback: DF defaults, skip Prepare carefully")
        sp.add_argument("--allow-unspent", action="store_true")
    for p in sub.choices.values():
        p.add_argument("--timeout", type=float, default=1800, help="seconds to wait for a run")
        p.add_argument("--no-wait", action="store_true")
    a = ap.parse_args(argv)
    out = out_dir()
    if a.cmd in ("state", "check", "status", "stop"):
        print(call([a.cmd]).strip())
        return 0
    if a.cmd == "screen":
        print(call(["screen"] + ([a.name] if a.name else [])).rstrip())
        return 0
    spec = make_spec(a.cmd, world=getattr(a, "world", None), cands=getattr(a, "sites", None),
                     site=getattr(a, "site", None), waive=getattr(a, "waive", ()),
                     play_now=getattr(a, "play_now", False), allow_unspent=getattr(a, "allow_unspent", False))
    path = write_spec(spec, out)
    print(call(["run", path.as_posix()]).strip())
    if a.no_wait:
        return 0
    doc = wait(spec["id"], out, a.timeout)
    print("\n".join(summarize(doc)))
    return 0 if doc and doc.get("state") == "done" else 1


if __name__ == "__main__":
    sys.exit(main())
