"""Defense designer (spec v3-08): ``python -m df_llm_helper defense design|status|stats``.

- ``design``: deterministic lane/killbox design from a terrain cut-out (``df_llm_helper.planners.defense``); prints the
  sketch, material list and stages and writes the quickfort CSV (``--out``). NEVER builds on its own: building only
  with ``--apply --confirm`` (runs ``quickfort run`` per stage label; the CSV must be in the DF blueprint folder,
  ``defense.blueprint_dir`` copies it there).
- ``status``: trap reload state from ``claude/pilot_defense status`` (LIVE-UNTESTED) or ``--file`` (fixture JSON);
  warns below ``reload_warn_pct`` loaded stone traps.
- ``stats``: effectiveness after an attack from the gamelog (lines mentioning traps; message texts unverified).

No check_hook on purpose: status needs a DF call and would make every ``python -m df_llm_helper check`` slower.
"""
from __future__ import annotations

import json
import re
import shutil
from pathlib import Path
from typing import Optional

KEY = "defense"
DEFAULTS = {"lane_len": 20, "wall": "Cw", "trap_mix": {"Ts": 0.6, "Tw": 0.3, "Tc": 0.1}, "shooter_niche": True,
            "reload_warn_pct": 70, "components_per_weapon_trap": 1, "bars_per_component": 3,
            "blueprint_dir": "", "blueprint_name": "defense", "in_check": False}

STATUS_CMD = "claude/pilot_defense status"
_STONE = re.compile(r"stone[\s_-]*(fall[\s_-]*)?trap|stonefall", re.I)


def _pt(text: Optional[str]):
    if not text:
        return None
    a = [int(v) for v in re.split(r"[,\s]+", text.strip()) if v]
    if len(a) < 2:
        raise ValueError(f"expected x,y: {text!r}")
    return (a[0], a[1])


def _cfg(args) -> dict:
    from ..config import load_config
    cfg = load_config(getattr(args, "config", None))
    d = dict(DEFAULTS)
    d.update(cfg.get(KEY, {}) or {})
    return d


# ---------------------------------------------------------------- status (pure)
def _is_stone(t: dict) -> bool:
    return str(t.get("kind", "")).lower() == "stone" or bool(_STONE.search(str(t.get("trap_type", ""))))


def evaluate_status(data: dict, warn_pct: float = 70) -> dict:
    """data = JSON of ``claude/pilot_defense status``: traps[{x,y,z,kind|trap_type,loaded}], jobs{raw name: n} or
    [names], stock{mechanisms, trap_components, boulders}. A stone trap without ``loaded`` counts as empty when an
    open stone-trap load job exists for it, else as loaded (unknown)."""
    traps = data.get("traps") or []
    jobs = data.get("jobs") or {}
    if isinstance(jobs, list):
        jl: dict = {}
        for j in jobs:
            name = j.get("name") if isinstance(j, dict) else str(j)
            jl[name] = jl.get(name, 0) + 1
        jobs = jl
    load_jobs = sum(int(n) for name, n in jobs.items() if _STONE.search(str(name)) and re.search(r"load", str(name), re.I))
    stone = [t for t in traps if _is_stone(t)]
    empty = sum(1 for t in stone if t.get("loaded") is False or (t.get("loaded") is None and t.get("load_job")))
    loaded = len(stone) - empty
    pct = round(100.0 * loaded / len(stone), 1) if stone else None
    kinds: dict = {}
    for t in traps:
        k = str(t.get("kind") or t.get("trap_type") or "?")
        kinds[k] = kinds.get(k, 0) + 1
    warn = pct is not None and pct < float(warn_pct)
    return {"stone_total": len(stone), "stone_loaded": loaded, "stone_empty": empty, "pct": pct, "warn": warn,
            "load_jobs": load_jobs, "kinds": kinds, "stock": data.get("stock") or {}}


