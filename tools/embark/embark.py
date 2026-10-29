"""Drive the in-game embark helper tools/embark/embark.lua (before `dfllm adopt`).

    python tools/embark/embark.py state | check | screen [NAME] | status | stop
    python tools/embark/embark.py newgame [--world Zilirr] [--world-folder F [--portable | --appdata]]
    python tools/embark/embark.py scan WX,WY[,LX,LY] ... [--tiles | --hover]
    python tools/embark/embark.py embark WX,WY[,LX,LY] | --here  [--waive ID ...] [--accept ID ... --reason TEXT]
                                        [--explore-first TEXT] [--play-now] [--allow-unspent]
    python tools/embark/embark.py prep [--play-now] [--allow-unspent]
    python tools/embark/embark.py load SAVE [--entry TEXT] [--no-stock] [--world-folder F]   (K2: a saved fort)
    python tools/embark/embark.py save-as NAME [--no-post]   (BUG-250: "Save and continue playing" as NAME)

A run costs ONE dfhack-run call (`embark.lua run <spec>`); afterwards only
<DF>/dfllm-runtime/embark/status.json is read. Stdlib only. Env DFLLM_DF = DF folder.
"""
from __future__ import annotations

import argparse
import json
import os
import re
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
# BUG-248: criteria a new fort may waive or accept only with --explore-first (= checklist.lua C.NEEDS_PLAN)
NEEDS_PLAN = ("stone",)
# BUG-250: a save folder name save-as types key by key (STRING_A<code>)
SAVE_NAME_RE = r"^[A-Za-z0-9][A-Za-z0-9 _-]{0,39}$"
PRIOR_FILES, PRIOR_ROWS = 30, 200      # embark --here: the newest result files and rows passed as spec.prior


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
              entry: str | None = None, stock: bool = True, world_folder: str | None = None,
              portable: bool | None = None, hover: bool = False, here: bool = False,
              explore_first: str | None = None, prior=None, name: str | None = None) -> dict:
    spec = {"v": 2, "id": run_id or f"{mode}{int(now if now is not None else time.time())}", "mode": mode}
    if mode == "embark" and here:
        mode = spec["mode"] = "here"           # BUG-250: the rectangle on the screen, gated on earlier reads
    if mode == "saveas":                       # BUG-250
        nm = " ".join(str(name or "").split())
        if not re.match(SAVE_NAME_RE, nm):
            raise ValueError(f"save-as needs a folder name of letters, digits, space, _ or - (40 at most): {name!r}")
        spec["name"] = nm
        return spec
    if mode == "load":
        name = " ".join(str(save or "").split())
        if not name or "/" in name or "\\" in name or name in (".", ".."):
            raise ValueError(f"load needs a save folder name (no path): {save!r}")
        spec["save"] = name
        if entry:
            spec["entry"] = " ".join(str(entry).split())[:80]
        spec["stock"] = bool(stock)
        if world_folder:   # BUG-230: which of several same-named worlds holds the save (a folder from the header list)
            wf = " ".join(str(world_folder).split())
            if not wf or "/" in wf or "\\" in wf or wf in (".", ".."):
                raise ValueError(f"--world-folder needs a folder name (no path): {world_folder!r}")
            spec["world_folder"] = wf
    elif mode == "newgame":
        spec["world"] = world or "Zilirr"
        if world_folder:   # BUG-245: the folder row of one of several same-named worlds
            wf = " ".join(str(world_folder).split())
            if not wf or "/" in wf or "\\" in wf or wf in (".", ".."):
                raise ValueError(f"--world-folder needs a folder name (no path): {world_folder!r}")
            spec["world_folder"] = wf
            if portable is not None:
                spec["portable"] = bool(portable)
        elif portable is not None:
            raise ValueError("--portable/--appdata go with --world-folder")
    elif mode == "scan":
        if not cands:
            raise ValueError("scan needs at least one site")
        if tiles and hover:
            raise ValueError("--tiles and --hover exclude each other")
        spec["cands"] = [list(c) for c in cands]
        if tiles:
            spec["tiles"] = True        # hover all 16 tiles of each rectangle (the panel shows one tile)
        if hover:
            spec["hover"] = True        # BUG-247: 16 hovered panels per candidate, no rectangle placed
    elif mode in ("embark", "here"):
        bad = sorted(set(waive) - set(WAIVABLE))
        if bad:
            raise ValueError(f"cannot waive {bad}; known: {list(WAIVABLE)}")
        if mode == "here":
            if site:
                raise ValueError("embark --here takes no site: it uses the rectangle on the screen")
            spec["prior"] = list(prior or [])
        else:
            if not site:
                raise ValueError("embark needs a site WX,WY[,LX,LY] (or --here)")
            spec["site"] = list(site)
        spec["waive"] = sorted(set(waive))
        plan = " ".join(str(explore_first or "").split())
        need = sorted((set(waive) | set(accept)) & set(NEEDS_PLAN))
        if need and len(plan) < 10:
            raise ValueError(f"waiving or accepting {need} needs --explore-first TEXT (10+ characters): how the fort "
                             "reaches hard stone in its first season (BUG-248)")
        if plan:
            spec["explore_first"] = plan[:200]
        bad = sorted(set(accept) - set(ACCEPTABLE))
        if bad:
            raise ValueError(f"cannot accept {bad}; known: {list(ACCEPTABLE)}")
        why = " ".join(str(reason or "").split())
        if accept and len(why) < 3:
            raise ValueError("--accept needs --reason (why this trade-off is acceptable; it is logged)")
        if accept:
            spec["accept"] = [{"id": a, "why": why[:200]} for a in sorted(set(accept))]
        if tiles is False and mode == "embark":
            spec["tiles"] = False       # default: all 16 tiles are read before the gate
    elif mode != "prep":
        raise ValueError(f"unknown mode {mode}")
    if mode in ("embark", "here", "prep"):
        spec.update(play_now=play_now, allow_unspent=allow_unspent)
    return spec


