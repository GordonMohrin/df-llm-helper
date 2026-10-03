"""FEATURE-006: registry of background loops (lockfile + heartbeat), duplicate detection.

Run 5 (2026-10-03): several helper loops ran more than once (multiple `holdguard.sh`, a forgotten siege loop) and gave
contradicting orders (kill orders set again after deletion, BUG-426); nobody could see which loops were running.

Convention: every loop takes a lockfile `<tools>/loops/<name>.lock` (JSON: name, pid, started, cmd, interval_s,
heartbeat). A second instance of the same name either refuses to start (default, config `loops.on_duplicate: refuse`)
or warns and registers itself as `<name>.<pid>.lock` (`warn`). The loop calls `beat()` once per pass: it rewrites the
heartbeat (at most every `beat_min_s`) and returns False when `loops stop <name>` asked it to end (stop file
`<tools>/loops/<name>.stop`). The lockfile is removed when the loop ends (also on SIGTERM / Ctrl+C).

Status per lock: OK, STALE (process alive, heartbeat older than the stale limit), DEAD (process gone, lock left
behind), DUPLICATE (more than one live lock with the same name). PID liveness without psutil: os.kill(pid, 0) on POSIX
(never on Windows, there it would terminate the process), OpenProcess/GetExitCodeProcess via ctypes on Windows.
Only helper-own processes are managed: `stop --kill` compares the recorded command with the live command line
(psutil, /proc or PowerShell CIM) and refuses on a mismatch (PID reused by another program).
"""
from __future__ import annotations

import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path

__all__ = ["DEFAULTS", "LoopBusy", "LoopLock", "LockInfo", "pid_alive", "proc_cmdline", "scan", "problems",
           "stop", "clean", "for_cli", "loops_dir", "valid_name", "wake_lines"]

DEFAULTS = {"on_duplicate": "refuse", "stale_min_s": 120, "stale_factor": 3, "reclaim_s": 6 * 3600,
            "beat_min_s": 5, "stop_wait_s": 10, "in_check": True}
_NAME = re.compile(r"^[A-Za-z0-9_-]{1,40}$")


def valid_name(name: str) -> str:
    if not isinstance(name, str) or not _NAME.match(name):
        raise ValueError(f"invalid loop name {name!r} (letters, digits, '-' and '_', at most 40)")
    return name


def loops_dir(tools) -> Path:
    return Path(getattr(tools, "path", tools)) / "loops"


class LoopBusy(ValueError):
    """A live loop with the same name exists and on_duplicate is 'refuse' (CLI: one line, exit 2)."""


# ---------------------------------------------------------------- processes (no psutil needed)
def _psutil():
    try:
        import psutil  # type: ignore
        return psutil
    except Exception:  # noqa: BLE001 - optional dependency
        return None


def pid_alive(pid) -> bool:
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return False
    if pid <= 0:
        return False
    ps = _psutil()
    if ps is not None:
        try:
            return bool(ps.pid_exists(pid)) and ps.Process(pid).status() != getattr(ps, "STATUS_ZOMBIE", "zombie")
        except Exception:  # noqa: BLE001 - fall back to the OS call
            pass
    if sys.platform.startswith("win"):
        return _win_alive(pid)
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True                       # exists, owned by another user
    except OSError:
        return False
    return not _zombie(pid)


def _zombie(pid: int) -> bool:
    try:
        st = Path(f"/proc/{pid}/stat").read_text()
        return st.rsplit(")", 1)[1].split()[0] == "Z"
    except (OSError, IndexError):
        return False


def _win_alive(pid: int) -> bool:
    try:
        import ctypes
        from ctypes import wintypes
        k32 = ctypes.WinDLL("kernel32", use_last_error=True)          # type: ignore[attr-defined]
        h = k32.OpenProcess(0x1000, False, pid)                        # PROCESS_QUERY_LIMITED_INFORMATION
        if not h:
            return ctypes.get_last_error() == 5                         # ERROR_ACCESS_DENIED: exists
        try:
            code = wintypes.DWORD()
            if not k32.GetExitCodeProcess(h, ctypes.byref(code)):
                return True
            return code.value == 259                                    # STILL_ACTIVE
        finally:
            k32.CloseHandle(h)
    except Exception:  # noqa: BLE001 - unknown: count as alive (never reclaim a lock by mistake)
        return True


