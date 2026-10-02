"""Spec 07: bottleneck watcher for material and fuel (`python -m df_llm_helper bottleneck`).

Dependency graph data/graphs/produktion.yaml. For each goal the path to the sources is followed; the first empty
node that cannot be produced is the bottleneck. Output: bottleneck, what it blocks (chain up to the goal),
solution (trade/reserve). Read only + proposals; feeds the shopping list (kv 'trade.boost_bottleneck', read by
caravan.py) and reports the bottleneck duration in game days (escalation after escalate_days).
"""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

from . import yamlmini

__all__ = ["DEFAULTS", "Graph", "GraphError", "Blocker", "load_graph", "stock_value", "find_blockers", "report_line",
           "BottleneckWatch", "backtest_timeline", "source_value", "starter_budget"]

DEFAULTS = {"graph": "data/graphs/produktion.yaml", "wood_reserve": 12, "fuel_reserve": 2, "coal_reserve": 20,
            "escalate_days": 20}


TRADE_LABEL = {"wood": "wood", "fuel": "coke/coal", "metal": "metal", "tools": "tools"}


class GraphError(ValueError):
    pass


@dataclass
class Graph:
    nodes: dict
    goals: list
    sources: list = field(default_factory=list)

    def validate(self) -> list[str]:
        errs = []
        for nid, n in self.nodes.items():
            for k in ("needs", "any"):
                for d in n.get(k) or []:
                    if d not in self.nodes:
                        errs.append(f"{nid}.{k}: unknown node {d}")
            if n.get("base") and n["base"] not in self.nodes:
                errs.append(f"{nid}.base: unknown node {n['base']}")
        for g in self.goals:
            if g.get("id") not in self.nodes:
                errs.append(f"Goal {g.get('id')}: unknown node")
        state: dict = {}

        def visit(nid, stack):
            if state.get(nid) == 1:
                errs.append("Cycle: " + " -> ".join(stack + [nid]))
                return
            if state.get(nid) == 2 or nid not in self.nodes:
                return
            state[nid] = 1
            n = self.nodes[nid]
            for d in list(n.get("needs") or []) + list(n.get("any") or []):
                visit(d, stack + [nid])
            state[nid] = 2
        for nid in self.nodes:
            visit(nid, [])
        return errs


def load_graph(path: Path) -> Graph:
    d = yamlmini.load_file(path) or {}
    nodes = {}
    for n in d.get("nodes") or []:
        if "id" not in n:
            raise GraphError(f"{path}: node without id: {n}")
        if n["id"] in nodes:
            raise GraphError(f"{path}: duplicate node: {n['id']}")
        nodes[n["id"]] = n
    srcs = [s for s in (d.get("sources") or []) if isinstance(s, dict)]
    for s in srcs:
        if not s.get("key") or not s.get("cmd") or not s.get("path"):
            raise GraphError(f"{path}: source needs key, cmd and path: {s}")
    g = Graph(nodes, list(d.get("goals") or []), srcs)
    errs = g.validate()
    if errs:
        raise GraphError(f"{path}: " + "; ".join(errs))
    return g


def _get(stock: dict, path: str):
    cur = stock
    for part in path.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur if isinstance(cur, (int, float)) else None


def source_value(answer, src: dict):
    """Value of one extra stock source (graph 'sources') from the JSON answer of its command; None = unknown.
    A negative number (Lua 'could not count') is unknown; 'item' picks 'TYPE=N' out of a text field."""
    cur = answer
    for part in str(src["path"]).split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    if src.get("item"):
        if not isinstance(cur, str):
            return None
        for tok in cur.split():
            k, _, v = tok.partition("=")
            if k == src["item"]:
                try:
                    return float(v)
                except ValueError:
                    return None
        return None
    if isinstance(cur, bool) or not isinstance(cur, (int, float)) or cur < 0:
        return None
    return cur


def stock_value(stock: dict, expr: str | None, cfg: dict):
    """'wood', 'bars.IRON', 'a+b' (sum; missing parts = 0, all missing = None), 'wood_spare'."""
    if not expr:
        return None
    if expr == "wood_spare":
        w = _get(stock, "wood")
        return None if w is None else w - cfg["wood_reserve"]
    vals = [_get(stock, p.strip()) for p in str(expr).split("+")]
    if all(v is None for v in vals):
        # section present (e.g. 'ore': {}), key missing -> 0; section missing -> unknown
        parents = {p.strip().split(".")[0] for p in str(expr).split("+")}
        return 0 if all(isinstance(stock.get(pp), dict) for pp in parents) and all("." in p for p in str(expr).split("+")) else None
    return sum(v or 0 for v in vals)


@dataclass
class Blocker:
    node: str
    label: str
    value: float | None
    chain: list = field(default_factory=list)      # labels from the bottleneck up to the goal
    goal: str = ""
    trade: str | None = None
    short: float = 0.0          # stock minus threshold (negative = shortfall); chooses between alternatives


