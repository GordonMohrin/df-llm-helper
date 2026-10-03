"""Spec v3-07: item hygiene (`python -m df_llm_helper hygiene`).

Keeps loose items under control without breaking the player's rules:
- measure:  `claude/pilot_hygiene status <start> <n>` in index blocks (read only, adaptive block size so one call
            never freezes the game), plus `report` (dump zones, DumpItem jobs, idle citizens) and `claude/gesund krypta`
- mark:     at most min(mark_batch, 300) items per cycle via the UI garbage flag (`flags.dump`), only while the number
            of still pending marks is below pending_max; loop protection max_marks_per_hour (state.db actions)
- check:    DumpItem jobs < 10 % of the pending marks -> cause (no zone / zone under a stockpile / path blocked /
            haulers busy / zone too far) and a zone proposal from hygiene.dump_zones (proposed, never built)
- digest:   one line <= 140 chars, e.g. 'loose stacks 12.5k (+200/h): boulders 10k (ok), corpses 900 (dump 6 jobs) ...'
- forbid:   `claude/pilot_hygiene forbid` (read only, BUG-125): own forbidden items by class and the drinks/food that
            sit in forbidden containers; a '!!' warning when drinks/food/containers/building material are forbidden
            (Run 5: 1043 forbidden items, digest 'Getraenke 475', > 10 dwarves died of thirst, hygiene stayed silent).
            In `check` this warning defers to `forbid-watch` (FEATURE-003) while that one reports.
- flow:     FEATURE-002 item flow budget (`hygiene flow [--hours 24] [--caps]`, `hygiene caps`, `hygiene bins [--apply]`):
            reachable vs unreachable loose stacks, inflow/sink per type from flow snapshots in state.db (table
            item_flow, one per measurement), free stockpile tiles, the manager-order cap audit, the bin planner and the
            garbage bridge (`hygiene zones`). `hygiene mark --unforbid` takes the legacy forbidden non-dwarf corpses.
            Logic in features/_itemflow.py. `bins --apply` needs the exception-register entry FP14.
Hard rules (independent of config): boulders, dwarf corpses, bones/skins, trade goods, weapons/armor are never marked;
`autodump` (item teleport) is never sent. Lua part: lua/pilot_hygiene.lua (LIVE-UNTESTED).
"""
from __future__ import annotations

from dataclasses import dataclass, field

__all__ = ["KEY", "DEFAULTS", "HARD_CAP", "HARD_NEVER", "MARKABLE", "FOOD_ROT", "effective_types", "markable",
           "select_marks", "Measurement", "aggregate", "from_muell", "diagnose", "suggest_zone", "zone_text", "digest_line",
           "forbid_lines", "legacy_lines", "Hygiene", "register", "check_hook"]

KEY = "hygiene"
HARD_CAP = 300                      # marks per cycle, never more (haulers must not be blocked)
MARKABLE = frozenset({"CORPSE", "CORPSEPIECE", "REMAINS"})
FOOD_ROT = frozenset({"FOOD", "MEAT", "FISH", "FISH_RAW", "PLANT", "PLANT_GROWTH", "EGG", "CHEESE", "GLOB"})
# player rules: boulders are building material; trade goods (goblets, crafts, thread, cloth); barracks gear; bars
HARD_NEVER = frozenset({"BOULDER", "BAR", "WEAPON", "ARMOR", "SHIELD", "HELM", "GLOVES", "SHOES", "PANTS", "AMMO",
                        "SIEGEAMMO", "TRAPCOMP", "GOBLET", "FIGURINE", "AMULET", "BRACELET", "EARRING", "CROWN", "RING",
                        "SCEPTER", "TOTEM", "INSTRUMENT", "TOY", "THREAD", "CLOTH", "SKIN_TANNED", "GEM", "SMALLGEM",
                        "ROUGH", "BLOCKS", "WOOD", "TOOL", "CRAFTS"})
CORPSE_T = frozenset({"CORPSE", "CORPSEPIECE", "REMAINS"})
FORBIDDEN_WORDS = ("autodump",)     # item teleport: never sent, whatever the config says

DEFAULTS = {
    "mark_batch": 300, "pending_max": 300, "mark_types": ["CORPSE", "CORPSEPIECE", "REMAINS"], "mark_rotten": True,
    "exclude_types": ["BOULDER", "BAR", "WEAPON", "ARMOR", "CRAFTS"], "keep_goods": ["GOBLET", "FIGURINE", "THREAD"],
    # proposals only (zone D: wirtschaft, Run 5 J109, near refuse room/crypt/barracks)
    "dump_zones": [{"name": "D", "z": 130, "x": [86, 88], "y": [112, 114], "note": "near refuse room/crypt/barracks"}],
    "block": 20000, "max_block_s": 1.0, "max_measure_s": 5.0, "far_tiles": 30, "effect_min_ratio": 0.10,
    "measure_every_s": 1800, "auto_mark": False, "max_marks_per_hour": 2, "corpse_warn": 50, "goblet_cap": 60,
    "zone_min_gap": 5,             # no zone proposal within this distance of an existing dump zone (BUG-220)
    "forbid_every_s": 300,         # BUG-125: forbidden-supply check in `check` (cheap, own interval)
    "forbid_material_warn": 10,    # forbidden own blocks/wood/bars/boulders from this count on -> warning
    "in_check": True,
    # FEATURE-002 item flow budget
    "flow": {"hours": 24, "sale_capacity": 800,   # trade goods one caravan season absorbs (player decision pending)
             "bin_capacity": 100, "wood_reserve": 10, "landing_warn": 300, "flow_rows": 8, "flow_eps": 0.5,
             "max_bins_per_order": 50},
}


# ------------------------------------------------------------------ pure rules
def effective_types(cfg: dict) -> list[str]:
    """Types that may be marked: configured mark_types, restricted to MARKABLE, minus all exclusions (hard + config)."""
    excl = set(HARD_NEVER) | set(cfg.get("exclude_types") or []) | set(cfg.get("keep_goods") or [])
    return sorted(t for t in (cfg.get("mark_types") or []) if t in MARKABLE and t not in excl)