def proc_cmdline(pid) -> str | None:
    """Command line of a live process, None when it cannot be read (then nothing is compared)."""
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return None
    ps = _psutil()
    if ps is not None:
        try:
            return " ".join(ps.Process(pid).cmdline())
        except Exception:  # noqa: BLE001
            pass
    p = Path(f"/proc/{pid}/cmdline")
    if p.exists():
        try:
            return p.read_bytes().replace(b"\0", b" ").decode("utf-8", "replace").strip()
        except OSError:
            return None
    if sys.platform.startswith("win"):
        try:
            out = subprocess.run(["powershell", "-NoProfile", "-Command",
                                  f"(Get-CimInstance Win32_Process -Filter 'ProcessId={pid}').CommandLine"],
                                 capture_output=True, timeout=20).stdout.decode("utf-8", "replace").strip()
            return out or None
        except Exception:  # noqa: BLE001
            return None
    return None


def _kill(pid: int) -> bool:
    try:
        os.kill(int(pid), signal.SIGTERM)       # Windows: TerminateProcess
        return True
    except (OSError, ValueError):
        return False


# ---------------------------------------------------------------- lockfiles
@dataclass
class LockInfo:
    name: str
    pid: int
    path: Path
    started: float = 0.0
    heartbeat: float = 0.0
    interval_s: float = 60.0
    cmd: str = ""
    child_pid: int | None = None
    alive: bool = False
    status: str = "OK"                  # OK | STALE | DEAD | DUPLICATE
    marks: list = field(default_factory=list)
    beat_age_s: float | None = None

    def to_dict(self) -> dict:
        return {"name": self.name, "pid": self.pid, "started": self.started, "heartbeat": self.heartbeat,
                "beat_age_s": None if self.beat_age_s is None else round(self.beat_age_s, 1),
                "interval_s": self.interval_s, "cmd": self.cmd, "child_pid": self.child_pid, "alive": self.alive,
                "status": self.status, "marks": list(self.marks), "lock": self.path.name}

    def line(self, now: float) -> str:
        up = _dur(now - self.started) if self.started else "?"
        beat = "never" if self.beat_age_s is None else f"{_dur(self.beat_age_s)} ago"
        mark = "/".join(self.marks) or "OK"
        return f"{mark:<14} {self.name:<12} pid {self.pid:<7} up {up:<6} beat {beat:<9} {self.cmd[:70]}"


def _dur(s: float) -> str:
    s = max(0.0, float(s))
    if s < 120:
        return f"{s:.0f}s"
    if s < 7200:
        return f"{s / 60:.0f}m"
    return f"{s / 3600:.1f}h"


def _read(path: Path) -> dict | None:
    try:
        d = json.loads(path.read_text(encoding="utf-8"))
        return d if isinstance(d, dict) else None
    except (OSError, ValueError):
        return None


def _write_atomic(path: Path, data: dict) -> bool:
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    try:
        tmp.write_text(json.dumps(data, ensure_ascii=False, sort_keys=True), encoding="utf-8")
        os.replace(tmp, path)
        return True
    except OSError:                       # Windows: the target is open in a reader right now -> next beat
        try:
            tmp.unlink()
        except OSError:
            pass
        return False


def _stale_limit(info: LockInfo, cfg: dict) -> float:
    return max(float(cfg["stale_min_s"]), float(cfg["stale_factor"]) * float(info.interval_s or 0) + 30.0)