def find_blockers(g: Graph, stock: dict, cfg: dict | None = None) -> tuple[list[Blocker], list[str]]:
    """-> (bottlenecks per goal, unknown nodes)."""
    c = {**DEFAULTS, **(cfg or {})}
    unknown: set = set()

    def threshold(n) -> float:
        r = n.get("reserve")
        return float(c.get(r, 0)) if isinstance(r, str) else float(r or 0)

    def labels(path: list) -> list:
        return [g.nodes[p].get("label", p) for p in reversed(path) if g.nodes[p].get("show", True) is not False]

    def check(nid: str, path: list, need: float = 1) -> Blocker | None:
        n = g.nodes[nid]
        v = stock_value(stock, n.get("stock"), c)
        thr = max(threshold(n), need - 1) if n.get("reserve") is None else threshold(n) + need - 1
        if v is not None and v > thr:
            return None
        if n.get("any"):
            alts = []
            for alt in n["any"]:
                b = check(alt, path + [nid])
                if b is None:
                    return None
                alts.append(b)
            # really empty before 'below reserve' (wood 0 before coal 3 < 20), then largest shortfall, then graph order
            return min(alts, key=lambda b: ((b.value or 0) > 0, b.short))
        if n.get("needs"):
            for d in n["needs"]:
                b = check(d, path + [nid])
                if b:
                    return b
            return None                                     # producible
        if v is None and not n.get("base"):
            unknown.add(nid)
            return None
        short = (v if v is not None else 0) - thr

        def mk(*a, **k) -> Blocker:
            b = Blocker(*a, **k)
            b.short = short
            return b
        base = n.get("base")
        if base and (stock_value(stock, g.nodes[base].get("stock"), c) or 0) <= 0:
            bn = g.nodes[base]
            return mk(base, bn.get("label", base), stock_value(stock, bn.get("stock"), c),
                           labels(path + [nid]), trade=bn.get("trade"))
        grp = n.get("group")
        if grp:
            gn = g.nodes[grp]
            return mk(grp, gn.get("label", grp), v, labels(path + [nid]), trade=n.get("trade") or gn.get("trade"))
        if base:                                           # e.g. wood > 0 but below the reserve: show the real stock
            return mk(nid, n.get("label", nid), stock_value(stock, g.nodes[base].get("stock"), c), labels(path),
                           trade=g.nodes[base].get("trade"))
        return mk(nid, n.get("label", nid), v, labels(path), trade=n.get("trade"))

    out = []
    for goal in g.goals:
        tgt = float(goal.get("target") or 1)
        b = check(goal["id"], [], tgt)
        if b:
            b.goal = goal.get("label", goal["id"])
            if b.chain and tgt > 1:
                b.chain[-1] = f"{tgt:g} {b.chain[-1]}"
            out.append(b)
    return out, sorted(unknown)


def _fmt(v) -> str:
    return "?" if v is None else f"{v:g}"


def report_line(blockers: list[Blocker], stock: dict, cfg: dict | None = None) -> str:
    """One line <= 160 chars: largest bottleneck + what it blocks + solution."""
    c = {**DEFAULTS, **(cfg or {})}
    if not blockers:
        return "No bottleneck in the production chains"
    by: dict = {}
    for b in blockers:
        by.setdefault(b.node, []).append(b)
    node, bs = max(by.items(), key=lambda kv: (len(kv[1]), -list(by).index(kv[0])))
    b0 = bs[0]
    chain = " → ".join(dict.fromkeys(b0.chain))
    also = list(dict.fromkeys(b.goal for b in bs[1:]))
    tl = TRADE_LABEL.get(b0.trade or "", b0.label)
    fix = []
    if b0.trade:
        fix.append(f"Caravan {tl}" + (f" ≥ {2 * c['wood_reserve'] - 4:g}" if b0.trade == "wood" else ""))
    if node == "wood":
        fix.append(f"do not burn reserve {c['wood_reserve']}")
    head = f"Bottleneck: {b0.label} ({_fmt(b0.value)}). Blocks: {chain}"
    tail = (". Solution: " + ", ".join(fix)) if fix else ""
    for n in range(len(also), -1, -1):                     # shorten 'also ...', the solution stays
        mid = ("; also " + ", ".join(also[:n]) + (f" +{len(also) - n}" if n < len(also) else "")) if also and n else (
            f"; +{len(also)} goals" if also else "")
        line = head + mid + tail
        if len(line) <= 160:
            return line
    return (head + tail)[:157] + "..."