def markable(item: dict, types: set | list, rotten: bool = True) -> bool:
    """Python mirror of the Lua 'mark' filter (lua/pilot_hygiene.lua). item: {type, dwarf, bone, rotten, forbid, dump,
    reach, hidden, outside, foreign, artifact, stockpile}."""
    t = item.get("type")
    if t in HARD_NEVER or t == "BOULDER":
        return False
    if item.get("dump") or item.get("forbid") or item.get("foreign") or item.get("artifact") or item.get("stockpile"):
        return False
    if item.get("hidden"):
        return False
    hit = (t in set(types) and t in MARKABLE) or (rotten and t in FOOD_ROT and bool(item.get("rotten")))
    if not hit:
        return False
    if t in CORPSE_T and (item.get("dwarf") or item.get("bone")):
        return False
    return bool(item.get("outside") or item.get("reach", True))


def select_marks(items: list[dict], cfg: dict, pending: int = 0) -> list[dict]:
    """Items one cycle would mark: <= min(mark_batch, 300, pending_max - pending)."""
    n = max(0, min(int(cfg.get("mark_batch", HARD_CAP)), HARD_CAP, int(cfg.get("pending_max", HARD_CAP)) - pending))
    types = set(effective_types(cfg))
    out = []
    for it in items:
        if len(out) >= n:
            break
        if markable(it, types, bool(cfg.get("mark_rotten", True))):
            out.append(it)
    return out


# ------------------------------------------------------------------ measurement
@dataclass
class Measurement:
    ok: bool = True
    loose: int = 0
    by_type: dict = field(default_factory=dict)
    boulder_z: dict = field(default_factory=dict)
    area: dict = field(default_factory=dict)
    dwarf_corpses: int = 0
    other_corpses: int = 0
    rotten: int = 0
    pending: int = 0
    unreachable: int = 0
    sums: list = field(default_factory=lambda: [0, 0, 0])
    blocks: int = 0
    elapsed_s: float = 0.0
    max_block_s: float = 0.0
    error: str = ""
    # FEATURE-002 (pilot_hygiene status with flow fields; empty for old Lua copies and fixtures)
    has_flow: bool = False
    stock: dict = field(default_factory=dict)
    new: dict = field(default_factory=dict)
    reach_type: dict = field(default_factory=dict)
    unreach: dict = field(default_factory=dict)
    forb_corpses: dict = field(default_factory=dict)
    since: int | None = None
    next_id: int | None = None

    @property
    def corpses(self) -> int:
        return self.dwarf_corpses + self.other_corpses

    @property
    def unreachable_loose(self) -> int:
        return int(self.unreach.get("cavern", 0)) + int(self.unreach.get("surface", 0))

    @property
    def actionable(self) -> int:
        """Loose stacks the haulers can reach (FEATURE-002); all loose stacks when the Lua has no reach split."""
        return sum(self.reach_type.values()) if self.has_flow else self.loose

    def centroid(self) -> tuple | None:
        if self.pending <= 0:
            return None
        return tuple(round(s / self.pending) for s in self.sums)


def _add(d: dict, src) -> None:
    for k, v in (src or {}).items() if isinstance(src, dict) else []:
        d[str(k)] = d.get(str(k), 0) + int(v or 0)


def aggregate(blocks: list[dict]) -> Measurement:
    m = Measurement()
    for j in blocks:
        m.blocks += 1
        m.loose += int(j.get("loose") or 0)
        _add(m.by_type, j.get("by_type"))
        _add(m.boulder_z, j.get("boulder_z"))
        _add(m.area, j.get("area"))
        c = j.get("corpses") or {}
        m.dwarf_corpses += int(c.get("dwarf") or 0)
        m.other_corpses += int(c.get("other") or 0)
        m.rotten += int(j.get("rotten") or 0)
        mk = j.get("marked") or {}
        m.pending += int(mk.get("pending") or 0)
        m.unreachable += int(mk.get("unreachable") or 0)
        for i, k in enumerate(("sx", "sy", "sz")):
            m.sums[i] += int(mk.get(k) or 0)
        if "stock" in j:                                   # FEATURE-002 flow fields
            m.has_flow = True
            _add(m.stock, j.get("stock"))
            _add(m.new, j.get("new"))
            _add(m.reach_type, j.get("reach_type"))
            _add(m.unreach, j.get("unreach"))
            _add(m.forb_corpses, j.get("forb_corpses"))
            if j.get("next_id") is not None:
                m.next_id = max(int(j["next_id"]), m.next_id or 0)
            if j.get("since") is not None:
                m.since = int(j["since"])
    return m


def from_muell(j: dict) -> Measurement:
    """Fallback: `claude/muell status` (live prototype, J109) -> Measurement (types only, no corpses/areas)."""
    m = Measurement()
    m.loose = int(j.get("lose_stapel") or 0)
    m.pending = int(j.get("davon_dump_markiert") or 0)
    for part in str(j.get("typen") or "").split():
        k, _, v = part.partition("=")
        if v.isdigit():
            m.by_type[k] = int(v)
    m.other_corpses = sum(m.by_type.get(t, 0) for t in CORPSE_T)
    for part in str(j.get("boulder_je_z") or "").split():
        k, _, v = part.partition(":")
        if v.isdigit():
            m.boulder_z[k] = int(v)
    m.blocks = 1
    return m


# ------------------------------------------------------------------ zones and diagnosis
def _dist(a, b) -> int:
    """Chebyshev in x/y plus 3 tiles per z level (stairs cost)."""
    return max(abs(a[0] - b[0]), abs(a[1] - b[1])) + 3 * abs(a[2] - b[2])