def status_lines(ev: dict, warn_pct: float = 70) -> list[str]:
    st = ev["stock"]
    if not ev["stone_total"]:
        lines = ["Defense: no stone traps found"]
    else:
        lines = [f"Defense: {ev['stone_loaded']} of {ev['stone_total']} stone traps loaded ({ev['pct']} %), "
                 f"{ev['stone_empty']} empty; open load jobs {ev['load_jobs']}"]
    lines.append("Traps: " + ", ".join(f"{k} {v}" for k, v in sorted(ev["kinds"].items())) +
                 f" | stock: mechanisms {st.get('mechanisms', '?')}, trap components {st.get('trap_components', '?')}, "
                 f"boulders {st.get('boulders', '?')}")
    if ev["warn"]:
        lines.append(f"!! {ev['stone_empty']} of {ev['stone_total']} stone traps empty (< {warn_pct:g} % loaded): "
                     "check mechanics labor, put a stone stockpile next to the lane")
        if ev["load_jobs"] < ev["stone_empty"]:
            lines.append(f"   only {ev['load_jobs']} load jobs open for {ev['stone_empty']} empty traps (stones reachable?)")
    return lines


# ---------------------------------------------------------------- stats (pure, gamelog)
_TRAP = re.compile(r"\btrap\b", re.I)
# job/announcement lines that mention a trap but are not a trap event (BUG-211: 'X cancels Load cage trap: ...')
_JOBLINE = re.compile(r"\bcancels\b|suspend|construction|\bLoad\b.*\btrap\b|\btrap\b.*(?:built|completed)", re.I)
_RELOAD = re.compile(r"\bcancels\b.*\bLoad\b.*\btrap\b", re.I)
# invasion announcements only; 'X attacks Y but Y jumps away' is sparring, 'siege operator' a profession (BUG-211)
_INVASION = re.compile(r"vile force|an ambush|\bambush\b|laying siege|siege(?! operator)|snatcher|\bthief\b|"
                       r"have come|\bare attacking\b", re.I)


def gamelog_stats(lines: list[str]) -> dict:
    """Counts trap events and invasion announcements in gamelog lines. Message texts are NOT verified live: job
    cancels ('cancels Load cage trap') count as reload problems, not as trap events; soldiers sparring is no attack."""
    trap = [ln for ln in lines if _TRAP.search(ln) and not _JOBLINE.search(ln)]
    caught = sum(1 for ln in trap if re.search(r"\bcaught\b", ln, re.I))
    hits = sum(1 for ln in trap if re.search(r"struck|crush|falls|falling|hit|slash|kill|dies|dead", ln, re.I))
    load = sum(1 for ln in lines if _RELOAD.search(ln))
    attacks = sum(1 for ln in lines if _INVASION.search(ln))
    return {"trap_lines": len(trap), "caught": caught, "hits": hits, "load_msgs": load, "attack_lines": attacks}


def stats_lines(s: dict) -> list[str]:
    out = [f"Defense stats (gamelog): trap events {s['trap_lines']} (caught {s['caught']}, hits {s['hits']}), "
           f"reload problems {s['load_msgs']}, invasion announcements {s['attack_lines']}"]
    if s["attack_lines"] and not s["trap_lines"]:
        out.append("!! invasion without any trap event: enemies bypass the lane? check `claude/zugaenge` (spec v3-01)")
    elif s["trap_lines"] and s["hits"] + s["caught"] == 0:
        out.append("Hint: traps mentioned but no hits/captures: lane too short or traps empty (`defense status`)")
    return out


# ---------------------------------------------------------------- apply (explicit only)
def apply_commands(plan, name: str) -> list[str]:
    x, y, z = plan.origin
    labels = re.findall(r"^#build label\((\w+)\)", plan.csv, re.M)
    return [f"quickfort run claude/{name}.csv -n /{lb} -c {x},{y},{z}" for lb in labels]


def apply_plan(client, plan, name: str, confirm: bool) -> tuple[int, list[str]]:
    """Runs quickfort per stage. Refuses without confirm (loop protection: no automatic build)."""
    if not confirm:
        return 2, ["Refused: --apply needs --confirm (no automatic build, spec v3-08 acceptance 5)"]
    if not plan.ok:
        return 2, ["Refused: plan is not valid: " + "; ".join(plan.notes)[:200]]
    out = []
    for cmd in apply_commands(plan, name):
        r = client.run(cmd)
        out.append(f"{'ok ' if r.ok else 'ERR'} {cmd} {(r.stdout or r.stderr or '').strip()[:80]}")
        if not r.ok:
            return 1, out
    return 0, out


