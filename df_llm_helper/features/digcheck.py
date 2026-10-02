"""Spec v3-02: dig safety checker (`python -m df_llm_helper digcheck`, alias `python -m df_llm_helper dig check`).

Checks dig orders BEFORE they are designated. Run 5: the farm hall z131 broke through to the surface (north opening),
the diagonal water access F=(184,43,z128) flooded tunnel W, stages ran into the blocked boxes, and unreachable
designations produced "Inappropriate dig square" cancel loops (41 cancels, 29 dwarves).

Input: `rect z x1 y1 x2 y2 [mode]` (like claude/dig), a quickfort #dig CSV (--csv FILE -c x,y,z) or a stage of
lua/claude/stages.lua (--stages FILE --stage NAME; literal add(...) lines only).
Tiles: lua/pilot_digcheck.lua dump, in blocks of <= 500 targets (box + margin 2) with a pause in between.
Rules per target (only REVEALED tiles; unrevealed targets are reported, never judged):
  R1 level z_min <= z <= z_max
  R2 outside contact: no outside tile/sky within the roof thickness (1; 2 at z >= surface_z) unless near an
     allowed access (perimeter allow-list)
  R3 water/magma in the 26-neighborhood (incl. diagonal and z+-1) or an aquifer wall
  R4 blocked boxes (digcheck.forbid_boxes + water.forbid_dig)
  R5 caverns: configured cavern boxes within 2, or >= cavern_void_min underground open-space tiles within 2
  R6 access: designation on an undiggable tile ("inappropriate dig square") or no walkable neighbor for the whole
     connected group of targets
Read only: nothing is designated; --strip prints the remaining dig commands without the problematic rows.
"""
from __future__ import annotations

import re
import time
from dataclasses import dataclass, field
from pathlib import Path

from ._grid import OUTSIDE, WALK, Grid, box_dist, clusters, fmt, in_box

__all__ = ["KEY", "DEFAULTS", "Finding", "DigReport", "parse_rect", "parse_qf_csv", "parse_stages", "check_targets",
           "strip_commands", "inappropriate_cancels", "DigCheck", "register", "check_hook"]

KEY = "digcheck"
DEFAULTS = {"z_min": 104, "z_max": 140, "roof_min": 1, "roof_min_surface": 2, "surface_z": 130, "forbid_boxes": [],
            "use_water_boxes": True, "cavern_boxes": [], "cavern_void_min": 8, "max_cells": 3000, "block": 500,
            "pause_s": 0.2, "in_check": True}
LINE_MAX = 120
DIG_MODES = set("dhujir")
RULE_TEXT = {"R1": "level outside z_min..z_max", "R2": "outside contact", "R3": "water/magma/aquifer",
             "R4": "blocked box", "R5": "cavern nearby", "R6": "no access / inappropriate dig square"}


@dataclass(frozen=True)
class Finding:
    rule: str
    xyz: tuple
    text: str
    detail: str = ""        # e.g. the outside tile; not used for grouping


@dataclass
class DigReport:
    name: str
    cells: int
    findings: list = field(default_factory=list)
    unrevealed: list = field(default_factory=list)
    uncertain: list = field(default_factory=list)       # revealed targets with unrevealed neighbors
    blocks: int = 0
    elapsed_s: float = 0.0
    error: str = ""

    @property
    def result(self) -> str:
        if self.error or self.findings:
            return "refused"
        return "unsafe" if self.unrevealed or self.uncertain else "ok"

    def rules(self) -> dict:
        out: dict = {}
        for f in self.findings:
            out.setdefault(f.rule, []).append(f)
        return out

    def summary(self) -> str:
        if self.error:
            return f"digcheck {self.name}: refused ({self.error})"
        rs = self.rules()
        parts = [f"{r} x{len(v)}" for r, v in sorted(rs.items())]
        extra = []
        if self.unrevealed:
            extra.append(f"{len(self.unrevealed)} unrevealed not judged")
        if self.uncertain:
            extra.append(f"{len(self.uncertain)} with unrevealed neighbors")
        s = f"digcheck {self.name}: {self.result} ({self.cells} tiles"
        s += (", " + ", ".join(parts) if parts else "") + (", " + ", ".join(extra) if extra else "") + ")"
        return s[:LINE_MAX]

    def lines(self, limit: int = 12) -> list:
        out = [self.summary()]
        for rule, fs in sorted(self.rules().items()):
            groups: dict = {}
            detail: dict = {}
            for f in fs:
                groups.setdefault(f.text, []).append(f.xyz)
                if f.detail:
                    detail.setdefault((f.text, f.xyz), f.detail)
            for text, pts in groups.items():
                for cl in clusters(pts, 1, 0):
                    xs, ys = [p[0] for p in cl], [p[1] for p in cl]
                    where = (fmt(cl[0]) if len(cl) == 1 else
                             f"x{min(xs)}..{max(xs)} y{min(ys)}..{max(ys)} z{cl[0][2]} ({len(cl)} tiles)")
                    d = detail.get((text, cl[0]))
                    out.append(f"{rule} {text}: {where}" + (f", e.g. {d}" if d else ""))
        if self.unrevealed:
            out.append(f"unrevealed (not judged): {len(self.unrevealed)} tiles, e.g. {fmt(self.unrevealed[0])}")
        if len(out) > limit:
            out = out[:limit] + [f"... +{len(out) - limit} lines"]
        return out