def scan(tools, cfg: dict | None = None, *, now: float | None = None) -> list[LockInfo]:
    """All lockfiles with status marks (pure read, nothing is deleted)."""
    c = {**DEFAULTS, **(cfg or {})}
    now = time.time() if now is None else now
    d = loops_dir(tools)
    out: list[LockInfo] = []
    if not d.is_dir():
        return out
    for p in sorted(d.glob("*.lock")):
        j = _read(p) or {}
        name = str(j.get("name") or p.name.split(".")[0])
        try:
            pid = int(j.get("pid") or 0)
        except (TypeError, ValueError):
            pid = 0
        info = LockInfo(name, pid, p, float(j.get("started") or 0), float(j.get("heartbeat") or 0),
                        float(j.get("interval_s") or 60), str(j.get("cmd") or ""), j.get("child_pid"))
        info.alive = pid_alive(pid)
        info.beat_age_s = (now - info.heartbeat) if info.heartbeat else None
        if not info.alive:
            info.marks.append("DEAD")
        elif info.beat_age_s is None or info.beat_age_s > _stale_limit(info, c):
            info.marks.append("STALE")
        out.append(info)
    by_name: dict = {}
    for i in out:
        if i.alive:
            by_name.setdefault(i.name, []).append(i)
    for group in by_name.values():
        if len(group) > 1:
            for i in group:
                i.marks.insert(0, "DUPLICATE")
    for i in out:
        i.status = i.marks[0] if i.marks else "OK"
    return out


def problems(infos: list[LockInfo]) -> list[str]:
    """One line per problem (digest/check/wake): duplicates, loops without heartbeat, dead locks."""
    out: list[str] = []
    dup: dict = {}
    for i in infos:
        if "DUPLICATE" in i.marks:
            dup.setdefault(i.name, []).append(str(i.pid))
    for name, pids in sorted(dup.items()):
        out.append(f"Loop {name} runs {len(pids)}x (pids {', '.join(pids)}) -> python -m df_llm_helper loops stop "
                   f"{name} --pid <pid>")
    for i in infos:
        if "STALE" in i.marks:
            age = "no heartbeat" if i.beat_age_s is None else f"heartbeat {_dur(i.beat_age_s)} old"
            out.append(f"Loop {i.name} (pid {i.pid}) hangs: {age} -> python -m df_llm_helper loops stop {i.name} --kill")
    for i in infos:
        if i.marks == ["DEAD"]:
            out.append(f"Loop {i.name} (pid {i.pid}) is gone, lock left behind -> python -m df_llm_helper loops clean")
    return out


def wake_lines(tools, cfg: dict | None = None) -> list[tuple[str, str]]:
    """(key, text) per DUPLICATE/STALE problem for the wake filter (files + PID check only, no DF call)."""
    out = []
    for ln in problems(scan(tools, cfg)):
        if " is gone" in ln:
            continue                       # a dead lock is cleaned at the next start; no reason to wake
        out.append((ln.split(" ")[1] + (":dup" if " runs " in ln else ":stale"), ln))
    return out


def clean(tools, cfg: dict | None = None) -> list[str]:
    """Remove locks of dead processes (and their stop files)."""
    out = []
    for i in scan(tools, cfg):
        if not i.alive:
            _unlink(i.path)
            out.append(f"removed dead lock {i.path.name} (pid {i.pid})")
    d = loops_dir(tools)
    if d.is_dir():
        live = {i.name for i in scan(tools, cfg)}
        for p in d.glob("*.stop"):
            if p.stem not in live:
                _unlink(p)
    return out


def _unlink(p: Path) -> bool:
    try:
        p.unlink()
        return True
    except FileNotFoundError:
        return False
    except OSError:
        return False


def _cmd_matches(recorded: str, live: str | None) -> bool:
    """The live process still runs our command? (unknown command line -> True, nothing to compare)"""
    if live is None or not recorded:
        return True
    rec = recorded.split()
    keys = [w for w in rec if "df_llm_helper" in w or w.endswith((".sh", ".py", ".ps1"))] or rec[:1]
    return all(k in live for k in keys)


