"""Spec v3-03: freeze profiler (`dfpilot perf sample|bisect|status`).

Run 5 (Y109): claude/raster (reapply + erzdig ALL every 1500 ticks) froze the game ~11 s every ~25 s, claude/kohle
needed 9.4 s per run, claude/bauprog 3.5 s; the diagnosis by hand (latency probe + switching repeat-util jobs off one
by one) took 15 turns and about 1.5 h of real time went by unnoticed.

1 latency probe  `perf sample --n 40 --gap 0.6`: a tiny command (frame counter) at intervals; outliers (> outlier_ms),
                 maximum, period in seconds (median distance of the freeze ends) and in ticks (frame counter).
2 auto watcher   the watcher (dfpilot/waechter.py) feeds the latency of its light queries into LatencyMonitor;
                 >= min_outliers outliers in window_s AND an outlier rate > warn_rate_pct -> perf.flag + digest line
                 (`dfpilot check`, via check_hook) 'Game hangs: 2.0 outliers/min (max 10.5 s, period 25 s)'.
3 bisect         `perf bisect`: baseline sample; only with outliers: binary search over the repeat-util services
                 (switch half off, measure, switch back on). The hypothesis "no listed service" is part of the search,
                 so 20 services need at most 1 + 5 measurements. Protected services (watchdog, milguard,
                 watchdog-alert) are switched off only in peace and never longer than bisect_pause_s.
                 Crash safety: before switching anything off the state file tools/out/perf_bisect.json lists the
                 services with their start command and deadline; `finally` restarts them; any later perf/check call
                 and the watcher (every tick, overdue entries) restart whatever is still listed.
4/5 heuristics   suggestion with a line reference into lua/claude/<name>.lua (scheduleEvery/reapply/erzdig);
                 never patches Lua files (KB entry perf_hanger).
Fair play: only reads and switches services off/on (repeat-util.cancel / claude/<name> start).
Lua one-liners here are LIVE-UNTESTED (repeat-util `scheduled` table).
"""
from __future__ import annotations

import json
import re
import statistics
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path

__all__ = ["KEY", "DEFAULTS", "PROBE_CMD", "LIST_CMD", "cancel_cmd", "Sample", "SampleResult", "sample",
           "LatencyMonitor", "digest_line", "BisectResult", "Bisect", "recover", "state_path", "suggest",
           "parse_list", "register", "check_hook", "EXTERNAL"]

KEY = "perf"
DEFAULTS = {
    "outlier_ms": 1500, "warn_rate_pct": 5, "min_outliers": 5, "window_s": 300,
    "bisect_pause_s": 40, "protected": ["claude-watchdog", "claude-watchdog-alert", "claude-milguard"],
    "sample_n": 40, "sample_gap_s": 0.6, "max_off_s": 600, "flag_repeat_min": 30, "max_bisect_per_hour": 2,
    "in_check": True,
}
RULE = "perf"
EXTERNAL = "<no listed service>"
PROBE_CMD = 'lua "print(df.global.world.frame_counter)"'
LIST_CMD = ('lua "local r=require(\'repeat-util\') local t={} for k in pairs(r.scheduled or {}) do t[#t+1]=k end '
            "table.sort(t) print('S '..table.concat(t,' '))\"")
_KEY_RE = re.compile(r"^[A-Za-z0-9_-]+$")


def _cfg(cfg: dict | None) -> dict:
    return {**DEFAULTS, **(cfg or {})}


def cancel_cmd(key: str) -> str:
    if not _KEY_RE.match(key):
        raise ValueError(f"invalid service key: {key!r}")
    return f'lua "require(\'repeat-util\').cancel(\'{key}\')"'


def parse_list(out: str) -> list[str]:
    for ln in (out or "").splitlines():
        if ln.startswith("S"):
            return [k for k in ln[1:].split() if _KEY_RE.match(k)]
    return []


# ---------------------------------------------------------------- latency probe
@dataclass
class Sample:
    t: float            # start (real time, epoch s)
    latency_s: float
    fc: int | None
    ok: bool = True

    @property
    def end(self) -> float:
        return self.t + self.latency_s