# ---------------------------------------------------------------- inputs

_RECT = re.compile(r"^(?:claude/dig\s+)?(-?\d+)\s+(-?\d+)\s+(-?\d+)\s+(-?\d+)\s+(-?\d+)(?:\s+(\w))?\s*$")


def parse_rect(text: str) -> dict:
    """'z x1 y1 x2 y2 [mode]' (claude/dig order) -> {(x,y,z): mode}."""
    m = _RECT.match(" ".join(text.split()))
    if not m:
        raise ValueError(f"rect: expected 'z x1 y1 x2 y2 [mode]', got {text!r}")
    z, x1, y1, x2, y2 = (int(m.group(i)) for i in range(1, 6))
    mode = m.group(6) or "d"
    return {(x, y, z): mode for x in range(min(x1, x2), max(x1, x2) + 1) for y in range(min(y1, y2), max(y1, y2) + 1)}


def parse_qf_csv(text: str, cursor) -> dict:
    """Quickfort #dig CSV (cells d/h/u/j/i/r, '#>' one level down, '#<' one level up) at cursor (x, y, z)."""
    x0, y0, z = (int(v) for v in cursor)
    out, row, started = {}, 0, False
    for raw in text.splitlines():
        s = raw.strip()
        if s.startswith("#dig"):
            started = True
            continue
        if s.startswith("#>"):
            z, row = z - 1, 0
            continue
        if s.startswith("#<"):
            z, row = z + 1, 0
            continue
        if s.startswith("#"):
            continue
        if not started:
            continue
        for i, cell in enumerate(raw.split(",")):
            c = cell.strip().strip('"')
            if c and c[0] in DIG_MODES:
                out[(x0 + i, y0 + row, z)] = c[0]
        row += 1
    return out


_ADD = re.compile(r"add\(\s*'([^']+)'\s*,\s*(-?\d+)\s*,\s*(-?\d+)\s*,\s*(-?\d+)\s*,\s*(-?\d+)\s*,\s*(-?\d+)\s*\)")


def parse_stages(text: str, name: str) -> tuple:
    """Literal add('name', z, x1, y1, x2, y2) lines of stages.lua -> (targets, rects). Stage = exact name or prefix
    ('N11' matches 'N11_Wohn1'). Stages generated in loops are not visible here (reported as 0 tiles)."""
    targets, rects = {}, []
    for m in _ADD.finditer(text):
        nm = m.group(1)
        if nm == name or nm.split("_")[0] == name:
            z, x1, y1, x2, y2 = (int(m.group(i)) for i in range(2, 7))
            rects.append((z, x1, y1, x2, y2))
            targets.update(parse_rect(f"{z} {x1} {y1} {x2} {y2} d"))
    return targets, rects


# ---------------------------------------------------------------- rules

def _kind(dx: int, dy: int, dz: int) -> str:
    if dz:
        return "vertical" if dx == 0 and dy == 0 else f"slanted z{dz:+d}"
    if dx == 0 and dy == 0:
        return "on the tile"
    return "orthogonal" if dx == 0 or dy == 0 else "diagonal"