def prior_rows(out: Path, files: int = PRIOR_FILES, rows: int = PRIOR_ROWS) -> list[dict]:
    """BUG-250: embark --here gates on panels read before: the rows (rectangle, merged record, hovered tiles) of the
    newest result files of scan/embark runs, newest first (Lua takes the first row of an exact rectangle and the
    first record of each hovered tile)."""
    try:
        paths = sorted(out.glob("result-*.json"), key=lambda p: p.stat().st_mtime, reverse=True)[:files]
    except OSError:
        return []
    got: list[dict] = []
    for p in paths:
        try:
            doc = json.loads(p.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        res = doc.get("results") if isinstance(doc, dict) else None
        for r in res if isinstance(res, list) else []:
            if isinstance(r, dict) and isinstance(r.get("rec"), dict):
                got.append({k: r.get(k) for k in ("tag", "emb", "size", "rec", "parts", "hover") if r.get(k) is not None})
                if len(got) >= rows:
                    return got
    return got


def log_accept(spec: dict, out: Path, now: float | None = None) -> Path | None:
    """FR-08: every accepted failed criterion is logged with its reason (<DF>/dfllm-runtime/embark/accept.log)."""
    if not spec.get("accept"):
        return None
    out.mkdir(parents=True, exist_ok=True)
    path = out / ACCEPT_LOG
    stamp = time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(now if now is not None else time.time()))
    site = "here" if spec.get("mode") == "here" else ",".join(str(x) for x in spec.get("site") or [])
    plan = f"\texplore first: {spec['explore_first']}" if spec.get("explore_first") else ""   # BUG-248
    with path.open("a", encoding="utf-8") as f:
        for a in spec["accept"]:
            f.write(f"{stamp}\t{spec['id']}\t{site}\t{a['id']}\t{a['why']}{plan if a['id'] in NEEDS_PLAN else ''}\n")
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
         clock=time.monotonic, sleep=time.sleep, echo=print, on_doc=None) -> dict | None:
    """Poll status.json until run_id is no longer running; echo each new step once; on_doc(doc) sees every poll."""
    end, last = clock() + timeout_s, None
    while True:
        doc = read_status(out)
        if doc and doc.get("id") == run_id:
            step = (doc.get("step"), doc.get("state"))
            if step != last:
                echo(f"  [{doc.get('i')}/{doc.get('n')}] {doc.get('step')} ({doc.get('live')}) {doc.get('msg', '')}")
                last = step
            if on_doc is not None and doc.get("state") == "running":
                on_doc(doc)
            if doc.get("state") != "running":
                return doc
        if clock() >= end:
            return doc
        sleep(poll_s)