def stop(tools, name: str, cfg: dict | None = None, *, pid: int | None = None, kill: bool = False,
         wait_s: float | None = None, sleep=time.sleep) -> list[str]:
    """Stop request for every lock of `name` (or only `pid`): stop file, wait, then (with kill) terminate the process.
    A lock whose process is gone is simply removed."""
    c = {**DEFAULTS, **(cfg or {})}
    valid_name(name)
    wait_s = float(c["stop_wait_s"] if wait_s is None else wait_s)
    locks = [i for i in scan(tools, c) if i.name == name and (pid is None or i.pid == int(pid))]
    if not locks:
        return [f"no lock for loop {name}" + (f" with pid {pid}" if pid else "")]
    out: list[str] = []
    stopf = loops_dir(tools) / f"{name}.stop"
    live = [i for i in locks if i.alive]
    for i in locks:
        if not i.alive:
            _unlink(i.path)
            out.append(f"{name} pid {i.pid}: process gone, lock removed")
    if live:
        stopf.parent.mkdir(parents=True, exist_ok=True)
        stopf.write_text(" ".join(str(i.pid) for i in live) if pid else "all", encoding="utf-8")
        waited = 0.0
        while waited < wait_s and any(i.path.exists() and pid_alive(i.pid) for i in live):
            sleep(0.5)
            waited += 0.5
        for i in live:
            if not i.path.exists() or not pid_alive(i.pid):
                _unlink(i.path)
                out.append(f"{name} pid {i.pid}: stopped (stop request), lock removed")
            elif kill:
                cl = proc_cmdline(i.pid)
                if not _cmd_matches(i.cmd, cl):
                    out.append(f"{name} pid {i.pid}: NOT killed - the process is now another program ({(cl or '')[:60]}); "
                               f"lock removed")
                    _unlink(i.path)
                    continue
                ok = True
                if i.child_pid and pid_alive(i.child_pid):
                    ok = _kill(i.child_pid)
                ok = _kill(i.pid) and ok
                waited = 0.0
                while waited < 5 and pid_alive(i.pid):
                    sleep(0.25)
                    waited += 0.25
                _unlink(i.path)
                out.append(f"{name} pid {i.pid}: " + ("killed, lock removed" if ok else "kill failed, lock removed"))
            else:
                out.append(f"{name} pid {i.pid}: did not stop within {wait_s:.0f} s (busy or no beat) -> "
                           f"python -m df_llm_helper loops stop {name} --kill")
        if not any(i.path.exists() for i in live):
            _unlink(stopf)
    return out