def _period(ends: list[float], merge_s: float) -> float | None:
    """Median distance between freeze ends (outliers closer than merge_s count as one freeze)."""
    pts: list[float] = []
    for e in sorted(ends):
        if not pts or e - pts[-1] > merge_s:
            pts.append(e)
    diffs = [b - a for a, b in zip(pts, pts[1:])]
    return statistics.median(diffs) if diffs else None


@dataclass
class SampleResult:
    samples: list = field(default_factory=list)
    outlier_s: float = 1.5

    @property
    def outliers(self) -> list[Sample]:
        return [s for s in self.samples if s.latency_s >= self.outlier_s]

    @property
    def max_s(self) -> float:
        return max((s.latency_s for s in self.samples), default=0.0)

    @property
    def duration_s(self) -> float:
        return (self.samples[-1].end - self.samples[0].t) if self.samples else 0.0

    @property
    def period_s(self) -> float | None:
        return _period([s.end for s in self.outliers], self.outlier_s)

    @property
    def tick_rate(self) -> float | None:
        pts = [(s.end, s.fc) for s in self.samples if s.fc is not None]
        if len(pts) < 2 or pts[-1][0] <= pts[0][0]:
            return None
        return (pts[-1][1] - pts[0][1]) / (pts[-1][0] - pts[0][0])

    @property
    def period_ticks(self) -> int | None:
        fcs: list[int] = []
        last_end = None
        for s in self.outliers:
            if s.fc is None:
                continue
            if last_end is None or s.end - last_end > self.outlier_s:
                fcs.append(s.fc)
            last_end = s.end
        diffs = [b - a for a, b in zip(fcs, fcs[1:])]
        return int(statistics.median(diffs)) if diffs else None

    @property
    def hang(self) -> bool:
        return bool(self.outliers)

    def line(self) -> str:
        n = len(self.outliers)
        s = f"Sample {len(self.samples)} in {self.duration_s:.0f} s: {n} outlier{'s' if n != 1 else ''} " \
            f"> {self.outlier_s:.1f} s, max {self.max_s:.1f} s"
        if self.period_s:
            s += f", period {self.period_s:.0f} s"
            if self.period_ticks:
                s += f" (~{self.period_ticks} ticks)"
        if self.tick_rate:
            s += f", {self.tick_rate:.0f} ticks/s"
        return s

    def to_dict(self) -> dict:
        return {"n": len(self.samples), "outliers": len(self.outliers), "max_s": round(self.max_s, 2),
                "period_s": round(self.period_s, 1) if self.period_s else None, "period_ticks": self.period_ticks,
                "tick_rate": round(self.tick_rate, 1) if self.tick_rate else None}


def sample(client, clock, *, n: int = 40, gap: float = 0.6, outlier_s: float = 1.5, duration_s: float | None = None,
           deadline: float | None = None, timeout: float = 30.0, on_sample=None) -> SampleResult:
    """Probe the game n times (or for duration_s seconds), gap seconds apart; stop at deadline (epoch)."""
    res = SampleResult(outlier_s=outlier_s)
    start = clock.now().epoch
    i = 0
    while True:
        now = clock.now().epoch
        if deadline is not None and now >= deadline:
            break
        if duration_s is not None:
            if now - start >= duration_s:
                break
        elif i >= n:
            break
        t0 = now
        if deadline is not None:
            timeout = max(1.0, min(timeout, deadline - now + outlier_s))
        r = client.run(PROBE_CMD, timeout=timeout)
        delta = clock.now().epoch - t0
        lat = max(float(r.elapsed_s or 0.0), delta)
        if lat - delta > 0.05:          # replayed latency on a fake clock: let time pass accordingly
            clock.sleep(lat - delta)
        lines = (r.stdout or "").strip().splitlines()
        fc = int(lines[-1]) if r.ok and lines and lines[-1].strip().isdigit() else None
        res.samples.append(Sample(t0, lat, fc, r.ok))
        if on_sample:
            on_sample()
        i += 1
        clock.sleep(gap)
    return res


