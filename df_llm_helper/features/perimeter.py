"""Spec v3-01: access watcher (`python -m df_llm_helper perimeter`).

Run 5 (J109): dig programs opened the north side of the farm hall z131 (23 tiles) and a stub stair (96,88); several
armies walked past the traps. Standing order of the player: "close everything except the trap path, watch for new openings".

- scan:   lua/pilot_perimeter.lua (multi-source BFS from the outside, chunked via dfhack.timeout, result file) delivers
          entry tiles with flags core/notrap; here: clustering (+-2 xy, +-1 z), allow-list (tools/zugang-erlaubt.txt,
          tolerance +-4 xy / +-2 z), findings = clusters leading to the core that are not allowed
- report: only on change (signature of the forbidden clusters); all-clear when closed; digest line
          "Accesses: 1 allowed, 0 forbidden (checked 20:05)"
- seal:   Quickfort '#build' CSV with Cw on the entry tiles; stairs/ramps are not buildable -> walls on the
          adjacent inside floor tiles instead. --dry-run writes the CSV, --apply runs quickfort (build orders) after
          `reach what-if` (never cuts a mandatory point without --override).
Read only except the explicit seal --apply (normal build orders, fair play).
"""
from __future__ import annotations

import re
import time
from dataclasses import dataclass, field
from pathlib import Path

from ._grid import OUTSIDE, STAIRS, WALK, Grid, clusters, core_sets, entries, fmt

__all__ = ["KEY", "DEFAULTS", "Access", "scan_grid", "parse_scan", "load_allow", "allow_entries", "is_allowed", "build_accesses",
           "signature", "digest_line", "diff_lines", "seal_walls", "seal_csv", "Perimeter", "register", "check_hook"]

KEY = "perimeter"
DEFAULTS = {"core": [100, 101, 130], "interval_s": 1200, "allow_file": "zugang-erlaubt.txt", "tolerance_xy": 4,
            "tolerance_z": 2, "z_range": [100, 136], "cluster_xy": 2, "cluster_z": 1, "chunked": True,
            "budget": 20000, "poll_s": 2.0, "timeout_s": 120, "blueprint": "claude/df_llm_helper_seal.csv",
            "blueprints_dir": None, "in_check": True, "min_outside": 3000}
LINE_MAX = 120


@dataclass
class Access:
    tiles: list
    core: bool
    notrap: bool
    allowed: bool = False

    @property
    def n(self) -> int:
        return len(self.tiles)

    @property
    def center(self) -> tuple:
        n = len(self.tiles)
        return (round(sum(t[0] for t in self.tiles) / n), round(sum(t[1] for t in self.tiles) / n),
                min(t[2] for t in self.tiles))

    @property
    def z_span(self) -> str:
        z0, z1 = min(t[2] for t in self.tiles), max(t[2] for t in self.tiles)
        return f"z{z0}" if z0 == z1 else f"z{z0}-{z1}"

    @property
    def forbidden(self) -> bool:
        return self.core and not self.allowed

    def label(self) -> str:
        c = self.center
        return f"({c[0]},{c[1]},{self.z_span}) {self.n} tile{'s' if self.n != 1 else ''}"

    def line(self) -> str:
        kind = "allowed" if self.allowed and self.core else "FORBIDDEN" if self.forbidden else "dead end"
        trap = ", bypasses the traps" if self.notrap else (", through the traps" if self.core else "")
        return f"{kind}: {self.label()}{trap}"


def _outside_area_ok(grid: Grid, start, min_outside: int, memo: dict) -> bool:
    """Enclave filter of pilot_perimeter.lua: the connected outside area of `start` has >= min_outside tiles."""
    if start in memo:
        return memo[start]
    seen, q, i = {start}, [start], 0
    while i < len(q) and len(q) < min_outside:
        for n in grid.neighbors(q[i]):
            if n not in seen and grid.outside(n):
                seen.add(n)
                q.append(n)
        i += 1
    big = len(q) >= min_outside
    for p in seen:
        memo[p] = big
    return big


