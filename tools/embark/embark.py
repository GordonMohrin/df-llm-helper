"""Drive the in-game embark helper tools/embark/embark.lua (before `dfllm adopt`).

    python tools/embark/embark.py state | check | screen [NAME] | status | stop
    python tools/embark/embark.py newgame [--world Zilirr] [--world-folder F [--portable | --appdata]]
    python tools/embark/embark.py scan WX,WY[,LX,LY] ... [--tiles | --hover]
    python tools/embark/embark.py rank --box X0,Y0,X1,Y1 [--step N] [--sample 1|4|9] [--top N]   (BUG-410: pre-rank)
    python tools/embark/embark.py rank --last [--top N]   (BUG-410: rank the newest finished sweep again, no DF needed)
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
ACCEPTABLE = ("old_sites", "dark_fortress", "evil", "savagery", "trees", "water", "aquifer", "soil", "ore",
              "temperature", "size")
# BUG-465 (all four forts of Run 16's world region1 had no hard stone): a FAILED criterion of this list is a hard reject, never accepted
# (= checklist.lua C.HARD_REJECT; `stone` may still be waived when the soil depth is unknown, with --explore-first)
HARD_REJECT = {"stone": "no hard stone within reach: a failed stone criterion cannot be accepted, choose another site"}
ACCEPT_LOG = "accept.log"
# BUG-248: criteria a new fort may waive or accept only with --explore-first (= checklist.lua C.NEEDS_PLAN)
NEEDS_PLAN = ("stone",)
# BUG-250: a save folder name save-as types key by key (STRING_A<code>)
SAVE_NAME_RE = r"^[A-Za-z0-9][A-Za-z0-9 _-]{0,39}$"
PRIOR_FILES, PRIOR_ROWS = 30, 200      # embark --here: the newest result files and rows passed as spec.prior
# BUG-410: rank = a hover sweep (few hovered tiles per world tile, compact rows). Samples per world tile (= steps.lua
# SWEEP_OFFSETS), world tiles per run (status.json is rewritten after every step), seconds per tile (guess, live-untested)
SWEEP_SAMPLES = (1, 4, 9)
SWEEP_MAX = 400
SWEEP_SECONDS = (5.0, 1.5)             # per world tile: base + per hovered tile
# BUG-427: rank returns after this many seconds with the partial pre-rank (em.sh killed the whole call at 590 s and
# printed nothing; the sweep itself goes on in DF and is read later with rank --last, or resumed with rank --resume)
RANK_BUDGET = 540.0
VARIANT_SHIFT = 3                      # BUG-428: LX/LY variants within this many tiles of the hovered 4x4
# BUG-409: an embark tile is 48 map cells (steps); a brook farther than this from every other scanned rectangle is not
# 'near' it (BUG-250 searched all scanned sites: 'brook=47 tiles at 390,391' for a site 160 tiles away)
TILE_STEPS = 48
BROOK_NEAR = 16


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


def parse_box(text: str) -> list[int]:
    """BUG-410: 'X0,Y0,X1,Y1' world tiles (inclusive, X0<=X1, Y0<=Y1)."""
    parts = [int(p) for p in text.split(",")]
    if len(parts) != 4 or any(p < 0 for p in parts) or parts[0] > parts[2] or parts[1] > parts[3]:
        raise ValueError(f"box must be X0,Y0,X1,Y1 with X0<=X1 and Y0<=Y1: {text!r}")
    return parts


def box_cands(box: list[int], step: int = 1) -> list[list[int]]:
    """BUG-410: the world tiles of a box, row by row, every STEP-th in each direction."""
    if step < 1:
        raise ValueError("--step must be 1 or more")
    return [[x, y] for y in range(box[1], box[3] + 1, step) for x in range(box[0], box[2] + 1, step)]


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
              explore_first: str | None = None, prior=None, name: str | None = None, sweep: int | None = None) -> dict:
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
        if sweep is not None:           # BUG-410: a pre-rank: SWEEP tiles hovered per world tile, compact rows
            if sweep not in SWEEP_SAMPLES:
                raise ValueError(f"--sample must be one of {list(SWEEP_SAMPLES)}: {sweep!r}")
            if tiles:
                raise ValueError("a sweep hovers a few tiles by itself: no --tiles")
            if len(cands) > SWEEP_MAX:
                raise ValueError(f"a sweep reads at most {SWEEP_MAX} world tiles per run ({len(cands)} asked): use --step "
                                 "or a smaller --box")
            spec["hover"], spec["sweep"] = True, sweep
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
        hard = sorted(set(accept) & set(HARD_REJECT))
        if hard:                                      # BUG-465
            raise ValueError(f"cannot accept {hard}: {'; '.join(HARD_REJECT[h] for h in hard)}")
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
            if isinstance(r, dict) and isinstance(r.get("rec"), dict) and not r.get("sweep"):
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


def brook_geometry(r: dict) -> dict | None:
    """BUG-409: the brook/river tiles a row saw against its rectangle: {n inside, core = not on the outer ring, d2 = twice
    the Chebyshev tile distance of the nearest one from the rectangle's centre, out = tiles outside it}; None without
    tile positions. A hover row has no size: the 4x4 the hover grid covers (= steps.lua water_geometry)."""
    rec = r.get("rec") if isinstance(r.get("rec"), dict) else {}
    tl = rec.get("tiles") if isinstance(rec.get("tiles"), dict) else {}
    at = tl.get("water_at")
    b = _box(r)
    if not (isinstance(at, list) and at and b):
        return None
    n = core = out = 0
    d2 = None
    for p in at:
        if not (isinstance(p, list) and len(p) == 2):
            continue
        x, y = p
        if not (b[0] <= x <= b[2] and b[1] <= y <= b[3]):
            out += 1
            continue
        n += 1
        if b[0] < x < b[2] and b[1] < y < b[3]:
            core += 1
        d = max(abs(2 * x - (b[0] + b[2])), abs(2 * y - (b[1] + b[3])))
        d2 = d if d2 is None else min(d2, d)
    return {"n": n, "core": core, "d2": d2, "out": out}


def brook_text(r: dict, pts: list[tuple[int, int, str]]) -> str:
    """' brook=in (stream) 3 tiles, nearest 0.5 tiles (~12 steps) from the centre', ' brook=EDGE ONLY (brook) ...' (BUG-409:
    only on the outer ring: it may lie at the map edge, i1 18,22 walked 95 steps), ' brook=5 tiles at 122,170 (scan1-3)'
    or ' brook=none seen'; '' without a record."""
    rec = r.get("rec")
    if not isinstance(rec, dict):
        return ""
    if rec.get("water"):
        if mountain_dry(r):   # BUG-426
            return f" brook=in a gully ({rec['water']}) but MOUNTAIN: no soil, no aquifer (no well, no farm, bank not reachable)"
        g = brook_geometry(r)
        if g is None:
            return f" brook=in ({rec['water']}) (tile positions not read: scan --tiles)"
        if g["n"] == 0:
            return f" brook=OUTSIDE the rectangle ({rec['water']}, {g['out']} tile(s) beyond it)"
        near = f"{g['n']} tile(s), nearest {g['d2'] / 2:g} tiles (~{g['d2'] * TILE_STEPS // 2} steps) from the centre"
        if g["core"] == 0:
            return f" brook=EDGE ONLY ({rec['water']}) {near}"
        return f" brook=in ({rec['water']}) {near}"
    b = _box(r)
    if not b:
        return ""
    best = None
    for x, y, tag in pts:
        d = max(max(0, b[0] - x, x - b[2]), max(0, b[1] - y, y - b[3]))
        if d <= BROOK_NEAR and (best is None or d < best[0]):
            best = (d, x, y, tag)
    if best is None:
        return " brook=none seen"
    return f" brook={best[0]} tiles at {best[1]},{best[2]} ({best[3]})"


def aquifer_text(r: dict) -> str:
    """BUG-411: ' aq=heavy (tiles differ, best none)' when the merged hovered tiles disagree (the row shows the worst).
    BUG-465: the spread of the hovered tiles (`aq=light 9 none, 6 light, 1 heavy`) and, with an aquifer, the estimated span and the
    estimated levels down to the hard stone (soil + aquifer): the panel class hides how many aquifer levels there are and that
    the heavy ones lie under the light ones (Basementflew: light z126/127 over heavy z120-123)."""
    rec = r.get("rec") if isinstance(r.get("rec"), dict) else {}
    tl = rec.get("tiles") if isinstance(rec.get("tiles"), dict) else {}
    out = ""
    if tl.get("aq_best") and rec.get("aquifer"):
        out = f" aq={rec['aquifer']} (tiles differ, best {tl['aq_best']})"
    n = tl.get("aq_n") if isinstance(tl.get("aq_n"), dict) else {}
    if len(n) > 1 or (n and "none" not in n and rec.get("aquifer") in ("light", "varied", "heavy")):
        order = ("none", "light", "varied", "heavy")
        out += " aq tiles: " + ", ".join(f"{n[k]} {k}" for k in order if n.get(k))
    span = r.get("aquifer_span")
    if isinstance(span, (int, float)) and span:
        reach = r.get("reach")
        out += (f" aq span ~{int(span)} levels incl. heavy ones under the light (panel class only; real span known after the "
                "first aqshaft)" + (f", hard stone ~{int(reach)} levels down" if isinstance(reach, (int, float)) else ""))
    elif isinstance(r.get("reach"), (int, float)) and r.get("reach"):
        out += f" hard stone ~{int(r['reach'])} levels down"
    return out


def mountain_dry(r: dict) -> bool:
    """BUG-426: a bare mountain (every read tile mountain, no soil, no aquifer): no well and no farm for dfpilot, and its
    brook runs in a gully behind rock (= checklist.lua mountain_dry)."""
    rec = r.get("rec") if isinstance(r.get("rec"), dict) else {}
    if rec.get("aquifer") not in (None, "none"):
        return False
    tl = rec.get("tiles") if isinstance(rec.get("tiles"), dict) else {}
    if tl.get("terrain"):
        return tl.get("mountain") == tl["terrain"] and not tl.get("soiled")
    return rec.get("terrain") == "mountain" and rec.get("soil") in (None, "none")


def variant_lines(r: dict) -> list[str]:
    """BUG-428: a hover row reads one fixed 4x4 (LX,LY = 6,6 unless given); when its brook is not in the core of that
    rectangle (EDGE ONLY, i1 Manorsubtle: moved to 7,6 by hand), propose the LX,LY within VARIANT_SHIFT tiles that
    puts the most of the brook tiles seen into the core (not on the outer ring). The tiles beyond the hovered 4x4 are
    unread: the line is a scan command, not a verdict."""
    rec = r.get("rec") if isinstance(r.get("rec"), dict) else {}
    tl = rec.get("tiles") if isinstance(rec.get("tiles"), dict) else {}
    at = [p for p in tl.get("water_at") or [] if isinstance(p, list) and len(p) == 2]
    w, e = r.get("world"), r.get("emb")
    if not (r.get("hover") and not r.get("sweep") and at and isinstance(w, list) and isinstance(e, list) and len(e) == 2):
        return []

    def core(x0: int, y0: int) -> tuple[int, int]:
        inner = [p for p in at if x0 < p[0] < x0 + 3 and y0 < p[1] < y0 + 3]
        d2 = min((max(abs(2 * p[0] - (2 * x0 + 3)), abs(2 * p[1] - (2 * y0 + 3))) for p in inner), default=99)
        return len(inner), -d2

    cur = core(e[0], e[1])
    best = None
    for dy in range(-VARIANT_SHIFT, VARIANT_SHIFT + 1):
        for dx in range(-VARIANT_SHIFT, VARIANT_SHIFT + 1):
            lx, ly = e[0] + dx - 16 * w[0], e[1] + dy - 16 * w[1]
            if not (0 <= lx <= 12 and 0 <= ly <= 12) or (dx, dy) == (0, 0):
                continue
            c = core(e[0] + dx, e[1] + dy)
            key = (c, -(abs(dx) + abs(dy)), -dy, -dx)
            if c > cur and (best is None or key > best[0]):
                best = (key, lx, ly, c[0])
    if best is None:
        return []
    return [f"    variant: LX,LY {best[1]},{best[2]} puts {best[3]} brook tile(s) in the core (now {cur[0]}): "
            f"scan {w[0]},{w[1]},{best[1]},{best[2]} --hover   (the tiles beyond the hovered 4x4 are unread)"]


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
        if u == "size" and r.get("hover"):   # a hover row placed no rectangle; embark reads the size it places
            continue
        cmd += f" --waive {u}"
    for f in r.get("fails") or []:
        cmd += f" --accept {f}"
    if r.get("fails"):
        cmd += " --reason TEXT"
    if set(NEEDS_PLAN) & set((r.get("fails") or []) + (r.get("unknown") or [])):
        cmd += " --explore-first TEXT"
    lacks = ",".join(r.get("fails") or []) or "-"
    return f"  best compromise: {r['tag']} score {r.get('score')} fails {lacks}: {cmd}"


def stone_tier(r: dict) -> int:
    """BUG-465: how far the hard stone is, as a rank tier: 0 pass, 1 warn (the estimated levels count within it), 2 unknown, 3 fail
    (a hard reject). Run 16: every fort of world region1 sat on 8-15 levels of soil under an aquifer and had no stone for years."""
    for key, tier in (("fails", 3), ("unknown", 2), ("warns", 1)):
        if "stone" in (r.get(key) or []):
            return tier
    return 0


def rank_key(r: dict) -> tuple:
    """BUG-410: best first: verdict, then (BUG-465) the nearest hard stone, then fewest failed criteria, fewest unknown, highest score.
    A site with a reachable hard stone beats any site that needs an explore shaft first, whatever else it lacks."""
    lv = r.get("reach") if isinstance(r.get("reach"), (int, float)) else r.get("stone_levels")
    return (ORDER.get(r.get("verdict"), 3), stone_tier(r), lv if isinstance(lv, (int, float)) else 99,
            len(r.get("fails") or []), len(r.get("unknown") or []), -(r.get("score") or 0), str(r.get("tag")))


def rank_lines(rows: list[dict], top: int = 8) -> list[str]:
    """BUG-410: the pre-rank of a sweep: counts, the reasons of the rejects, the best `top` world tiles and the scan command
    that reads their 16 tiles each."""
    sw = sorted((r for r in rows if r.get("sweep") and isinstance(r.get("world"), list)), key=rank_key)
    if not sw:
        return ["  rank: no sweep rows"]
    verdicts = {v: sum(1 for r in sw if r.get("verdict") == v) for v in ORDER}
    lines = [f"  pre-rank: {len(sw)} world tile(s) read: " + ", ".join(f"{v} {n}" for v, n in verdicts.items())]
    why: dict[str, int] = {}
    for r in sw:
        for f in r.get("fails") or []:
            why[f] = why.get(f, 0) + 1
    if why:
        lines.append("  fails: " + ", ".join(f"{k} {n}" for k, n in sorted(why.items(), key=lambda kv: (-kv[1], kv[0]))))
    best = sw[:max(1, top)]
    for i, r in enumerate(best, 1):
        rec = r.get("rec") if isinstance(r.get("rec"), dict) else {}
        w = r["world"]
        lines.append(f"  {i}. {w[0]},{w[1]} {r.get('verdict')} {r.get('score')} fail={','.join(r.get('fails') or []) or '-'}"
                     f" warn={','.join(r.get('warns') or []) or '-'} water={rec.get('water') or '-'}"
                     f" aquifer={rec.get('aquifer') or '-'} goblins={rec.get('goblins') or '-'}")
    lines.append("  next: python tools/embark/embark.py scan " + " ".join(f"{r['world'][0]},{r['world'][1]}" for r in best)
                 + " --hover   (all 16 tiles per site; a sweep only samples, the popup of a placed rectangle decides)")
    return lines


def _sweep_docs(out: Path) -> list[dict]:
    """BUG-427: the result files and the (maybe still running) status.json that hold sweep rows, newest first."""
    try:
        paths = [p for p in list(out.glob("result-*.json")) + [out / "status.json"] if p.exists()]
        paths.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    except OSError:
        return []
    docs = []
    for p in paths:
        try:
            doc = json.loads(p.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        res = doc.get("results") if isinstance(doc, dict) else None
        if isinstance(res, list) and any(isinstance(r, dict) and r.get("sweep") for r in res):
            docs.append(doc)
    return docs


def last_sweep(out: Path) -> dict | None:
    """BUG-410: the newest result file (BUG-427: or the running status.json) that holds sweep rows (rank --last)."""
    docs = _sweep_docs(out)
    return docs[0] if docs else None


def sweep_rows(out: Path, extra: list[dict] | None = None) -> dict[tuple[int, int], dict]:
    """BUG-427: every world tile any sweep read so far, the newest read of a tile wins (rank --resume skips them)."""
    rows: dict[tuple[int, int], dict] = {}
    docs = _sweep_docs(out)
    for res in [d["results"] for d in reversed(docs)] + ([extra] if extra else []):
        for r in res:
            w = r.get("world") if isinstance(r, dict) and r.get("sweep") else None
            if isinstance(w, list) and len(w) == 2:
                rows[(w[0], w[1])] = r
    return rows


def summarize(doc: dict | None, top: int = 8) -> list[str]:
    if not doc:
        return ["no status (is DF running and the run started?)"]
    lines = [f"{doc['id']}: {doc['state']} at {doc.get('step') or '-'} ({doc.get('i')}/{doc.get('n')}) {doc.get('msg', '')}"]
    if doc.get("fort"):   # BUG-355: the new fort's name, readable right after embark (before save-as)
        lines.append(f"  fort name: {doc['fort']}")
    res = doc.get("results")
    rows = sorted(res, key=rank_key) if isinstance(res, list) else []   # BUG-465: reachable hard stone first
    if any(r.get("sweep") for r in rows):   # BUG-410: one line per world tile would be hundreds
        lines.extend(rank_lines(rows, top))
        rows = [r for r in rows if not r.get("sweep")]
    wpts = water_points(rows)
    for r in rows:
        w, e, s = r.get("world") or ["?", "?"], r.get("emb") or ["?", "?"], r.get("size") or ["?", "?"]
        lines.append(f"  {r['tag']}: world {w[0]},{w[1]} rect {e[0]},{e[1]} {s[0]}x{s[1]} -> {r['verdict']} {r.get('score')}"
                     f" fail={','.join(r.get('fails') or []) or '-'} warn={','.join(r.get('warns') or []) or '-'}"
                     f" unknown={','.join(r.get('unknown') or []) or '-'}" + brook_text(r, wpts) + aquifer_text(r)
                     + (" (hover read, no rectangle placed)" if r.get("hover") else ""))
        lines.extend(variant_lines(r))   # BUG-428
    if any(r.get("hover") for r in rows):   # BUG-411
        lines.append("  note: a hover row merges the WORST aquifer and the DEEPEST soil of its hovered tiles, but covers "
                     "only the tiles it hovered; the rectangle you place may differ: its Confirm popup (embark gate) decides")
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


def saveas_hint(doc: dict | None, name: str) -> list[str]:
    """BUG-362: after a finished save-as the kernel still runs under the runtime folder of the old save name; its next boot
    (dfllm adopt on an adopted fort = boot) moves the runtime folder to <NAME>-site<N> and the status shows the new name."""
    if not doc or doc.get("state") != "done":
        return []
    return [f"  save-as {name}: now run `dfhack-run dfllm adopt` so the kernel renames its runtime folder after the save "
            "(status shows the new name; without it the old name stays until the next boot in this folder)"]


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
    sp = sub.add_parser("rank", help="BUG-410: pre-rank the world: a hover sweep (few panels per world tile, vanilla "
                                     "UI only) over a box of world tiles, then the best N tiles to scan")
    sp.add_argument("--box", type=parse_box, help="X0,Y0,X1,Y1 world tiles, inclusive (at most 400 after --step)")
    sp.add_argument("--step", type=int, default=1, help="read every STEP-th world tile (default 1)")
    sp.add_argument("--sample", type=int, default=4, choices=SWEEP_SAMPLES,
                    help="panels hovered per world tile (default 4: the corners of the 4x4; ~5 s + 1.5 s each, a guess)")
    sp.add_argument("--top", type=int, default=8, help="how many tiles to propose (default 8)")
    sp.add_argument("--last", action="store_true", help="rank the newest sweep (finished or still running) again (no DF call)")
    sp.add_argument("--resume", action="store_true",
                    help="BUG-427: skip the world tiles an earlier sweep already read and rank old and new together")
    sp.add_argument("--budget", type=float, default=RANK_BUDGET,
                    help="BUG-427: seconds to wait, then print the partial pre-rank (the sweep goes on in DF); 0 = wait "
                         "for the whole sweep (default %(default)s, below em.sh's 590 s)")
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
            sp.add_argument("--accept", action="append", default=[], choices=ACCEPTABLE + tuple(HARD_REJECT), metavar="ID",
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
    if a.cmd == "rank" and a.last:   # BUG-410: no DF call
        doc = last_sweep(out)
        print("\n".join(rank_lines(doc["results"], a.top) if doc else ["  rank: no finished sweep result in " + str(out)]))
        if doc and doc.get("state") == "running":   # BUG-427
            print(f"  (the sweep is still running: {sum(1 for r in doc['results'] if r.get('sweep'))} world tiles read "
                  "so far; ask again later)")
        return 0 if doc else 1
    here = getattr(a, "here", False)
    try:
        if a.cmd == "rank":   # BUG-410
            if not a.box:
                ap.error("rank needs --box X0,Y0,X1,Y1 (or --last)")
            cands = box_cands(a.box, a.step)
            if a.resume:   # BUG-427
                old = sweep_rows(out)
                cands = [c for c in cands if (c[0], c[1]) not in old]
                print(f"  resume: {len(old)} world tile(s) read before, {len(cands)} left in the box")
                if not cands:
                    print("\n".join(rank_lines(list(old.values()), a.top)))
                    return 0
            spec = make_spec("scan", cands=cands, hover=True, sweep=a.sample)
            if a.timeout == 1800:
                a.timeout = max(1800.0, 2 * len(cands) * (SWEEP_SECONDS[0] + SWEEP_SECONDS[1] * a.sample))
            if a.budget > 0:
                a.timeout = min(a.timeout, a.budget)
        else:
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
    if a.cmd == "rank":   # BUG-427: one flushed line per world tile, the partial pre-rank at the budget or on ^C
        old = sweep_rows(out) if a.resume else {}
        seen = [0]
        total = len(spec["cands"])

        def progress(d):
            rows = [r for r in d.get("results") or [] if isinstance(r, dict) and r.get("sweep")]
            for i, r in enumerate(rows[seen[0]:], seen[0] + 1):
                w = r.get("world") or ["?", "?"]
                print(f"  [{i}/{total}] {w[0]},{w[1]} {r.get('verdict')} {r.get('score')}"
                      f" fail={','.join(r.get('fails') or []) or '-'}", flush=True)
            seen[0] = len(rows)
        try:
            doc = wait(spec["id"], out, a.timeout, on_doc=progress, echo=lambda *_: None)
        except KeyboardInterrupt:
            doc = read_status(out)
        if doc and doc.get("id") == spec["id"] and isinstance(doc.get("results"), list):
            progress(doc)
            if a.resume:
                doc["results"] = list({**old, **sweep_rows(out, doc["results"])}.values())
            lines = summarize(doc, a.top)
            if doc.get("state") == "running":
                lines.append(f"  PARTIAL: {seen[0]} of {total} world tiles read, the sweep still runs in DF. Later: "
                             "rank --last (no DF call), or after it ends the same command with --resume")
            print("\n".join(lines), flush=True)
        else:
            print("\n".join(summarize(doc)))
        return 0 if doc and doc.get("state") in ("done", "running") else 1
    doc = wait(spec["id"], out, a.timeout, on_doc=hook)
    print("\n".join(summarize(doc)))
    if a.cmd == "load":
        print(load_verdict(doc))
    return 0 if doc and doc.get("state") == "done" else 1


if __name__ == "__main__":
    sys.exit(main())
