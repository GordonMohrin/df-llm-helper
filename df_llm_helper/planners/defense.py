"""Defense designer (spec v3-08), pure functions, no DF calls.

Input: a terrain cut-out of one z-level around the fort entrance (text grid, see ``parse_terrain``), the door tile
(stair/door into the fort), the access point (where attackers arrive) and optionally the stock. Output (``DefensePlan``):
a 1-tile-wide lane of length ``lane_len`` that starts at the door, walled on both sides with constructed walls (``Cw``),
one trap per lane tile (stone-fall ``Ts`` near the mouth, weapon ``Tw`` in the door-side third, cage ``Tc`` as the last
line), an optional shooter niche behind the lane wall (fortifications ``CF``, weapon rack ``r``, armor stand ``a``),
a material list (mechanisms = traps), build stages, a quickfort CSV (three ``#build`` sections) and an ASCII sketch.

Terrain characters: ``.`` floor (buildable), ``#`` rock/wall, ``_`` or space open air (impassable on this level),
``^`` ramp (walkable, not buildable), ``>`` ``<`` ``X`` stairs/door (walkable, not buildable), ``T`` existing trap and
``B`` other building (walkable, not buildable), ``~`` water (impassable). Unknown characters count as impassable.

Movement model for the path checks: 8-neighborhood (DF allows diagonal steps, also between two diagonal walls),
constructed walls and fortifications block, traps do not. Deterministic: same input -> same lane and CSV.

Assumptions (verify live): ``bars_per_component`` (bars per serrated disc/spiked ball) and the quickfort keys
``r`` (weapon rack) / ``a`` (armor stand) / ``CF`` (fortification) in ``#build``.
"""
from __future__ import annotations

from collections import deque
from dataclasses import dataclass, field
from typing import Iterable, Optional

from .blueprint import has_errors, validate_blueprint

__all__ = ["Terrain", "DefensePlan", "parse_terrain", "design_defense", "reachable", "trap_kinds", "DEFAULTS"]

DEFAULTS = {"lane_len": 20, "wall": "Cw", "trap_mix": {"Ts": 0.6, "Tw": 0.3, "Tc": 0.1}, "shooter_niche": True,
            "components_per_weapon_trap": 1, "bars_per_component": 3, "max_nodes": 300_000}

FLOOR = "."
WALKABLE = set(".^><XTB")
DIRS4 = ((0, -1), (1, 0), (0, 1), (-1, 0))          # N E S W (fixed tie-break order)
DIRS8 = tuple((dx, dy) for dy in (-1, 0, 1) for dx in (-1, 0, 1) if dx or dy)
TRAP_ORDER = ("Ts", "Tw", "Tc")                       # placement order from the lane mouth towards the door
SKETCH = {"Ts": "S", "Tw": "W", "Tc": "C", "Cw": "#", "CF": "F", "r": "r", "a": "a"}

Pt = tuple[int, int]


@dataclass
class Terrain:
    x0: int
    y0: int
    z: int
    rows: list[str]
    door: Optional[Pt] = None
    access: Optional[Pt] = None
    synthetic: bool = False

    @property
    def width(self) -> int:
        return max((len(r) for r in self.rows), default=0)

    @property
    def height(self) -> int:
        return len(self.rows)

    def at(self, p: Pt) -> Optional[str]:
        x, y = p[0] - self.x0, p[1] - self.y0
        if y < 0 or y >= len(self.rows) or x < 0:
            return None
        row = self.rows[y]
        return row[x] if x < len(row) else "_"

    def walkable(self, p: Pt) -> bool:
        return self.at(p) in WALKABLE

    def tiles(self) -> Iterable[Pt]:
        for j, row in enumerate(self.rows):
            for i in range(len(row)):
                yield (self.x0 + i, self.y0 + j)


@dataclass
class DefensePlan:
    ok: bool
    lane: list[Pt] = field(default_factory=list)            # lane[0] next to the door, lane[-1] = mouth
    approach: Optional[Pt] = None                           # free tile in front of the mouth
    walls: list[Pt] = field(default_factory=list)           # Cw around lane + door (stage 1)
    traps: list[tuple[int, int, str]] = field(default_factory=list)
    niche: dict = field(default_factory=dict)               # tiles, fortifications, walls, furniture, segment
    materials: dict = field(default_factory=dict)
    missing: dict = field(default_factory=dict)
    stages: list[str] = field(default_factory=list)
    csv: str = ""
    origin: Optional[tuple[int, int, int]] = None           # quickfort cursor (top-left of the CSV grid)
    sketch: str = ""
    checks: dict = field(default_factory=dict)
    notes: list[str] = field(default_factory=list)

    @property
    def mechanisms(self) -> int:
        return int(self.materials.get("mechanisms", 0))