def scan_grid(grid: Grid, core, z_range=None, min_outside: int = 0) -> list:
    """Python reference of pilot_perimeter.lua on a grid fixture -> [(x,y,z,core,notrap)].
    min_outside > 1: an entry counts only if an adjacent reached outside area has >= min_outside tiles (enclave filter,
    same as the Lua 8th argument; the small fixture grids use 0 = no filter)."""
    allc, notrap = core_sets(grid, tuple(core), z_range)
    ents = entries(grid, z_range)
    if min_outside > 1:
        zr = z_range or (-10**9, 10**9)
        memo: dict = {}
        ents = [e for e in ents
                if any(zr[0] <= n[2] <= zr[1] and grid.outside(n) and _outside_area_ok(grid, n, min_outside, memo)
                       for n in grid.neighbors(e))]
    return [(e[0], e[1], e[2], e in allc, e in notrap) for e in ents]


def parse_scan(j) -> list | None:
    if not isinstance(j, dict) or not j.get("ok") or not j.get("done"):
        return None
    out = []
    for e in j.get("entries") or []:
        if isinstance(e, list) and len(e) >= 5:
            out.append((int(e[0]), int(e[1]), int(e[2]), bool(e[3]), bool(e[4])))
    return out


_ALLOW = re.compile(r"^\s*(-?\d+)\s*,\s*(-?\d+)\s*,\s*(-?\d+)")


def load_allow(path) -> list:
    """tools/zugang-erlaubt.txt: one 'x,y,z  comment' per line."""
    p = Path(path)
    if not p.exists():
        return []
    out = []
    for ln in p.read_text(encoding="utf-8", errors="replace").splitlines():
        m = _ALLOW.match(ln)
        if m:
            out.append(tuple(int(v) for v in m.groups()))
    return out


def allow_entries(path) -> list:
    """Allow-list with notes: [((x, y, z), note)] (BUG-217: the listing hid the notes)."""
    p = Path(path)
    if not p.exists():
        return []
    out = []
    for ln in p.read_text(encoding="utf-8", errors="replace").splitlines():
        m = _ALLOW.match(ln)
        if m:
            out.append((tuple(int(v) for v in m.groups()), ln[m.end():].strip()))
    return out


def _allow_coords(words) -> tuple:
    vals = [str(w).strip() for w in words]
    if len(vals) != 3 or not all(v.lstrip("-").isdigit() for v in vals):
        raise ValueError(f"usage: perimeter allow X Y Z [--note TEXT] (three integers), got {' '.join(vals)}")
    return tuple(int(v) for v in vals)


def _allow_warnings(p, per, xyz) -> list:
    """Refuse coordinates outside the map; warn when the entry would legalise accesses next to the core (BUG-217)."""
    x, y, z = xyz
    ms = None
    if min(xyz) >= 0:
        r = p.client.run("claude/status")
        m = (r.json or {}).get("map_size") if r.ok and isinstance(r.json, dict) else None
        if isinstance(m, dict) and all(k in m for k in "xyz"):
            ms = (int(m["x"]), int(m["y"]), int(m["z"]))
    if min(xyz) < 0 or (ms and (x >= ms[0] or y >= ms[1] or z >= ms[2])):
        return [f"Refused: ({x},{y},z{z}) is outside the map" + (f" ({ms[0]}x{ms[1]}x{ms[2]})" if ms else "")]
    c = per.cfg["core"]
    if is_allowed((x, y, z), [tuple(c)], int(per.cfg["tolerance_xy"]), int(per.cfg["tolerance_z"])):
        return [f"WARNING: ({x},{y},z{z}) lies within the tolerance of the core {tuple(c)}: every access near the core "
                "counts as allowed"]
    return []


def is_allowed(center, allow, tol_xy: int = 4, tol_z: int = 2) -> bool:
    return any(abs(center[0] - a[0]) <= tol_xy and abs(center[1] - a[1]) <= tol_xy and abs(center[2] - a[2]) <= tol_z
               for a in allow)


def build_accesses(ents, allow, cfg: dict | None = None) -> list:
    c = {**DEFAULTS, **(cfg or {})}
    flags = {(e[0], e[1], e[2]): (e[3], e[4]) for e in ents}
    out = []
    for cl in clusters(flags, int(c["cluster_xy"]), int(c["cluster_z"])):
        a = Access(cl, any(flags[t][0] for t in cl), any(flags[t][1] for t in cl))
        a.allowed = is_allowed(a.center, allow, int(c["tolerance_xy"]), int(c["tolerance_z"]))
        out.append(a)
    out.sort(key=lambda a: (not a.forbidden, not a.core, a.center))
    return out