def _box(r: dict) -> tuple[int, int, int, int] | None:
    e, s = r.get("emb"), r.get("size") or [4, 4]
    if not (isinstance(e, list) and len(e) == 2 and isinstance(s, list) and len(s) == 2):
        return None
    return e[0], e[1], e[0] + s[0] - 1, e[1] + s[1] - 1


def water_points(rows: list[dict]) -> list[tuple[int, int, str]]:
    """BUG-250: every embark tile a scan saw a brook or river on (the hovered tiles' water_at; a rectangle read
    without tiles counts at its corner)."""
    pts = []
    for r in rows:
        rec = r.get("rec") if isinstance(r.get("rec"), dict) else {}
        at = (rec.get("tiles") or {}).get("water_at") if isinstance(rec.get("tiles"), dict) else None
        if isinstance(at, list) and at:
            pts.extend((p[0], p[1], r.get("tag", "?")) for p in at if isinstance(p, list) and len(p) == 2)
        elif rec.get("water") and _box(r):
            b = _box(r)
            pts.append((b[0], b[1], r.get("tag", "?")))
    return pts


def brook_text(r: dict, pts: list[tuple[int, int, str]]) -> str:
    """' brook=in (stream)', ' brook=5 tiles at 122,170 (scan1-3)' or ' brook=none seen'; '' without a record."""
    rec = r.get("rec")
    if not isinstance(rec, dict):
        return ""
    if rec.get("water"):
        return f" brook=in ({rec['water']})"
    b = _box(r)
    if not b:
        return ""
    best = None
    for x, y, tag in pts:
        d = max(max(0, b[0] - x, x - b[2]), max(0, b[1] - y, y - b[3]))
        if best is None or d < best[0]:
            best = (d, x, y, tag)
    if best is None:
        return " brook=none seen"
    return f" brook={best[0]} tiles at {best[1]},{best[2]} ({best[3]})"


def best_compromise(rows: list[dict]) -> str | None:
    """BUG-250 (Run 15c: 14 rectangles scanned by hand): with no 'ok' rectangle, the one with the fewest failed
    criteria that FR-08 can accept (then the highest score), as the embark line to run."""
    if not rows or any(r.get("verdict") == "ok" for r in rows):
        return None
    cands = [r for r in rows if _box(r) and isinstance(r.get("world"), list)
             and all(f in ACCEPTABLE for f in r.get("fails") or [])
             and all(u in WAIVABLE for u in r.get("unknown") or [])]
    if not cands:
        return "  best compromise: none (every rectangle fails a criterion that cannot be accepted)"
    r = min(cands, key=lambda x: (len(x.get("fails") or []), len(x.get("unknown") or []), -(x.get("score") or 0)))
    w, b = r["world"], _box(r)
    cmd = f"embark {w[0]},{w[1]},{b[0] - 16 * w[0]},{b[1] - 16 * w[1]}"
    for u in r.get("unknown") or []:
        cmd += f" --waive {u}"
    for f in r.get("fails") or []:
        cmd += f" --accept {f}"
    if r.get("fails"):
        cmd += " --reason TEXT"
    if set(NEEDS_PLAN) & set((r.get("fails") or []) + (r.get("unknown") or [])):
        cmd += " --explore-first TEXT"
    lacks = ",".join(r.get("fails") or []) or "-"
    return f"  best compromise: {r['tag']} score {r.get('score')} fails {lacks}: {cmd}"


