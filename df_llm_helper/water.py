"""Spec 08: water and flood watcher (`python -m df_llm_helper water`).

- scan:   count liquid tiles in boxes (`claude/pilot_water scan`, not tested live)
- check:  check a planned dig tile in advance (`pilot_water near`): water orthogonal, DIAGONAL or z+-1 -> forbidden
          (run 5: river water ran diagonally between two rock edges into the tunnel), hidden neighbors or water
          at distance 2 -> unsafe, otherwise ok. Conservative.
- watch:  water in the fort box rises -> critical warning + wasser.flag + emergency-wall proposal (nearest planned
          choke point between front and fort, Quickfort raster) -> runbook rb21_flut.
- Blocked boxes water.forbid_dig: lint/RealClient refuse dig orders inside them (rule L31, lint.lint_dig).
Read only and proposals; the emergency wall is a normal build order (runbook, not automatic).
"""
from __future__ import annotations

from dataclasses import dataclass

__all__ = ["DEFAULTS", "check_near", "in_box", "Verdict", "WaterWatch", "notwand_for", "parse_xyz", "fort_center"]

# fort_box ends at x=127: the emergency wall (128,99,z128) has cut off the flooded tunnel W since run 5 (LAYOUT-run5.md 11)
DEFAULTS = {"watch_box": [60, 40, 126, 190, 130, 131], "fort_box": [60, 40, 126, 127, 130, 133],
            "forbid_dig": [[127, 97, 127, 181, 101, 129], [180, 40, 127, 180, 99, 128], [181, 42, 127, 189, 49, 128]],
            "notwand_blueprint": "claude/r5_notwand.csv", "chokepoints": [[128, 99, 128]],
            "fort_center": None, "rise_min": 1, "watch_in_check": True}


def in_box(x: int, y: int, z: int, box) -> bool:
    x1, y1, z1, x2, y2, z2 = box
    return min(x1, x2) <= x <= max(x1, x2) and min(y1, y2) <= y <= max(y1, y2) and min(z1, z2) <= z <= max(z1, z2)


@dataclass
class Verdict:
    result: str          # ok | unsafe | forbidden
    reasons: list

    def line(self) -> str:
        return f"{self.result}: " + ("; ".join(self.reasons[:4]) if self.reasons else "no water nearby")


def _kind(t: dict) -> str:
    dx, dy, dz = t.get("dx", 0), t.get("dy", 0), t.get("dz", 0)
    if dz:
        return "vertical" if dx == 0 and dy == 0 else "slanted z" + ("+1" if dz > 0 else "-1")
    return "orthogonal" if dx == 0 or dy == 0 else "diagonal"


def check_near(j: dict | None, forbid: list | None = None) -> Verdict:
    """Response of `claude/pilot_water near x y z 2` -> verdict. If the response is missing: unsafe."""
    if not isinstance(j, dict) or not j.get("ok"):
        return Verdict("unsafe", ["Neighborhood not readable (pilot_water installed?)"])
    reasons, bad, unsure = [], False, False
    x, y, z = j.get("x"), j.get("y"), j.get("z")
    for box in forbid or []:
        if None not in (x, y, z) and in_box(x, y, z, box):
            bad = True
            reasons.append(f"in blocked box {box}")
    me = j.get("self")
    if not isinstance(me, dict):            # BUG-205: no record of the tile itself = outside the map / no map block
        return Verdict("unsafe", [f"tile ({x},{y},z{z}) outside the map or not readable - check x y z"])
    if me.get("hidden"):
        unsure = True
        reasons.append("tile itself unrevealed")
    if me.get("flow"):
        bad = True
        reasons.append("tile itself carries liquid")
    for t in j.get("tiles") or []:
        near = max(abs(t.get("dx", 0)), abs(t.get("dy", 0))) <= 1
        if t.get("hidden"):
            if near:
                unsure = True
                reasons.append(f"hidden neighbor tile ({t.get('dx')},{t.get('dy')},{t.get('dz')})")
            continue
        if (t.get("flow") or 0) > 0:
            what = "Magma" if t.get("magma") else "Water"
            where = f"({t.get('dx')},{t.get('dy')},{t.get('dz')})"
            if near:
                bad = True
                reasons.append(f"{what} {_kind(t)} {where}, flow {t.get('flow')}")
            else:
                unsure = True
                reasons.append(f"{what} at distance 2 {where}")
    # decisive reasons first (blocked box / own tile / water next to the tile), hints last: line() shows only 4 of them
    reasons.sort(key=lambda r: (0 if (r.startswith(("in blocked box", "tile itself")) or "diagonal" in r
                                      or "orthogonal" in r or "vertical" in r or "slanted" in r) else 1, r))
    return Verdict("forbidden" if bad else "unsafe" if unsure else "ok", reasons)


