"""FEATURE-002 item flow budget: pure logic behind `hygiene flow`, `hygiene caps`, `hygiene bins` and the garbage bridge.

Inputs are the JSON answers of `claude/pilot_hygiene status|report|piles|caps` (lua/pilot_hygiene.lua) and the flow
snapshots this module keeps in state.db (table `item_flow`, one row per measurement: stock, reachable loose stacks and
newly created items per item type). No DF call here; hygiene.py runs the Lua and prints.

Rates: each snapshot counts the items created since the previous snapshot (item id >= the previous next_id), so
  inflow/h = sum(new) / hours            sink/h = (stock_first + sum(new) - stock_last) / hours
over the window. A type that appears has stock_first 0; a type that vanishes has stock_last 0. When the chain of
snapshots is broken (no since id, other game) only the net change is known.
"""
from __future__ import annotations

import json
import math

__all__ = ["CRAFT_KINDS", "FINISHED_GOODS", "CATEGORY", "group_of", "FlowRow", "record_snapshot", "load_snapshots",
           "flow_rows", "capacity", "caps_audit", "craft_cap_info", "bin_plan", "bridge_lines", "flow_table",
           "transition"]

CORPSES = ("CORPSE", "CORPSEPIECE", "REMAINS")
CRAFT_KINDS = ("CRAFTS", "FIGURINE", "AMULET", "SCEPTER", "CROWN", "RING", "EARRING", "BRACELET")
FINISHED_GOODS = frozenset(CRAFT_KINDS) | {"GOBLET", "INSTRUMENT", "TOY", "TOTEM", "FLASK", "BOX"}
# item type -> stockpile category (settings.flags) that accepts it
CATEGORY = {**{t: "finished_goods" for t in FINISHED_GOODS}, "BLOCKS": "bars_blocks", "BAR": "bars_blocks",
            "BOULDER": "stone", "WOOD": "wood", "CORPSE": "corpses", "CORPSEPIECE": "refuse", "REMAINS": "refuse",
            "WEAPON": "weapons", "AMMO": "ammo", "ARMOR": "armor", "HELM": "armor", "SHOES": "armor", "PANTS": "armor",
            "GLOVES": "armor", "SHIELD": "armor", "THREAD": "cloth", "CLOTH": "cloth", "SKIN_TANNED": "leather",
            "ROUGH": "gems", "SMALLGEM": "gems", "GEM": "gems", "BARREL": "furniture", "BIN": "furniture",
            "BUCKET": "furniture", "CHAIR": "furniture", "TABLE": "furniture", "BED": "furniture", "DOOR": "furniture"}
SCHEMA = ("CREATE TABLE IF NOT EXISTS item_flow (id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL, game_id TEXT, "
          "since INTEGER, next_id INTEGER, data TEXT)")


def group_of(t: str) -> str:
    if t in CORPSES:
        return "CORPSE+PIECE"
    if t in CRAFT_KINDS:
        return "CRAFTS"
    return t


# ------------------------------------------------------------------ snapshots (state.db table item_flow)
def record_snapshot(store, ts: float, game_id, since, next_id, stock: dict, reach: dict, new: dict) -> None:
    """One row per measurement: {type: [stock, reachable loose stacks, new since the previous snapshot]}."""
    store.db.execute(SCHEMA)
    types = set(stock) | set(reach) | set(new)
    data = {t: [int(stock.get(t, 0)), int(reach.get(t, 0)), int(new.get(t, 0))] for t in sorted(types)}
    store.db.execute("INSERT INTO item_flow(ts, game_id, since, next_id, data) VALUES(?,?,?,?,?)",
                     (ts, game_id, since, next_id, json.dumps(data, sort_keys=True)))
    store.db.execute("DELETE FROM item_flow WHERE id NOT IN (SELECT id FROM item_flow ORDER BY id DESC LIMIT 500)")