def parse_terrain(text: str) -> Terrain:
    """Text format: optional ``# comment`` lines, ``key: value`` lines (origin x y | z | door x y | access x y),
    then ``grid:`` followed by the rows (row = y, column = x, starting at origin)."""
    x0 = y0 = z = 0
    door = access = None
    rows: list[str] = []
    in_grid = False
    synthetic = False
    for raw in text.splitlines():
        if in_grid:
            if raw.strip() == "" and not rows:
                continue
            rows.append(raw.rstrip("\r\n"))
            continue
        line = raw.strip()
        if line.startswith("#"):
            synthetic = synthetic or "SYNTHETIC" in line.upper()
            continue
        if not line:
            continue
        key, _, val = line.partition(":")
        key = key.strip().lower()
        nums = [int(v) for v in val.replace(",", " ").split()] if key != "grid" else []
        if key == "grid":
            in_grid = True
        elif key == "origin" and len(nums) >= 2:
            x0, y0 = nums[0], nums[1]
            if len(nums) >= 3:
                z = nums[2]
        elif key == "z" and nums:
            z = nums[0]
        elif key == "door" and len(nums) >= 2:
            door = (nums[0], nums[1])
        elif key == "access" and len(nums) >= 2:
            access = (nums[0], nums[1])
        else:
            raise ValueError(f"terrain: unknown line {line[:40]!r}")
    while rows and not rows[-1].strip():
        rows.pop()
    if not rows:
        raise ValueError("terrain: no grid rows (expected 'grid:' followed by rows)")
    return Terrain(x0, y0, z, rows, door, access, synthetic)


def reachable(terrain: Terrain, start: Pt, blocked: set | frozenset = frozenset()) -> set:
    """8-neighborhood BFS over walkable, not blocked tiles."""
    if not terrain.walkable(start) or start in blocked:
        return set()
    seen = {start}
    q = deque([start])
    while q:
        x, y = q.popleft()
        for dx, dy in DIRS8:
            n = (x + dx, y + dy)
            if n not in seen and n not in blocked and terrain.walkable(n):
                seen.add(n)
                q.append(n)
    return seen


def trap_kinds(n: int, mix: dict) -> list[str]:
    """Trap key per lane position from the mouth towards the door (largest remainder, deterministic)."""
    keys = [k for k in TRAP_ORDER if float(mix.get(k, 0) or 0) > 0] or ["Ts"]
    total = sum(float(mix.get(k, 0) or 0) for k in keys) or 1.0
    raw = {k: n * float(mix.get(k, 0) or 0) / total if mix.get(k) else float(n) for k in keys}
    cnt = {k: int(raw[k]) for k in keys}
    rest = n - sum(cnt.values())
    for k in sorted(keys, key=lambda k: (-(raw[k] - cnt[k]), TRAP_ORDER.index(k)))[:rest]:
        cnt[k] += 1
    out: list[str] = []
    for k in TRAP_ORDER:
        out += [k] * cnt.get(k, 0)
    return out


def _adj8(a: Pt, b: Pt) -> bool:
    return a != b and abs(a[0] - b[0]) <= 1 and abs(a[1] - b[1]) <= 1


def _run_len(t: Terrain, p: Pt, d: Pt) -> int:
    n = 0
    q = (p[0] + d[0], p[1] + d[1])
    while t.at(q) == FLOOR:
        n += 1
        q = (q[0] + d[0], q[1] + d[1])
    return n


def _ring(t: Terrain, seq: list[Pt], approach: Pt) -> Optional[set]:
    """Wall tiles: all floor 8-neighbors of door + lane that are neither lane nor approach. None = hole."""
    lane = set(seq)
    walls = set()
    for p in seq:
        for dx, dy in DIRS8:
            n = (p[0] + dx, p[1] + dy)
            if n in lane or n == approach:
                continue
            c = t.at(n)
            if c is None:
                return None
            if c == FLOOR:
                walls.add(n)
            elif c in WALKABLE:
                return None
    return walls


def _tile_ok(t: Terrain, seq: list[Pt], used: set, n: Pt) -> bool:
    if n in used or t.at(n) != FLOOR:
        return False
    k = len(seq)
    for j in range(k - 2):                                # only the two previous tiles may touch the new one
        if _adj8(n, seq[j]):
            return False
    for dx, dy in DIRS8:                                  # every neighbor must be wallable or already blocking
        c = t.at((n[0] + dx, n[1] + dy))
        if c is None:
            return False
        if c != FLOOR and c in WALKABLE and (n[0] + dx, n[1] + dy) != seq[0]:
            return False
    return True