def summarize(doc: dict | None) -> list[str]:
    if not doc:
        return ["no status (is DF running and the run started?)"]
    lines = [f"{doc['id']}: {doc['state']} at {doc.get('step') or '-'} ({doc.get('i')}/{doc.get('n')}) {doc.get('msg', '')}"]
    res = doc.get("results")
    rows = sorted(res, key=lambda r: (ORDER.get(r.get("verdict"), 3), -r.get("score", 0))) if isinstance(res, list) else []
    wpts = water_points(rows)
    for r in rows:
        w, e, s = r.get("world") or ["?", "?"], r.get("emb") or ["?", "?"], r.get("size") or ["?", "?"]
        lines.append(f"  {r['tag']}: world {w[0]},{w[1]} rect {e[0]},{e[1]} {s[0]}x{s[1]} -> {r['verdict']} {r.get('score')}"
                     f" fail={','.join(r.get('fails') or []) or '-'} warn={','.join(r.get('warns') or []) or '-'}"
                     f" unknown={','.join(r.get('unknown') or []) or '-'}" + brook_text(r, wpts)
                     + (" (hover read, no rectangle placed)" if r.get("hover") else ""))
    best = best_compromise(rows)
    if best:
        lines.append(best)
    if isinstance(res, dict):
        if isinstance(res.get("world_row"), dict):   # BUG-245: the folder row newgame clicked
            wr = res["world_row"]
            lines.append(f"  world row clicked: \"{wr.get('text')}\" (row {wr.get('y')}, "
                         f"{'portable' if wr.get('portable') else 'appdata'})")
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
    for sc in res.get("scrolls") or []:
        out.append(f"  scrolled the {sc.get('which')} list to {sc.get('to')} (entry {sc.get('idx')})")
    title = res.get("title")
    if isinstance(title, dict) and title:
        flat = {k: v for k, v in title.items() if not isinstance(v, (list, dict))}
        out.append("  title screen fields: " + json.dumps(flat, sort_keys=True))
        for key in ("worlds", "games"):   # BUG-230: the header lists (folder = what --world-folder / SAVE name)
            rows = title.get(key)
            if isinstance(rows, list) and rows:
                shown = ", ".join(f"{i + 1}:{r.get('folder')}={r.get('world') or r.get('fort') or '?'}"
                                  for i, r in enumerate(rows[:12]) if isinstance(r, dict))
                more = f" (+{len(rows) - 12})" if len(rows) > 12 else ""
                out.append(f"  {key}: {shown}{more}")
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


def df_window(df: Path):
    """BUG-250: the visible top-level window of the DF process started from `df` (several DF instances run side by
    side: the window is matched by its executable's folder, never by its title); None when not exactly found."""
    if os.name != "nt":
        return None
    import ctypes
    from ctypes import wintypes
    user32, kernel32 = ctypes.windll.user32, ctypes.windll.kernel32
    want = os.path.normcase(os.path.abspath(str(df)))
    found: list[int] = []

    def visit(hwnd, _lparam):
        if not user32.IsWindowVisible(hwnd) or user32.GetWindowTextLengthW(hwnd) == 0:
            return True
        pid = wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        h = kernel32.OpenProcess(0x1000, False, pid.value)   # PROCESS_QUERY_LIMITED_INFORMATION
        if h:
            try:
                buf, n = ctypes.create_unicode_buffer(1024), wintypes.DWORD(1024)
                if kernel32.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(n)):
                    exe = os.path.normcase(buf.value)
                    if os.path.dirname(exe) == want and os.path.basename(exe).startswith("dwarf fortress"):
                        found.append(hwnd)
            finally:
                kernel32.CloseHandle(h)
        return True

    proc = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)(visit)
    user32.EnumWindows(proc, 0)
    return found[0] if found else None


def post_key(hwnd, vk: int = 0x1B, scan: int = 1) -> bool:
    """One key press posted to a window (WM_KEYDOWN + WM_KEYUP; Run 15c: DF on another virtual desktop takes it
    without focus). Default: Esc."""
    import ctypes
    user32 = ctypes.windll.user32
    down = 1 | (scan << 16)
    up = down | (1 << 30) | (1 << 31)
    return bool(user32.PostMessageW(hwnd, 0x0100, vk, down)) and bool(user32.PostMessageW(hwnd, 0x0101, vk, up))