def load_snapshots(store, game_id=None, limit: int = 500) -> list[dict]:
    store.db.execute(SCHEMA)
    rows = store.db.execute("SELECT * FROM item_flow ORDER BY id DESC LIMIT ?", (limit,)).fetchall()
    out = []
    for r in reversed(rows):
        if game_id is not None and r["game_id"] not in (None, game_id):
            continue
        try:
            data = json.loads(r["data"])
        except (TypeError, ValueError):
            continue
        out.append({"ts": r["ts"], "game_id": r["game_id"], "since": r["since"], "next_id": r["next_id"], "data": data})
    return out


class FlowRow:
    __slots__ = ("group", "stock", "loose", "inflow", "sink", "net", "kinds")

    def __init__(self, group: str):
        self.group, self.stock, self.loose = group, 0, 0
        self.inflow = self.sink = self.net = None
        self.kinds = set()

    def __repr__(self) -> str:                 # pragma: no cover - debugging aid
        return f"FlowRow({self.group}, stock={self.stock}, loose={self.loose}, in={self.inflow}, sink={self.sink})"


def _grouped(data: dict) -> dict:
    out: dict = {}
    for t, v in (data or {}).items():
        g = group_of(t)
        s = out.setdefault(g, [0, 0, 0, set()])
        for i in range(3):
            s[i] += int(v[i] if i < len(v) else 0)
        if int(v[0] if v else 0) or int(v[1] if len(v) > 1 else 0):
            s[3].add(t)
    return out


def flow_rows(snaps: list[dict], hours: float = 24.0, min_span_s: float = 900.0) -> tuple[dict, float | None]:
    """{group: FlowRow} from the newest snapshot, with inflow/sink/net per hour over the window (None = unknown),
    and the window length in hours (None if fewer than two usable snapshots)."""
    if not snaps:
        return {}, None
    last = snaps[-1]
    win = [s for s in snaps if s["ts"] >= last["ts"] - hours * 3600]
    cur = _grouped(last["data"])
    rows = {}
    for g, (stock, loose, _new, kinds) in cur.items():
        r = FlowRow(g)
        r.stock, r.loose, r.kinds = stock, loose, kinds
        rows[g] = r
    if len(win) < 2 or last["ts"] - win[0]["ts"] < min_span_s:
        return rows, None
    first = win[0]
    span_h = (last["ts"] - first["ts"]) / 3600.0
    chain = all(b.get("since") is not None and a.get("next_id") is not None and int(b["since"]) == int(a["next_id"])
                for a, b in zip(win, win[1:]))
    g0 = _grouped(first["data"])
    news: dict = {}
    for s in win[1:]:
        for g, v in _grouped(s["data"]).items():
            news[g] = news.get(g, 0) + v[2]
    for g in set(g0) | set(cur):
        r = rows.get(g)
        if r is None:                             # vanished since the window start
            r = rows[g] = FlowRow(g)
        s0 = g0.get(g, [0])[0]
        r.net = (r.stock - s0) / span_h
        if chain:
            n = news.get(g, 0)
            r.inflow = n / span_h
            r.sink = max(0.0, s0 + n - r.stock) / span_h
    return rows, span_h


# ------------------------------------------------------------------ capacity, caps, bins
def _list(v) -> list:
    if isinstance(v, dict):                       # an empty Lua table arrives as {}
        return list(v.values())
    return list(v or [])


def capacity(piles: dict | None) -> dict:
    """{category: free tiles in stockpiles that accept it} + '_bins_fg' (bins in finished-goods piles)."""
    out: dict = {}
    for p in _list((piles or {}).get("piles")):
        for c in _list(p.get("cats")):
            out[c] = out.get(c, 0) + int(p.get("free") or 0)
            if c == "finished_goods":
                out["_bins_fg"] = out.get("_bins_fg", 0) + int(p.get("bins") or 0)
    return out


def craft_cap_info(caps: dict | None) -> dict:
    """Per-kind caps of the craft orders: {kind: cap} (largest LessThan value per kind)."""
    out: dict = {}
    for o in _list((caps or {}).get("orders")):
        for c in _list(o.get("conds")):
            if c.get("cmp") == "LessThan" and c.get("type") in CRAFT_KINDS:
                out[c["type"]] = max(out.get(c["type"], 0), int(c.get("value") or 0))
    return out