# ---------------------------------------------------------------- watcher auto detection
class LatencyMonitor:
    """Sliding window of the watcher's query latencies (spec 03 item 2)."""

    def __init__(self, cfg: dict | None = None):
        c = _cfg(cfg)
        self.window_s = float(c["window_s"])
        self.outlier_s = float(c["outlier_ms"]) / 1000.0
        self.min_outliers = int(c["min_outliers"])
        self.rate_pct = float(c["warn_rate_pct"])
        self.samples: deque = deque()

    def add(self, ts: float, latency_s: float) -> None:
        self.samples.append((ts, latency_s))
        while self.samples and self.samples[0][0] < ts - self.window_s:
            self.samples.popleft()

    def stats(self, now: float) -> dict:
        win = [(t, l) for t, l in self.samples if t >= now - self.window_s]
        outs = [(t, l) for t, l in win if l >= self.outlier_s]
        span_min = max(1.0, min(self.window_s, now - win[0][0]) if win else self.window_s) / 60.0
        return {"n": len(win), "outliers": len(outs), "max_s": round(max((l for _, l in outs), default=0.0), 1),
                "rate_pct": round(100.0 * len(outs) / len(win), 1) if win else 0.0,
                "per_min": round(len(outs) / span_min, 1),
                "period_s": _period([t + l for t, l in outs], self.outlier_s)}

    def should_flag(self, now: float) -> bool:
        st = self.stats(now)
        return st["outliers"] >= self.min_outliers and st["rate_pct"] > self.rate_pct


def digest_line(st: dict) -> str:
    p = f", period {st['period_s']:.0f} s" if st.get("period_s") else ""
    s = f"Game hangs: {st.get('per_min', 0):.1f} outliers/min (max {st.get('max_s', 0):.1f} s{p}) -> dfpilot perf bisect"
    return s[:120]


# ---------------------------------------------------------------- crash-safe service switching
def state_path(tools) -> Path:
    return Path(tools.path) / "out" / "perf_bisect.json"


def _load_state(tools) -> dict:
    p = state_path(tools)
    try:
        return json.loads(p.read_text(encoding="utf-8")) if p.exists() else {}
    except (OSError, ValueError):
        return {"off": [], "corrupt": True}


def _save_state(tools, st: dict) -> None:
    p = state_path(tools)
    if not st.get("off"):
        try:
            p.unlink()
        except FileNotFoundError:
            pass
        return
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(".tmp")
    tmp.write_text(json.dumps(st, ensure_ascii=False), encoding="utf-8")
    tmp.replace(p)


def recover(client, tools, store, clock, *, overdue_only: bool = False, stale_s: float = 30.0) -> list[str]:
    """Restart services still listed in the state file (crash during a bisect).
    overdue_only (watcher): only entries past their deadline. Otherwise also everything when the bisect
    heartbeat is older than stale_s (the bisect process is gone)."""
    st = _load_state(tools)
    if not st.get("off"):
        return []
    now = clock.now().epoch
    stale = now - float(st.get("heartbeat") or 0) > stale_s
    keep, out = [], []
    for e in st["off"]:
        due = now >= float(e.get("deadline") or 0)
        if not (due or (stale and not overdue_only)):
            keep.append(e)
            continue
        cmd = e.get("start")
        ok = False
        if cmd:
            try:
                ok = client.run(cmd).ok
            except Exception as ex:  # noqa: BLE001 - never raise from the recovery path
                out.append(f"restart {e['key']} failed: {type(ex).__name__}")
        store.log_action(now, "perf", RULE, "recover", e["key"], cmd or "", False, ok,
                         "overdue" if due else "bisect process gone")
        if ok:
            out.append(f"{e['key']} restarted from the state file ({'overdue' if due else 'bisect gone'})")
        else:
            keep.append(e)
    st["off"] = keep
    _save_state(tools, st)
    return out