# ---------------------------------------------------------------- the loop side
class LoopLock:
    """Context manager for one loop process. `beat()` once per pass; False = stop requested."""

    def __init__(self, tools, name: str, cmd: str | None = None, *, interval_s: float = 60.0,
                 cfg: dict | None = None, on_duplicate: str | None = None, clock=time.time, child_pid=None,
                 report=None):
        self.cfg = {**DEFAULTS, **(cfg or {})}
        self.dir = loops_dir(tools)
        self.name = valid_name(name)
        self.cmd = cmd if cmd is not None else " ".join(["python", "-m", "df_llm_helper", *sys.argv[1:]])
        self.interval_s = float(interval_s)
        self.mode = on_duplicate or str(self.cfg["on_duplicate"])
        self.clock = clock
        self.pid = os.getpid()
        self.child_pid = child_pid
        self.path: Path | None = None
        self.warnings: list[str] = []
        self._last_beat = 0.0
        self._old_term = None
        self.report = report

    # -- acquire / release
    def _data(self, now: float) -> dict:
        return {"name": self.name, "pid": self.pid, "started": self._started, "heartbeat": now,
                "interval_s": self.interval_s, "cmd": self.cmd[:300], "child_pid": self.child_pid,
                "host": os.environ.get("COMPUTERNAME") or os.environ.get("HOSTNAME") or ""}

    def _create(self, path: Path, now: float) -> bool:
        try:
            fd = os.open(str(path), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
        except FileExistsError:
            return False
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(json.dumps(self._data(now), ensure_ascii=False, sort_keys=True))
        return True

    def acquire(self) -> "LoopLock":
        now = self.clock()
        self._started = now
        self.dir.mkdir(parents=True, exist_ok=True)
        for i in scan(self.dir.parent, self.cfg, now=now):
            if i.name != self.name or i.pid == self.pid:
                continue
            old = i.beat_age_s is not None and i.beat_age_s > float(self.cfg["reclaim_s"])
            if not i.alive or old:                   # dead process, or a heartbeat so old that the PID is reused
                _unlink(i.path)
                continue
            msg = (f"loop '{self.name}' already runs (pid {i.pid}, heartbeat "
                   f"{'never' if i.beat_age_s is None else _dur(i.beat_age_s) + ' ago'}): {i.cmd[:80]}")
            if self.mode != "warn":
                raise LoopBusy(msg + f" -> python -m df_llm_helper loops list; loops stop {self.name}")
            self.warnings.append("WARNING: " + msg + " - starting a DUPLICATE (loops.on_duplicate: warn)")
            if self.report:
                self.report(self.warnings[-1])
        _unlink(self.dir / f"{self.name}.stop")       # an old stop request must not end the new loop
        main = self.dir / f"{self.name}.lock"
        if self._create(main, now):
            self.path = main
        else:                                         # lost a race or warn mode: own lockfile, listed as DUPLICATE
            if self.mode != "warn":
                j = _read(main) or {}
                if j.get("pid") and pid_alive(j.get("pid")):
                    raise LoopBusy(f"loop '{self.name}' was started at the same moment by pid {j.get('pid')}")
                _unlink(main)
                if self._create(main, now):
                    self.path = main
            if self.path is None:
                alt = self.dir / f"{self.name}.{self.pid}.lock"
                _unlink(alt)
                self._create(alt, now)
                self.path = alt
        self._last_beat = now
        self._hook_signals()
        return self

    def release(self) -> None:
        if self.path is not None:
            j = _read(self.path) or {}
            if not j or int(j.get("pid") or 0) == self.pid:
                _unlink(self.path)
            self.path = None
        if self._old_term is not None:
            try:
                signal.signal(signal.SIGTERM, self._old_term)
            except (ValueError, OSError):
                pass
            self._old_term = None

    def _hook_signals(self) -> None:
        """SIGTERM -> SystemExit, so `finally` removes the lockfile (main thread only)."""
        if threading.current_thread() is not threading.main_thread():
            return
        try:
            self._old_term = signal.signal(signal.SIGTERM, _term)
        except (ValueError, OSError):
            self._old_term = None

    def __enter__(self) -> "LoopLock":
        return self.acquire()

    def __exit__(self, *exc) -> None:
        self.release()

    # -- per pass
    def stop_requested(self) -> bool:
        p = self.dir / f"{self.name}.stop"
        if not p.exists():
            return False
        try:
            txt = p.read_text(encoding="utf-8").split()
        except OSError:
            return True
        return not txt or txt == ["all"] or str(self.pid) in txt

    def beat(self) -> bool:
        """Refresh the heartbeat (throttled). Returns False when a stop was requested (the loop should end)."""
        now = self.clock()
        if self.path is not None and now - self._last_beat >= float(self.cfg["beat_min_s"]):
            if not self.path.exists():                   # lock removed by `loops stop`/`clean`: recreate it
                self._create(self.path, now)
            else:
                _write_atomic(self.path, self._data(now))
            self._last_beat = now
        return not self.stop_requested()


def _term(signum, frame):  # noqa: ARG001
    raise SystemExit(128 + int(signum))


class _NoLock:
    """Stand-in when no lock is taken (one pass, dry run): beat() is always True."""
    warnings: list = []

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return None

    def beat(self) -> bool:
        return True


def for_cli(cfg, name: str, *, enabled: bool = True, interval_s: float = 60.0, report=None):
    """CLI helper: a LoopLock under <paths.tools>/loops for a real loop, else a no-op stand-in.
    cfg = Config (paths.tools, loops.*)."""
    if not enabled:
        return _NoLock()
    lc = cfg.get("loops", {}) if hasattr(cfg, "get") else {}
    return LoopLock(cfg.path("tools"), name, interval_s=interval_s, cfg=lc or {}, report=report)