# ---------------------------------------------------------------- CLI
def cmd_defense(args) -> int:
    if args.action == "design":
        return _design(args)
    if args.action == "status":
        return _status(args)
    return _stats(args)


_NAME = re.compile(r"[A-Za-z0-9_-]{1,40}")


def _read(path: str, what: str) -> str:
    """Input file -> text; missing/unreadable = usage error (rc 2), not a traceback (BUG-214)."""
    p = Path(path)
    if not p.is_file():
        raise ValueError(f"{what} file not found: {path}")
    try:
        return p.read_text(encoding="utf-8-sig", errors="replace")
    except OSError as e:
        raise ValueError(f"cannot read {what} file {path}: {e.strerror or e}") from None


def _json(path: str, what: str):
    try:
        return json.loads(_read(path, what))
    except json.JSONDecodeError as e:
        raise ValueError(f"{what} file {path} is not valid JSON: {e.msg} (line {e.lineno})") from None


def _design(args) -> int:
    from ..planners.defense import WALKABLE, design_defense, parse_terrain
    cfg = _cfg(args)
    name = args.name if args.name is not None else (cfg.get("blueprint_name") or "defense")
    if not _NAME.fullmatch(str(name)):           # BUG-212: becomes a file name and a quickfort blueprint name
        raise ValueError(f"--name must be 1-40 characters A-Z a-z 0-9 _ - (got {name!r})")
    if args.lane_len is not None:                # BUG-212: 0 was silently ignored
        if args.lane_len < 3:
            raise ValueError(f"--lane-len must be >= 3 (got {args.lane_len})")
        cfg["lane_len"] = int(args.lane_len)
    if args.no_niche:
        cfg["shooter_niche"] = False
    terrain = parse_terrain(_read(args.terrain, "--terrain"))
    stock = _json(args.stock, "--stock") if args.stock else None
    free = sum(1 for row in terrain.rows for ch in row if ch in WALKABLE)
    if int(cfg["lane_len"]) > free:              # fail fast instead of a long search (BUG-212)
        print(f"Defense design FAILED: no lane of length {cfg['lane_len']} fits (the terrain has only {free} "
              "walkable tiles); shorten --lane-len or enlarge the cut-out")
        return 1
    plan = design_defense(terrain, _pt(args.door), _pt(args.access), stock=stock, cfg=cfg)
    if terrain.synthetic:
        print("Note: terrain fixture is marked SYNTHETIC")
    if not plan.lane:
        print("Defense design FAILED: " + "; ".join(plan.notes))
        return 1
    ck = plan.checks
    print(f"Defense design: lane {ck['lane_len']} tiles, door only via lane: {ck['only_via_lane']}, "
          f"mouth {plan.approach}, cursor {plan.origin}")
    print(plan.sketch)
    print("Materials: " + ", ".join(f"{k} {v}" for k, v in plan.materials.items()))
    if plan.missing:
        print("Missing: " + ", ".join(f"{k} {v}" for k, v in plan.missing.items()))
    for s in plan.stages:
        print("Stage " + s)
    for n in plan.notes:
        print("Note: " + n)
    if args.out:
        od = Path(args.out)
        od.mkdir(parents=True, exist_ok=True)
        (od / f"{name}.csv").write_text(plan.csv, encoding="utf-8")
        (od / f"{name}.txt").write_text(plan.sketch + "\n", encoding="utf-8")
        print(f"Written: {od / (name + '.csv')} (+ .txt sketch)")
    elif args.csv:
        print(plan.csv, end="")
    for c in apply_commands(plan, name):
        print(("Run: " if args.apply else "Build later (explicit): ") + c)
    if not args.apply:
        return 0 if plan.ok else 1
    if not args.confirm:
        print("Refused: --apply needs --confirm (no automatic build)")
        return 2
    bdir = cfg.get("blueprint_dir")
    if bdir:
        dst = Path(bdir) / f"{name}.csv"
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_text(plan.csv, encoding="utf-8")
        print(f"Copied to {dst}")
    else:
        print(f"Note: defense.blueprint_dir not set: {name}.csv must already be in dfhack-config/blueprints/claude/")
    from ..cli import _pilot
    rc, lines = apply_plan(_pilot(args).client, plan, name, confirm=True)
    print("\n".join(lines))
    return rc