def _find_lane(t: Terrain, door: Pt, access: Pt, length: int, max_nodes: int):
    """DFS from the door; prefers straight runs, then the turn with the longer free run (fixed N/E/S/W tie-break)."""
    seq: list[Pt] = [door]
    used = {door}
    nodes = 0
    result = None

    def order(p: Pt, prev: Optional[Pt]) -> list[Pt]:
        cands = []
        for i, d in enumerate(DIRS4):
            straight = prev is not None and d == prev
            cands.append((0 if straight else 1, -_run_len(t, p, d), i, d))
        return [c[3] for c in sorted(cands)]

    def finish() -> Optional[tuple]:
        last = seq[-1]
        prev_d = (last[0] - seq[-2][0], last[1] - seq[-2][1])
        for d in order(last, prev_d):
            a = (last[0] + d[0], last[1] + d[1])
            if a in used or not t.walkable(a):
                continue
            if any(_adj8(a, seq[j]) for j in range(len(seq) - 2)):
                continue
            walls = _ring(t, seq, a)
            if walls is None:
                continue
            blocked = walls
            outside = reachable(t, access, blocked)
            if a not in outside:
                continue
            if door in reachable(t, access, blocked | set(seq[1:])):
                continue                                   # a way around the lane exists
            return a, walls
        return None

    def dfs(prev_d: Optional[Pt]) -> bool:
        nonlocal nodes, result
        nodes += 1
        if nodes > max_nodes:
            return False
        if len(seq) - 1 == length:
            r = finish()
            if r:
                result = (list(seq[1:]), r[0], r[1])
                return True
            return False
        p = seq[-1]
        for d in order(p, prev_d):
            n = (p[0] + d[0], p[1] + d[1])
            if not _tile_ok(t, seq, used, n):
                continue
            seq.append(n)
            used.add(n)
            if dfs(d):
                return True
            seq.pop()
            used.discard(n)
        return False

    dfs(None)
    return result, nodes


def _find_niche(t: Terrain, lane: list[Pt], walls: set, approach: Pt, access: Pt, door: Pt):
    """Niche 3 wide x 2 deep behind the lane wall (offset 2..3 from a straight lane segment); the shared wall row
    becomes fortifications. Candidates sorted by distance of the segment center from the lane middle."""
    lane_set = set(lane)
    cands = []
    for i in range(1, len(lane) - 1):
        a, b, c = lane[i - 1], lane[i], lane[i + 1]
        d = (c[0] - b[0], c[1] - b[1])
        if (b[0] - a[0], b[1] - a[1]) != d:
            continue
        for side, s in ((0, (-d[1], d[0])), (1, (d[1], -d[0]))):
            cands.append((abs(i - len(lane) / 2), i, side, s))
    for _, i, _, s in sorted(cands):
        seg = lane[i - 1:i + 2]
        fort = [(p[0] + s[0], p[1] + s[1]) for p in seg]
        front = [(p[0] + 2 * s[0], p[1] + 2 * s[1]) for p in seg]
        back = [(p[0] + 3 * s[0], p[1] + 3 * s[1]) for p in seg]
        if not all(f in walls for f in fort):
            continue
        tiles = front + back
        if any(t.at(p) != FLOOR or p in walls or p in lane_set or p == approach for p in tiles):
            continue
        new_walls = set()
        bad = False
        inner = set(tiles) | set(fort)
        for p in tiles:
            for dx, dy in DIRS8:
                n = (p[0] + dx, p[1] + dy)
                if n in inner or n in walls:
                    continue
                cc = t.at(n)
                if cc is None or n in lane_set or n == approach or (cc in WALKABLE and cc != FLOOR):
                    bad = True
                    break
                if cc == FLOOR:
                    new_walls.add(n)
            if bad:
                break
        if bad:
            continue
        blocked = (walls - set(fort)) | new_walls | set(fort)
        if approach not in reachable(t, access, blocked):
            continue
        if door in reachable(t, access, blocked | set(lane)):
            continue
        if set(tiles) & reachable(t, access, blocked):
            continue
        return {"tiles": tiles, "front": front, "back": back, "fortifications": fort,
                "walls": sorted(new_walls, key=lambda p: (p[1], p[0])),
                "furniture": [(back[0][0], back[0][1], "r"), (back[-1][0], back[-1][1], "a")],
                "segment": (i - 1, i + 1)}
    return {}


