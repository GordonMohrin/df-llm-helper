"""Drive the in-game embark helper tools/embark/embark.lua (before `dfllm adopt`).

    python tools/embark/embark.py state | check | screen [NAME] | status | stop
    python tools/embark/embark.py newgame [--world Zilirr]
    python tools/embark/embark.py scan WX,WY[,LX,LY] ...
    python tools/embark/embark.py embark WX,WY[,LX,LY] [--waive ID ...] [--accept ID ... --reason TEXT]
                                        [--play-now] [--allow-unspent]
    python tools/embark/embark.py prep [--play-now] [--allow-unspent]
    python tools/embark/embark.py load SAVE [--entry TEXT] [--no-stock]    (K2: a saved fort from the title screen)

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
WAIVABLE = ("old_sites", "dark_fortress", "evil", "savagery", "trees", "water", "aquifer", "soil", "stone", "ore",
            "temperature", "size")
# FR-08: criteria that may be accepted although they FAILED, one by one, with a logged reason
# (= checklist.lua C.ACCEPTABLE; never the unreadable panel or a failing warning popup)
ACCEPTABLE = ("old_sites", "dark_fortress", "evil", "savagery", "trees", "water", "aquifer", "soil", "stone", "ore",
              "temperature", "size")
ACCEPT_LOG = "accept.log"


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
              waive=(), accept=(), reason: str | None = None, play_now: bool = False, allow_unspent: bool = False,
              tiles: bool | None = None, now: float | None = None, save: str | None = None,
              entry: str | None = None, stock: bool = True) -> dict:
    spec = {"v": 2, "id": run_id or f"{mode}{int(now if now is not None else time.time())}", "mode": mode}
    if mode == "load":
        name = " ".join(str(save or "").split())
        if not name or "/" in name or "\\" in name or name in (".", ".."):
            raise ValueError(f"load needs a save folder name (no path): {save!r}")
        spec["save"] = name
        if entry:
            spec["entry"] = " ".join(str(entry).split())[:80]
        spec["stock"] = bool(stock)
    elif mode == "newgame":
        spec["world"] = world or "Zilirr"
    elif mode == "scan":
        if not cands:
            raise ValueError("scan needs at least one site")
        spec["cands"] = [list(c) for c in cands]
        if tiles:
            spec["tiles"] = True        # hover all 16 tiles of each rectangle (the panel shows one tile)
    elif mode == "embark":
        bad = sorted(set(waive) - set(WAIVABLE))
        if bad:
            raise ValueError(f"cannot waive {bad}; known: {list(WAIVABLE)}")
        spec["site"] = list(site)
        spec["waive"] = sorted(set(waive))
        bad = sorted(set(accept) - set(ACCEPTABLE))
        if bad:
            raise ValueError(f"cannot accept {bad}; known: {list(ACCEPTABLE)}")
        why = " ".join(str(reason or "").split())
        if accept and len(why) < 3:
            raise ValueError("--accept needs --reason (why this trade-off is acceptable; it is logged)")
        if accept:
            spec["accept"] = [{"id": a, "why": why[:200]} for a in sorted(set(accept))]
        if tiles is False:
            spec["tiles"] = False       # default: all 16 tiles are read before the gate
    elif mode != "prep":
        raise ValueError(f"unknown mode {mode}")
    if mode in ("embark", "prep"):
        spec.update(play_now=play_now, allow_unspent=allow_unspent)
    return spec


def log_accept(spec: dict, out: Path, now: float | None = None) -> Path | None:
    """FR-08: every accepted failed criterion is logged with its reason (<DF>/dfllm-runtime/embark/accept.log)."""
    if not spec.get("accept"):
        return None
    out.mkdir(parents=True, exist_ok=True)
    path = out / ACCEPT_LOG
    stamp = time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(now if now is not None else time.time()))
    site = ",".join(str(x) for x in spec.get("site") or [])
    with path.open("a", encoding="utf-8") as f:
        for a in spec["accept"]:
            f.write(f"{stamp}\t{spec['id']}\t{site}\t{a['id']}\t{a['why']}\n")
    return path


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
    res = doc.get("results")
    rows = sorted(res, key=lambda r: (ORDER.get(r.get("verdict"), 3), -r.get("score", 0))) if isinstance(res, list) else []
    for r in rows:
        w, e, s = r.get("world") or ["?", "?"], r.get("emb") or ["?", "?"], r.get("size") or ["?", "?"]
        lines.append(f"  {r['tag']}: world {w[0]},{w[1]} rect {e[0]},{e[1]} {s[0]}x{s[1]} -> {r['verdict']} {r.get('score')}"
                     f" fail={','.join(r.get('fails') or []) or '-'} warn={','.join(r.get('warns') or []) or '-'}"
                     f" unknown={','.join(r.get('unknown') or []) or '-'}")
    if isinstance(res, dict):
        lines.extend(load_lines(res))
    for w in doc.get("warnings") or []:
        lines.append(f"  warning: {w}")
    return lines


def load_lines(res: dict) -> list[str]:
    """K2: what a load run saw and clicked (the first live use is calibrated from these lines)."""
    out = []
    for c in res.get("clicks") or []:
        out.append(f"  click {c.get('n')}: {c.get('kind')} \"{c.get('text')}\" tile {c.get('tx')},{c.get('ty')} "
                   f"pixel {c.get('px')},{c.get('py')}")
    if res.get("title"):
        out.append("  title screen fields: " + json.dumps(res["title"], sort_keys=True))
    if res.get("rows"):
        out.append(f"  last screen ({res.get('screen')}): {res['rows']}")
    return out


def load_verdict(doc: dict | None) -> str:
    """K2: the one line a load run ends with: LOAD OK or LOAD FAILED and the reason (screen text found or not, no such save)."""
    if not doc:
        return "LOAD UNKNOWN: no status (is DF running at the title screen and the run started?)"
    res = doc.get("results") if isinstance(doc.get("results"), dict) else {}
    clicks = len(res.get("clicks") or [])
    if doc.get("state") == "done":
        how = f"after {clicks} click(s)" if clicks else "by DFHack's own load-save"
        return f"LOAD OK: left the title screen ({res.get('outcome') or '?'}) {how}"
    why = doc.get("msg") or doc.get("state")
    return f"LOAD {str(doc.get('state')).upper()}: {why}"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description="vanilla-UI embark helper (see tools/embark/README.md)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("state", "check", "status", "stop"):
        sub.add_parser(name)
    sp = sub.add_parser("screen")
    sp.add_argument("name", nargs="?")
    sp = sub.add_parser("load", help="K2: load a saved fort from the title screen (Continue / Load game, then the list)")
    sp.add_argument("save", help="the save folder name, e.g. 'autosave 1'")
    sp.add_argument("--entry", help="the text to click in the list when it does not show the folder name")
    sp.add_argument("--no-stock", action="store_true", help="do not try DFHack's own load-save first")
    sp = sub.add_parser("newgame")
    sp.add_argument("--world", default="Zilirr", help="ASCII part of the world name (accents read as '?')")
    sp = sub.add_parser("scan")
    sp.add_argument("sites", nargs="+", type=parse_site)
    sp.add_argument("--tiles", action="store_true", help="read the panel on all 16 tiles of each rectangle")
    for name in ("embark", "prep"):
        sp = sub.add_parser(name)
        if name == "embark":
            sp.add_argument("site", type=parse_site)
            sp.add_argument("--waive", action="append", default=[], choices=WAIVABLE, metavar="ID",
                            help="accept this one criterion although the panel did not show it (checked by eye); "
                                 "repeatable; " + ", ".join(WAIVABLE))
            sp.add_argument("--accept", action="append", default=[], choices=ACCEPTABLE, metavar="ID",
                            help="FR-08: embark although this criterion FAILED (a known trade-off); repeatable, "
                                 "needs --reason; logged to dfllm-runtime/embark/accept.log; " + ", ".join(ACCEPTABLE))
            sp.add_argument("--reason", help="why the accepted criteria are acceptable (logged with the run)")
            sp.add_argument("--no-tiles", action="store_true", help="read only the hovered tile's panel")
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
    try:
        spec = make_spec(a.cmd, world=getattr(a, "world", None), cands=getattr(a, "sites", None),
                         site=getattr(a, "site", None), waive=getattr(a, "waive", ()),
                         accept=getattr(a, "accept", ()), reason=getattr(a, "reason", None),
                         play_now=getattr(a, "play_now", False), allow_unspent=getattr(a, "allow_unspent", False),
                         tiles=(True if getattr(a, "tiles", False) else False if getattr(a, "no_tiles", False)
                                else None),
                         save=getattr(a, "save", None), entry=getattr(a, "entry", None),
                         stock=not getattr(a, "no_stock", False))
    except ValueError as e:
        ap.error(str(e))
    log_accept(spec, out)
    path = write_spec(spec, out)
    print(call(["run", path.as_posix()]).strip())
    if a.no_wait:
        return 0
    doc = wait(spec["id"], out, a.timeout)
    print("\n".join(summarize(doc)))
    if a.cmd == "load":
        print(load_verdict(doc))
    return 0 if doc and doc.get("state") == "done" else 1


if __name__ == "__main__":
    sys.exit(main())