def notwand_for(front, chokepoints: list, center) -> list | None:
    """Nearest planned choke point between front and fort: the point with the smallest distance to the front that is
    closer to the fort than the front (otherwise the wall would lie behind the water)."""
    if not front or not chokepoints:
        return None

    def d(a, b):
        return max(abs(a[0] - b[0]), abs(a[1] - b[1])) + abs(a[2] - b[2])
    cands = [c for c in chokepoints if center is None or d(c, center) <= d(front, center)]
    if not cands:
        return None
    return min(cands, key=lambda c: (d(c, front), tuple(c)))


def parse_xyz(words, usage: str = "water check X Y Z") -> tuple:
    """CLI coordinates -> (x, y, z); anything else is a usage error (ValueError -> rc 2, BUG-214)."""
    vals = [str(w).strip() for w in (words or [])]
    if len(vals) != 3 or not all(v.lstrip("-").isdigit() for v in vals):
        raise ValueError(f"usage: {usage} (three integers), got {' '.join(vals) or 'nothing'}")
    return tuple(int(v) for v in vals)


def fort_center(cfg: dict) -> list | None:
    """Fort point for the emergency wall: water.fort_center, else the centre of fort_box (BUG-206: with None every
    choke point counted as 'between front and fort', also one behind the water)."""
    if cfg.get("fort_center"):
        return list(cfg["fort_center"])
    b = cfg.get("fort_box")
    if not b or len(b) != 6:
        return None
    return [(b[0] + b[3]) // 2, (b[1] + b[4]) // 2, max(b[2], b[5])]


class WaterWatch:
    def __init__(self, client, tools, store, clock, cfg: dict):
        self.client, self.tools, self.store, self.clock = client, tools, store, clock
        self.cfg = {**DEFAULTS, **(cfg or {})}

    def scan(self, box) -> dict | None:
        r = self.client.run("claude/pilot_water scan " + " ".join(str(int(v)) for v in box))
        return r.json if r.ok and isinstance(r.json, dict) and r.json.get("ok") else None

    def map_size(self) -> tuple | None:
        r = self.client.run("claude/status")
        m = (r.json or {}).get("map_size") if r.ok and isinstance(r.json, dict) else None
        try:
            return int(m["x"]), int(m["y"]), int(m["z"])
        except (TypeError, KeyError, ValueError):
            return None

    def check(self, x: int, y: int, z: int) -> Verdict:
        ms = self.map_size() if min(x, y, z) >= 0 else None
        if min(x, y, z) < 0 or (ms and (x >= ms[0] or y >= ms[1] or z >= ms[2])):
            size = f" ({ms[0]}x{ms[1]}x{ms[2]})" if ms else ""
            return Verdict("unsafe", [f"({x},{y},z{z}) is outside the map{size} - check the order x y z"])
        r = self.client.run(f"claude/pilot_water near {x} {y} {z} 2")
        return check_near(r.json if r.ok else None, self.cfg["forbid_dig"])

    def watch(self, *, dry: bool = False) -> list[str]:
        """Measure water in the fort box; rise -> critical + wasser.flag + emergency-wall proposal."""
        now = self.clock.now().epoch
        j = self.scan(self.cfg["fort_box"])
        if j is None:
            return ["Water: pilot_water scan not readable"]
        cnt = int(j.get("water") or 0) + int(j.get("magma") or 0)
        prev = self.store.get("water.fort_count")
        out = []
        rising = prev is not None and cnt - int(prev) >= self.cfg["rise_min"]
        first = prev is None and cnt > 0
        if rising or first:
            front = j.get("front")
            fx = "(" + ",".join(map(str, front)) + ")" if front else "?"
            msg = f"!! Water in the fort at {fx}: {cnt} tiles (before {prev if prev is not None else '?'})"
            out.append(msg)
            nw = notwand_for(front, self.cfg["chokepoints"], fort_center(self.cfg))
            inside = front and len(front) == 3 and in_box(*front, self.cfg["fort_box"])
            if nw and inside and not in_box(*nw, self.cfg["fort_box"]):
                nw = None                   # the front is already inside the fort box: an outer wall lies behind it
            if nw is None and inside and self.cfg["chokepoints"]:
                out.append("Emergency wall: the water is already inside the fort box, the planned choke points "
                           f"{self.cfg['chokepoints']} lie behind the front - wall breached/not tight? check them; "
                           "wall off the front by hand")
            elif nw:
                out.append(f"Emergency wall: runbook rb21_flut --param x={nw[0]} --param y={nw[1]} --param z={nw[2]} "
                           f"(Quickfort {self.cfg['notwand_blueprint']}); dig ban around the front")
            else:
                out.append("Emergency wall: no planned choke point between front and fort (water.chokepoints) - by hand")
            if not dry:
                self.store.warn(now, "water", "water:fort", msg, "crit")
                self.tools.write_flag("wasser", "\n".join(out))
                self.store.log_action(now, "water", "water", "alarm", "water", "wasser.flag", False, True, msg[:120])
        elif cnt == 0 and prev and not dry and self.tools.flag("wasser").exists:
            self.tools.delete_flag("wasser")
            out.append("Water in the fort back to 0: wasser.flag deleted")
        if not dry:
            self.store.set("water.fort_count", cnt)
        return out or [f"Water in the fort: {cnt} tiles (unchanged)"]