def check_targets(grid: Grid, targets: dict, cfg: dict | None = None, *, forbid_boxes=None, allow=None,
                  tol=(4, 2), name: str = "stage") -> DigReport:
    """Pure rule evaluation on a grid (fixture or Lua dump)."""
    c = {**DEFAULTS, **(cfg or {})}
    rep = DigReport(name, len(targets))
    boxes = list(c["forbid_boxes"] or []) + list(forbid_boxes or [])
    allow = list(allow or [])
    diggable = []
    for t in sorted(targets, key=lambda p: (p[2], p[1], p[0])):
        mode = targets[t]
        if mode == "x":
            continue
        ch = grid.get(t)
        x, y, z = t
        if ch == "?":
            rep.unrevealed.append(t)
            continue
        if not c["z_min"] <= z <= c["z_max"]:
            rep.findings.append(Finding("R1", t, f"z{z} outside {c['z_min']}..{c['z_max']}"))
        for b in boxes:
            if in_box(t, b):
                rep.findings.append(Finding("R4", t, f"in blocked box {list(b)}"))
                break
        hidden_n = False
        r2 = int(c["roof_min_surface"] if z >= c["surface_z"] else c["roof_min"])
        r = max(r2, 2)
        voids, water, aquifer, outside = 0, None, None, None
        for dz in range(-r, r + 1):
            for dy in range(-r, r + 1):
                for dx in range(-r, r + 1):
                    q = (x + dx, y + dy, z + dz)
                    qc = grid.get(q)
                    near1 = max(abs(dx), abs(dy), abs(dz)) <= 1
                    if qc == "?":
                        hidden_n = hidden_n or near1
                        continue
                    if qc == "V" and max(abs(dx), abs(dy), abs(dz)) <= 2:
                        voids += 1
                    if near1 and qc in "~M" and water is None:
                        water = (dx, dy, dz, qc)
                    if near1 and qc == "A" and aquifer is None:
                        aquifer = (dx, dy, dz)
                    if (qc in OUTSIDE and max(abs(dx), abs(dy), abs(dz)) <= r2 and outside is None
                            and not any(abs(q[0] - a[0]) <= tol[0] and abs(q[1] - a[1]) <= tol[0]
                                        and abs(q[2] - a[2]) <= tol[1] for a in allow)):
                        outside = q
        if outside is not None:
            rep.findings.append(Finding("R2", t, f"outside contact within {r2}", f"outside tile {fmt(outside)}"))
        if water is not None:
            what = "Magma" if water[3] == "M" else "Water"
            rep.findings.append(Finding("R3", t, f"{what} {_kind(*water[:3])} ({water[0]},{water[1]},{water[2]})"))
        elif aquifer is not None:
            rep.findings.append(Finding("R3", t, f"aquifer wall {_kind(*aquifer)} ({aquifer[0]},{aquifer[1]},{aquifer[2]})"))
        cav = [b for b in (c["cavern_boxes"] or []) if box_dist(t, b) <= 2]
        if cav:
            rep.findings.append(Finding("R5", t, f"cavern box {list(cav[0])} within 2"))
        elif voids >= int(c["cavern_void_min"]):
            rep.findings.append(Finding("R5", t, f"underground open space nearby ({voids} tiles within 2): cavern?"))
        ok_tile = ch in "#A" or (mode == "h" and ch in "#A.,")
        if not ok_tile:
            what = {"C": "a construction (remove it instead)", "~": "liquid", "M": "magma"}.get(
                ch, "already dug/open" if ch in WALK or ch in "_'V" else ch)
            rep.findings.append(Finding("R6", t, f"inappropriate dig square: tile is {what}"))
        elif not hidden_n:
            diggable.append(t)
        if hidden_n:
            rep.uncertain.append(t)
    # R6 access: groups of diggable targets without any walkable neighbor
    tset = set(diggable)
    stair_mode = {t for t in tset if targets[t] in "ujih"}
    reached = set()
    for t in tset:
        x, y, z = t
        same = any(grid.get((x + dx, y + dy, z)) in WALK for dx in (-1, 0, 1) for dy in (-1, 0, 1) if dx or dy)
        vert = t in stair_mode and any(grid.get((x + dx, y + dy, z + dz)) in WALK
                                       for dz in (-1, 1) for dx in (-1, 0, 1) for dy in (-1, 0, 1))
        if same or vert:
            reached.add(t)
    stack = list(reached)
    while stack:
        x, y, z = stack.pop()
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for dz in ((-1, 0, 1) if (x, y, z) in stair_mode else (0,)):
                    q = (x + dx, y + dy, z + dz)
                    if q in tset and q not in reached and (dz == 0 or q in stair_mode):
                        reached.add(q)
                        stack.append(q)
    unreachable = set(rep.uncertain)
    for t in sorted(tset - reached, key=lambda p: (p[2], p[1], p[0])):
        if t not in unreachable:
            rep.findings.append(Finding("R6", t, "no walkable neighbor for this group (unreachable -> "
                                                 "'Inappropriate dig square' cancel loop)"))
    return rep