def caps_audit(caps: dict | None, cfg: dict) -> list[str]:
    """One line per manager-order condition with an item cap, '!' marks a finding that needs the player."""
    if not isinstance(caps, dict) or not caps.get("ok"):
        return ["caps: not readable (claude/pilot_hygiene caps missing? reinstall the Lua scripts)"]
    stock = caps.get("stock") if isinstance(caps.get("stock"), dict) else {}
    out = []
    for o in _list(caps.get("orders")):
        for c in _list(o.get("conds")):
            if c.get("cmp") not in ("LessThan", "AtMost") or c.get("type") in (None, "*"):
                continue
            t, cap = c["type"], int(c.get("value") or 0)
            s = stock.get(t) or {}
            n, inc = int(s.get("stock") or 0), int(s.get("in_container") or 0)
            head = f"order #{o.get('id')} {o.get('job')} ({o.get('freq')}): cap {t} < {cap}, stock {n}"
            if c.get("flags"):
                out.append(f"{head} [{c['flags']}] - cap counts differently (condition flags; the manager counts "
                           f"only matching items)")
            elif n >= cap and n - inc < cap:
                out.append(f"{head} ({inc} in containers) - cap counts differently (container contents decide)")
            elif n >= cap:
                out.append(f"{head} - cap exceeded (fine, production stopped)")
            else:
                out.append(f"{head} - cap above stock (production never stops until {cap})")
    kinds = craft_cap_info(caps)
    if kinds:
        total_cap = sum(kinds.values())
        sale = int(cfg.get("sale_capacity", 800))
        crafts = sum(int((stock.get(k) or {}).get("stock") or 0) for k in CRAFT_KINDS)
        if total_cap > sale:
            out.append(f"! crafts: cap {max(kinds.values())} per kind x {len(kinds)} kinds = {total_cap} > sale "
                       f"capacity {sale} (flow.sale_capacity) - cap above sale capacity, lower the cap")
        if crafts > sale:
            out.append(f"! crafts: stock {crafts} = {crafts / sale:.1f}x the sale capacity {sale} per caravan season")
    return out or ["caps: no manager order with an item cap"]


def bin_plan(reach_type: dict, piles: dict | None, cfg: dict, pile_id: int | None = None) -> dict:
    """Bins needed for the loose reachable finished goods, wood cost, max_bins vs existing bins, target pile."""
    per_bin = max(1, int(cfg.get("bin_capacity", 100)))
    loose = {t: int(n) for t, n in (reach_type or {}).items() if t in FINISHED_GOODS and int(n) > 0}
    total = sum(loose.values())
    need = math.ceil(total / per_bin) if total else 0
    pj = piles or {}
    bins = pj.get("bins") if isinstance(pj.get("bins"), dict) else {}
    plist = _list(pj.get("piles"))
    fg = [p for p in plist if "finished_goods" in _list(p.get("cats"))]
    want = sum(int(p.get("max_bins") or 0) for p in plist)
    wood = int(pj.get("wood") or 0)
    reserve = int(cfg.get("wood_reserve", 10))
    target = None
    if pile_id is not None:
        target = next((p for p in plist if int(p.get("id", -1)) == int(pile_id)), None)
    elif fg:
        target = max(fg, key=lambda p: (int(p.get("tiles") or 0), -int(p.get("id") or 0)))
    open_orders = [o for o in _list(pj.get("bin_orders")) if int(o.get("left") or 0) > 0]
    return {"loose": loose, "loose_total": total, "need": need, "wood": wood, "reserve": reserve,
            "wood_ok": wood >= need + reserve, "bins_total": int(bins.get("total") or 0),
            "bins_empty": int(bins.get("empty") or 0), "bins_outside": int(bins.get("outside") or 0),
            "max_bins_sum": want, "mismatch": want > int(bins.get("total") or 0), "target": target, "fg_piles": fg,
            "open_orders": open_orders}


