"""Spec 08: water and flood watcher (`dfpilot water`).

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

__all__ = ["DEFAULTS", "check_near", "in_box", "Verdict", "WaterWatch", "notwand_for"]

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
    me = j.get("self") or {}
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
    reasons.sort(key=lambda r: (0 if ("diagonal" in r or "orthogonal" in r or "vertical" in r or "slanted" in r)
                                else 1, r))
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


class WaterWatch:
    def __init__(self, client, tools, store, clock, cfg: dict):
        self.client, self.tools, self.store, self.clock = client, tools, store, clock
        self.cfg = {**DEFAULTS, **(cfg or {})}

    def scan(self, box) -> dict | None:
        r = self.client.run("claude/pilot_water scan " + " ".join(str(int(v)) for v in box))
        return r.json if r.ok and isinstance(r.json, dict) and r.json.get("ok") else None

    def check(self, x: int, y: int, z: int) -> Verdict:
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
            nw = notwand_for(front, self.cfg["chokepoints"], self.cfg["fort_center"])
            if nw:
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