def esc_poster(df: Path, find=None, post=None, clock=time.monotonic, gap_s: float = 15.0, most: int = 2):
    """BUG-250: the wait() hook of save-as: while the run waits at fort.menu.wait and its log says the menu was not
    open, post Esc to this DF's window (at most `most` times, gap_s apart). Never otherwise: Esc would close a menu
    or a popup."""
    find, post = find or df_window, post or post_key
    st = {"n": 0, "t": None}

    def hook(doc: dict) -> None:
        log = doc.get("log") if isinstance(doc.get("log"), list) else []
        if doc.get("step") != "fort.menu.wait" or not any(str(x).endswith("fort.menu: Esc menu not open") for x in log):
            return
        if st["n"] >= most or (st["t"] is not None and clock() - st["t"] < gap_s):
            return
        hwnd = find(df)
        st["n"], st["t"] = st["n"] + 1, clock()
        if hwnd is None:
            print(f"  save-as: no DF window of {df} found: press Esc in DF")
            return
        print("  save-as: posted Esc to DF's window" if post(hwnd) else "  save-as: posting Esc failed: press Esc in DF")
    return hook


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
    sp.add_argument("--world-folder", help="BUG-230: the world (its folder in the header list) when several worlds "
                                           "share a name and the run cannot tell which one holds SAVE")
    sp = sub.add_parser("newgame")
    sp.add_argument("--world", default="Zilirr", help="ASCII part of the world name (accents read as '?')")
    sp.add_argument("--world-folder", help="BUG-245: click the row 'Folder: F' of this world folder (several worlds "
                                           "share a name)")
    g = sp.add_mutually_exclusive_group()
    g.add_argument("--portable", dest="portable", action="store_const", const=True,
                   help="only the 'Portable Folder: F' row (<DF>/save)")
    g.add_argument("--appdata", dest="portable", action="store_const", const=False,
                   help="only the plain 'Folder: F' row (AppData)")
    sp = sub.add_parser("scan")
    sp.add_argument("sites", nargs="+", type=parse_site)
    sp.add_argument("--tiles", action="store_true", help="read the panel on all 16 tiles of each rectangle")
    sp.add_argument("--hover", action="store_true", help="BUG-247: read 16 hovered panels per site without placing "
                                                         "a rectangle (when the rectangle does not follow the mouse)")
    sp = sub.add_parser("save-as", help="BUG-250: Esc menu > 'Save and continue playing' under the name NAME")
    sp.add_argument("name", help="the new save folder name (letters, digits, space, _ -)")
    sp.add_argument("--no-post", action="store_true", help="do not post the Esc key to DF's window (press it yourself)")
    for name in ("embark", "prep"):
        sp = sub.add_parser(name)
        if name == "embark":
            sp.add_argument("site", type=parse_site, nargs="?")
            sp.add_argument("--here", action="store_true",
                            help="BUG-250: the rectangle on the screen (its Confirm popup open), gated on the panels "
                                 "earlier scan/embark runs read")
            sp.add_argument("--explore-first", help="BUG-248: the plan that reaches hard stone in the first season; "
                                                    "needed to waive or accept 'stone'")
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
    here = getattr(a, "here", False)
    try:
        spec = make_spec("saveas" if a.cmd == "save-as" else a.cmd, world=getattr(a, "world", None),
                         cands=getattr(a, "sites", None),
                         site=getattr(a, "site", None), waive=getattr(a, "waive", ()),
                         accept=getattr(a, "accept", ()), reason=getattr(a, "reason", None),
                         play_now=getattr(a, "play_now", False), allow_unspent=getattr(a, "allow_unspent", False),
                         tiles=(True if getattr(a, "tiles", False) else False if getattr(a, "no_tiles", False)
                                else None),
                         save=getattr(a, "save", None), entry=getattr(a, "entry", None),
                         stock=not getattr(a, "no_stock", False), world_folder=getattr(a, "world_folder", None),
                         portable=getattr(a, "portable", None), hover=getattr(a, "hover", False), here=here,
                         explore_first=getattr(a, "explore_first", None),
                         prior=prior_rows(out) if here else None, name=getattr(a, "name", None))
    except ValueError as e:
        ap.error(str(e))
    if spec["mode"] == "saveas" and (df_dir() / "save" / spec["name"]).exists():
        ap.error(f"save folder {spec['name']!r} exists already: choose another name (save-as never overwrites)")
    log_accept(spec, out)
    path = write_spec(spec, out)
    print(call(["run", path.as_posix()]).strip())
    if a.no_wait:
        return 0
    hook = esc_poster(df_dir()) if spec["mode"] == "saveas" and not a.no_post else None
    doc = wait(spec["id"], out, a.timeout, on_doc=hook)
    print("\n".join(summarize(doc)))
    if a.cmd == "load":
        print(load_verdict(doc))
    return 0 if doc and doc.get("state") == "done" else 1


if __name__ == "__main__":
    sys.exit(main())