def _csv(sections: list[tuple[str, str, dict]], bbox: tuple[int, int, int, int]) -> str:
    x1, y1, x2, y2 = bbox
    out = []
    for label, text, cells in sections:
        out.append(f"#build label({label}) {text}")
        for y in range(y1, y2 + 1):
            out.append(",".join(cells.get((x, y), "") for x in range(x1, x2 + 1)))
    return "\n".join(out) + "\n"


def _sketch(t: Terrain, plan: DefensePlan, door: Pt, access: Pt) -> str:
    over: dict[Pt, str] = {}
    for p in plan.walls:
        over[p] = "#"
    for x, y, k in plan.traps:
        over[(x, y)] = SKETCH[k]
    for p in plan.niche.get("walls", []):
        over[p] = "#"
    for p in plan.niche.get("fortifications", []):
        over[p] = "F"
    for p in plan.niche.get("tiles", []):
        over[p] = "n"
    for x, y, k in plan.niche.get("furniture", []):
        over[(x, y)] = k
    over[door] = "D"
    if plan.approach:
        over[plan.approach] = "+"
    over[access] = "A"
    terrain_map = {"#": "%", "_": " ", ".": "."}
    lines = [f"z={t.z} x={t.x0}..{t.x0 + t.width - 1} y={t.y0}..{t.y0 + t.height - 1}"]
    for j, row in enumerate(t.rows):
        y = t.y0 + j
        line = "".join(over.get((t.x0 + i, y), terrain_map.get(ch, ch)) for i, ch in enumerate(row))
        lines.append(f"{y:4d} {line}")
    lines.append("Legend: D door  A access  + lane mouth  S stone trap  W weapon trap  C cage trap  # new wall (Cw)  "
                 "F fortification  n niche  r weapon rack  a armor stand  % rock  T old trap  ^ ramp")
    return "\n".join(lines)