def strip_commands(targets: dict, rep: DigReport) -> list:
    """--strip: drop every row (same z, y) that holds a finding or an unrevealed tile; the rest as claude/dig orders."""
    bad_rows = {(f.xyz[2], f.xyz[1]) for f in rep.findings} | {(t[2], t[1]) for t in rep.unrevealed}
    rows: dict = {}
    for (x, y, z), mode in targets.items():
        if (z, y) not in bad_rows:
            rows.setdefault((z, y, mode), []).append(x)
    out = []
    for (z, y, mode), xs in sorted(rows.items()):
        xs.sort()
        start = prev = xs[0]
        for x in xs[1:] + [None]:
            if x is not None and x == prev + 1:
                prev = x
                continue
            out.append(f"claude/dig {z} {start} {y} {prev} {y}" + ("" if mode == "d" else f" {mode}"))
            if x is not None:
                start = prev = x
    return out


def inappropriate_cancels(lines) -> tuple:
    """Gamelog: (count, dwarves) of 'cancels Dig...: Inappropriate dig square'."""
    from ..anomaly import cancel_loops
    n = who = 0
    for c in cancel_loops(lines, min_count=1):
        if "inappropriate dig square" in c.reason.lower():
            n += c.count
            who = max(who, c.who)
    return n, who


# ---------------------------------------------------------------- live

class DigCheck:
    def __init__(self, client, store, clock, cfg: dict | None = None, *, water_boxes=None, allow=None, tol=(4, 2)):
        self.client, self.store, self.clock = client, store, clock
        self.cfg = {**DEFAULTS, **(cfg or {})}
        self.water_boxes = list(water_boxes or []) if self.cfg["use_water_boxes"] else []
        self.allow = list(allow or [])
        self.tol = tol

    def fetch(self, targets: dict) -> tuple:
        """Dump the tiles around the targets in blocks of <= block targets (box + margin 2), pause between blocks.
        -> (grid, blocks, error)."""
        from ..client import register_read
        pts = sorted(targets, key=lambda p: (p[2], p[1], p[0]))
        block = max(1, int(self.cfg["block"]))
        grid = Grid(default="?")                 # tiles that could not be read count as unrevealed
        blocks = 0
        for i in range(0, len(pts), block):
            chunk = pts[i:i + block]
            xs, ys, zs = [p[0] for p in chunk], [p[1] for p in chunk], [p[2] for p in chunk]
            cmd = (f"claude/pilot_digcheck dump {min(xs) - 2} {min(ys) - 2} {min(zs) - 2} {max(xs) + 2} "
                   f"{max(ys) + 2} {max(zs) + 2}")
            register_read(cmd)
            r = self.client.run(cmd)
            j = r.json if r.ok else None
            if not (isinstance(j, dict) and j.get("ok")):
                return grid, blocks, f"tiles not readable ({(j or {}).get('error') if isinstance(j, dict) else r.stderr[:60]})"
            grid.add_dump(j)
            blocks += 1
            if i + block < len(pts) and float(self.cfg["pause_s"]) > 0:
                self.clock.sleep(float(self.cfg["pause_s"]))
        return grid, blocks, ""

    def check(self, targets: dict, name: str = "stage", *, grid: Grid | None = None, dry: bool = True) -> DigReport:
        t0 = time.time()
        if len(targets) > int(self.cfg["max_cells"]):
            rep = DigReport(name, len(targets), error=f"{len(targets)} tiles > max_cells {self.cfg['max_cells']}: "
                                                      f"split the stage")
        else:
            blocks, err = 0, ""
            if grid is None:
                grid, blocks, err = self.fetch(targets)
            if err:
                rep = DigReport(name, len(targets), blocks=blocks, error=err)
            else:
                rep = check_targets(grid, targets, self.cfg, forbid_boxes=self.water_boxes, allow=self.allow,
                                    tol=self.tol, name=name)
                rep.blocks = blocks
        rep.elapsed_s = time.time() - t0
        now = self.clock.now().epoch
        self.store.log_action(now, "digcheck", "digcheck", "check", name, f"{len(targets)} tiles", dry,
                              rep.result == "ok", rep.summary())
        if rep.result != "ok":
            self.store.set("digcheck.unreported", rep.summary())
        return rep


