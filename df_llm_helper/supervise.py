"""dfllm supervise (DESIGN §10, CONTRACTS §15): liveness, DEGRADED, backup, restart.

`once()` is one pass; the Windows task DF-Aufsicht runs `pythonw -m df_llm_helper supervise --once` every 60 s.
Steady state makes 0 DF calls: it reads ACTIVE, heartbeat, perf.csv, events.jsonl and the DF save folder.
  liveness  DF process + <runtime>/ACTIVE + heartbeat mtime; older than 120 s = stale (reported, never killed).
  backup    every new save of a dfllm fort is copied once to <backups>/ (last 3 + one per day, <= 1 GB).
  crash     DF gone in 2 runs while ACTIVE exists (no clean unload) -> Steam start -> load-save the newest save.
  DEGRADED  rolling 10-min ticks/s < 60 % of the post-load baseline (same mode) or an autosave freeze > 20 s, from
            perf.csv (kernel PERF_DEGRADED events of this load are hints only) -> restart only in PEACE, unpaused,
            right after an autosave: re-check -> kill DF -> backup -> Steam -> wait for the window ->
            vdesk_move.ps1 (desktop 1) -> wait for DFHack -> load-save.
Hard rules: never pauses or unpauses, writes no inbox verbs, never loads a save older than the newest one, never
loads a save without the dfllm marker or from another session. A DEGRADED kill is deferred to the next autosave if
the reload would silently undo something (a command or class A/B event after the save, pending inbox files, a
caravan on the map). <runtime>/norestart.flag or a held live.lock turns kills and starts off (checked again right
before the kill and while waiting for the autosave; liveness and backups keep running). supervise.json writes are
best effort and never break the restart chain. Ported from repo B tools/aufsicht/neustart.py and tools/sicherung.py.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Callable

from . import schema

HB_MAX_S = 120                    # liveness: heartbeat mtime older than this = stale
DOWN_RUNS = 2                     # crash: DF missing in this many consecutive runs
MAX_RESTARTS, RESTARTS_WINDOW_S = 2, 6 * 3600
DEGRADED_GAP_S = 2 * 3600         # at most one DEGRADED restart per 2 h
SAVE_MAX_AGE_S = 6 * 3600         # a crash restart never loads a save older than this (report instead)
FRESH_SAVE_S = 15                 # "right after an autosave" (the game runs on until the kill)
IMMINENT_S = 55                   # wait inside the run for an autosave due within this many seconds
AUTOSAVE_MAX_S = 60               # extra wait for the autosave freeze and the write
STABLE_S = 3                      # a save is complete when no file is younger than this (and save/current is empty)
BROKEN_PCT = 50                   # newest save smaller than 50 % of the fort's older saves = broken
KILL_MAX_S, WINDOW_SETTLE_S, START_MAX_S = 60, 40, 300   # START_MAX_S: Steam start -> DF window/process
LOAD_MAX_S, LOAD_RETRY_S, MAP_MAX_S = 15 * 60, 180, 15 * 60
PERF_WARMUP_S, PERF_WINDOW_S, PERF_PCT, BASE_ROWS, SESSION_GAP_S = 120, 600, 60, 20, 180
FREEZE_MS = 20000
BACKUP_KEEP, BACKUP_CAP, BACKUP_GAP_S = 3, 1024 ** 3, 600
LOCK_STALE_S, SAY_EVERY_S, LOG_MAX = 3600, 1800, 1 << 20
TAIL_BYTES = 1 << 18
STEAM_URL = "steam://rungameid/975370"
DF_EXE = "Dwarf Fortress.exe"
DESKTOP = 1
YEAR = schema.TICKS["YEAR"]
MARKER_KEY = "dfllm"              # persist key of the site marker (CONTRACTS §10)
BACKUP_META, BACKUP_TOOL = "dfllm-backup.json", "dfllm-supervise"
NORESTART = "norestart.flag"
# emitted by the year boundary or the save freeze itself: a reload onto that save does not undo anything of these
AFTER_SAVE_OK = frozenset({"YEAR_REVIEW", "PERF_DEGRADED", "KERNEL_SLOW"})
CONFIRM_RE = re.compile(r"untested|warning|confirm|again", re.I)   # neustart.py: DFHack asked to confirm
NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)


# ---------------------------------------------------------------- environment
@dataclass
class Env:
    df: Path                       # DF install
    runtime: Path                  # <df>/dfllm-runtime
    saves: Path                    # DF save folder (%APPDATA%/Bay 12 Games/Dwarf Fortress/save)
    backups: Path                  # backup root (own folders only)
    repo: Path                     # repo A (tools/win/vdesk_move.ps1)
    os: Any = None                 # process/window/dfhack hooks; WinOS by default, a fake in tests
    clock: Callable[[], float] = time.time
    sleep: Callable[[float], None] = time.sleep
    autosave_ticks: int = YEAR     # arbiter sets yearly autosave (DESIGN §10)

    def __post_init__(self):
        self.df, self.runtime, self.saves = Path(self.df), Path(self.runtime), Path(self.saves)
        self.backups, self.repo = Path(self.backups), Path(self.repo)
        if self.os is None:
            self.os = WinOS(self.df, self.repo)


def default_env() -> Env:
    from . import paths
    df = paths.df_dir()
    appdata = os.environ.get("APPDATA") or str(Path.home() / "AppData" / "Roaming")
    saves = os.environ.get("DFLLM_SAVES") or os.path.join(appdata, "Bay 12 Games", "Dwarf Fortress", "save")
    backups = os.environ.get("DFLLM_BACKUPS") or os.path.join(df.anchor or "C:\\", "df-backups", "dfllm")
    return Env(df=df, runtime=paths.runtime_root(), saves=Path(saves), backups=Path(backups),
               repo=Path(__file__).resolve().parent.parent)


class WinOS:
    """Windows side effects (tasklist, taskkill, Steam, windows, vdesk_move.ps1, dfhack-run). Tests replace it."""

    def __init__(self, df: Path, repo: Path):
        self.dfhack_exe = Path(df) / "hack" / "dfhack-run.exe"
        self.vdesk = Path(repo) / "tools" / "win" / "vdesk_move.ps1"
        self._names: dict[int, str] = {}

    @staticmethod
    def _run(cmd: list, timeout: float, cwd: str | None = None) -> tuple[int, str]:
        r = subprocess.run(cmd, capture_output=True, timeout=timeout, cwd=cwd, creationflags=NO_WINDOW)
        return r.returncode, (r.stdout or b"").decode("utf-8", "replace") + (r.stderr or b"").decode("utf-8", "replace")

    def df_proc(self) -> tuple[str, float | None]:
        """('up', start epoch or None) | ('down', None) | ('unknown', None). 'down' needs two answers 3 s apart
        (tasklist can time out during an autosave freeze); an error is 'unknown', which never triggers a restart."""
        for attempt in (0, 1):
            try:
                _rc, out = self._run(["tasklist", "/FI", f"IMAGENAME eq {DF_EXE}", "/FO", "CSV", "/NH"], 30)
            except (OSError, subprocess.SubprocessError):
                return "unknown", None
            pids = [int(m.group(1)) for m in re.finditer(r'^"Dwarf Fortress\.exe","(\d+)"', out, re.M | re.I)]
            if pids:
                return "up", proc_start(pids[0])
            if attempt == 0:
                time.sleep(3)
        return "down", None

    def kill_df(self) -> tuple[bool, str]:
        try:
            rc, out = self._run(["taskkill", "/IM", DF_EXE, "/F"], 30)
        except (OSError, subprocess.SubprocessError) as e:
            return False, f"{type(e).__name__}: {e}"
        return rc == 0, out.strip()[:200]

    def start_df(self) -> tuple[bool, str]:
        try:
            os.startfile(STEAM_URL)      # Steam is logged in; no password involved
        except OSError as e:
            return False, f"{type(e).__name__}: {e}"
        return True, STEAM_URL

    def df_window(self) -> int | None:
        """First visible, unowned top-level window of Dwarf Fortress.exe (what .NET calls MainWindowHandle)."""
        return _win().df_window(self._names)

    def move_window(self, hwnd: int, desktop: int) -> tuple[bool, str]:
        cmd = ["powershell", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", str(self.vdesk),
               "-Hwnd", str(int(hwnd)), "-DesktopIndex", str(int(desktop))]
        try:
            _rc, out = self._run(cmd, 60)
        except (OSError, subprocess.SubprocessError) as e:
            return False, f"{type(e).__name__}: {e}"
        return bool(re.search(r"MOVED hr=0\b", out)), out.strip()[:200]

    def dfhack(self, *args: str, timeout: float = 60) -> tuple[bool, str]:
        if not self.dfhack_exe.is_file():
            return False, f"missing {self.dfhack_exe}"
        try:
            rc, out = self._run([str(self.dfhack_exe), *args], timeout, cwd=str(self.dfhack_exe.parent))
        except (OSError, subprocess.SubprocessError) as e:
            return False, f"{type(e).__name__}: {e}"
        return rc == 0 and "error" not in out.lower()[:200], out


class _Win32:
    """ctypes bindings (stdlib) for the window search and the process start time."""

    def __init__(self):
        import ctypes
        from ctypes import wintypes as w
        self.c, self.w = ctypes, w
        self.k32 = k32 = ctypes.WinDLL("kernel32", use_last_error=True)
        self.u32 = u32 = ctypes.WinDLL("user32", use_last_error=True)
        k32.OpenProcess.argtypes, k32.OpenProcess.restype = [w.DWORD, w.BOOL, w.DWORD], w.HANDLE
        k32.CloseHandle.argtypes = [w.HANDLE]
        k32.GetProcessTimes.argtypes = [w.HANDLE] + [ctypes.POINTER(w.FILETIME)] * 4
        k32.QueryFullProcessImageNameW.argtypes = [w.HANDLE, w.DWORD, w.LPWSTR, ctypes.POINTER(w.DWORD)]
        self.ENUM = ctypes.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)
        u32.EnumWindows.argtypes = [self.ENUM, w.LPARAM]
        u32.IsWindowVisible.argtypes = [w.HWND]
        u32.GetWindow.argtypes, u32.GetWindow.restype = [w.HWND, w.UINT], w.HWND
        u32.GetWindowThreadProcessId.argtypes = [w.HWND, ctypes.POINTER(w.DWORD)]

    def _open(self, pid: int):
        return self.k32.OpenProcess(0x1000, False, pid)          # PROCESS_QUERY_LIMITED_INFORMATION

    def image(self, pid: int) -> str:
        h = self._open(pid)
        if not h:
            return ""
        try:
            buf, n = self.c.create_unicode_buffer(1024), self.w.DWORD(1024)
            return buf.value if self.k32.QueryFullProcessImageNameW(h, 0, buf, self.c.byref(n)) else ""
        finally:
            self.k32.CloseHandle(h)

    def start(self, pid: int) -> float | None:
        h = self._open(pid)
        if not h:
            return None
        try:
            ft = [self.w.FILETIME() for _ in range(4)]
            if not self.k32.GetProcessTimes(h, *[self.c.byref(f) for f in ft]):
                return None
            return ((ft[0].dwHighDateTime << 32) | ft[0].dwLowDateTime) / 1e7 - 11644473600.0
        finally:
            self.k32.CloseHandle(h)

    def df_window(self, names: dict) -> int | None:
        found: list[int] = []

        def cb(hwnd, _lp):
            if hwnd and self.u32.IsWindowVisible(hwnd) and not self.u32.GetWindow(hwnd, 4):      # 4 = GW_OWNER
                pid = self.w.DWORD()
                self.u32.GetWindowThreadProcessId(hwnd, self.c.byref(pid))
                if pid.value not in names:
                    names[pid.value] = os.path.basename(self.image(pid.value)).lower()
                if names[pid.value] == DF_EXE.lower():
                    found.append(int(hwnd))
                    return False
            return True

        self.u32.EnumWindows(self.ENUM(cb), 0)
        return found[0] if found else None


_WIN: _Win32 | None = None


def _win() -> _Win32:
    global _WIN
    if _WIN is None:
        _WIN = _Win32()
    return _WIN


def proc_start(pid: int) -> float | None:
    try:
        return _win().start(pid)
    except (OSError, AttributeError, ValueError):
        return None


# ---------------------------------------------------------------- small file helpers
def _mtime(p: Path) -> float | None:
    try:
        return p.stat().st_mtime
    except OSError:
        return None


def _read_json(p: Path) -> Any:
    try:
        return json.loads(Path(p).read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return None


def _write_json(p: Path, doc: Any, sleep: Callable[[float], None] = time.sleep) -> bool:
    """Best-effort atomic write; never raises. On Windows os.replace fails while a reader or the virus scanner
    holds the target, so retry 3 times at 100 ms, then give up (False)."""
    tmp = p.with_name("." + p.name + ".tmp")
    for attempt in range(3):
        try:
            p.parent.mkdir(parents=True, exist_ok=True)
            tmp.write_text(json.dumps(doc, ensure_ascii=False, sort_keys=True, indent=1), encoding="utf-8")
            os.replace(tmp, p)
            return True
        except (OSError, TypeError, ValueError):
            if attempt < 2:
                sleep(0.1)
    return False


def _int(v: Any, default: int = -1) -> int:
    return v if isinstance(v, int) and not isinstance(v, bool) else default


def tail_lines(p: Path, max_bytes: int = TAIL_BYTES) -> list[str]:
    """Complete lines from the last max_bytes of a file (a torn last line is dropped)."""
    try:
        with open(p, "rb") as f:
            f.seek(0, 2)
            n = f.tell()
            f.seek(max(0, n - max_bytes))
            data = f.read()
    except OSError:
        return []
    lines = data.split(b"\n")
    if n > max_bytes:
        lines = lines[1:]
    lines = lines[:-1]                 # after the last '\n': empty or torn
    return [ln.decode("utf-8", "replace").rstrip("\r") for ln in lines if ln.strip()]


def read_active(runtime: Path) -> tuple[str | None, float | None]:
    """(save folder name, ACTIVE mtime). ACTIVE exists while a marked fort is loaded (kern deletes it at unload)."""
    p = runtime / "ACTIVE"
    mt = _mtime(p)
    if mt is None:
        return None, None
    try:
        name = p.read_text(encoding="utf-8-sig").strip().splitlines()[0].strip()
    except (OSError, IndexError):
        return None, mt
    if not name or "/" in name or "\\" in name or name in (".", ".."):
        return None, mt
    return name, mt


def read_heartbeat(p: Path, now: float) -> tuple[float | None, dict | None]:
    """(age from mtime, parsed doc or None). Liveness uses the mtime only; a torn line just gives doc None."""
    mt = _mtime(p)
    if mt is None:
        return None, None
    doc = _read_json(p)
    if not isinstance(doc, dict) or schema.validate("heartbeat", doc):
        doc = None
    return max(0.0, now - mt), doc


def live_lock(runtime: Path, now: float) -> str | None:
    """Holder of a valid, unexpired live.lock (CONTRACTS §9.15); an unreadable lock blocks for 30 min."""
    p = runtime / "live.lock"
    mt = _mtime(p)
    if mt is None:
        return None
    d = _read_json(p)
    if isinstance(d, dict) and not schema.validate("lock", d):
        return f"{d['holder']} ({d['purpose']})" if d["expires"] > now else None
    return "unreadable live.lock" if now - mt < 1800 else None


def _state_doc(save_dir: Path) -> dict:
    try:
        from . import files              # WP2: best valid a/b slot
        doc = files.read_state(save_dir)
    except Exception:  # noqa: BLE001 - any reader problem means "unknown"
        return {}
    return doc if isinstance(doc, dict) else {}


def _tempo_owner(save_dir: Path) -> str | None:
    return (_state_doc(save_dir).get("owners") or {}).get("tempo")


def _caravan(save_dir: Path) -> bool:
    return (_state_doc(save_dir).get("trade") or {}).get("caravan") == 1


def _pending_inbox(save_dir: Path) -> int:
    """Inbox files kern has not consumed yet (it ignores names starting with '.' or not ending in .json, §8)."""
    try:
        return sum(1 for n in os.listdir(save_dir / "inbox") if n.endswith(".json") and not n.startswith("."))
    except OSError:
        return 0


# ---------------------------------------------------------------- saves
def folder_info(p: Path) -> dict:
    size = files = 0
    newest = 0.0
    for root, _dirs, names in os.walk(p):
        for n in names:
            try:
                s = os.stat(os.path.join(root, n))
            except OSError:
                continue
            size, files, newest = size + s.st_size, files + 1, max(newest, s.st_mtime)
    return {"size": size, "files": files, "newest": newest}


def marker_of(p: Path) -> list | None:
    """[save, adopted, fort] of the dfllm site marker in a save folder, or None. DFHack 53.16-r2 stores site data
    as a JSON list of {k, s, ...} in dfhack-entity-<id>.dat (observed in saves on 2026-10-10; confirm in S9)."""
    for f in sorted(p.glob("dfhack-entity-*.dat")):
        try:
            raw = f.read_bytes()
        except OSError:
            continue
        if MARKER_KEY.encode() not in raw:
            continue
        try:
            items = json.loads(raw.decode("utf-8", "replace"))
        except ValueError:
            continue
        for it in items if isinstance(items, list) else []:
            if isinstance(it, dict) and it.get("k") == MARKER_KEY:
                try:
                    m = json.loads(it.get("s") or "")
                except ValueError:
                    m = None
                if isinstance(m, dict) and "adopted" in m:
                    return [str(m.get("save", "")), m.get("adopted"), str(m.get("fort", ""))]
    return None


def scan_saves(saves: Path, cache: dict, now: float) -> list[dict]:
    """Fortress saves (folders with world.sav, not 'current'), newest first. cache (in supervise.json) keeps the
    folder walk and the marker per world.sav mtime/size; recent saves are re-walked every time."""
    out = []
    try:
        dirs = [d for d in saves.iterdir() if d.is_dir() and d.name != "current"]
    except OSError:
        dirs = []
    for d in dirs:
        try:
            ws = (d / "world.sav").stat()
        except OSError:
            continue
        c = cache.get(d.name)
        if not c or c["wsm"] != ws.st_mtime or c["wss"] != ws.st_size or now - c["newest"] < 60:
            c = {"wsm": ws.st_mtime, "wss": ws.st_size, **folder_info(d), "marker": marker_of(d)}
        cache[d.name] = c
        out.append({"name": d.name, "path": str(d), "mt": c["wsm"], "size": c["size"], "files": c["files"],
                    "newest": c["newest"], "marker": c["marker"]})
    names = {e["name"] for e in out}
    for k in [k for k in cache if k not in names]:
        del cache[k]
    out.sort(key=lambda e: e["mt"], reverse=True)
    return out


def busy(saves: Path) -> bool:
    """DF writes a save to save/current first (world.sav last) and then moves it (sicherung.py)."""
    return (saves / "current" / "world.sav").is_file()


def ident_of(saves: list, active: str | None) -> list | None:
    s = next((e for e in saves if e["name"] == active), None)
    return s["marker"][:2] if s and s["marker"] else None


def pick_save(saves: list, now: float, *, active: str | None, since: float | None, ident: list | None = None,
              is_busy: bool = False, last_mt: float = 0.0, max_age: float = SAVE_MAX_AGE_S) -> tuple[dict | None, str]:
    """The newest save if it may be loaded, else (None, reason). Never an older one (no save scumming)."""
    if not saves:
        return None, "no fortress save"
    s = saves[0]
    if is_busy:
        return None, "DF is writing a save (save/current/world.sav)"
    if now - s["newest"] < STABLE_S:
        return None, f"{s['name']} is still being written"
    if not s["marker"]:
        return None, f"newest save '{s['name']}' has no dfllm marker"
    if ident and s["marker"][:2] != list(ident[:2]):
        return None, f"newest save '{s['name']}' belongs to another fort"
    if not (s["name"] == active or (since is not None and s["mt"] >= since - 5)):
        return None, f"newest save '{s['name']}' is not from the session of '{active}'"
    same = [e["size"] for e in saves[1:] if e["marker"] and e["marker"][:2] == s["marker"][:2]][:3]
    if same and s["size"] < sum(same) / len(same) * BROKEN_PCT / 100:
        return None, f"newest save '{s['name']}' looks broken ({s['size']} B)"
    if s["mt"] < last_mt:
        return None, f"newest save '{s['name']}' is older than the save loaded last"
    if now - s["mt"] > max_age:
        return None, f"newest save '{s['name']}' is {int((now - s['mt']) / 60)} min old"
    return s, "ok"


# ---------------------------------------------------------------- DEGRADED
def perf_rows(p: Path) -> list[dict]:
    """perf.csv rows (CONTRACTS §9.11): wall,tick,mode,tps,pop,units,items,ms_s,gap_max_ms,gaps3,mods."""
    rows = []
    for ln in tail_lines(p):
        f = ln.split(",")
        if len(f) != 11 or f[0] == "wall":
            continue
        try:
            rows.append({"wall": int(f[0]), "tick": int(f[1]), "mode": f[2], "tps": int(f[3]),
                         "gap": int(f[8]), "gaps3": int(f[9])})
        except ValueError:
            continue
    return rows


def last_session(rows: list) -> list:
    """Rows since the last load: a wall gap > 180 s or a tick going backwards starts a new session."""
    out: list = []
    for r in rows:
        if out and (r["wall"] - out[-1]["wall"] > SESSION_GAP_S or r["tick"] < out[-1]["tick"]):
            out = []
        out.append(r)
    return out


def _median(v: list) -> int:
    v = sorted(v)
    return v[len(v) // 2] if len(v) % 2 else (v[len(v) // 2 - 1] + v[len(v) // 2]) // 2


def boot_of(events: list) -> tuple[int, int]:
    """(n, tick) of the last BOOT event (kern.lua:971); (-1, 0) if the tail holds none (the boot is older than every
    event in it). events.jsonl survives loading an older save (CONTRACTS §9.4): only n > boot n is this load."""
    for e in reversed(events):
        if e.get("type") == "BOOT":
            return _int(e.get("n")), max(0, _int(e.get("tick"), 0))
    return -1, 0


def _row_at(s: list, tick: int) -> dict | None:
    """The perf row that records something of this tick: the first row at or after it."""
    return next((r for r in s if r["tick"] >= tick), None)


def kernel_hints(s: list, now: float, events: list) -> list[dict]:
    """PERF_DEGRADED events (perf.lua:93, :119) of this load whose tick falls into the last PERF_WINDOW_S of rows."""
    boot_n, _tick = boot_of(events)
    before = [r["tick"] for r in s if r["wall"] <= now - PERF_WINDOW_S]
    t_lo = before[-1] if before else s[0]["tick"]
    return [e for e in events if e.get("type") == "PERF_DEGRADED" and _int(e.get("n")) > boot_n
            and _int(e.get("tick")) >= t_lo and isinstance(e.get("d"), dict)]


def degraded(rows: list, now: float, save_mts: list, events: list) -> dict:
    """DESIGN §10 rule on perf rows: rolling 10-min tps < 60 % of the post-load baseline (same mode), or an
    autosave freeze > 20 s (a frame gap that coincides with a save). Paused rows (tps 0) and rows with a frame gap
    > 3 s are not used for tps. Kernel PERF_DEGRADED events are hints only (perf.lua emits why=freeze for any gap,
    also a sleep/resume, and recovers why=tps at 80 %): a hint of this load inside the window may supply the
    baseline before the supervisor has its own (why=tps), or flag a freeze before its row exists (why=freeze), but
    the rows must confirm it: tps rolling < 60 % now, or a save at the freeze."""
    res: dict = {"on": False, "why": "", "mode": None, "tps": None, "base": None, "pct": None, "tps_now": None}
    s = last_session(rows)
    if not s or now - s[-1]["wall"] > 90:
        res["why"] = "no recent perf rows"
        return res
    mode = res["mode"] = s[-1]["mode"]

    def usable(r: dict) -> bool:
        return r["mode"] == mode and r["tps"] > 0 and r["gaps3"] == 0

    def at_save(wall: float) -> bool:
        return any(wall - 40 <= mt <= wall + 10 for mt in save_mts)

    ok = [r for r in s if usable(r)]
    res["tps_now"] = _median([r["tps"] for r in ok[-3:]]) if ok else None
    for r in s:
        if r["gap"] > FREEZE_MS and at_save(r["wall"]):
            res.update(on=True, why=f"autosave freeze {r['gap'] // 1000} s")
            return res
    hints = kernel_hints(s, now, events)
    for e in hints:
        if e["d"].get("why") == "freeze" and at_save((_row_at(s, e["tick"]) or {}).get("wall", now)):
            res.update(on=True, why="autosave freeze (kernel PERF_DEGRADED)")
            return res
    base_rows = [r for r in ok if r["wall"] >= s[0]["wall"] + PERF_WARMUP_S][:BASE_ROWS]
    win = [r for r in s if r["wall"] > now - PERF_WINDOW_S]
    roll = [r for r in win if usable(r)]
    base, src = None, ""
    if len(base_rows) >= 8 and roll and roll[0]["wall"] > base_rows[-1]["wall"]:
        base = _median([r["tps"] for r in base_rows])
    else:
        kb = [_int(e["d"].get("base")) for e in hints if e["d"].get("why") == "tps"
              and (_row_at(s, e["tick"]) or {}).get("mode") == mode]
        if kb and kb[-1] > 0:
            base, src = kb[-1], " (kernel baseline)"
    if base is None:
        res["why"] = "baseline not ready" if len(base_rows) < 8 else "window not ready"
    elif any(r["mode"] != mode for r in win):
        res["why"] = "mode changed inside the window"
    elif len(roll) < 10:
        res["why"] = "window not ready"
    else:
        tps = sum(r["tps"] for r in roll) // len(roll)
        pct = tps * 100 // max(1, base)
        res.update(tps=tps, base=base, pct=pct, on=pct < PERF_PCT, why=f"tps {tps}/{base} = {pct} %{src}")
    return res


def tail_events(p: Path) -> list[dict]:
    out = []
    for ln in tail_lines(p):
        try:
            e = json.loads(ln)
        except ValueError:
            continue
        if isinstance(e, dict):
            out.append(e)
    return out


def seconds_to_autosave(tick: int, hb_age: float, tps: int | None, every: int = YEAR) -> float | None:
    """Real seconds until the next autosave boundary, from the heartbeat tick (abs) and the current tps."""
    if not tps or tps <= 0:
        return None
    return (every - tick % every) / tps - (hb_age or 0.0)


# ---------------------------------------------------------------- backup (port of tools/sicherung.py)
def _safe(s: Any) -> str:
    return re.sub(r"[^A-Za-z0-9_-]+", "_", str(s or "")).strip("_") or "fort"


def list_backups(root: Path) -> list[dict]:
    out = []
    try:
        dirs = [d for d in root.iterdir() if d.is_dir()]
    except OSError:
        return out
    for d in dirs:
        m = _read_json(d / BACKUP_META)
        if not isinstance(m, dict) or m.get("tool") != BACKUP_TOOL:
            continue                                   # not ours: never touched
        out.append({"name": d.name, "path": d, "created": m.get("created", 0), "size": m.get("size", 0),
                    "src": m.get("src"), "src_mt": m.get("src_mt", 0)})
    out.sort(key=lambda b: b["created"], reverse=True)
    return out


def plan_rotation(backups: list, keep_last: int = BACKUP_KEEP, cap: int = BACKUP_CAP) -> tuple[list, list]:
    """Keep the last keep_last plus the newest of every older calendar day; then drop the oldest kept until the
    total is <= cap (the newest always stays). Returns (keep names, drop names), newest first."""
    keep, drop, days = [], [], set()
    for i, b in enumerate(sorted(backups, key=lambda b: b["created"], reverse=True)):
        day = datetime.fromtimestamp(b["created"]).date()
        (keep if i < keep_last or day not in days else drop).append(b)
        days.add(day)
    while len(keep) > 1 and sum(b["size"] for b in keep) > cap:
        drop.append(keep.pop())
    return [b["name"] for b in keep], [b["name"] for b in drop]


def backup(env: Env, s: dict, now: float) -> dict:
    """Copy save folder s once to env.backups/<fort>-<folder>-<time>/ with a meta file, verify, rotate.
    Never raises: a failed backup must not stop a crash restart."""
    try:
        return _backup(env, s, now)
    except (OSError, shutil.Error) as e:
        return {"ok": False, "why": f"{type(e).__name__}: {e}"[:200]}


def _backup(env: Env, s: dict, now: float) -> dict:
    root = env.backups
    have = list_backups(root)
    dup = next((b for b in have if b["src"] == s["name"] and abs(b["src_mt"] - s["mt"]) < 1), None)
    if dup:
        return {"ok": True, "skip": f"already in {dup['name']}"}
    if s["size"] > BACKUP_CAP:
        return {"ok": False, "why": f"save {s['size'] >> 20} MB > cap {BACKUP_CAP >> 20} MB"}
    root.mkdir(parents=True, exist_ok=True)
    if shutil.disk_usage(root).free < s["size"] * 2 + (512 << 20):
        return {"ok": False, "why": f"not enough free space on {root.anchor}"}
    m = s["marker"] or ["", 0, ""]
    name = f"{_safe(m[2] or m[0])}-{_safe(s['name'])}-{time.strftime('%Y%m%d-%H%M%S', time.localtime(s['mt']))}"
    tmp, dst = root / (name + ".tmp"), root / name
    if dst.exists():
        return {"ok": False, "why": f"{dst.name} exists without meta"}
    if tmp.exists():
        shutil.rmtree(tmp)
    shutil.copytree(s["path"], tmp)
    after, copy = folder_info(Path(s["path"])), folder_info(tmp)
    if _mtime(Path(s["path"]) / "world.sav") != s["mt"] or after["newest"] > s["newest"]:
        shutil.rmtree(tmp, ignore_errors=True)
        return {"ok": False, "why": "source changed while copying (DF saved) - next run"}
    if (copy["files"], copy["size"]) != (s["files"], s["size"]):
        shutil.rmtree(tmp, ignore_errors=True)
        return {"ok": False, "why": f"incomplete copy ({copy['files']}/{s['files']} files)"}
    meta = {"tool": BACKUP_TOOL, "v": 2, "created": int(now), "size": s["size"], "files": s["files"],
            "src": s["name"], "src_mt": s["mt"], "fort": s["marker"],
            "note": "emergency copy; never loaded automatically (no save scumming)"}
    (tmp / BACKUP_META).write_text(json.dumps(meta, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(tmp, dst)
    by_name = {b["name"]: b for b in list_backups(root)}
    _keep, drop = plan_rotation(list(by_name.values()))
    dropped = []
    for n in drop:
        p = by_name[n]["path"]
        if p.parent == root and (p / BACKUP_META).is_file():     # safety net: own folders directly in root only
            shutil.rmtree(p, ignore_errors=True)
            dropped.append(n)
    return {"ok": True, "name": name, "mb": s["size"] >> 20, "dropped": dropped}


# ---------------------------------------------------------------- restart (port of neustart.py)
def blockers(env: Env, st: dict, now: float, kind: str) -> list[str]:
    b = []
    if (env.runtime / NORESTART).exists():
        b.append(f"{NORESTART} present")
    held = live_lock(env.runtime, now)
    if held:
        b.append(f"live.lock held by {held}")
    recent = [t for t in st.get("restarts", []) if now - t < RESTARTS_WINDOW_S]
    if len(recent) >= MAX_RESTARTS:
        b.append(f"{len(recent)} restarts in {RESTARTS_WINDOW_S // 3600} h")
    elif kind == "degraded" and recent and now - max(recent) < DEGRADED_GAP_S:
        b.append(f"last restart {int((now - max(recent)) / 60)} min ago")
    return b


def holds(env: Env, st: dict, now: float, kind: str, name: str, hb: dict | None) -> list[str]:
    """Why DF may not be killed now: blockers, not PEACE, paused (honoured), tempo lowered through the inbox."""
    b = blockers(env, st, now, kind)
    if not hb:
        b.append("heartbeat unreadable")
    elif hb["mode"] != "PEACE":
        b.append(f"mode {hb['mode']}")
    elif hb["paused"]:
        b.append("game paused (honoured)")
    if _tempo_owner(env.runtime / name) == "inbox":
        b.append("tempo lowered through the inbox")
    return b


def save_tick(floor: int, hb_tick: int, every: int) -> int:
    """Lower bound of the abs tick a save holds: the autosave boundary when it lies between `floor` (a tick seen
    before the save was written) and the heartbeat tick now, else `floor` itself."""
    b = hb_tick - hb_tick % every
    return b if floor <= b <= hb_tick else floor


def rollback_risk(save_dir: Path, tick: int) -> str | None:
    """What a reload onto a save of `tick` would silently undo (None = nothing): commands (CMD) or class A/B events
    of this load at or after it (their outbox replies and plan.json would lie; deaths, moods, migrants or trades
    would be save scumming), inbox files not consumed yet, a caravan on the map."""
    evs = tail_events(save_dir / "events.jsonl")
    boot_n, _tick = boot_of(evs)
    late = sorted({str(e.get("type")) for e in evs if _int(e.get("n")) > boot_n and _int(e.get("tick")) >= tick
                   and (e.get("type") == "CMD" or e.get("cls") in ("A", "B")) and e.get("type") not in AFTER_SAVE_OK})
    if late:
        return "after the save: " + ", ".join(late[:4])
    n = _pending_inbox(save_dir)
    if n:
        return f"{n} inbox command(s) pending"
    if _caravan(save_dir):
        return "caravan on the map"
    return None


def pre_kill(env: Env, st: dict, active: str | None, floor: int) -> str | None:
    """Re-check right before a DEGRADED kill (files only); None = go."""
    name, _amt = read_active(env.runtime)
    if not name or name != active:
        return f"fort changed ({name or 'none'} loaded)"
    p = env.runtime / name / "heartbeat"
    age, hb = read_heartbeat(p, env.clock())
    if age is not None and hb is None:                 # torn line: one retry after 50 ms (CONTRACTS §8)
        env.sleep(0.05)
        age, hb = read_heartbeat(p, env.clock())
    b = holds(env, st, env.clock(), "degraded", name, hb)
    if hb and age is not None and age > HB_MAX_S:
        b.append(f"heartbeat {int(age)} s old")
    if busy(env.saves):
        b.append("DF is writing a save")
    if hb and not b:
        risk = rollback_risk(env.runtime / name, save_tick(floor, hb["tick"], env.autosave_ticks))
        if risk:
            b.append(risk + " - waiting for the next autosave")
    return "; ".join(b) or None


def restart(env: Env, st: dict, s: dict, why: str, kill: bool, flush: Callable[[], None],
            active: str | None = None, floor: int = 0) -> dict:
    """Blocking chain: [pre-kill check, kill] -> backup -> Steam -> window to desktop 1 -> load-save -> kern boot
    (ACTIVE + heartbeat). `floor` is a tick seen before save s was written (pre_kill)."""
    o, clk = env.os, env.clock
    t0 = clk()
    rs = st["restart"] = {"why": why, "save": s["name"], "save_mt": s["mt"], "kill": kill, "t0": int(t0),
                          "phase": "start", "log": []}

    def step(phase: str, msg: str) -> dict:
        rs["phase"] = phase
        rs["log"].append(f"+{int(clk() - t0)}s {phase}: {msg}"[:240])
        _log(env, f"restart {phase}: {msg}")
        try:
            os.utime(env.runtime / "supervise.lock")
        except OSError:
            pass
        flush()                                # best effort, never raises
        return rs

    def fail(msg: str) -> dict:
        st["failed"] = {"wall": int(clk()), "msg": msg}
        return step("failed", msg)

    if kill:
        held = pre_kill(env, st, active, floor)
        if held:
            return step("aborted", held)
    st.setdefault("restarts", []).append(int(t0))
    killed = started = False
    try:
        if kill:
            killed = True
            ok, out = o.kill_df()
            step("kill", f"taskkill {'ok' if ok else 'FAILED'} {out[:100]}")
            while o.df_proc()[0] != "down":
                if clk() - t0 > KILL_MAX_S:
                    return fail(f"DF still running {KILL_MAX_S} s after taskkill")
                env.sleep(1)
        # DF is down: the folder cannot change and the copy does not widen the rollback window
        bk = rs["backup"] = backup(env, s, clk())
        if bk.get("ok"):
            st.setdefault("backup", {}).update(key=f"{s['name']}|{int(s['mt'])}", wall=int(clk()))
        step("backup", str(bk.get("name") or bk.get("skip") or bk.get("why")))
        started = True
        return _start_and_load(env, st, s, step, fail, t0)
    except Exception as e:  # noqa: BLE001 - never leave DF killed without a start attempt
        if killed and not started:
            try:
                o.start_df()
            except Exception:  # noqa: BLE001
                pass
        return fail(f"{type(e).__name__}: {e}"[:200])


def _start_and_load(env: Env, st: dict, s: dict, step: Callable, fail: Callable, t0: float) -> dict:
    o, clk = env.os, env.clock
    ok, out = o.start_df()
    if not ok:
        return fail(f"Steam start failed: {out}")
    t_start = clk()
    step("steam", out)
    moved = _move_window(env, step, t_start)
    step("window", f"moved {moved} window(s) to desktop {DESKTOP}" if moved else "no DF window moved (focus?)")
    t1, retried = clk(), False
    while True:
        if clk() - t1 > LOAD_MAX_S:
            return fail(f"load-save did not start within {LOAD_MAX_S // 60} min")
        if o.df_proc()[0] == "down":                       # a cold Steam start can be slow
            if clk() - t_start > START_MAX_S:
                return fail(f"DF not running {START_MAX_S} s after the Steam start")
            env.sleep(5)
            continue
        ok, out = o.dfhack("load-save", s["name"], timeout=60)
        if ok and CONFIRM_RE.search(out or ""):
            ok, out = o.dfhack("load-save", s["name"], timeout=60)
        if ok:
            break
        if "can't find save" in (out or "").lower():
            return fail(f"load-save: {out.strip()[:120]}")
        env.sleep(5)
    step("load", f"load-save '{s['name']}' {(out or '').strip()[:100]}")
    t2 = clk()
    while clk() - t2 <= MAP_MAX_S:
        name, amt = read_active(env.runtime)
        hb = _mtime(env.runtime / name / "heartbeat") if name else None
        if name and amt is not None and amt >= t2 - 5 and hb is not None and hb >= t2 - 5:
            st["last_loaded"] = {"name": s["name"], "mt": s["mt"]}
            st.pop("failed", None)
            return step("done", f"'{name}' live {int(clk() - t0)} s after the start")
        if not retried and clk() - t2 > LOAD_RETRY_S:      # neustart.py: one more load-save if still at the title
            retried = True
            _ok, out = o.dfhack("load-save", s["name"], timeout=60)
            step("load", f"2nd load-save: {(out or '').strip()[:100]}")
        env.sleep(5)
    return fail(f"fort not live {MAP_MAX_S // 60} min after load-save")


def _move_window(env: Env, step: Callable, t0: float) -> int:
    """Poll for the DF window (100 ms, ctypes only) and move it to the desktop, at most START_MAX_S after the
    Steam start; DF may replace its window once while it initialises, so keep watching for WINDOW_SETTLE_S
    after the first move (as tools/win/start_df_desktop1.ps1 does)."""
    o, clk = env.os, env.clock
    first, moved, tries = None, set(), {}
    while clk() - t0 < START_MAX_S:
        h = o.df_window()
        if h and h not in moved and tries.get(h, 0) < 3:
            tries[h] = tries.get(h, 0) + 1
            ok, out = o.move_window(h, DESKTOP)
            step("window", f"hwnd {h}: {out[:80]}")
            if ok:
                moved.add(h)
                first = first if first is not None else clk()
        if first is not None and clk() - first >= WINDOW_SETTLE_S:
            break
        env.sleep(0.1)
    return len(moved)


def wait_for_save(env: Env, st: dict, active: str, since: float, ident: list | None, secs: float,
                  hb: dict) -> tuple[dict | None, str, int]:
    """Wait (1 s polls, files only) for the next save of this session; give up as soon as anything holds the
    restart (holds(): flag, live.lock, mode, pause, inbox tempo). Returns (save or None, why, floor): floor = the
    heartbeat tick of the last poll that saw no new save and no save in progress (a lower bound of its tick)."""
    clk = env.clock
    deadline = clk() + max(0.0, secs) + AUTOSAVE_MAX_S
    base = max((e["mt"] for e in scan_saves(env.saves, st.setdefault("scan", {}), clk())), default=0.0)
    floor = hb["tick"]
    while clk() <= deadline:
        env.sleep(1)
        now = clk()
        saves = scan_saves(env.saves, st["scan"], now)
        is_busy = busy(env.saves)
        s, _why = pick_save(saves, now, active=active, since=since, ident=ident, is_busy=is_busy)
        if s and s["mt"] > base:
            return s, "ok", floor
        _age, doc = read_heartbeat(env.runtime / active / "heartbeat", now)
        hb = doc or hb                                     # a torn line keeps the last good one
        held = holds(env, st, now, "degraded", active, hb)
        if held:
            return None, "; ".join(held), floor
        if doc and not is_busy and max((e["mt"] for e in saves), default=0.0) <= base:
            floor = max(floor, doc["tick"])
    return None, "no autosave came", floor


# ---------------------------------------------------------------- one pass
def _log(env: Env, msg: str) -> None:
    p = env.runtime / "supervise.log"
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        if (_mtime(p) is not None) and p.stat().st_size > LOG_MAX:
            os.replace(p, p.with_name(p.name + ".1"))
        with open(p, "a", encoding="utf-8") as f:
            f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(env.clock()))}\t{msg}\n")
    except OSError:
        pass


def _run_lock(env: Env, now: float) -> Path | None:
    p = env.runtime / "supervise.lock"
    p.parent.mkdir(parents=True, exist_ok=True)
    for _ in (0, 1):
        try:
            fd = os.open(p, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            os.write(fd, f"{os.getpid()} {int(now)}\n".encode())
            os.close(fd)
            return p
        except FileExistsError:
            mt = _mtime(p)
            if mt is not None and abs(now - mt) < LOCK_STALE_S:
                return None
            try:
                p.unlink()
            except OSError:
                return None
    return None


def load_state(env: Env) -> dict:
    d = _read_json(env.runtime / "supervise.json")
    return d if isinstance(d, dict) and d.get("v") == 2 else {"v": 2}


def once(now: float | None = None, *, env: Env | None = None, dry_run: bool = False) -> dict:
    """One supervisor pass. Returns the result dict (also stored as `last` in <runtime>/supervise.json)."""
    env = env or default_env()
    now = env.clock() if now is None else now
    st = load_state(env)
    r: dict = {"v": 2, "wall": int(now), "dry_run": dry_run, "df": None, "active": None, "hb_age": None,
               "live": False, "why": "", "mode": None, "paused": None, "degraded": None, "backup": None,
               "restart": None, "actions": [], "alerts": []}
    lock = None
    if not dry_run:
        lock = _run_lock(env, now)
        if lock is None:
            r["why"] = "another supervise run holds supervise.lock"
            return r
    try:
        _pass(env, st, r, now, dry_run)
    except Exception as e:  # noqa: BLE001 - the task must log, not die silently
        r["alerts"].append({"key": "error", "msg": f"{type(e).__name__}: {e}"})
        if not dry_run:
            _log(env, f"ERROR {type(e).__name__}: {e}")
    finally:
        if lock:
            try:
                lock.unlink()
            except OSError:
                pass
    if not dry_run:
        st["runs"], st["last"] = st.get("runs", 0) + 1, r
        if not _write_json(env.runtime / "supervise.json", st, env.sleep):     # never raises
            _log(env, "ERROR supervise.json not written (file locked?)")
    return r


def _pass(env: Env, st: dict, r: dict, now: float, dry_run: bool) -> None:
    said = st.setdefault("said", {})

    def alert(key: str, msg: str) -> None:
        r["alerts"].append({"key": key, "msg": msg})
        if not dry_run and now - said.get(key, 0) >= SAY_EVERY_S:
            said[key] = now
            _log(env, f"ALERT {key}: {msg}")

    def flush() -> None:                       # called after every restart phase; must never break the chain
        if not dry_run and not _write_json(env.runtime / "supervise.json", st, env.sleep):
            _log(env, "supervise.json write failed (kept in memory, written at the next flush)")

    st["restarts"] = [t for t in st.get("restarts", []) if now - t < 4 * RESTARTS_WINDOW_S]
    prev = st.get("restart")
    if prev and prev.get("phase") not in ("done", "failed", "aborted"):
        prev["phase"] = "failed"
        prev["log"].append("interrupted (the previous supervise run ended mid-restart)")
        st["failed"] = {"wall": int(now), "msg": "restart interrupted"}
    proc, started = env.os.df_proc()
    r["df"] = proc
    name, amt = read_active(env.runtime)
    if name and proc == "up" and started and amt is not None and amt < started - 5:
        st["stale_active"] = int(amt)                    # ACTIVE from an earlier DF session (crash, then another game)
    if name and amt is not None and st.get("stale_active") == int(amt):
        r["active_stale"], name = True, None
    r["active"] = name
    hb_age, hb = read_heartbeat(env.runtime / name / "heartbeat", now) if name else (None, None)
    r["hb_age"] = None if hb_age is None else int(hb_age)
    if hb:
        r["mode"], r["paused"] = hb["mode"], hb["paused"]
    saves = scan_saves(env.saves, st.setdefault("scan", {}), now)
    is_busy = busy(env.saves) and proc != "down"
    st["down"] = st.get("down", 0) + 1 if proc == "down" else 0

    if proc == "unknown":
        r["why"] = "DF process state unknown (tasklist failed)"
    elif proc == "down":
        r["why"] = f"DF not running; '{name}' was not unloaded (crash?)" if name else "DF not running (clean exit)"
    elif not name:
        r["why"] = "no dfllm fort loaded (title screen or an unmarked save)"
    elif hb_age is None or hb_age > HB_MAX_S:
        r["why"] = f"heartbeat {'missing' if hb_age is None else f'{int(hb_age)} s old'}"
        alert("stale", f"{name}: {r['why']} (DF hung or kernel stopped); not killed, check `dfllm doctor`")
    else:
        r["live"], r["why"] = True, "ok"
        st.pop("failed", None)
    if st.get("failed") and not r["live"]:
        alert("restart_failed", f"automatic restart failed: {st['failed']['msg']} - human needed")

    if proc == "down" and name:                # DF is down: back up first, then restart
        r["backup"] = _backup_step(env, st, saves, is_busy, now, dry_run)
        _crash(env, st, r, saves, name, amt, now, dry_run, alert, flush)
    else:                                      # a DEGRADED restart copies after its kill (restart())
        if r["live"]:
            _degraded(env, st, r, saves, name, amt, hb, hb_age, is_busy, now, dry_run, alert, flush)
        if r["restart"] is None:
            r["backup"] = _backup_step(env, st, saves, is_busy, now, dry_run)
    if r["backup"] and r["backup"].get("ok") is False:
        alert("backup", f"backup: {r['backup'].get('why') or r['backup'].get('skip')}")


def _backup_step(env: Env, st: dict, saves: list, is_busy: bool, now: float, dry_run: bool) -> dict | None:
    marked = [e for e in saves if e["marker"]]
    if not marked:
        return None
    s, b = marked[0], st.setdefault("backup", {})
    key = f"{s['name']}|{int(s['mt'])}"
    if b.get("key") == key:
        return {"ok": True, "skip": f"{s['name']} already backed up"}
    if is_busy or now - s["newest"] < STABLE_S:
        return {"ok": True, "skip": f"{s['name']} is being written"}
    if now - b.get("wall", 0) < BACKUP_GAP_S:
        return {"ok": True, "skip": "last backup < 10 min ago"}
    if dry_run:
        return {"ok": True, "would": f"back up {s['name']}"}
    res = backup(env, s, now)
    if res.get("ok"):
        b.update(key=key, wall=int(now), name=res.get("name") or res.get("skip"))
        if res.get("name"):
            _log(env, f"backup {res['name']} ({res['mb']} MB) dropped {res['dropped']}")
    return res


def _crash(env, st, r, saves, name, amt, now, dry_run, alert, flush) -> None:
    if st["down"] < DOWN_RUNS:
        r["actions"].append(f"DF down {st['down']}/{DOWN_RUNS} runs - waiting")
        return
    b = blockers(env, st, now, "crash")
    if b:
        alert("crash_blocked", "DF down, no automatic restart: " + "; ".join(b))
        return
    s, why = pick_save(saves, now, active=name, since=amt, ident=ident_of(saves, name),
                       last_mt=(st.get("last_loaded") or {}).get("mt", 0.0))
    if not s:
        alert("crash_nosave", "DF down, nothing to load: " + why)
        return
    if dry_run:
        r["actions"].append(f"would start DF and load-save '{s['name']}'")
        return
    r["restart"] = restart(env, st, s, "crash", kill=False, flush=flush)
    r["actions"].append(f"restart (crash) -> {r['restart']['phase']}")


def _degraded(env, st, r, saves, name, amt, hb, hb_age, is_busy, now, dry_run, alert, flush) -> None:
    sdir = env.runtime / name
    rows, evs = perf_rows(sdir / "perf.csv"), tail_events(sdir / "events.jsonl")
    d = r["degraded"] = degraded(rows, now, [e["mt"] for e in saves], evs)
    if not d["on"]:
        return
    alert("degraded", f"{name}: DEGRADED ({d['why']})")
    b = holds(env, st, now, "degraded", name, hb)
    if b:
        r["actions"].append("restart deferred: " + "; ".join(b))
        return
    ident, last_mt = ident_of(saves, name), (st.get("last_loaded") or {}).get("mt", 0.0)
    s, _why = pick_save(saves, now, active=name, since=amt, ident=ident, is_busy=is_busy, last_mt=last_mt)
    floor = 0
    if not (s and now - s["mt"] <= FRESH_SAVE_S and amt is not None and s["mt"] >= amt - 5):
        secs = seconds_to_autosave(hb["tick"], hb_age or 0.0, d.get("tps_now"), env.autosave_ticks)
        if secs is None or secs > IMMINENT_S:
            r["actions"].append("restart waits for the next autosave" + (f" (~{int(secs)} s)" if secs else ""))
            return
        if dry_run:
            r["actions"].append(f"would wait ~{max(0, int(secs))} s for the autosave, then restart")
            return
        r["actions"].append(f"waiting ~{max(0, int(secs))} s for the autosave")
        s, why, floor = wait_for_save(env, st, name, amt, ident, secs, hb)
        if not s:
            r["actions"].append("restart deferred: " + why)
            return
    if dry_run:
        r["actions"].append(f"would restart DF onto '{s['name']}' ({d['why']})")
        return
    # ticks seen before the save was written: perf rows of this load older than it, the BOOT, the wait's polls
    seen = [x["tick"] for x in last_session(rows) if x["wall"] < s["mt"] - 1]
    floor = max(seen + [boot_of(evs)[1], floor])
    rs = r["restart"] = restart(env, st, s, f"degraded: {d['why']}", kill=True, flush=flush, active=name,
                                floor=floor)
    r["backup"] = rs.get("backup")
    r["actions"].append(f"restart (degraded) -> {rs['phase']}" + (f": {rs['log'][-1]}" if rs["phase"] == "aborted"
                                                                   else ""))


# ---------------------------------------------------------------- CLI
def summary(r: dict) -> str:
    parts = [f"supervise: DF {r['df']}", f"fort {r['active'] or '-'}", r["why"]]
    if r["hb_age"] is not None:
        parts.append(f"hb {r['hb_age']} s {r['mode'] or '?'}{' paused' if r['paused'] else ''}")
    d = r.get("degraded")
    if d:
        parts.append(f"degraded {'YES' if d['on'] else 'no'} ({d['why']})")
    if r.get("backup"):
        b = r["backup"]
        parts.append("backup " + str(b.get("name") or b.get("skip") or b.get("would") or b.get("why")))
    parts += r["actions"] + [f"ALERT {a['key']}: {a['msg']}" for a in r["alerts"]]
    return "; ".join(p for p in parts if p)


def main(argv: list[str] | None = None, env: Env | None = None) -> int:
    ap = argparse.ArgumentParser(prog="dfllm supervise", description="Liveness, DEGRADED, backup and restart of DF "
                                 "(never pauses or unpauses; never loads an older or unmarked save).")
    ap.add_argument("--once", action="store_true", help="one pass (what the DF-Aufsicht task runs)")
    ap.add_argument("--every", type=int, default=60, help="loop period in seconds without --once")
    ap.add_argument("--dry-run", action="store_true", help="decide only: no kill, start, load, backup or state write")
    ap.add_argument("--reset", action="store_true", help="forget restart history, failures and stale ACTIVE")
    ap.add_argument("--json", action="store_true", help="print the result as JSON")
    a = ap.parse_args(argv)
    env = env or default_env()
    if a.reset:
        st = load_state(env)
        for k in ("restarts", "failed", "restart", "stale_active", "down"):
            st.pop(k, None)
        if not _write_json(env.runtime / "supervise.json", st):
            print("supervise: supervise.json could not be written (locked?)", file=sys.stderr)
            return 1
        print("supervise: restart history cleared")
        return 0
    while True:
        r = once(env=env, dry_run=a.dry_run)
        print(json.dumps(r, ensure_ascii=False) if a.json else summary(r), flush=True)
        if a.once:
            return 1 if any(x["key"] == "error" for x in r["alerts"]) else 0
        env.sleep(max(5, a.every))


if __name__ == "__main__":
    sys.exit(main())