def starter_budget(stock: dict, cfg: dict | None = None) -> str | None:
    """Maintenance rule for the wood reserve: how much wood the charcoal starter may burn (acceptance 2)."""
    c = {**DEFAULTS, **(cfg or {})}
    wood, coke = _get(stock, "wood"), _get(stock, "coke")
    if wood is None or coke is None or coke >= c["fuel_reserve"]:
        return None
    spare = max(0, int(wood - c["wood_reserve"]))
    if spare <= 0:
        return f"Starter blocked: wood {wood:g} ≤ reserve {c['wood_reserve']} (moods)"
    return f"Starter: burn at most {spare} wood (wood {wood:g}, reserve {c['wood_reserve']}), coke {coke:g}"


class BottleneckWatch:
    def __init__(self, client, store, clock, cfg: dict, home: Path):
        self.client, self.store, self.clock = client, store, clock
        self.cfg = {**DEFAULTS, **(cfg or {})}
        self.graph = load_graph(home / self.cfg["graph"])

    def stock(self) -> dict | None:
        r = self.client.run("claude/material status")
        j = r.json if r.ok and isinstance(r.json, dict) else None
        st = j.get("stock") if j and isinstance(j.get("stock"), dict) else None
        if st is not None:
            st = self.add_sources(dict(st))
        return st

    def add_sources(self, stock: dict) -> dict:
        """BUG-220: keys claude/material status does not report (mechanism, blocks) from the graph's read-only
        'sources' (claude/pilot_defense status, claude/muell status); one call per command, only for missing keys."""
        answers: dict = {}
        for src in self.graph.sources:
            if src["key"] in stock:
                continue
            cmd = src["cmd"]
            if cmd not in answers:
                r = self.client.run(cmd)
                answers[cmd] = r.json if r.ok and isinstance(r.json, dict) else None
            v = source_value(answers[cmd], src) if answers[cmd] is not None else None
            if v is not None:
                stock[src["key"]] = v
        return stock

    def run(self, stock: dict | None = None, game_day: float | None = None, *, dry: bool = False) -> list[str]:
        stock = stock if stock is not None else self.stock()
        if stock is None:
            return ["Bottleneck: claude/material status not readable"]
        blockers, unknown = find_blockers(self.graph, stock, self.cfg)
        out = [report_line(blockers, stock, self.cfg)]
        sb = starter_budget(stock, self.cfg)
        if sb:
            out.append(sb)
        if self.store.get("mood.block_charcoal") and _get(stock, "wood") is not None:
            out.append("Mood needs wood: charcoal starter stays off (spec 03)")
        trade = list(dict.fromkeys(b.trade for b in blockers if b.trade))
        since = dict(self.store.get("bottleneck.since") or {})
        now_nodes = {b.node for b in blockers}
        if game_day is not None:
            for n in now_nodes:
                since.setdefault(n, game_day)
            for n in list(since):
                if n not in now_nodes:
                    since.pop(n)
            for n, d0 in since.items():
                days = game_day - d0
                if days >= self.cfg["escalate_days"]:
                    lab = self.graph.nodes[n].get("label", n)
                    msg = f"Bottleneck {lab} for {days:.0f} game days: escalate (prioritize trade/exploration)"
                    out.append(msg)
                    if not dry:
                        self.store.warn(self.clock.now().epoch, "bottleneck", f"bottleneck:esc:{n}", msg, "crit")
        if unknown:
            out.append("no stock data: " + ", ".join(unknown)[:100])
        if not dry:
            self.store.set("bottleneck.since", since)
            self.store.set("bottleneck.line", out[0])                 # dashboard (spec 11)
            self.store.set("bottleneck.stock", {k: v for k, v in stock.items() if k in ("wood", "coke", "coal", "bars")})
            if trade != (self.store.get("trade.boost_bottleneck") or []):
                self.store.set("trade.boost_bottleneck", trade)
                self.store.log_action(self.clock.now().epoch, "bottleneck", "bottleneck", "trade-boost", "trade",
                                      "kv trade.boost_bottleneck = " + ",".join(trade), False, True, out[0][:120])
            if blockers:
                self.store.warn(self.clock.now().epoch, "bottleneck", "bottleneck:main", out[0], "warn")
        return out[:6]


def backtest_timeline(entries: list[dict], g: Graph, cfg: dict | None = None) -> dict:
    """entries: [{time: 'HH:MM', stock: {...}, manual: bool}] (timeline from chronicle/scope files).
    -> first report of the watcher vs. first manual diagnosis (minutes of lead)."""
    def mins(t: str) -> int:
        h, m = t.split(":")
        return int(h) * 60 + int(m)
    first = next((e for e in entries if find_blockers(g, e.get("stock") or {}, cfg)[0]), None)
    manual = next((e for e in entries if e.get("manual")), None)
    lead = mins(manual["time"]) - mins(first["time"]) if first and manual else None
    return {"first_detect": first and first["time"], "manual": manual and manual["time"], "lead_min": lead,
            "line": report_line(find_blockers(g, first["stock"], cfg)[0], first["stock"], cfg) if first else None}