def bin_lines(plan: dict) -> list[str]:
    lt = plan["loose_total"]
    parts = ", ".join(f"{t} {n}" for t, n in sorted(plan["loose"].items(), key=lambda kv: -kv[1])[:6])
    out = [f"bins: loose finished goods {lt}" + (f" ({parts})" if parts else "")
           + f" -> need {plan['need']} bins (wood cost {plan['need']} logs; free logs {plan['wood']}, reserve "
             f"{plan['reserve']})"]
    out.append(f"bins existing {plan['bins_total']} (empty {plan['bins_empty']}, outside a stockpile "
               f"{plan['bins_outside']}); max_bins requested by stockpiles {plan['max_bins_sum']}")
    if plan["mismatch"]:
        out.append(f"! max_bins sum {plan['max_bins_sum']} > bins that exist {plan['bins_total']}: new bins go to random "
                   f"stockpiles (e.g. a block stockpile) - lower max_bins where bins are not needed")
    for p in plan["fg_piles"][:6]:
        out.append(f"  finished-goods stockpile #{p.get('id')} z{p.get('z')}: {p.get('free')}/{p.get('tiles')} tiles free, "
                   f"bins {p.get('bins')} (empty {p.get('bins_empty')}), max_bins {p.get('max_bins')}")
    if not plan["fg_piles"]:
        out.append("  no finished-goods stockpile: build one first (bins alone do not help)")
    if plan["open_orders"]:
        out.append("  open ConstructBin order(s): " + ", ".join(f"#{o.get('id')} {o.get('left')} left"
                                                               for o in plan["open_orders"]) + " - no second order")
    elif plan["need"] and not plan["wood_ok"]:
        out.append(f"  wood gate: {plan['wood']} logs < {plan['need']} bins + reserve {plan['reserve']} - cut wood first")
    return out


# ------------------------------------------------------------------ garbage bridge
def bridge_lines(report: dict | None, cfg: dict) -> tuple[list[str], dict]:
    """Lines for the garbage bridges and {bridge id: state key} ('full' when the landing holds > landing_warn)."""
    out, states = [], {}
    limit = int(cfg.get("landing_warn", 300))
    for b in _list((report or {}).get("bridges")):
        n = int(b.get("items") or 0)
        bt = b.get("by_type") if isinstance(b.get("by_type"), dict) else {}
        top = ", ".join(f"{t} {k}" for t, k in sorted(bt.items(), key=lambda kv: -kv[1])[:4])
        levers = ", ".join(f"#{lv}" for lv in _list(b.get("levers"))) or "none linked"
        line = (f"garbage bridge #{b.get('id')} z{b.get('z')} (dump zone #{b.get('zone')}): {b.get('state', '?')}, "
                f"{n} items on the landing" + (f" ({top})" if top else "") + f", lever {levers}")
        if n > limit:
            line = "!! " + line + f" - over {limit}: pull the lever (player action)"
            states[str(b.get("id"))] = "full"
        else:
            states[str(b.get("id"))] = "ok"
        out.append(line)
    return out, states


# ------------------------------------------------------------------ the flow table
def _rate(v) -> str:
    return "-" if v is None else f"{v:+.0f}"


def _state(r: FlowRow, free, cap: dict, cfg: dict, bridge_full: int, plan: dict | None) -> str:
    eps = float(cfg.get("flow_eps", 0.5))
    if r.inflow is not None:
        grow = r.inflow > (r.sink or 0) + eps
        shrink = (r.sink or 0) > r.inflow + eps
    elif r.net is not None:
        grow, shrink = r.net > eps, r.net < -eps
    else:
        grow = shrink = False
    if r.group == "BOULDER":
        return ("growing" if grow else "shrinking" if shrink else "flat (no inflow)") + ", never dump"
    if r.group == "CORPSE+PIECE":
        s = "GROWING" if grow else "shrinking" if shrink else "flat"
        return s + (f" (bridge not pulled: {bridge_full} on landing)" if bridge_full else "")
    bits = []
    if grow:
        bits.append("GROWING")
    elif shrink:
        bits.append("shrinking")
    if r.group == "CRAFTS" and cap:
        sale = int(cfg.get("sale_capacity", 800))
        top = max(cap.values())
        if sum(cap.values()) > sale:
            bits.append(f"cap {top} x {len(cap)} kinds above sale capacity {sale} -> lower cap")
        elif top * len(cap) > r.stock:
            bits.append(f"cap {top} > stock {r.stock}/{max(1, len(cap))}")
    if r.loose > 0 and free == 0:
        if r.group in FINISHED_GOODS or r.group == "CRAFTS":
            n = math.ceil(r.loose / max(1, int(cfg.get("bin_capacity", 100))))
            bits.append(f"stuck: needs {n} bin{'s' if n != 1 else ''}")
        else:
            bits.append("stuck: no free stockpile tile")
    if not bits:
        bits.append("ok" if r.loose == 0 or free else "flat")
    return ", ".join(bits)


