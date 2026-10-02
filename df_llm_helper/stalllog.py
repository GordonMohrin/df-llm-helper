"""BUG-421: stall log of slow dfhack-run calls (`<tools>/out/stall.log`).

A dfhack-run request is served by the game's main thread, so a call that normally takes 0.1 s but now takes 8-9 s
means that something held that thread (a periodic Lua job, an autosave, the OS). RealClient appends every call that
takes longer than STALL_S (3 s) - including timeouts - with time, duration and command; the file is rotated at 1 MB
(one older generation `stall.log.1`). `python -m df_llm_helper perf status` reports the stall period: the median
interval between stalls (calls within CLUSTER_S of each other are one stall), which identifies the periodic job.

Line format (tab separated): ISO time (UTC), epoch start, duration s, ok|fail|timeout, command.
"""
from __future__ import annotations

import statistics
from datetime import datetime, timezone
from pathlib import Path

__all__ = ["STALL_S", "MAX_BYTES", "CLUSTER_S", "append_stall", "read_stalls", "stall_stats", "stall_line"]

STALL_S = 3.0
MAX_BYTES = 1_000_000
CLUSTER_S = 15.0


def append_stall(path: Path, start_epoch: float, duration_s: float, cmd: str, status: str = "ok",
                 *, max_bytes: int = MAX_BYTES) -> None:
    """Appends one line; never raises (the log must not break a game call)."""
    try:
        path = Path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.exists() and path.stat().st_size >= max_bytes:
            old = path.with_name(path.name + ".1")
            old.unlink(missing_ok=True)
            path.replace(old)
        iso = datetime.fromtimestamp(start_epoch, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        one = " ".join(str(cmd).split())[:200]
        with path.open("a", encoding="utf-8") as f:
            f.write(f"{iso}\t{start_epoch:.3f}\t{duration_s:.2f}\t{status}\t{one}\n")
    except (OSError, ValueError, OverflowError):
        pass


def read_stalls(path: Path) -> list[tuple[float, float, str, str]]:
    """-> [(epoch, duration, status, cmd)] of stall.log.1 + stall.log, oldest first; bad lines are skipped."""
    out = []
    path = Path(path)
    for f in (path.with_name(path.name + ".1"), path):
        try:
            text = f.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for ln in text.splitlines():
            p = ln.split("\t")
            if len(p) < 5:
                continue
            try:
                out.append((float(p[1]), float(p[2]), p[3], p[4]))
            except ValueError:
                continue
    out.sort(key=lambda r: r[0])
    return out


def stall_stats(path: Path, *, cluster_s: float = CLUSTER_S) -> dict:
    """Stalls (clusters of slow calls), median interval between them (= period), longest call, top commands."""
    rows = read_stalls(path)
    starts: list[float] = []
    for ep, _, _, _ in rows:
        if not starts or ep - starts[-1] > cluster_s:
            starts.append(ep)
    gaps = [b - a for a, b in zip(starts, starts[1:])]
    cmds: dict = {}
    for _, _, _, c in rows:
        cmds[c] = cmds.get(c, 0) + 1
    return {"calls": len(rows), "stalls": len(starts),
            "period_s": statistics.median(gaps) if gaps else None,
            "max_s": max((r[1] for r in rows), default=None),
            "timeouts": sum(1 for r in rows if r[2] == "timeout"),
            "first": starts[0] if starts else None, "last": starts[-1] if starts else None,
            "top": sorted(cmds.items(), key=lambda kv: -kv[1])[:3]}


def stall_line(path: Path) -> str:
    """One line for `perf status`."""
    s = stall_stats(path)
    if not s["calls"]:
        return f"stall log: no dfhack-run call slower than {STALL_S:g} s recorded ({Path(path).name})"
    period = f"median interval {s['period_s']:.0f} s" if s["period_s"] is not None else "period unknown (1 stall)"
    last = datetime.fromtimestamp(s["last"], tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%SZ")
    top = ", ".join(f"{c[:40]} x{n}" for c, n in s["top"])
    return (f"stall log: {s['stalls']} stalls ({s['calls']} calls > {STALL_S:g} s, {s['timeouts']} timeouts, "
            f"longest {s['max_s']:.1f} s), stall period: {period}, last {last}; top: {top}")
