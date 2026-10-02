"""Cancel loops in the gamelog + robust trend statistics (F14).

cancel_loops(): counts 'X cancels <job>: <reason>' by (job, reason). Run 5 example:
'Make unknown material bed: Needs logs' 314x in the excerpt (5600x over the whole run).
"""
from __future__ import annotations

import math
import re
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

__all__ = ["CancelLoop", "cancel_loops", "GamelogReader", "ewma", "mad", "Detector", "Anomaly", "detect_series"]

_CANCEL = re.compile(r"^(?P<who>.+?) cancels (?P<job>[^:]+): (?P<reason>.+?)\.?\s*$")


@dataclass(frozen=True)
class CancelLoop:
    job: str
    reason: str
    count: int
    who: int          # number of distinct dwarves

    @property
    def key(self) -> str:
        return f"{self.job}: {self.reason}"


def _norm_job(job: str) -> str:
    # merge material variants: 'Make unknown material bed' / 'Make rock bed' -> 'Make bed'
    j = re.sub(r"\b(unknown material|rock|wooden|metal|stone|bone|glass)\s+", "", job.strip())
    return re.sub(r"\s+", " ", j)


def cancel_loops(lines, min_count: int = 10, top: int | None = None) -> list[CancelLoop]:
    cnt: Counter = Counter()
    whos: dict = {}
    for ln in lines:
        m = _CANCEL.match(ln.strip())
        if not m:
            continue
        key = (_norm_job(m.group("job")), m.group("reason").strip().rstrip("."))
        cnt[key] += 1
        whos.setdefault(key, set()).add(m.group("who"))
    out = [CancelLoop(j, r, n, len(whos[(j, r)])) for (j, r), n in cnt.items() if n >= min_count]
    out.sort(key=lambda c: (-c.count, c.job, c.reason))
    return out[:top] if top else out


def _decode(b: bytes) -> str:
    try:
        return b.decode("utf-8")
    except UnicodeDecodeError:
        return b.decode("cp437", errors="replace")


class GamelogReader:
    """Reads new lines from the stored offset (store KV); detects truncation/re-creation."""

    def __init__(self, path: str | Path | None, store, key: str = "gamelog.offset", window: int = 5000):
        self.path = Path(path) if path else None
        self.store = store
        self.key = key
        self.window = window

    def new_lines(self, max_bytes: int = 2_000_000) -> list[str]:
        if not self.path or not self.path.exists():
            return []
        size = self.path.stat().st_size
        off = int(self.store.get(self.key, 0) or 0)
        if off > size:          # file new/truncated
            off = 0
        if size - off > max_bytes:
            off = size - max_bytes
        with self.path.open("rb") as f:
            f.seek(off)
            data = f.read()
        self.store.set(self.key, size)
        lines = _decode(data).splitlines()
        buf = list(self.store.get(self.key + ".recent", []) or []) + lines
        self.store.set(self.key + ".recent", buf[-self.window:])
        return lines

    def recent(self) -> list[str]:
        return list(self.store.get(self.key + ".recent", []) or [])


# ---------------------------------------------------------------- robust statistics

def ewma(values, alpha: float = 0.3) -> list[float]:
    out, s = [], None
    for v in values:
        s = v if s is None else alpha * v + (1 - alpha) * s
        out.append(s)
    return out


def mad(values) -> tuple[float, float]:
    """(median, MAD*1.4826) - robust against outliers."""
    xs = sorted(values)
    if not xs:
        return 0.0, 0.0
    n = len(xs)
    med = xs[n // 2] if n % 2 else (xs[n // 2 - 1] + xs[n // 2]) / 2
    dev = sorted(abs(x - med) for x in xs)
    m = dev[n // 2] if n % 2 else (dev[n // 2 - 1] + dev[n // 2]) / 2
    return med, m * 1.4826


@dataclass
class Anomaly:
    series: str
    index: int
    value: float
    kind: str        # 'fall' | 'rise' | 'spike'
    score: float
    hint: str = ""


class Detector:
    """Anomaly when a value deviates > k robust standard deviations from the window's moving median
    and the direction fits the series (e.g. drinks 'fall', idle 'rise')."""

    def __init__(self, window: int = 20, k: float = 6.0, min_abs: float = 0.0):
        self.window, self.k, self.min_abs = window, k, min_abs

    def scan(self, name: str, values: list[float], direction: str = "both") -> list[Anomaly]:
        out = []
        for i in range(self.window, len(values)):
            hist = values[i - self.window:i]
            med, sd = mad(hist)
            sd = max(sd, 1.0, 0.05 * abs(med))      # lower bound: do not over-react on constant series
            d = values[i] - med
            if abs(d) < self.min_abs:
                continue
            z = d / sd
            kind = "rise" if z > 0 else "fall"
            if direction != "both" and kind != direction:
                continue
            if abs(z) >= self.k and not math.isinf(z):
                out.append(Anomaly(name, i, values[i], kind, round(abs(z), 1)))
        return out


def detect_series(name: str, values: list[float], direction: str = "both", **kw) -> list[Anomaly]:
    return Detector(**kw).scan(name, values, direction)


# ---------------------------------------------------------------- time series from the store -> digest hints

SERIES = {
    # metric -> (direction, KB search query for the cause hint, minimum deviation)
    "drink_days": ("fall", "drinks thirst brew plants", 10.0),
    "food_days": ("fall", "food hunger meals", 15.0),
    "idle_pct": ("rise", "idle dig backlog tool", 15.0),
    "dig_jobs": ("rise", "dig jobs pick pickaxe", 30.0),
}


def series_anomalies(history: list[dict], *, window: int = 12, k: float = 5.0, hint=None) -> list[Anomaly]:
    """history: list of facts dicts (oldest first). Checks only the newest point."""
    out = []
    for name, (direction, query, min_abs) in SERIES.items():
        vals = [h.get(name) for h in history if isinstance(h.get(name), (int, float))]
        if len(vals) < window + 1:
            continue
        found = Detector(window=window, k=k, min_abs=min_abs).scan(name, vals[-(window + 1):], direction)
        for a in found:
            a.hint = hint(query) if hint else ""
            out.append(a)
    return out


def cancel_anomalies(loops: list[CancelLoop], hint=None) -> list[Anomaly]:
    return [Anomaly(f"cancel:{c.job}", 0, float(c.count), "spike", float(c.count),
                    hint(f"{c.job} {c.reason}") if hint else "") for c in loops]