def design_defense(terrain: Terrain, door: Optional[Pt] = None, access: Optional[Pt] = None,
                   stock: Optional[dict] = None, cfg: Optional[dict] = None) -> DefensePlan:
    """Deterministic lane/killbox design. Never builds anything (only returns data)."""
    c = dict(DEFAULTS)
    c.update(cfg or {})
    door = door or terrain.door
    access = access or terrain.access
    plan = DefensePlan(ok=False)
    if door is None or access is None:
        plan.notes.append("door and access point are required")
        return plan
    if not terrain.walkable(door) or not terrain.walkable(access):
        plan.notes.append(f"door {door} or access {access} is not walkable in the terrain")
        return plan
    if door not in reachable(terrain, access):
        plan.notes.append("door is not reachable from the access point even without a lane (nothing to defend here?)")
        return plan
    length = int(c["lane_len"])
    if length < 3:
        plan.notes.append("lane_len must be >= 3")
        return plan
    if length < 20:
        plan.notes.append(f"lane_len {length} < 20 (spec default >= 20)")
    found, nodes = _find_lane(terrain, door, access, length, int(c["max_nodes"]))
    plan.checks["search_nodes"] = nodes
    if not found:
        plan.notes.append(f"no lane of length {length} fits (searched {nodes} nodes); shorten lane_len or enlarge the cut-out")
        return plan
    lane, approach, walls = found
    plan.lane, plan.approach = lane, approach
    plan.walls = sorted(walls, key=lambda p: (p[1], p[0]))
    kinds = trap_kinds(len(lane), c.get("trap_mix") or {})
    plan.traps = [(p[0], p[1], k) for p, k in zip(reversed(lane), kinds)]   # mouth first
    if c.get("shooter_niche", True):
        plan.niche = _find_niche(terrain, lane, walls, approach, access, door)
        if not plan.niche:
            plan.notes.append("no room for a shooter niche (3x2 behind a straight lane segment); plan it by hand")
    fort_set = set(plan.niche.get("fortifications", []))
    plan.walls = [p for p in plan.walls if p not in fort_set]       # CF replaces those lane-wall tiles

    # path checks (acceptance 1): with lane -> door reachable; lane tiles blocked -> door unreachable
    blocked = set(plan.walls) | set(plan.niche.get("walls", [])) | fort_set
    out_with = reachable(terrain, access, blocked)
    out_without = reachable(terrain, access, blocked | set(lane))
    pocket = {p for p in terrain.tiles() if terrain.at(p) == FLOOR} - out_with - blocked - set(lane) \
        - set(plan.niche.get("tiles", []))
    plan.checks.update({"door_reachable": door in out_with, "only_via_lane": door not in out_without,
                        "mouth_reachable": approach in out_with, "isolated_floor_tiles": len(pocket),
                        "lane_len": len(lane)})
    if pocket:
        plan.notes.append(f"{len(pocket)} floor tiles are cut off by the walls (no harm, but no free space either)")

    # material list (acceptance 2: mechanisms = traps)
    n_tw = sum(1 for _, _, k in plan.traps if k == "Tw")
    comps = n_tw * int(c["components_per_weapon_trap"])
    fort = len(plan.niche.get("fortifications", []))
    all_walls = len(plan.walls) + len(plan.niche.get("walls", []))
    mat = {"mechanisms": len(plan.traps), "wall_blocks_or_stones": all_walls + fort,
           "trap_components": comps, "metal_bars": comps * int(c["bars_per_component"]),
           "weapon_racks": 1 if plan.niche else 0, "armor_stands": 1 if plan.niche else 0}
    for k in TRAP_ORDER:
        mat[f"traps_{k}"] = sum(1 for _, _, kk in plan.traps if kk == k)
    mat["walls_Cw"] = all_walls
    mat["fortifications_CF"] = fort
    plan.materials = mat
    if stock is not None:
        have = {"mechanisms": stock.get("mechanisms", 0), "trap_components": stock.get("trap_components", 0),
                "wall_blocks_or_stones": stock.get("blocks", 0) + stock.get("stones", stock.get("boulders", 0)),
                "metal_bars": stock.get("bars", stock.get("bars_iron", 0) + stock.get("bars_steel", 0))}
        plan.missing = {k: mat[k] - int(v or 0) for k, v in have.items() if mat[k] > int(v or 0)}

    # quickfort CSV: three #build sections (walls / traps / niche), cursor = top-left of the bounding box
    cells_w = {p: str(c["wall"]) for p in plan.walls}
    cells_t = {(x, y): k for x, y, k in plan.traps}
    cells_n: dict[Pt, str] = {p: str(c["wall"]) for p in plan.niche.get("walls", [])}
    cells_n.update({p: "CF" for p in plan.niche.get("fortifications", [])})
    cells_n.update({(x, y): k for x, y, k in plan.niche.get("furniture", [])})
    pts = list(cells_w) + list(cells_t) + list(cells_n)
    bbox = (min(p[0] for p in pts), min(p[1] for p in pts), max(p[0] for p in pts), max(p[1] for p in pts))
    plan.origin = (bbox[0], bbox[1], terrain.z)
    o = f"origin {bbox[0]} {bbox[1]} {terrain.z}"
    sections = [("walls", f"python -m df_llm_helper defense stage 1: lane walls {o}", cells_w),
                ("traps", f"python -m df_llm_helper defense stage 2: traps mouth to door {o}", cells_t)]
    if cells_n:
        sections.append(("niche", f"python -m df_llm_helper defense stage 3: shooter niche {o}", cells_n))
    plan.csv = _csv(sections, bbox)
    fs = validate_blueprint(plan.csv)
    plan.checks["blueprint_findings"] = [str(f) for f in fs]
    if has_errors(fs):
        plan.notes.append("generated CSV fails the blueprint validator: " + "; ".join(str(f) for f in fs)[:200])
        return plan

    plan.stages = [
        "0 check: `claude/zugaenge` (spec v3-01) reports only the door as access; quicksave",
        f"1 walls: {len(cells_w)} Cw around lane and door (quickfort label walls) - first the door side",
        f"2 traps: {mat['traps_Ts']} Ts (mouth side), {mat['traps_Tw']} Tw (door third), {mat['traps_Tc']} Tc "
        f"(last line) = {mat['mechanisms']} mechanisms; orders at the mechanic's workshop/metalsmith first",
    ]
    if plan.niche:
        plan.stages.append(f"3 niche: {fort} CF + {len(plan.niche['walls'])} Cw + rack/stand; stair from z{terrain.z - 1} "
                           "into the niche by hand; squad 'shooters' station in the niche")
    plan.stages.append("4 check: `python -m df_llm_helper defense status` (>= 70 % loaded), stone stockpile near the lane")
    plan.notes.append("citizens/merchants: the door is only reachable through the lane (traps do not fire on "
                      "citizens; the depot must be reached from the map edge, not through the lane)")
    plan.sketch = _sketch(terrain, plan, door, access)
    plan.ok = bool(plan.checks["only_via_lane"] and plan.checks["door_reachable"] and plan.checks["mouth_reachable"])
    if not plan.ok:
        plan.notes.append("path check failed: the lane is not the only way to the door")
    return plan