def _zone_center(z: dict) -> tuple:
    if "x1" in z:
        return ((z["x1"] + z["x2"]) // 2, (z["y1"] + z["y2"]) // 2, z["z"])
    return ((z["x"][0] + z["x"][-1]) // 2, (z["y"][0] + z["y"][-1]) // 2, z["z"])


def zone_text(c: dict) -> str:
    return f"zone {c.get('name', '?')} z{c['z']} x{c['x'][0]}..{c['x'][-1]},y{c['y'][0]}..{c['y'][-1]}"


def suggest_zone(cfg: dict, existing: list[dict], near: tuple | None) -> dict | None:
    """Nearest configured candidate that is not already a dump zone (proposal only, nothing is built)."""
    taken = [_zone_center(z) for z in existing or []]
    gap = int(cfg.get("zone_min_gap", 5))           # BUG-220: no proposal right next to an existing dump zone
    cands = [c for c in cfg.get("dump_zones") or []
             if not any(_dist(_zone_center(c), t) <= gap for t in taken)]
    if not cands:
        return None
    if near is None:
        return cands[0]
    return min(cands, key=lambda c: _dist(_zone_center(c), near))


def diagnose(m: Measurement, rep: dict | None, cfg: dict) -> tuple[str, str] | None:
    """(cause, suggestion) if dumping does not work, else None. rep = `pilot_hygiene report` JSON."""
    rep = rep or {}
    zones = rep.get("dump_zones") or []
    if isinstance(zones, dict):          # empty Lua table may arrive as {}
        zones = list(zones.values())
    near = m.centroid() or (tuple(rep["ref"]) if rep.get("ref") else None)
    sug = suggest_zone(cfg, zones, near)
    sug_t = f"propose {zone_text(sug)}" if sug else "propose a 3x3 dump zone in a dead corner (hygiene.dump_zones)"
    if not zones:
        if m.other_corpses + m.rotten + m.pending > 0:
            return "no dump zone", sug_t
        return None
    if m.pending <= 0:
        return None
    jobs = int(rep.get("dump_jobs") or 0)
    if jobs >= float(cfg.get("effect_min_ratio", 0.10)) * m.pending:
        return None
    if any(z.get("under_stockpile") for z in zones):
        return "zone under a stockpile", "move the dump zone onto free tiles (Run 1: 0 DumpItem jobs under a stockpile)"
    if m.unreachable * 2 >= m.pending:
        return "path blocked", f"{m.unreachable}/{m.pending} marked items unreachable from the fort; open the path"
    if int(rep.get("citizens") or 0) > 0 and int(rep.get("idle") or 0) == 0:
        return "haulers busy", "no idle citizen; add haulers or wait"
    c = m.centroid()
    if c is not None:
        d = min(_dist(_zone_center(z), c) for z in zones)
        if d > int(cfg.get("far_tiles", 30)):
            return "zone too far", sug_t + f" (nearest zone {d} tiles from the marked items)"
        return "unclear", "wild/rotten corpses are often never hauled (kb aufraeumen); check stockpile_delay"
    return "zone too far", sug_t


def area_split_failed(m) -> str:
    """BUG-210: many loose items but none in the area 'fort' = the reference tile reaches nothing (e.g. it lies outside a
    closed gatehouse). Returns the warning line or ''."""
    if int(m.area.get("fort", 0)) == 0 and m.loose > 1000:
        return ("!! area classification failed: no loose item is reachable from the fort reference "
                "(claude/config FORT_REFS outside a closed gate?) - areas and dump diagnosis unreliable")
    return ""


def _k(n: int) -> str:
    if n >= 100000:
        return f"{n / 1000:.0f}k"
    if n >= 1000:
        return f"{n / 1000:.1f}".rstrip("0").rstrip(".") + "k"
    return str(n)


def digest_line(m: Measurement, rep: dict | None, rate_h: float | None, cfg: dict) -> str:
    """'loose stacks 12.5k (+200/h): boulders 10k (ok), corpses 900 (dump 6 jobs), goblets 410 (cap)' (<= 140)."""
    rep = rep or {}
    head = f"loose stacks {_k(m.actionable)}" + (f" ({rate_h:+.0f}/h)" if rate_h is not None else "")
    parts = []
    b = int(m.by_type.get("BOULDER", 0))
    if b:
        parts.append(f"boulders {_k(b)} (ok)")
    if m.corpses:
        zones = rep.get("dump_zones") or []
        tail = f"dump {int(rep.get('dump_jobs') or 0)} jobs" if zones else "no dump zone"
        parts.append(f"corpses {_k(m.corpses)} ({tail})")
    g = int(m.by_type.get("GOBLET", 0))
    if g:
        parts.append(f"goblets {_k(g)} ({'cap' if g > int(cfg.get('goblet_cap', 60)) else 'ok'})")
    t = int(m.by_type.get("THREAD", 0))
    if t:
        parts.append(f"thread {_k(t)} (keep)")
    if m.has_flow and m.unreachable_loose:           # FEATURE-002: webs/cavern items are no KPI
        parts.append(f"unreachable {_k(m.unreachable_loose)} ignored")
    line = head + (": " + ", ".join(parts) if parts else "")
    while len(line) > 140 and parts:
        parts.pop()
        line = head + (": " + ", ".join(parts) if parts else "")
    return line[:140]


def _pct(a: int, b: int) -> str:
    return f"{round(100 * a / b)} %" if b else "0 %"


def forbid_lines(j: dict | None, cfg: dict) -> list[str]:
    """BUG-125: `pilot_hygiene forbid` JSON -> lines. A line starting with '!!' is a warning (blocked drinks/food,
    forbidden containers, or >= forbid_material_warn forbidden building material). Forbidden 'other' items (siege
    loot, enemy gear) alone are only reported, never warned."""
    if not isinstance(j, dict) or not j.get("ok"):
        return ["forbidden own items: not readable (claude/pilot_hygiene forbid missing? reinstall the Lua scripts)"]
    c = j.get("classes") if isinstance(j.get("classes"), dict) else {}
    n = {k: int(c.get(k) or 0) for k in ("container", "drink", "food", "material", "other")}
    dr = j.get("drink") if isinstance(j.get("drink"), dict) else {}
    fo = j.get("food") if isinstance(j.get("food"), dict) else {}
    d_tot, d_bl, d_in = (int(dr.get(k) or 0) for k in ("total", "blocked", "in_forbidden_container"))
    f_tot, f_bl, f_in = (int(fo.get(k) or 0) for k in ("total", "blocked", "in_forbidden_container"))
    total = int(j.get("total") or 0)
    head = (f"forbidden own items: {total} (containers {n['container']}, drinks {n['drink']}, food {n['food']}, "
            f"material {n['material']}, other {n['other']})")
    if total == 0 and d_bl == 0 and f_bl == 0:
        return [head]
    blocked = (f"drinks blocked {d_bl}/{d_tot} ({_pct(d_bl, d_tot)}, {d_in} in forbidden containers), "
               f"food blocked {f_bl}/{f_tot} ({_pct(f_bl, f_tot)})")
    warn = d_bl > 0 or f_bl > 0 or n["container"] > 0 or n["material"] >= int(cfg.get("forbid_material_warn", 10))
    if not warn:
        return [head]
    fix = "unforbid own barrels/drinks/food/blocks (dwarves cancel 'Drink: Forbidden area' and die of thirst)"
    return [f"!! {head}; {blocked} -> {fix}"]


def legacy_lines(m: Measurement, rep: dict | None) -> list[str]:
    """FEATURE-002 rule 5: forbidden reachable non-dwarf corpses (legacy piles nobody marks) + the standing order that
    produces them. The standing order is never changed automatically (it protects haulers during sieges)."""
    out = []
    fc = m.forb_corpses or {}
    n, bone, dwarf = int(fc.get("other", 0)), int(fc.get("bone", 0)), int(fc.get("dwarf", 0))
    if m.has_flow:
        line = f"forbidden reachable non-dwarf corpses: {n}"
        extra = [f"{bone} bones/skins kept"] if bone else []
        extra += [f"{dwarf} dwarf/named never touched"] if dwarf else []
        if extra:
            line += " (" + ", ".join(extra) + ")"
        if n:
            line += " -> hygiene mark --unforbid (dry run; --apply sets forbid off + dump on)"
        out.append(line)
    st = (rep or {}).get("standing") if isinstance((rep or {}).get("standing"), dict) else {}
    if st.get("forbid_other_dead_items"):
        out.append("standing order forbid_other_dead_items=1: every enemy corpse/loot gets forbidden (source of future "
                   "legacy piles; keep it during sieges - df-llm-helper never changes it)")
    return out


# ------------------------------------------------------------------ runner
class Hygiene:
    def __init__(self, client, store, clock, cfg: dict | None = None):
        self.client, self.store, self.clock = client, store, clock
        self.cfg = {**DEFAULTS, **(cfg or {})}

    def _run(self, cmd: str):
        if any(w in cmd for w in FORBIDDEN_WORDS):
            raise PermissionError(f"hygiene: refused (item teleport): {cmd}")
        return self.client.run(cmd)

    @property
    def fcfg(self) -> dict:
        return {**DEFAULTS["flow"], **(self.cfg.get("flow") or {})}

    def _game_id(self):
        return self.store.get("game_id")

    def _since(self) -> int | None:
        """next_id of the newest flow snapshot of this game: the Lua counts items created since then (inflow)."""
        from ._itemflow import load_snapshots
        snaps = load_snapshots(self.store, self._game_id(), limit=1)
        return int(snaps[-1]["next_id"]) if snaps and snaps[-1].get("next_id") is not None else None

    def measure(self) -> Measurement:
        """All blocks; block size halves after a block slower than max_block_s (stored for the next run)."""
        block = int(self.store.get("hygiene.block") or self.cfg["block"])
        start, blocks, elapsed, worst = 0, [], 0.0, 0.0
        since = self._since()
        tail = f" {since}" if since is not None else ""
        for _ in range(10000):
            r = self._run(f"claude/pilot_hygiene status {start} {block}{tail}")
            elapsed += r.elapsed_s
            worst = max(worst, r.elapsed_s)
            j = r.json if r.ok and isinstance(r.json, dict) else None
            if not j or not j.get("ok"):
                if not blocks:                  # pilot_hygiene not installed: live prototype claude/muell
                    r2 = self._run("claude/muell status")
                    if r2.ok and isinstance(r2.json, dict) and "lose_stapel" in r2.json:
                        m = from_muell(r2.json)
                        m.elapsed_s = elapsed + r2.elapsed_s
                        m.max_block_s = max(worst, r2.elapsed_s)
                        m.error = "fallback claude/muell status (no corpse split, no areas)"
                        return m
                m = aggregate(blocks)
                m.ok, m.error = False, (r.stderr or "pilot_hygiene status not readable")[:120]
                m.elapsed_s, m.max_block_s = elapsed, worst
                return m
            blocks.append(j)
            if r.elapsed_s > float(self.cfg["max_block_s"]) and block > 1000:
                block = max(1000, block // 2)
                self.store.set("hygiene.block", block)
            nxt = int(j.get("next") or 0)
            if j.get("done") or nxt <= start:
                break
            start = nxt
        m = aggregate(blocks)
        m.elapsed_s, m.max_block_s = elapsed, worst
        return m

    def report(self) -> dict:
        r = self._run("claude/pilot_hygiene report")
        return r.json if r.ok and isinstance(r.json, dict) and r.json.get("ok") else {}

    def forbid(self) -> dict | None:
        r = self._run("claude/pilot_hygiene forbid")
        return r.json if r.ok and isinstance(r.json, dict) else None

    def piles(self) -> dict | None:
        r = self._run("claude/pilot_hygiene piles")
        return r.json if r.ok and isinstance(r.json, dict) and r.json.get("ok") else None

    def caps(self) -> dict | None:
        r = self._run("claude/pilot_hygiene caps")
        return r.json if r.ok and isinstance(r.json, dict) and r.json.get("ok") else None

    def record_flow(self, m: Measurement) -> None:
        """FEATURE-002: one flow snapshot per measurement (stock, reachable loose, new items per type)."""
        from ._itemflow import record_snapshot
        if m.has_flow:
            record_snapshot(self.store, self.clock.now().epoch, self._game_id(), m.since, m.next_id, m.stock,
                            m.reach_type, m.new)

    def flow(self, *, hours: float | None = None, record: bool = True, with_caps: bool = False) -> tuple[list[str], dict]:
        """`hygiene flow`: measure (records a snapshot unless record=False), then the flow table from the snapshots."""
        from . import _itemflow as fl
        fc = self.fcfg
        m = self.measure()
        if not m.ok:
            return [f"Hygiene: measurement failed ({m.error})"], {}
        if not m.has_flow:
            return ["flow: the installed claude/pilot_hygiene has no flow fields - reinstall the Lua scripts "
                    "(python -m df_llm_helper install-lua --apply)"], {}
        if record:
            self.record_flow(m)
        snaps = fl.load_snapshots(self.store, self._game_id())
        if not record:                          # dry run: the fresh measurement as the newest point, not stored
            snaps.append({"ts": self.clock.now().epoch, "since": m.since, "next_id": m.next_id,
                          "data": {t: [int(m.stock.get(t, 0)), int(m.reach_type.get(t, 0)), int(m.new.get(t, 0))]
                                   for t in set(m.stock) | set(m.reach_type) | set(m.new)}})
        rows, span = fl.flow_rows(snaps, float(hours or fc["hours"]))
        rep, piles, caps = self.report(), self.piles(), self.caps()
        space = fl.capacity(piles)
        kinds = fl.craft_cap_info(caps)
        blines, bstates = fl.bridge_lines(rep, fc)
        full = sum(int(b.get("items") or 0) for b in (rep.get("bridges") or [])
                   if isinstance(b, dict) and bstates.get(str(b.get("id"))) == "full")
        plan = fl.bin_plan(m.reach_type, piles, fc) if piles else None
        out = fl.flow_table(rows, span, m, space, kinds, fc, full, plan)
        if piles is None:
            out.append("free slots unknown (claude/pilot_hygiene piles not readable)")
        out += legacy_lines(m, rep)
        out += blines
        if with_caps:
            out += fl.caps_audit(caps, fc)
        info = {"rows": rows, "span": span, "bridges": bstates, "measurement": m, "report": rep}
        return out, info

    def bins(self, *, apply: bool = False, pile: int | None = None, registry=None) -> list[str]:
        """`hygiene bins`: bin planner; --apply = ONE one-off ConstructBin order + max_bins of one stockpile, only with
        the exception-register entry FP14 (player consent) and never while a bin order is open."""
        from . import _itemflow as fl
        fc = self.fcfg
        m = self.measure()
        if not m.ok:
            return [f"Hygiene: measurement failed ({m.error})"]
        piles = self.piles()
        if piles is None:
            return ["bins: claude/pilot_hygiene piles not readable (reinstall the Lua scripts)"]
        plan = fl.bin_plan(m.reach_type if m.has_flow else m.by_type, piles, fc, pile)
        out = fl.bin_lines(plan)
        n = min(plan["need"], int(fc.get("max_bins_per_order", 50)))
        tgt = plan["target"]
        if n <= 0:
            out.append("no bins needed")
            return out
        new_max = (int(tgt.get("bins") or 0) + n) if tgt else None
        cmds = [f"claude/pilot_hygiene bins_order {n} --reserve {plan['reserve']}"]
        if tgt and new_max > int(tgt.get("max_bins") or 0):     # only ever raised, never lowered
            cmds.append(f"claude/pilot_hygiene max_bins {tgt.get('id')} {new_max}")
        elif tgt:
            out.append(f"stockpile #{tgt.get('id')} max_bins {tgt.get('max_bins')} already >= {new_max}: unchanged")
            tgt = None
        if not apply:
            what = f" and set max_bins of stockpile #{tgt.get('id')} to {new_max}" if tgt else ""
            out.append(f"[dry] would order {n} bins (one-off, wood){what}: " + "; ".join(c + " --apply" for c in cmds))
            return out
        if plan["open_orders"]:
            out.append("refused: a ConstructBin order is still open (no second order)")
            return out
        if not plan["wood_ok"]:
            out.append("refused: not enough free logs (wood gate)")
            return out
        reg = registry if registry is not None else getattr(self.client, "registry", None)
        if reg is None or not reg.allows("FP14", cmd=cmds[0] + " --apply"):
            out.append("refused: bins --apply creates a manager order and changes a stockpile setting; it needs the "
                       "player's exception-register entry FP14 (python -m df_llm_helper exception add FP14 --reason "
                       "\"bin planner\" --ja \"<player quote>\")")
            return out
        now = self.clock.now().epoch
        r = self._run(cmds[0] + " --apply")
        j = r.json if r.ok and isinstance(r.json, dict) else {}
        ok = bool(j.get("ok") and j.get("applied"))
        self.store.log_action(now, "hygiene", "hygiene", "bins_order", "manager_orders", cmds[0] + " --apply", False, ok,
                              f"order {j.get('order_id')} n={n} {j.get('reason', '')}"[:200])
        if not ok:
            out.append(f"bin order refused by the game script: {j.get('reason') or r.stderr or 'no answer'}")
            return out
        out.append(f"ordered {n} bins (one-off manager order #{j.get('order_id')}, wood {j.get('wood')})")
        if tgt:
            try:
                r2 = self._run(cmds[1] + " --apply")
            except PermissionError as e:       # FP14 entry used up (max_uses) by the order itself
                out.append(f"max_bins not set: {e}"[:200])
                return out
            j2 = r2.json if r2.ok and isinstance(r2.json, dict) else {}
            self.store.log_action(now, "hygiene", "hygiene", "max_bins", f"stockpile:{tgt.get('id')}",
                                  cmds[1] + " --apply", False, bool(j2.get("applied")),
                                  f"{j2.get('before')} -> {j2.get('after')}")
            out.append(f"stockpile #{tgt.get('id')} max_bins {j2.get('before')} -> {j2.get('after')}"
                       if j2.get("applied") else f"max_bins not set: {j2.get('reason') or r2.stderr or 'no answer'}")
        return out

    def crypt(self) -> dict:
        r = self._run("claude/gesund krypta")
        return r.json if r.ok and isinstance(r.json, dict) else {}

    def rate(self, total: int, record: bool = True) -> float | None:
        now = self.clock.now().epoch
        hist = [h for h in (self.store.get("hygiene.history") or []) if now - h[0] <= 6 * 3600]
        rate = None
        if hist and now - hist[0][0] >= 900:
            rate = (total - hist[0][1]) / ((now - hist[0][0]) / 3600.0)
        if record:
            hist.append([now, total])
            self.store.set("hygiene.history", hist[-48:])
        return rate

    def status(self, *, record: bool = True) -> tuple[list[str], Measurement, dict]:
        m = self.measure()
        if not m.ok:
            return [f"Hygiene: measurement failed ({m.error})"], m, {}
        rep = self.report()
        line = digest_line(m, rep, self.rate(m.actionable, record), self.cfg)
        if record:
            self.record_flow(m)                            # FEATURE-002: flow snapshot per measurement
        out = [line]
        top = sorted(m.by_type.items(), key=lambda kv: -kv[1])[:8]
        out.append("types: " + " ".join(f"{k}={v}" for k, v in top))
        out.append("areas: " + " ".join(f"{k}={v}" for k, v in sorted(m.area.items()))
                   + f"; corpses dwarf={m.dwarf_corpses} other={m.other_corpses}; rotten={m.rotten}")
        out.append(f"marked pending={m.pending} (unreachable {m.unreachable}); dump jobs={rep.get('dump_jobs', '?')}; "
                   f"zones={len(rep.get('dump_zones') or [])}")
        if m.has_flow:
            u = m.unreach
            out.append(f"reachable loose {m.actionable}; unreachable {m.unreachable_loose} ignored (cavern "
                       f"{u.get('cavern', 0)}, surface {u.get('surface', 0)}, webs {u.get('thread', 0)})")
        out += legacy_lines(m, rep)
        from ._itemflow import bridge_lines
        out += bridge_lines(rep, self.fcfg)[0]
        bad_split = area_split_failed(m)
        if bad_split:                     # BUG-210: every diagnosis below would build on a wrong area split
            out.append(bad_split)
        dg = None if bad_split else diagnose(m, rep, self.cfg)
        if dg:
            out.append(f"Dump: cause '{dg[0]}' -> {dg[1]}")
        g = int(m.by_type.get("GOBLET", 0))
        if g > int(self.cfg["goblet_cap"]):
            out.append(f"Goblets {g} loose: never dump (trade goods); order cap goblets <= {self.cfg['goblet_cap']} "
                       f"(claude/orders) + stockpile with bins")
        if int(m.by_type.get("BOULDER", 0)):
            out.append("Boulders: never dumped (building material); if needed propose an extra stone stockpile")
        out += self.crypt_lines(m)
        out += forbid_lines(self.forbid(), self.cfg)           # BUG-125: never silent about forbidden supplies
        if m.error:
            out.append(f"note: {m.error}")
        speed = f"measurement {m.elapsed_s:.1f} s in {m.blocks} blocks (slowest {m.max_block_s:.1f} s)"
        if m.elapsed_s > float(self.cfg["max_measure_s"]):
            speed += f" - over {self.cfg['max_measure_s']} s, block size now {self.store.get('hygiene.block')}"
        out.append(speed)
        if record:
            self.store.set("hygiene.line", line)
            self.store.set("hygiene.last_measure", self.clock.now().epoch)
        return out, m, rep

    def crypt_lines(self, m: Measurement) -> list[str]:
        if m.dwarf_corpses <= 0:
            return []
        k = self.crypt()
        free = k.get("saerge_frei")
        ghosts = int(k.get("geister") or 0)
        if free is None:
            return [f"Dwarf corpses loose: {m.dwarf_corpses} (never dumped; crypt status not readable)"]
        opened = k.get("leichen_offen")
        if isinstance(opened, (int, float)) and int(opened) < m.dwarf_corpses:
            # BUG-210: the crypt script counts the corpses that really wait for a burial; trust it for the alarm
            if int(opened) <= 0:
                return [f"Dwarf corpses (item count) {m.dwarf_corpses}, crypt status: 0 waiting for burial "
                        f"({free} coffins free) - no ghost risk"]
            if int(free) < int(opened):
                return [f"!! Dwarf corpses waiting for burial {int(opened)} > free coffins {free}: ghost risk - "
                        "build coffins/tombs" + (f" ({ghosts} ghosts)" if ghosts else "")]
            return [f"Dwarf corpses waiting for burial {int(opened)}: {free} coffins free (burial runs, never dumped)"]
        if int(free) < m.dwarf_corpses:
            return [f"!! Dwarf corpses {m.dwarf_corpses} > free coffins {free}: ghost risk - build coffins/tombs"
                    + (f" ({ghosts} ghosts)" if ghosts else "")]
        return [f"Dwarf corpses {m.dwarf_corpses}: {free} coffins free (burial runs, never dumped)"]

    def cycle(self, *, apply: bool = False, unforbid: bool = False) -> list[str]:
        """One mark cycle. apply=False: dry run (Lua counts candidates, marks nothing). unforbid=True (FEATURE-002):
        the legacy FORBIDDEN non-dwarf corpses/parts/remains get forbid off + dump on (own items, item-menu actions)."""
        now = self.clock.now().epoch
        m = self.measure()
        if not m.ok:
            return [f"Hygiene: measurement failed ({m.error}) - nothing marked"]
        rep = self.report()
        zones = rep.get("dump_zones") or []
        out = []
        bad_split = area_split_failed(m)
        if bad_split:                     # BUG-210: every diagnosis below would build on a wrong area split
            out.append(bad_split)
        dg = None if bad_split else diagnose(m, rep, self.cfg)
        if dg:
            out.append(f"Dump: cause '{dg[0]}' -> {dg[1]}")
        if not zones:
            out.append("No dump zone: nothing marked (marks without a zone only pile up)")
            return out
        room = min(int(self.cfg["mark_batch"]), HARD_CAP, int(self.cfg["pending_max"]) - m.pending)
        if room <= 0:
            out.append(f"{m.pending} marks still pending (>= {self.cfg['pending_max']}): wait for the haulers")
            return out
        types = effective_types(self.cfg)
        if unforbid:
            types = [t for t in types if t in CORPSE_T]
            if not types:
                out.append("No corpse types configured (hygiene.mark_types): nothing to unforbid")
                return out
        if not types and not self.cfg.get("mark_rotten"):
            out.append("No markable types configured")
            return out
        act = "unforbid" if unforbid else "mark"
        if apply and self.store.count_actions("hygiene", act, now - 3600) >= int(self.cfg["max_marks_per_hour"]):
            out.append(f"Loop protection: already {self.cfg['max_marks_per_hour']} {act} cycles in the last hour")
            return out
        if unforbid:
            cmd = (f"claude/pilot_hygiene mark {room} {','.join(types)} --unforbid"
                   + (" --apply" if apply else " --dry"))
            if apply:                     # an old Lua copy ignores --unforbid and would dump-mark other items: probe
                probe = self._run(cmd.replace(" --apply", " --dry"))
                pj = probe.json if probe.ok and isinstance(probe.json, dict) else {}
                if pj.get("unforbid") is not True:
                    out.append("unforbid: the installed claude/pilot_hygiene does not know --unforbid (reinstall the "
                               "Lua scripts); nothing changed")
                    return out
        else:
            cmd = (f"claude/pilot_hygiene mark {room} {','.join(types) or 'NONE'}"
                   + (" --rotten" if self.cfg.get("mark_rotten") else "") + (" --apply" if apply else " --dry"))
        r = self._run(cmd)
        j = r.json if r.ok and isinstance(r.json, dict) else {}
        n = int(j.get("marked") or 0)
        refused = j.get("refused") or {}
        if unforbid:
            ids = j.get("ids") if isinstance(j.get("ids"), list) else []
            id_txt = ",".join(str(i) for i in ids)
            ref_txt = ", ".join(f"{k} {v}" for k, v in sorted(refused.items()))
            if j.get("unforbid") is not True:
                out.append("unforbid: the installed claude/pilot_hygiene does not know --unforbid (reinstall the Lua "
                           "scripts); nothing changed")
                return out
            if apply:
                self.store.log_action(now, "hygiene", "hygiene", "unforbid", "items", cmd, False, bool(j.get("ok")),
                                      f"unforbid+dump {n}: {id_txt}"[:200])
                out.append(f"Unforbid + dump-marked {n} legacy corpses/parts (cap {room}); refused: {ref_txt}")
            else:
                out.append(f"[dry] would unforbid + dump-mark {int(j.get('candidates') or 0)} forbidden non-dwarf "
                           f"corpses/parts (cap {room}); refused: {ref_txt}")
            if id_txt:
                out.append(f"ids: {id_txt}")
            return out
        if apply:
            self.store.log_action(now, "hygiene", "hygiene", "mark", "items", cmd, False, bool(j.get("ok")),
                                  f"marked {n}, refused {refused}"[:200])
            out.append(f"Marked {n} items for the dump (cap {room}); refused: "
                       + ", ".join(f"{k} {v}" for k, v in sorted(refused.items())))
        else:
            out.append(f"[dry] would mark {int(j.get('candidates') or 0)} items (cap {room}): {cmd}")
        return out


# ------------------------------------------------------------------ CLI + check
def flow_transitions(h: "Hygiene", info: dict, now: float, dry: bool) -> list[str]:
    """FEATURE-002 rule 9: wake lines only on a state change (CRAFTS growing, garbage-bridge landing over the limit),
    once per transition."""
    from ._itemflow import transition
    out = []
    rows = info.get("rows") or {}
    cr = rows.get("CRAFTS")
    if cr is not None and cr.inflow is not None:
        grow = cr.inflow > (cr.sink or 0) + float(h.fcfg.get("flow_eps", 0.5))
        out += transition(h.store, "crafts", "growing" if grow else "ok",
                          f"crafts GROWING: +{cr.inflow:.0f}/h made, {cr.sink or 0:.0f}/h sold/used, stock {cr.stock} "
                          f"-> lower the craft cap (hygiene flow --caps)", now, alarm={"growing"}, dry=dry)
    rep = info.get("report") or {}
    for b in rep.get("bridges") or []:
        if not isinstance(b, dict):
            continue
        bid = str(b.get("id"))
        st = (info.get("bridges") or {}).get(bid, "ok")
        out += transition(h.store, f"bridge:{bid}", st,
                          f"garbage bridge #{bid}: {b.get('items')} items on the landing (> "
                          f"{h.fcfg.get('landing_warn', 300)}) -> pull the lever (player action)", now,
                          alarm={"full"}, dry=dry)
    return out


def _cmd(args) -> int:
    from ..cli import _pilot          # lazy: no cli import at module level (import cycles)
    p = _pilot(args)
    h = Hygiene(p.client, p.store, p.clock, p.cfg.get(KEY, {}))
    now = p.clock.now().epoch
    if args.action == "mark":
        print("\n".join(h.cycle(apply=bool(args.apply), unforbid=bool(args.unforbid))))
        return 0
    if args.action == "zones":
        from ._itemflow import bridge_lines
        rep = h.report()
        zones = rep.get("dump_zones") or []
        for z in zones:
            print(f"dump zone #{z.get('id')} z{z.get('z')} x{z.get('x1')}..{z.get('x2')},y{z.get('y1')}..{z.get('y2')}"
                  + (" UNDER A STOCKPILE" if z.get("under_stockpile") else ""))
        sug = suggest_zone(h.cfg, zones, tuple(rep["ref"]) if rep.get("ref") else None)
        print(f"{len(zones)} dump zones; DumpItem jobs {rep.get('dump_jobs', '?')}"
              + (f"; proposal: {zone_text(sug)} ({sug.get('note', '')})" if sug else ""))
        blines, bstates = bridge_lines(rep, h.fcfg)
        for ln in blines:
            print(ln)
        for ln in flow_transitions(h, {"report": rep, "bridges": bstates}, now, bool(args.dry_run)):
            print(ln)
        return 0
    if args.action in ("flow", "caps"):
        if args.action == "caps":
            from ._itemflow import caps_audit
            print("\n".join(caps_audit(h.caps(), h.fcfg)))
            return 0
        lines, info = h.flow(hours=args.hours, record=not args.dry_run, with_caps=bool(args.caps))
        print("\n".join(lines))
        if info:
            for ln in flow_transitions(h, info, now, bool(args.dry_run)):
                print(ln)
        return 0 if info else 1
    if args.action == "bins":
        print("\n".join(h.bins(apply=bool(args.apply), pile=args.pile)))
        return 0
    lines, m, _ = h.status(record=not args.dry_run)
    print("\n".join(lines))
    return 0 if m.ok else 1


def register(sub) -> None:
    s = sub.add_parser("hygiene", help="item hygiene: loose stacks, dump marks (<= 300/cycle), zone proposals, item flow "
                                       "budget (flow/caps/bins)")
    s.add_argument("action", nargs="?", default="status", choices=["status", "mark", "zones", "flow", "caps", "bins"])
    s.add_argument("--apply", action="store_true",
                   help="mark: really set the garbage flag; bins: create the bin order + max_bins (needs FP14); "
                        "otherwise dry run")
    s.add_argument("--unforbid", action="store_true",
                   help="mark: the forbidden non-dwarf corpses/parts (legacy piles) get forbid off + dump on")
    s.add_argument("--dry-run", action="store_true", help="status/flow/zones: do not record history or states")
    s.add_argument("--hours", type=float, default=None, help="flow: rate window in hours (default hygiene.flow.hours)")
    s.add_argument("--caps", action="store_true", help="flow: add the manager-order cap audit")
    s.add_argument("--pile", type=int, default=None, help="bins: stockpile id whose max_bins is raised")
    s.set_defaults(fn=_cmd)


def _forbid_hook(pilot, h: "Hygiene", cfg: dict, now: float, dry: bool) -> list[str]:
    """BUG-125: forbidden supplies on their own short interval; the warning repeats only when its text changes or
    every 30 min (it is the cause of thirst deaths, not a cosmetic finding)."""
    last = pilot.store.get("hygiene.forbid_last")
    if last is not None and now - float(last) < float(cfg.get("forbid_every_s", 300)):
        return []
    j = h.forbid()
    if not dry:
        pilot.store.set("hygiene.forbid_last", now)
    if j is None:                       # old Lua without 'forbid': stay quiet in check (status shows the hint)
        return []
    warn = [ln for ln in forbid_lines(j, cfg) if ln.startswith("!!")]
    if not warn:
        if not dry:
            pilot.store.set("hygiene.forbid_warn", None)
        return []
    prev = pilot.store.get("hygiene.forbid_warn") or {}
    if prev.get("text") == warn[0] and now - float(prev.get("ts") or 0) < 1800:
        return []
    if not dry:
        pilot.store.set("hygiene.forbid_warn", {"text": warn[0], "ts": now})
    return ["Hygiene: " + warn[0]]


def _forbid_watch_active(pilot, now: float) -> bool:
    """FEATURE-003: forbid-watch reports the forbidden supplies (with causes); hygiene stays quiet meanwhile."""
    if not pilot.cfg.get("forbid_watch.in_check", True):
        return False
    ts = pilot.store.get("forbid_watch.active_ts")
    return ts is not None and now - float(ts) < 2 * float(pilot.cfg.get("forbid_watch.every_s", 300)) + 60


def check_hook(pilot, report, dry: bool) -> list[str]:
    cfg = {**DEFAULTS, **(pilot.cfg.get(KEY, {}) or {})}
    now = pilot.clock.now().epoch
    h = Hygiene(pilot.client, pilot.store, pilot.clock, cfg)
    forb = [] if _forbid_watch_active(pilot, now) else _forbid_hook(pilot, h, cfg, now, dry)
    last = pilot.store.get("hygiene.last_measure")
    if last is not None and now - float(last) < float(cfg["measure_every_s"]):
        return forb
    lines, m, rep = h.status(record=not dry)
    if not m.ok:
        if not dry:                     # rate-limit failures too (script missing -> one line per interval)
            pilot.store.set("hygiene.last_measure", now)
        return [lines[0]] + forb
    out = list(forb)
    warn = [ln for ln in lines if ln.startswith(("Dump: cause", "!!"))
            and not ln.startswith(("!! forbidden own", "!! garbage bridge"))]   # bridge: once per transition below
    if warn or m.other_corpses >= int(cfg["corpse_warn"]):
        out.append("Hygiene: " + lines[0])
        out += warn
    if m.has_flow:                       # FEATURE-002: wake lines on a state change only (no extra DF call)
        from ._itemflow import bridge_lines, flow_rows, load_snapshots
        rows, _ = flow_rows(load_snapshots(pilot.store, h._game_id()), float(h.fcfg["hours"]))
        info = {"rows": rows, "report": rep, "bridges": bridge_lines(rep, h.fcfg)[1]}
        out += ["Hygiene: !! " + ln.removeprefix("WAKE hygiene: ") for ln in flow_transitions(h, info, now, dry)]
    if cfg.get("auto_mark") and not dry and (rep.get("dump_zones") or []):
        out += [ln for ln in h.cycle(apply=True) if ln.startswith(("Marked", "Loop protection"))]
    return out