def _status(args) -> int:
    cfg = _cfg(args)
    if args.file:
        data = _json(args.file, "--file")
    else:
        from ..cli import _pilot
        r = _pilot(args).client.run(STATUS_CMD)
        data = r.json if r.ok and isinstance(r.json, dict) else None
        if not data or data.get("ok") is False:
            print(f"Defense: {STATUS_CMD} not readable (script installed?)")
            return 2
    warn = float(cfg.get("reload_warn_pct", 70))
    ev = evaluate_status(data, warn)
    print("\n".join(status_lines(ev, warn)))
    return 1 if ev["warn"] else 0


def _stats(args) -> int:
    path = args.gamelog
    if not path:
        from ..config import load_config
        path = load_config(getattr(args, "config", None)).get("paths.gamelog")
    p = Path(path)
    if not p.exists():
        print(f"Defense stats: gamelog not found: {p}")
        return 2
    if args.tail is not None and args.tail < 1:
        raise ValueError(f"--tail must be >= 1 (got {args.tail})")
    lines, cut = tail_lines(p, args.tail, STATS_MAX_BYTES)
    out = stats_lines(gamelog_stats(lines))
    if cut:
        out.append(f"(only the last {len(lines)} lines / {STATS_MAX_BYTES // 1_000_000} MB of the gamelog; --tail N)")
    print("\n".join(out))
    return 0


STATS_MAX_BYTES = 8_000_000


def tail_lines(path: Path, n: int | None, max_bytes: int) -> tuple[list[str], bool]:
    """Last n lines (or all lines of the last max_bytes) without reading the whole file (BUG-211: 146 MB = 10 s).
    -> (lines, cut: True when the start of the file was not read)."""
    size = path.stat().st_size
    with path.open("rb") as f:
        start = max(0, size - max_bytes)
        f.seek(start)
        data = f.read()
    text = data.decode("utf-8", errors="replace")
    lines = text.splitlines()
    if start > 0 and lines:
        lines = lines[1:]                        # first line is cut in the middle
    if n is not None:
        cut = start > 0 or len(lines) > n
        return lines[-n:], cut and len(lines) >= n
    return lines, start > 0


def register(sub) -> None:
    s = sub.add_parser("defense", help="Defense designer (spec v3-08): design|status|stats (design never builds "
                                       "without --apply --confirm)")
    s.add_argument("action", choices=["design", "status", "stats"])
    s.add_argument("--terrain", default=None, help="design: terrain cut-out (see fixtures/v3/defense/plateau_z133.txt)")
    s.add_argument("--door", default=None, help="design: door tile x,y (overrides the terrain file)")
    s.add_argument("--access", default=None, help="design: access point x,y (overrides the terrain file)")
    s.add_argument("--lane-len", type=int, default=None)
    s.add_argument("--no-niche", action="store_true", help="design: no shooter niche")
    s.add_argument("--stock", default=None, help="design: stock JSON {mechanisms, trap_components, blocks, stones, bars}")
    s.add_argument("--out", default=None, help="design: folder for <name>.csv + <name>.txt")
    s.add_argument("--name", default=None, help="design: blueprint name (default defense.blueprint_name)")
    s.add_argument("--csv", action="store_true", help="design: print the CSV")
    s.add_argument("--apply", action="store_true", help="design: build via quickfort (needs --confirm)")
    s.add_argument("--confirm", action="store_true", help="design: confirm --apply")
    s.add_argument("--file", default=None, help="status: JSON fixture instead of claude/pilot_defense status")
    s.add_argument("--gamelog", default=None, help="stats: gamelog file (default paths.gamelog)")
    s.add_argument("--tail", type=int, default=None, help="stats: only the last N lines")
    s.set_defaults(fn=_dispatch)


def _dispatch(args) -> int:
    if args.action == "design" and not args.terrain:
        print("defense design needs --terrain <file>")
        return 2
    return cmd_defense(args)
