"""Spec 05: famine forecast (`dfpilot forecast`).

Time series (game day, population, total food, drinks) in kv 'forecast.series' (<= max_points points, ~2 KB).
Model per resource over the last `window` intervals:
  consumption/head/day = median of the FALLING intervals (-delta/dt/pop) -> harvest/cooking jumps never count as
                         negative consumption; band = min/max of these values.
  production/day       = sum of the rises / total duration of the window.
  net/day              = production - consumption/head * population NOW (growth shortens the forecast immediately).
  days                 = stock / -net (None = no shortage).
Self-calibration: predicted stock for the next point vs. the real one -> error log, confidence.
Read only (fair play).
"""
from __future__ import annotations

import statistics
from dataclasses import dataclass

from .clock import TICKS_PER_DAY, GameDate

__all__ = ["DEFAULTS", "Estimate", "point_from_snapshot", "estimate", "fmt_line", "Forecaster", "backtest",
           "series_from_metrics"]

DEFAULTS = {"warn_days": 30, "crit_days": 10, "window": 5, "include_raw_plants": True, "max_points": 50,
            "min_dt_days": 0.25}
RES = ("food", "drink")
LABEL = {"food": "Food", "drink": "Drink"}


@dataclass
class Estimate:
    res: str
    stock: float
    days: float | None
    lo: float | None
    hi: float | None
    net: float
    per_head: float | None
    production: float
    samples: int

    @property
    def spread(self) -> float | None:
        if self.lo is None or self.hi is None:
            return None
        return (self.hi - self.lo) / 2


def point_from_snapshot(snap, include_raw: bool = True) -> list | None:
    """Snapshot -> [day, pop, food, drink] or None (date/population missing)."""
    if not snap.date or not snap.pop_total:
        return None
    st = snap.stocks
    parts = [st.meals, st.fish, st.meat] + ([st.plants] if include_raw else [])
    food = None if all(p is None for p in parts) else float(sum(p or 0 for p in parts))
    drink = None if st.drink is None else float(st.drink)
    return [round(snap.date.abs_ticks / TICKS_PER_DAY, 3), int(snap.pop_total), food, drink]


def _idx(res: str) -> int:
    return 2 if res == "food" else 3


def estimate(series: list, res: str, window: int = 5, min_dt: float = 0.25) -> Estimate | None:
    pts = [p for p in series if p[_idx(res)] is not None]
    if len(pts) < 2:
        return None
    # intervals; merge too short ones (same day)
    iv = []
    a = pts[0]
    for b in pts[1:]:
        dt = b[0] - a[0]
        if dt < min_dt:
            continue
        iv.append((dt, b[_idx(res)] - a[_idx(res)], max(1, (a[1] + b[1]) / 2)))
        a = b
    if not iv:
        return None
    rates_head = [-d / dt / pop for dt, d, pop in iv if d < 0][-window:]
    win = iv[-max(window, 1) * 2:]                        # smooth production over a somewhat longer window
    total_dt = sum(dt for dt, _, _ in win)
    production = sum(d for _, d, _ in win if d > 0) / total_dt if total_dt else 0.0
    stock = float(pts[-1][_idx(res)])
    pop = float(pts[-1][1])
    if not rates_head:
        return Estimate(res, stock, None, None, None, production, None, production, len(iv))
    ph = statistics.median(rates_head)

    def days_for(rate: float) -> float | None:
        net = production - rate * pop
        return None if net >= 0 else stock / -net

    net = production - ph * pop
    lo = days_for(max(rates_head))
    hi = days_for(min(rates_head))
    return Estimate(res, stock, days_for(ph), lo, hi, net, ph, production, len(rates_head))


def _num(x: float) -> str:
    return f"{x:+.1f}"


def fmt_line(ests: dict) -> str:
    parts = []
    for res in RES:
        e = ests.get(res)
        if e is None:
            parts.append(f"{LABEL[res]} ?")
            continue
        if e.days is None:
            parts.append(f"{LABEL[res]} stable ({_num(e.net)}/day)")
            continue
        band = ""
        if e.spread is not None and e.lo is not None and e.hi is not None:
            band = f"±{e.spread:.0f}" if e.spread >= 0.5 else ""
        elif e.lo is not None and e.hi is None:
            band = f" (min {e.lo:.0f})"
        parts.append(f"{LABEL[res]} {e.days:.0f}{band} days ({_num(e.net)}/day)")
    return ("Forecast: " + ", ".join(parts))[:120]


def level(e: Estimate | None, cfg: dict) -> str:
    if e is None or e.days is None:
        return "ok"
    if e.days < cfg["crit_days"]:
        return "crit"
    if e.days < cfg["warn_days"]:
        return "warn"
    return "ok"


MEASURES = {"food": ["Trade: raise food/seeds priority (data/trade/wants.yaml)", "Farms: check more plots/harvest cycle",
                     "Population stop STRICT_POPULATION_CAP (only takes effect after a restart)",
                     "Emergency brake: dfpilot tempo off (play slower)"],
            "drink": ["Check brewery/barrels (spec 04/drinking)", "Trade: buy drinks/plants",
                      "Emergency brake: dfpilot tempo off"]}