@dataclass
class BisectResult:
    culprit: str | None = None
    latency_s: float = 0.0
    measurements: int = 0
    baseline: dict = field(default_factory=dict)
    untestable: list = field(default_factory=list)
    lines: list = field(default_factory=list)
    restored: bool = True
    suggestion: list = field(default_factory=list)


class Bisect:
    def __init__(self, client, tools, store, clock, cfg: dict | None, starts: dict[str, str], *,
                 lua_dir: Path | None = None):
        self.client, self.tools, self.store, self.clock = client, tools, store, clock
        self.cfg = _cfg(cfg)
        self.starts = starts                     # repeat-util key -> start command
        self.lua_dir = lua_dir
        self.measurements = 0

    # -- helpers
    def peace(self) -> bool:
        hold = self.tools.flag("pause.hold")
        return not (self.tools.flag("alert").exists or self.tools.flag("siege").exists or
                    (hold.exists and hold.text.startswith(("alarm", "gefahr"))))

    def _sample(self, *, deadline: float | None = None, duration: float | None = None) -> SampleResult:
        self.measurements += 1
        st = _load_state(self.tools)

        def beat():
            if st.get("off"):
                st["heartbeat"] = self.clock.now().epoch
                _save_state(self.tools, st)
        return sample(self.client, self.clock, n=int(self.cfg["sample_n"]), gap=float(self.cfg["sample_gap_s"]),
                      outlier_s=float(self.cfg["outlier_ms"]) / 1000.0, duration_s=duration, deadline=deadline,
                      on_sample=beat)

    def _measure_off(self, off: list[str], period: float | None, max_freeze: float = 0.0) -> SampleResult:
        now = self.clock.now().epoch
        prot = set(self.cfg["protected"])
        has_prot = any(k in prot for k in off)
        limit = float(self.cfg["bisect_pause_s"]) if has_prot else float(self.cfg["max_off_s"])
        st = {"heartbeat": now, "started": now,
              "off": [{"key": k, "start": self.starts[k], "since": now, "deadline": now + limit,
                       "protected": k in prot} for k in off]}
        _save_state(self.tools, st)              # BEFORE switching anything off (crash recovery)
        try:
            for k in off:
                r = self.client.run(cancel_cmd(k))
                self.store.log_action(now, "perf", RULE, "cancel", k, cancel_cmd(k), False, r.ok, "bisect")
            want = max(float(self.cfg["sample_n"]) * float(self.cfg["sample_gap_s"]), (period or 0) * 1.3 + 2)
            # leave time for one more freeze (a probe blocks until it ends) and the restart before the limit
            deadline = now + limit - 3.0 - (max_freeze if has_prot else 0.0)
            return self._sample(duration=want, deadline=deadline)
        finally:
            self._restart(off)

    def _restart(self, keys: list[str]) -> None:
        now = self.clock.now().epoch
        st = _load_state(self.tools)
        left = []
        for k in keys:
            ok = False
            try:
                ok = self.client.run(self.starts[k]).ok
            except Exception:  # noqa: BLE001 - keep it in the state file, recover() retries
                ok = False
            self.store.log_action(now, "perf", RULE, "restart", k, self.starts[k], False, ok, "bisect")
            if not ok:
                left.append(k)
        st["off"] = [e for e in st.get("off", []) if e["key"] in left]
        _save_state(self.tools, st)

    def list_services(self) -> list[str]:
        return parse_list(self.client.run(LIST_CMD).stdout)

    def plan(self, keys: list[str]) -> tuple[list[str], list[str]]:
        prot = set(self.cfg["protected"])
        test = [k for k in keys if self.starts.get(k)]
        test.sort(key=lambda k: (k in prot, keys.index(k)))       # protected last
        return test, [k for k in keys if not self.starts.get(k)]

    # -- main
    def run(self, *, dry: bool = False) -> BisectResult:
        r = BisectResult()
        r.lines += recover(self.client, self.tools, self.store, self.clock)
        keys = self.list_services()
        if not keys:
            r.lines.append("No repeat-util services found (list empty or query failed)")
            return r
        cands, r.untestable = self.plan(keys)
        if dry:
            r.lines.append(f"[dry] {len(keys)} services, testable {len(cands)}: {' '.join(cands)}")
            if r.untestable:
                r.lines.append(f"[dry] without start command (never switched off): {' '.join(r.untestable)}")
            return r
        base = self._sample()
        r.baseline = base.to_dict()
        r.lines.append("Baseline: " + base.line())
        if not base.hang:
            r.lines.append("No outliers: nothing switched off")
            r.measurements = self.measurements
            return r
        prot = set(self.cfg["protected"])
        cands = cands + [EXTERNAL]               # hypothesis "not caused by a listed service" (never switched off)
        last_lat = base.max_s
        try:
            while len(cands) > 1:
                off = cands[:len(cands) // 2]
                if any(k in prot for k in off) and not self.peace():
                    r.lines.append("Suspects include protected services, no test during an alarm: " + " ".join(cands))
                    r.measurements = self.measurements
                    return r
                m = self._measure_off(off, base.period_s, base.max_s)
                r.lines.append(f"off {' '.join(off)}: " + m.line())
                if m.hang:
                    cands = cands[len(off):]
                    last_lat = m.max_s
                else:
                    cands = off
        finally:
            r.restored = self._verify_all_on(keys, r)
        r.culprit = cands[0]
        r.latency_s = last_lat
        r.measurements = self.measurements
        if r.culprit == EXTERNAL:
            r.lines.append(f"Hang persists with every testable service off: not a single listed service "
                           f"(untestable: {' '.join(r.untestable) or '-'})")
        else:
            r.suggestion = suggest(r.culprit, self.lua_dir, base.tick_rate, base.period_s)
            r.lines.append(f"Culprit: {r.culprit} (freezes up to {last_lat:.1f} s, period "
                           f"{base.period_s or 0:.0f} s) after {r.measurements} measurements")
            r.lines += r.suggestion
        return r

    def _verify_all_on(self, keys: list[str], r: BisectResult) -> bool:
        now_on = set(self.list_services())
        missing = [k for k in keys if k not in now_on and self.starts.get(k)]
        if missing:
            self._restart(missing)
            now_on = set(self.list_services())
            missing = [k for k in missing if k not in now_on]
        if missing:
            r.lines.append("WARNING: services still off: " + " ".join(missing))
        return not missing


# ---------------------------------------------------------------- heuristics (KB perf_hanger)
_SCAN = re.compile(r"scheduleEvery|reapply|erzdig|\bALL\b|INTERVAL\s*=|, *\d{3,}\s*$")
_HINTS = {"raster": "reapply + erzdig ALL scan the map",
          "kohle": "coal scan + erzdig ALL (9.4 s live)",
          "bauprog": "building program sync (3.5 s live)"}


def suggest(key: str, lua_dir: Path | None, tick_rate: float | None = None, period_s: float | None = None) -> list[str]:
    """Proposal with line references (no automatic patch)."""
    name = key.removeprefix("claude-").split("-")[0]
    out = [f"Proposal for {key}: raise the interval, split the scan into blocks, or run only on demand "
           f"(no automatic Lua patch). " + _HINTS.get(name, "")]
    f = Path(lua_dir) / f"{name}.lua" if lua_dir else None
    interval = None
    if f and f.is_file():
        refs = []
        for no, ln in enumerate(f.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            if _SCAN.search(ln):
                refs.append(f"  {f.name}:{no}: {ln.strip()[:90]}")
                m = re.search(r"INTERVAL\s*=\s*(\d+)|,\s*(\d{3,})\s*$|scheduleEvery\([^,]+,\s*(\d+)", ln)
                if m and interval is None:
                    interval = int(next(g for g in m.groups() if g))
        out += refs[:4]
    if interval and tick_rate:
        out.append(f"  period ~ {interval} ticks / {tick_rate:.0f} ticks/s = {interval / tick_rate:.0f} s"
                   + (f" (measured {period_s:.0f} s)" if period_s else "") + "; timestream raises the tick rate")
    return out


# ---------------------------------------------------------------- CLI
def _starts(home: Path, cfg) -> dict[str, str]:
    from ..reboot import load_services
    try:
        svcs = load_services(home / cfg.get("reboot.services_file", "data/services.yaml"))
    except Exception:  # noqa: BLE001
        return {}
    return {s.key: s.start for s in svcs if getattr(s, "key", None) and getattr(s, "start", None)}


def cmd_perf(args) -> int:
    from ..cli import _pilot
    from ..config import HOME
    p = _pilot(args)
    c = _cfg(p.cfg.get(KEY, {}))
    for ln in recover(p.client, p.tools, p.store, p.clock):
        print(ln)
    if args.action == "sample":
        res = sample(p.client, p.clock, n=int(args.n or c["sample_n"]), gap=float(args.gap or c["sample_gap_s"]),
                     outlier_s=float(c["outlier_ms"]) / 1000.0)
        print(res.line())
        for s in res.outliers[:8]:
            print(f"  outlier {s.latency_s:.1f} s at +{s.t - res.samples[0].t:.0f} s" + (f" fc={s.fc}" if s.fc else ""))
        p.store.set("perf.sample", res.to_dict())
        return 1 if res.hang else 0
    if args.action == "status":
        st = _load_state(p.tools)
        flag = p.tools.flag("perf")
        print(f"perf.flag: {flag.text if flag.exists else 'none'}")
        print(f"switched off by a bisect: {' '.join(e['key'] for e in st.get('off', [])) or 'nothing'}")
        print(f"last sample: {p.store.get('perf.sample') or '-'}")
        last = p.store.get("perf.last") or {}
        print(f"last bisect: {last.get('culprit') or '-'} ({last.get('measurements', 0)} measurements)")
        if args.clear and flag.exists:
            p.tools.delete_flag("perf")
            print("perf.flag deleted")
        return 0
    # bisect
    now = p.clock.now().epoch
    if not args.dry_run and not args.force and \
            p.store.count_actions(RULE, "bisect", now - 3600) >= int(c["max_bisect_per_hour"]):
        print(f"Bisect ran {c['max_bisect_per_hour']}x in the last hour; use --force to run again")
        return 1
    b = Bisect(p.client, p.tools, p.store, p.clock, c, _starts(HOME, p.cfg), lua_dir=HOME / "lua" / "claude")
    r = b.run(dry=args.dry_run)
    print("\n".join(r.lines))
    if not args.dry_run:
        p.store.log_action(now, "perf", RULE, "bisect", r.culprit or "-", "", False, r.restored,
                           f"{r.measurements} measurements")
        p.store.set("perf.last", {"culprit": r.culprit, "latency_s": r.latency_s, "measurements": r.measurements,
                                  "baseline": r.baseline, "ts": now})
    return 0 if r.restored else 1


def register(sub) -> None:
    s = sub.add_parser("perf", help="freeze profiler (spec v3-03): sample|bisect|status")
    s.add_argument("action", nargs="?", default="status", choices=["sample", "bisect", "status"])
    s.add_argument("--n", type=int, default=None, help="sample: number of probes (default 40)")
    s.add_argument("--gap", type=float, default=None, help="sample: seconds between probes (default 0.6)")
    s.add_argument("--dry-run", action="store_true", help="bisect: list services, switch nothing off")
    s.add_argument("--force", action="store_true", help="bisect: ignore the per-hour limit")
    s.add_argument("--clear", action="store_true", help="status: delete perf.flag after handling")
    s.set_defaults(fn=cmd_perf)


def check_hook(pilot, report, dry: bool) -> list[str]:
    lines: list[str] = []
    if not dry:
        lines += recover(pilot.client, pilot.tools, pilot.store, pilot.clock)
    flag = pilot.tools.flag("perf")
    if flag.exists:
        lines.append((flag.text.splitlines() or ["Game hangs (perf.flag)"])[0][:120])
    return lines