def signature(accesses) -> list:
    return sorted([a.center[0] // 4, a.center[1] // 4, a.center[2]] for a in accesses if a.forbidden)


def digest_line(accesses, hhmm: str) -> str:
    allowed = sum(1 for a in accesses if a.core and a.allowed)
    bad = sum(1 for a in accesses if a.forbidden)
    return f"Accesses: {allowed} allowed, {bad} forbidden (checked {hhmm})"


def diff_lines(prev_sig, accesses) -> list:
    """WAKE lines only for changes: new forbidden accesses; all-clear when the last one is closed."""
    sig = signature(accesses)
    prev = [list(s) for s in (prev_sig or [])]
    out = []
    for a in accesses:
        if a.forbidden and [a.center[0] // 4, a.center[1] // 4, a.center[2]] not in prev:
            out.append(f"WAKE perimeter: forbidden access to the core at {a.label()} -> seal "
                       f"(python -m df_llm_helper perimeter seal --dry-run)"[:LINE_MAX + 40])
    if prev and not sig:
        out.append("WAKE perimeter: all forbidden accesses closed (only allowed ones open)")
    elif prev and sig != prev and not out:
        out.append(f"perimeter: {len(prev) - len(sig)} forbidden access(es) closed, {len(sig)} still open")
    return out


def seal_walls(grid: Grid, access: Access) -> tuple:
    """Wall tiles for one access. Stairs/ramps cannot carry a construction: walls go on the adjacent INSIDE floor
    tiles of the same level instead. Building tiles (door/trap) are left to the player. -> (walls, notes)."""
    walls, notes = set(), []
    for t in access.tiles:
        c = grid.get(t)
        if c in STAIRS:
            x, y, z = t
            found = False
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    q = (x + dx, y + dy, z)
                    qc = grid.get(q)
                    if (dx or dy) and qc in WALK and qc not in OUTSIDE and qc not in STAIRS and qc not in "DT":
                        walls.add(q)
                        found = True
            if not found:                       # BUG-217: say why there is no proposal instead of "nothing to do"
                notes.append(f"stair/ramp entry {fmt(t)} has no inside floor tile next to it on its level (only "
                             "outside floor/walls) - seal by hand: wall/door on the level the stair leads to, or "
                             "remove the stair")
        elif c in "DT":
            notes.append(f"building on entry tile {fmt(t)} - seal by hand")
        elif c in WALK:
            walls.add(t)
    return sorted(walls), notes


def seal_csv(walls, label: str = "df_llm_helper_seal") -> tuple:
    """Quickfort #build CSV (Cw = constructed wall) for all walls. Levels top-down separated by '#>'.
    -> (csv text, cursor (x, y, z) = top-left of the highest level)."""
    if not walls:
        return "", None
    xs, ys, zs = [w[0] for w in walls], [w[1] for w in walls], [w[2] for w in walls]
    x0, x1, y0, y1, z0, z1 = min(xs), max(xs), min(ys), max(ys), min(zs), max(zs)
    ws = set(map(tuple, walls))
    lines = [f"#build label({label}) message(python -m df_llm_helper perimeter seal: {len(ws)} walls, cursor {x0},{y0},{z1})"]
    for z in range(z1, z0 - 1, -1):
        if z != z1:
            lines.append("#>")
        for y in range(y0, y1 + 1):
            row = ",".join("Cw" if (x, y, z) in ws else "" for x in range(x0, x1 + 1)).rstrip(",")
            lines.append(row or "`")                  # keep the row: a bare backtick is an empty quickfort cell
    return "\n".join(lines) + "\n", (x0, y0, z1)


class Perimeter:
    def __init__(self, client, tools, store, clock, cfg: dict | None = None):
        self.client, self.tools, self.store, self.clock = client, tools, store, clock
        self.cfg = {**DEFAULTS, **(cfg or {})}
        self.extra_allow: list = []        # offline: '@allow x y z' lines of a grid fixture

    @property
    def allow_path(self) -> Path:
        p = Path(self.cfg["allow_file"])
        return p if p.is_absolute() else Path(self.tools.path) / p

    def allow(self) -> list:
        return load_allow(self.allow_path) + [tuple(a) for a in self.extra_allow]

    def _read(self, cmd: str):
        from ..client import register_read
        register_read(cmd)
        r = self.client.run(cmd, timeout=float(self.cfg["timeout_s"]))
        return r.json if r.ok else None

    def _args(self) -> str:
        c, zr = self.cfg["core"], self.cfg["z_range"]
        return f"{c[0]} {c[1]} {c[2]} {zr[0]} {zr[1]} {int(self.cfg['budget'])} {int(self.cfg['min_outside'])}"

    # ---- live scan
    def start(self) -> bool:
        from ..client import register_read
        cmd = "claude/pilot_perimeter start " + self._args()
        register_read(cmd)                  # read only for the game (writes only the result file in tools/out)
        r = self.client.run(cmd)
        ok = r.ok and isinstance(r.json, dict) and bool(r.json.get("ok"))
        if ok:
            self.store.set("perimeter.pending", self.clock.now().epoch)
        return ok

    def result(self):
        return self._read("claude/pilot_perimeter result")

    def scan_live(self) -> list | None:
        """Chunked (default): start + poll the result file; otherwise one synchronous call (blocks DF ~10 s)."""
        if not self.cfg["chunked"]:
            return parse_scan(self._read("claude/pilot_perimeter scan " + self._args()))
        if not self.start():
            return None
        t_end = self.clock.now().epoch + float(self.cfg["timeout_s"])
        while self.clock.now().epoch <= t_end:
            j = self.result()
            ents = parse_scan(j)
            if ents is not None:
                self.store.set("perimeter.pending", None)
                return ents
            if isinstance(j, dict) and j.get("done") and not j.get("ok"):
                break
            self.clock.sleep(float(self.cfg["poll_s"]))
        self.store.set("perimeter.pending", None)
        return None

    # ---- evaluation
    def evaluate(self, ents, *, dry: bool = False) -> tuple:
        """-> (accesses, wake lines, digest line). Stores the signature, warns (crit) on new forbidden accesses."""
        now = self.clock.now()
        acc = build_accesses(ents, self.allow(), self.cfg)
        prev = self.store.get("perimeter.sig")
        wake = diff_lines(prev, acc)
        line = digest_line(acc, now.hhmm())
        if not dry:
            self.store.set("perimeter.sig", signature(acc))
            self.store.set("perimeter.last", {"ts": now.epoch, "line": line,
                                              "accesses": [a.line() for a in acc if a.core][:12]})
            self.store.set("perimeter.last_ts", now.epoch)
            if any(w.startswith("WAKE perimeter: forbidden") for w in wake):
                self.store.warn(now.epoch, "perimeter", "perimeter:forbidden", wake[0][:200], "crit")
        self.store.log_action(now.epoch, "perimeter", "perimeter", "scan", "perimeter", "claude/pilot_perimeter",
                              dry, not any(a.forbidden for a in acc), line)
        return acc, wake, line

    # ---- seal
    def grid_around(self, access: Access) -> Grid | None:
        xs, ys, zs = [t[0] for t in access.tiles], [t[1] for t in access.tiles], [t[2] for t in access.tiles]
        j = self._read(f"claude/pilot_reach dump {min(xs) - 1} {min(ys) - 1} {min(zs)} {max(xs) + 1} {max(ys) + 1} "
                       f"{max(zs)}")
        return Grid.from_dump(j) if isinstance(j, dict) and j.get("ok") else None

    def plan_seal(self, acc, grid: Grid | None = None) -> tuple:
        walls, notes = set(), []
        for a in acc:
            if not a.forbidden:
                continue
            g = grid if grid is not None else self.grid_around(a)
            if g is None:
                notes.append(f"{a.label()}: tiles not readable (pilot_reach dump) - no proposal")
                continue
            w, n = seal_walls(g, a)
            walls.update(w)
            notes += n
        return sorted(walls), notes

    def blueprints_dir(self) -> Path | None:
        if self.cfg.get("blueprints_dir"):
            return Path(self.cfg["blueprints_dir"])
        return None

    def seal(self, acc, *, apply: bool = False, override: str | None = None, grid: Grid | None = None,
             reach=None, dfhack_run: str | None = None) -> tuple:
        """-> (exit code, lines). --apply only after reach what-if (or an explicit override reason)."""
        now = self.clock.now().epoch
        walls, notes = self.plan_seal(acc, grid)
        if not walls:
            bad = [a for a in acc if a.forbidden]
            if bad and not notes:
                notes = [f"{a.label()}: no buildable entry tile found - seal by hand" for a in bad]
            head = ("Seal: no automatic proposal for " + ", ".join(a.label() for a in bad[:3]) + " (see notes)"
                    if bad else "Seal: nothing to do (no forbidden access)")
            return (1 if bad else 0), [head] + notes
        csv, cur = seal_csv(walls)
        out = Path(self.tools.path) / "out" / "perimeter_seal.csv"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(csv, encoding="utf-8")
        lines = [f"Seal proposal: {len(walls)} walls (Cw), cursor {cur[0]},{cur[1]},{cur[2]} -> {out}"] + notes
        if not apply:
            lines.append(f"apply: python -m df_llm_helper perimeter seal --apply  (runs quickfort run {self.cfg['blueprint']} "
                         f"-c {cur[0]},{cur[1]},{cur[2]})")
            self.store.log_action(now, "perimeter", "perimeter", "seal-plan", "perimeter", str(out), True, True,
                                  f"{len(walls)} walls")
            return 0, lines
        if reach is not None:
            wi = reach.what_if(walls, grid=grid)
            lines += wi.lines()
            if not wi.safe and not override:
                self.store.log_action(now, "perimeter", "perimeter", "seal-refused", "perimeter", str(out), False,
                                      False, "; ".join(wi.lines())[:200])
                return 2, lines + ["REFUSED: the walls would cut off mandatory points - "
                                   "use --override \"<reason>\" only with the player's yes"]
            if not wi.safe:
                lines.append(f"OVERRIDE: {override}")
        else:
            lines.append("what-if: no reach watcher available")
            if not override:
                return 2, lines + ["REFUSED: no what-if check possible - --override \"<reason>\" required"]
        bdir = self.blueprints_dir()
        if bdir is None and dfhack_run:
            bdir = Path(dfhack_run).resolve().parent.parent / "dfhack-config" / "blueprints"
        if bdir is None:
            return 2, lines + ["REFUSED: perimeter.blueprints_dir unknown"]
        target = bdir / self.cfg["blueprint"]
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(csv, encoding="utf-8")
        cmd = f"quickfort run {self.cfg['blueprint']} -c {cur[0]},{cur[1]},{cur[2]}"
        r = self.client.run(cmd)
        self.store.log_action(now, "perimeter", "perimeter", "seal", "perimeter", cmd, False, r.ok,
                              f"{len(walls)} walls" + (f"; override: {override}" if override else ""))
        lines.append(f"{'ok' if r.ok else 'FAILED'}: {cmd}" + ("" if r.ok else f" ({r.stderr[:80]})"))
        return (0 if r.ok else 1), lines


# ---------------------------------------------------------------- CLI + check hook

def _perimeter(p) -> Perimeter:
    return Perimeter(p.client, p.tools, p.store, p.clock, p.cfg.get(KEY, {}) or {})


def cmd_perimeter(args) -> int:
    from ..cli import _pilot
    p = _pilot(args)
    per = _perimeter(p)
    if args.action == "allow":
        if args.coords:
            x, y, z = _allow_coords(args.coords)
            for w in _allow_warnings(p, per, (x, y, z)):
                if w.startswith("Refused"):
                    print(w)
                    return 2
                print(w)
            per.allow_path.parent.mkdir(parents=True, exist_ok=True)
            with per.allow_path.open("a", encoding="utf-8") as f:
                f.write(f"{x},{y},{z}  {args.note or 'added by python -m df_llm_helper perimeter allow'}\n")
            p.store.log_action(p.clock.now().epoch, "perimeter", "perimeter", "allow", "perimeter",
                               f"{x},{y},{z}", False, True, args.note or "")
        for a, note in allow_entries(per.allow_path) + [(tuple(a), "grid fixture") for a in per.extra_allow]:
            print(f"allowed: {a[0]},{a[1]},{a[2]}" + (f"  ({note})" if note else ""))
        print(f"(file {per.allow_path}, tolerance +-{per.cfg['tolerance_xy']} xy / +-{per.cfg['tolerance_z']} z)")
        return 0
    if args.action == "status":
        last = p.store.get("perimeter.last") or {}
        print(last.get("line", "no scan yet"))
        for ln in last.get("accesses", []):
            print("  " + ln)
        return 0
    grid = Grid.from_file(args.grid) if args.grid else None
    if grid is not None:
        from ..store import Store
        per.store = Store()          # BUG-204: an offline fixture run never touches the fort's state.db
        core = tuple(int(v) for v in (grid.meta.get("core") or [per.cfg["core"]])[0])
        per.extra_allow = [tuple(int(v) for v in a[:3]) for a in grid.meta.get("allow", [])]
        ents = scan_grid(grid, core, per.cfg["z_range"])
    else:
        ents = per.scan_live()
    if ents is None:
        print("Perimeter: scan result not readable (pilot_perimeter installed? timeout?)")
        return 2
    acc, wake, line = per.evaluate(ents, dry=args.dry_run and args.action == "scan")
    if args.action == "scan":
        print("\n".join(wake + [line] + ["  " + a.line() for a in acc if a.core or args.verbose]))
        return 1 if any(a.forbidden for a in acc) else 0
    reach = None
    if args.apply:
        from .reach import ReachWatch, points_from_grid, DEFAULTS as RD
        rcfg = p.cfg.get("reach", {}) or {}
        if args.points_grid:
            g2 = Grid.from_file(args.points_grid)
            st, pts = points_from_grid(g2, {**RD, **rcfg}["mandatory"])
            reach = ReachWatch(p.client, p.store, p.clock, rcfg, points=pts, start=st)
        else:
            reach = ReachWatch(p.client, p.store, p.clock, rcfg)
    code, lines = per.seal(acc, apply=args.apply, override=args.override, grid=grid, reach=reach,
                           dfhack_run=p.cfg.get("dfhack_run"))
    csv = Path(per.tools.path) / "out" / "perimeter_seal.csv"
    if not args.apply and lines and lines[0].startswith("Seal proposal") and csv.exists():
        lines.append(csv.read_text(encoding="utf-8").rstrip())
    print("\n".join(lines))
    return code


def register(sub) -> None:
    s = sub.add_parser("perimeter", help="Access watcher (spec v3-01): scan|status|seal|allow")
    s.add_argument("action", nargs="?", default="scan", choices=["scan", "status", "seal", "allow"])
    s.add_argument("coords", nargs="*", help="allow: x y z to add to the allow-list")
    s.add_argument("--note", help="allow: comment for the new line")
    s.add_argument("--dry-run", action="store_true", help="scan: do not store; seal: only write the CSV (default)")
    s.add_argument("--apply", action="store_true", help="seal: run quickfort (after reach what-if)")
    s.add_argument("--override", help="seal --apply: reason (player's yes) to build although what-if warns")
    s.add_argument("--grid", help="offline: grid fixture instead of live DF")
    s.add_argument("--points-grid", help="seal --apply offline: grid fixture with @point lines for what-if")
    s.add_argument("--verbose", action="store_true")
    s.set_defaults(fn=cmd_perimeter)


def check_hook(pilot, report, dry: bool) -> list:
    """Never blocks: starts a chunked scan every interval_s (game running, no alarm) and evaluates it on a later
    check. Lines only on change (WAKE + digest line)."""
    cfg = {**DEFAULTS, **(pilot.cfg.get(KEY, {}) or {})}
    if dry:
        return []
    per = Perimeter(pilot.client, pilot.tools, pilot.store, pilot.clock, cfg)
    now = pilot.clock.now().epoch
    pending = pilot.store.get("perimeter.pending")
    if pending:
        j = per.result()
        ents = parse_scan(j)
        if ents is None:
            if now - float(pending) > float(cfg["timeout_s"]) * 3:
                pilot.store.set("perimeter.pending", None)
                return ["perimeter: scan did not finish (pilot_perimeter result) - retry later"]
            return []
        pilot.store.set("perimeter.pending", None)
        _, wake, line = per.evaluate(ents)
        return [w[:LINE_MAX + 40] for w in wake] + ([line] if wake else [])
    last = pilot.store.get("perimeter.last_ts")
    if last is not None and now - float(last) < float(cfg["interval_s"]):
        return []
    snap = getattr(report, "snapshot", None)
    if getattr(snap, "paused", None) is True:
        return []
    if pilot.tools.flag("alert").exists or pilot.tools.flag("siege").exists:
        return []
    if not cfg["chunked"]:
        return []                                     # never block the check with the synchronous 10 s scan
    if not per.start():
        pilot.store.set("perimeter.last_ts", now)     # retry after the interval, not on every check
    return []