def flow_table(rows: dict, span_h, m, cap_space: dict, kinds: dict, cfg: dict, bridge_full: int = 0,
               plan: dict | None = None) -> list[str]:
    """~10 lines: one per relevant group, then the unreachable line."""
    head = f"FLOW {span_h:.0f}h" if span_h else "FLOW (no rate yet)"
    out = [f"{head:<11}{'type':<14}{'stock':>7}{'reach_loose':>12}{'inflow/h':>9}{'sink/h':>8}{'free_slots':>11}  state"]
    fixed = ["BOULDER", "CORPSE+PIECE", "GOBLET", "CRAFTS", "BLOCKS"]
    rest = sorted((g for g in rows if g not in fixed), key=lambda g: -rows[g].loose)
    want = [g for g in fixed if g in rows and (rows[g].stock or rows[g].loose)]
    want += [g for g in rest if rows[g].loose > 0][:max(0, int(cfg.get("flow_rows", 8)) - len(want))]
    for g in want:
        r = rows[g]
        name = f"CRAFTS({len(r.kinds)})" if g == "CRAFTS" else g
        cat = CATEGORY.get(g if g != "CRAFTS" else "CRAFTS")
        if g == "CORPSE+PIECE":
            cat = "refuse"
        free = cap_space.get(cat) if cat else None
        if g == "CORPSE+PIECE":
            fs = "dump zone"
        elif free is None:
            fs = "-"
        elif cat == "finished_goods" and free == 0 and not cap_space.get("_bins_fg"):
            fs = "0 (no bins)"
        else:
            fs = str(free)
        st = _state(r, free, kinds if g == "CRAFTS" else {}, cfg, bridge_full if g == "CORPSE+PIECE" else 0, plan)
        out.append(f"{'':<11}{name:<14}{r.stock:>7}{r.loose:>12}{_rate(r.inflow):>9}{_rate(r.sink):>8}{fs:>11}  {st}")
    un = m.unreach if isinstance(getattr(m, "unreach", None), dict) else {}
    n_un = int(un.get("cavern", 0)) + int(un.get("surface", 0))
    if n_un:
        out.append(f"{'':<11}{'unreachable':<14}{n_un:>7}{'-':>12}{'-':>9}{'-':>8}{'-':>11}  ignored "
                   f"(cavern {un.get('cavern', 0)}, surface {un.get('surface', 0)}, webs {un.get('thread', 0)})")
    if span_h is None:
        out.append("rates need a second snapshot >= 15 min later (hygiene status/check record one per measurement)")
    return out


# ------------------------------------------------------------------ wake on state change
def transition(store, key: str, state: str, text: str, now: float, *, alarm: set, dry: bool = False) -> list[str]:
    """Remember the state of `key`; on a change INTO an alarm state return one wake line and queue a crit warning
    (wake picks those up once). An unchanged state never repeats; a dry run reads but never writes."""
    kv = f"hygiene.state.{key}"
    prev = store.get(kv)
    if prev == state:
        return []
    if not dry:
        store.set(kv, state)
    if state not in alarm:
        return []
    if not dry:
        store.warn(now, "hygiene", f"hygiene:{key}:{state}:{int(now)}", text[:200], "crit")   # new row = new wake
    return [f"WAKE hygiene: {text}"[:220]]