class Forecaster:
    def __init__(self, store, clock, cfg: dict):
        self.store, self.clock = store, clock
        self.cfg = {**DEFAULTS, **(cfg or {})}

    def series(self) -> list:
        return list(self.store.get("forecast.series") or [])

    def add_point(self, pt: list) -> None:
        s = self.series()
        if s and s[-1][0] > pt[0] + 1:                    # time going backwards = new game/loaded -> start over
            s = []
        self._calibrate(s, pt)
        if s and abs(pt[0] - s[-1][0]) < 1e-6:
            s[-1] = pt
        else:
            s.append(pt)
        self.store.set("forecast.series", s[-int(self.cfg["max_points"]):])

    def _calibrate(self, s: list, pt: list) -> None:
        pred = self.store.get("forecast.pred") or {}
        if not pred or not s or pt[0] - s[-1][0] < self.cfg["min_dt_days"]:
            return
        errs = list(self.store.get("forecast.errors") or [])
        for res in RES:
            p = pred.get(res)
            actual = pt[_idx(res)]
            if p is None or actual is None:
                continue
            exp = p["stock"] + p["net"] * (pt[0] - p["day"])
            errs.append(round(abs(exp - actual) / max(abs(actual), abs(exp), 1.0), 3))
        self.store.set("forecast.errors", errs[-20:])

    def confidence(self) -> float:
        errs = self.store.get("forecast.errors") or []
        if not errs:
            return 1.0
        return round(max(0.0, 1.0 - statistics.mean(errs[-10:])), 2)

    def estimates(self) -> dict:
        s = self.series()
        return {res: estimate(s, res, int(self.cfg["window"]), float(self.cfg["min_dt_days"])) for res in RES}

    def update(self, snap, *, record: bool = True) -> tuple[str, list[str]]:
        """Record a point, compute the forecast. -> (line <= 120 chars, new warnings only on crossing a threshold)."""
        pt = point_from_snapshot(snap, self.cfg["include_raw_plants"])
        if pt and record:
            self.add_point(pt)
        ests = self.estimates()
        if record and pt:
            self.store.set("forecast.pred", {r: {"day": pt[0], "stock": e.stock, "net": e.net}
                                             for r, e in ests.items() if e is not None})
        line = fmt_line(ests)
        conf = self.confidence()
        if conf < 0.7 and len(line) < 100:
            line = (line + f" [confidence {conf:.1f}]")[:120]
        news = []
        prev = dict(self.store.get("forecast.level") or {})
        for res, e in ests.items():
            lv = level(e, self.cfg)
            rank = {"ok": 0, "warn": 1, "crit": 2}
            if rank[lv] > rank.get(prev.get(res, "ok"), 0):
                news.append(f"{'!!' if lv == 'crit' else '!'} {LABEL[res]} lasts only ~{e.days:.0f} days: "
                            + "; ".join(MEASURES[res][:2]))
                if record:
                    self.store.warn(self.clock.now().epoch, "forecast", f"forecast:{res}", news[-1], lv)
            prev[res] = lv
        if record:
            self.store.set("forecast.level", prev)
        return line, news


def series_from_metrics(path, include_raw: bool = True) -> list:
    """metrics.csv (run 5, ';'-separated) -> time series. Food = mahlzeiten (+ pflanzen)."""
    import csv
    out = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for row in csv.DictReader(f, delimiter=";"):
            d = GameDate.parse_text(row.get("spieldatum", ""))
            try:
                pop = int(row["buerger"])
                food = float(row["mahlzeiten"]) + (float(row["pflanzen"]) if include_raw else 0.0)
                drink = float(row["getraenke"])
            except (KeyError, TypeError, ValueError):
                continue
            if d is None or pop <= 0:
                continue
            out.append([d.abs_ticks / TICKS_PER_DAY, pop, food, drink])
    return out


def backtest(series: list, res: str = "food", window: int = 5, horizon_days: float = 10.0) -> dict:
    """For each point: forecast from the past only, predict the stock in ~horizon_days, compare with the real value.
    Error relative to the stock (|pred-real| / max(real, pred, 1)), stock never below 0."""
    errs = []
    for i in range(window + 1, len(series) - 1):
        hist = series[:i + 1]
        e = estimate(hist, res, window)
        if e is None:
            continue
        t0 = series[i][0]
        j = next((k for k in range(i + 1, len(series)) if series[k][0] - t0 >= horizon_days), None)
        if j is None:
            break
        real = series[j][_idx(res)]
        pred = max(0.0, e.stock + e.net * (series[j][0] - t0))
        errs.append(abs(pred - real) / max(real, pred, 1.0))
    return {"n": len(errs), "mean_err": round(statistics.mean(errs), 3) if errs else None,
            "median_err": round(statistics.median(errs), 3) if errs else None}