# ---------------------------------------------------------------- CLI + check hook

def _targets(args) -> tuple:
    if args.csv:
        if not args.cursor:
            raise ValueError("--csv needs -c x,y,z")
        cur = [int(v) for v in args.cursor.split(",")]
        return parse_qf_csv(Path(args.csv).read_text(encoding="utf-8"), cur), Path(args.csv).name
    if args.stages:
        if not args.stage:
            raise ValueError("--stages needs --stage NAME")
        t, _ = parse_stages(Path(args.stages).read_text(encoding="utf-8"), args.stage)
        return t, args.stage
    if args.rect:
        return parse_rect(" ".join(args.rect)), "rect " + " ".join(args.rect)
    raise ValueError("digcheck: give rect z x1 y1 x2 y2 [mode] | --csv FILE -c x,y,z | --stages FILE --stage NAME")


def cmd_digcheck(args) -> int:
    from ..cli import _pilot
    from ..toolsfs import read_text_tolerant
    p = _pilot(args)
    targets, name = _targets(args)
    pcfg = p.cfg.get("perimeter", {}) or {}
    allow = []
    try:
        from .perimeter import Perimeter
        allow = Perimeter(p.client, p.tools, p.store, p.clock, pcfg).allow()
    except Exception:
        pass
    dc = DigCheck(p.client, p.store, p.clock, p.cfg.get(KEY, {}) or {}, water_boxes=p.cfg.get("water.forbid_dig"),
                  allow=allow, tol=(int(pcfg.get("tolerance_xy", 4)), int(pcfg.get("tolerance_z", 2))))
    grid = Grid.from_file(args.grid) if args.grid else None
    rep = dc.check(targets, name, grid=grid)
    lines = rep.lines()
    if args.gamelog:
        n, who = inappropriate_cancels(read_text_tolerant(Path(args.gamelog)).splitlines())
        if n:
            lines.append(f"gamelog: {n}x 'Inappropriate dig square' ({who} dwarves) - check R6 targets")
    if args.strip and rep.result != "ok":
        cmds = strip_commands(targets, rep)
        lines.append(f"--strip: {len(cmds)} dig orders without the problematic rows:")
        lines += cmds
    print("\n".join(lines))
    return {"ok": 0, "unsafe": 1}.get(rep.result, 2)


def _add_args(s) -> None:
    s.add_argument("rect", nargs="*", help="z x1 y1 x2 y2 [mode] (like claude/dig)")
    s.add_argument("--csv", help="quickfort #dig CSV")
    s.add_argument("-c", "--cursor", help="x,y,z of the CSV cursor")
    s.add_argument("--stages", help="stages.lua")
    s.add_argument("--stage", help="stage name or prefix (e.g. N11)")
    s.add_argument("--strip", action="store_true", help="print the dig orders without the problematic rows")
    s.add_argument("--grid", help="offline: grid fixture instead of live DF")
    s.add_argument("--gamelog", help="gamelog excerpt: count 'Inappropriate dig square' cancels")


def cmd_dig(args) -> int:
    return cmd_digcheck(args)


def register(sub) -> None:
    s = sub.add_parser("digcheck", help="Dig safety checker (spec v3-02): check dig orders before designating")
    _add_args(s)
    s.set_defaults(fn=cmd_digcheck)
    try:
        d = sub.add_parser("dig", help="alias: dig check ... = digcheck ...")
    except Exception:                                    # another module already owns 'dig'
        return
    d.add_argument("action", choices=["check"])
    _add_args(d)
    d.set_defaults(fn=cmd_dig)


def check_hook(pilot, report, dry: bool) -> list:
    """One line after a refused/unsafe check (once)."""
    msg = pilot.store.get("digcheck.unreported")
    if not msg:
        return []
    if not dry:
        pilot.store.set("digcheck.unreported", None)
    return [str(msg)[:LINE_MAX]]
