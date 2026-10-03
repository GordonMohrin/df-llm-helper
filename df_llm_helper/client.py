"""DFClient (SPEC 5.1): RealClient (dfhack-run), MockClient (Fixtures), ReplayClient (JSONL), RecordingClient.

All clients check commands against fair play before executing them (fairplay.check_command).
"""
from __future__ import annotations

import json
import re
import shlex
import subprocess
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any, Callable, Iterable

from .clock import Clock, SystemClock
from .fairplay import ExceptionRegistry, check_command

__all__ = ["Result", "DFClient", "RealClient", "MockClient", "ReplayClient", "RecordingClient", "ReplayMismatch",
           "parse_json_tolerant", "is_write", "FIXTURE_COMMANDS", "MAX_REPORT_ID_CMD", "load_records",
           "SERVICES_CMD", "SERVICE_KEYS", "register_read"]

# read command for the highest report ID (as in the PowerShell guard)
MAX_REPORT_ID_CMD = ('lua "local r=df.global.world.status.reports '
                     'print(#r>0 and r[#r-1].id or -1)"')

# Query running background jobs without side effects (repeat-util keys of the claude/* scripts).
# 'claude/arbeit status' answers with a usage error; 'claude/ueberwacher status' is a pure read (BUG-407). Query
# running jobs with SERVICES_CMD below instead.
SERVICE_KEYS = ["watchdog", "arbeit", "trinken", "ueberwacher", "essen", "orders", "gesund", "auslastung",
                "material", "tempo", "migranten", "schau"]
SERVICES_CMD = ('lua "local r=require(\'repeat-util\') local t={} for _,k in ipairs({'
                + ",".join(f"\'claude-{k}\'" for k in SERVICE_KEYS)
                + '}) do t[#t+1]=k..\'=\'..tostring(r.isScheduled(k)) end print(table.concat(t,\' \'))"')

# fixture file -> command that yields this response (fixtures/run5)
FIXTURE_COMMANDS: dict[str, str] = {
    "status.txt": "claude/status",
    "report.txt": "claude/report",
    "units.txt": "claude/units",
    "buildings.txt": "claude/buildings",
    "config.txt": "claude/config",
    "mil_tabelle.txt": "claude/mil tabelle",
    "mil_report.txt": "claude/mil report",
    "workdetail_list.txt": "claude/workdetail list",
    "tempo_status.txt": "claude/tempo status",
    "handel_status.txt": "claude/handel status",
    "mood_status.txt": "claude/mood status",
    "orders_status.txt": "claude/orders status",
    "essen_status.txt": "claude/essen status",
    "trinken_status.txt": "claude/trinken status",
    "aemter_status.txt": "claude/aemter status",
    "gefahr_status.txt": "claude/gefahr status",
    "migranten_status.txt": "claude/migranten status",
    "auslastung_status.txt": "claude/auslastung status",
    "gesund_krypta.txt": "claude/gesund krypta",
    "area_z130.txt": "claude/area 130 80 90 40 28",
    "area_z133.txt": "claude/area 133 80 90 40 28",
}

_READ_EXACT = {"claude/status", "claude/report", "claude/units", "claude/buildings", "claude/config",
               "claude/probe", "claude/gefahr", "claude/mood", "claude/tempo",
               "claude/advance clock", "claude/migranten", "claude/auslastung", MAX_REPORT_ID_CMD, SERVICES_CMD}
# not 'lager': claude/trinken lager rewrites max_barrels of every stockpile (BUG-406)
_READ_SUB = {"status", "list", "tabelle", "report", "plan", "clock", "equip", "routines",
             "enemies", "krypta", "werkstaetten"}
# df-llm-helper Lua (v2): pure read commands
_READ_PILOT = {("claude/pilot_water", "scan"), ("claude/pilot_water", "near"), ("claude/pilot_mood", "need"),
               ("claude/pilot_hygiene", "forbid"), ("claude/pilot_lever", "list"),
               ("claude/pilot_hygiene", "piles"), ("claude/pilot_hygiene", "caps")}      # FEATURE-002
# scripts WITHOUT a read-only status command (claude/arbeit only knows start|stop|once); bauprog/raster have one (BUG-406).
# claude/ueberwacher got 'status' with BUG-407, but older installed copies run a round for it -> stays conservative.
_NO_STATUS = {"claude/arbeit", "claude/ueberwacher"}
# whole-map scanners: they change nothing but hold the game's main thread for seconds (BUG-415) -> never treated as a
# free read (loop guard / max_per_hour apply), also with --dry
_HEAVY = {"claude/ores", "claude/geo", "claude/zugaenge", "claude/kohle", "claude/erzdig", "claude/pfadcheck"}
# options that turn a read sub-command into a write (mil tabelle --file writes a file, --say announces in the game)
_WRITE_OPTS = {"--file", "--say"}


def register_read(cmd: str) -> None:
    """Register another pure read command (e.g. generated repeat-util queries of the v2 modules)."""
    _READ_EXACT.add(" ".join(cmd.strip().split()))


def is_write(cmd: str) -> bool:
    """True if the command MAY have a write effect (conservative: unknown = write)."""
    c = " ".join(cmd.strip().split())
    if c.split(" ")[0] in _HEAVY and c != "claude/kohle status":
        return True
    if c in _READ_EXACT:
        return False
    if "--apply" in c or "--live" in c:
        return True
    parts = c.split(" ")
    if parts[0] == "claude/area":
        return False
    if parts[0] in _NO_STATUS:
        return True
    if c in ("claude/handel scan",) or (parts[0] == "claude/handel" and len(parts) > 1 and parts[1] == "scan"):
        return False
    if len(parts) > 1 and (parts[0], parts[1]) in _READ_PILOT:
        return False
    if any(p in _WRITE_OPTS for p in parts):
        return True
    if parts[0].startswith("claude/") and len(parts) >= 2:
        sub = parts[1]
        if sub in _READ_SUB:
            return False
        if parts[0] == "claude/mil" and sub == "guard" and len(parts) > 2 and parts[2] == "status":
            return False
        if "--dry" in parts:
            return False
    return True


_DEC_COMMA = re.compile(r"(:\s*-?\d+),(\d+)(?=\s*[,}\]\n])")


def parse_json_tolerant(text: str) -> dict | list | None:
    """JSON from dfhack output: ignore BOM/preamble, repair decimal comma ('250,0'). Never raises."""
    if not text:
        return None
    t = text.lstrip("﻿")
    starts = [i for i in (t.find("{"), t.find("[")) if i >= 0]
    if not starts:
        return None
    t = t[min(starts):].strip()
    for cand in (t, _DEC_COMMA.sub(r"\1.\2", t)):
        try:
            return json.loads(cand)
        except (json.JSONDecodeError, ValueError):
            pass
    # last chance: cut off after the last closing bracket
    end = max(t.rfind("}"), t.rfind("]"))
    if end > 0:
        try:
            return json.loads(_DEC_COMMA.sub(r"\1.\2", t[:end + 1]))
        except (json.JSONDecodeError, ValueError):
            return None
    return None


@dataclass
class Result:
    ok: bool
    stdout: str
    stderr: str = ""
    elapsed_s: float = 0.0
    json: dict | list | None = None
    cmd: str = ""

    @classmethod
    def make(cls, cmd: str, ok: bool, stdout: str, stderr: str = "", elapsed_s: float = 0.0) -> "Result":
        return cls(ok=ok, stdout=stdout, stderr=stderr, elapsed_s=elapsed_s,
                   json=parse_json_tolerant(stdout) if ok else None, cmd=cmd)

    @property
    def timed_out(self) -> bool:
        """BUG-421: the call hit its timeout (RealClient/MockClient stderr 'Timeout after ...')."""
        return not self.ok and (self.stderr or "").startswith("Timeout after")

    def to_record(self) -> dict:
        d = asdict(self)
        d.pop("json", None)
        return d


class DFClient:
    """Abstract base. Subclasses implement _run(cmd, timeout)."""

    def __init__(self, registry: ExceptionRegistry | None = None, clock: Clock | None = None):
        self.registry = registry
        self.clock = clock or SystemClock()
        self.calls: list[str] = []
        self.observers: list[Callable[[Result], None]] = []

    def run(self, cmd: str, *, timeout: float = 40.0) -> Result:
        check_command(cmd, self.registry)
        self.calls.append(cmd)
        res = self._run(cmd, timeout)
        if not res.cmd:
            res.cmd = cmd
        for ob in self.observers:
            ob(res)
        return res

    def run_many(self, cmds: list[str], *, timeout: float = 60.0) -> list[Result]:
        out = []
        for c in cmds:
            try:
                out.append(self.run(c, timeout=timeout))
            except PermissionError:
                raise
            except Exception as e:  # one partial failure does not stop the others
                out.append(Result(ok=False, stdout="", stderr=f"{type(e).__name__}: {e}", cmd=c))
        return out

    @property
    def write_calls(self) -> list[str]:
        return [c for c in self.calls if is_write(c)]

    def _run(self, cmd: str, timeout: float) -> Result:  # pragma: no cover - abstract
        raise NotImplementedError


class RealClient(DFClient):
    """Calls dfhack-run.exe (one process per command). Only usable locally on the player's machine."""

    def __init__(self, dfhack_run: str | Path, registry: ExceptionRegistry | None = None,
                 clock: Clock | None = None, lint: Callable[[str], list] | None = None,
                 stall_log: str | Path | None = None):
        super().__init__(registry, clock)
        self.exe = Path(dfhack_run)
        self.lint = lint
        self.stall_log = Path(stall_log) if stall_log else None     # BUG-421: <tools>/out/stall.log

    def _stall(self, start: float, res: Result) -> Result:
        """BUG-421: every call slower than stalllog.STALL_S goes to the stall log (time, duration, command)."""
        from .stalllog import STALL_S, append_stall
        if self.stall_log is not None and res.elapsed_s > STALL_S:
            append_stall(self.stall_log, start, res.elapsed_s, res.cmd,
                         "timeout" if res.timed_out else ("ok" if res.ok else "fail"))
        return res

    def available(self) -> bool:
        return self.exe.is_file()

    def _run(self, cmd: str, timeout: float) -> Result:
        if self.lint is not None:
            findings = self.lint(cmd)
            if findings:
                return Result(ok=False, stdout="", stderr="Lint refused: " + "; ".join(map(str, findings)), cmd=cmd)
        if not self.available():
            return Result(ok=False, stdout="", stderr=f"dfhack-run not found: {self.exe} "
                                                      f"(set the path in config.yaml dfhack_run)", cmd=cmd)
        args = [str(self.exe)] + shlex.split(cmd, posix=True)
        start = self.clock.now().epoch
        t0 = time.monotonic()
        try:
            p = subprocess.run(args, cwd=str(self.exe.parent), capture_output=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            return self._stall(start, Result(ok=False, stdout="", stderr=f"Timeout after {timeout}s: {cmd} (game "
                                                                         f"hanging? Try a smaller query or retry later)",
                                             elapsed_s=time.monotonic() - t0, cmd=cmd))
        out = p.stdout.decode("utf-8", errors="replace")
        err = p.stderr.decode("utf-8", errors="replace")
        ok = p.returncode == 0 and "error" not in err.lower()[:200]
        return self._stall(start, Result.make(cmd, ok, out, err, time.monotonic() - t0))


class MockClient(DFClient):
    """Fixture responses by command; deterministic; error/delay injection.

    responses: command -> str | Result | callable(cmd)->str|Result. Unknown read commands -> ok=False,
    unknown write commands -> ok=True with empty output (logged in .calls).
    """

    def __init__(self, responses: dict[str, Any] | None = None, *, fail: dict[str, int] | None = None,
                 delay: dict[str, float] | None = None, registry: ExceptionRegistry | None = None,
                 clock: Clock | None = None, strict: bool = False):
        super().__init__(registry, clock)
        self.responses: dict[str, Any] = dict(responses or {})
        self.fail = dict(fail or {})
        self.delay = dict(delay or {})
        self.strict = strict
        self.processes = 0
        self.prefix_handlers: list[tuple[str, Callable[[str], Any]]] = []

    @classmethod
    def from_fixture_dir(cls, path: str | Path, **kw) -> "MockClient":
        p = Path(path)
        resp = {}
        for fname, cmd in FIXTURE_COMMANDS.items():
            f = p / fname
            if f.exists():
                resp[cmd] = f.read_text(encoding="utf-8", errors="replace")
        return cls(resp, **kw)

    def set(self, cmd: str, response: Any) -> None:
        self.responses[cmd] = response

    def _run(self, cmd: str, timeout: float) -> Result:
        self.processes += 1
        d = self.delay.get(cmd, 0.0)
        if d:
            if d > timeout:
                self.clock.sleep(timeout)
                return Result(ok=False, stdout="", stderr=f"Timeout after {timeout}s", elapsed_s=timeout, cmd=cmd)
            self.clock.sleep(d)
        if self.fail.get(cmd, 0) > 0:
            self.fail[cmd] -= 1
            return Result(ok=False, stdout="", stderr="injected failure", elapsed_s=d, cmd=cmd)
        r = self.responses.get(cmd)
        if r is None:
            norm = " ".join(cmd.split())
            r = self.responses.get(norm)
        if r is None:
            for prefix, fn in self.prefix_handlers:
                if cmd.startswith(prefix):
                    r = fn
                    break
        if callable(r):
            r = r(cmd)
        if isinstance(r, Result):
            return r
        if r is None:
            if self.strict:
                raise KeyError(f"MockClient: no response for {cmd!r}")
            if is_write(cmd):
                return Result(ok=True, stdout="", elapsed_s=d, cmd=cmd)
            return Result(ok=False, stdout="", stderr=f"no fixture for {cmd!r}", elapsed_s=d, cmd=cmd)
        return Result.make(cmd, True, str(r), "", d)


class ReplayMismatch(AssertionError):
    pass


def load_records(path: str | Path) -> tuple[dict, list[dict]]:
    """Read JSONL: optional first line {"meta": {...}}; remaining lines = records."""
    meta: dict = {}
    recs: list[dict] = []
    for no, line in enumerate(Path(path).read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            d = json.loads(line)
        except json.JSONDecodeError as e:
            raise ValueError(f"{path}:{no}: not JSON ({e.msg})") from None
        if "meta" in d and len(d) == 1:
            meta = d["meta"]
        else:
            recs.append(d)
    return meta, recs


class ReplayClient(DFClient):
    """Replays recorded responses.

    Without time steps (record->replay): FIFO per command in recording order.
    With time steps (scenarios, field "t"): set_step(t) -> for each command the latest response with t' <= t applies.
    strict: any deviation (unknown command, queue empty) -> ReplayMismatch.
    lenient: unknown read commands -> ok=False; write commands -> ok=True (logged).
    """

    def __init__(self, records: Iterable[dict], *, strict: bool = False, registry: ExceptionRegistry | None = None,
                 clock: Clock | None = None):
        super().__init__(registry, clock)
        self.records = [r for r in records if "cmd" in r]
        self.strict = strict
        self.timeline = any("t" in r for r in self.records)
        self.step = 0
        self._queues: dict[str, list[dict]] = {}
        for r in self.records:
            self._queues.setdefault(r["cmd"], []).append(r)
        self._pos: dict[str, int] = {}

    @classmethod
    def from_file(cls, path: str | Path, **kw) -> "ReplayClient":
        _, recs = load_records(path)
        return cls(recs, **kw)

    def set_step(self, t: int) -> None:
        self.step = t

    def _answer(self, rec: dict, cmd: str) -> Result:
        return Result.make(cmd, bool(rec.get("ok", True)), rec.get("stdout", ""), rec.get("stderr", ""),
                           float(rec.get("elapsed_s", 0.0)))

    def _run(self, cmd: str, timeout: float) -> Result:
        q = self._queues.get(cmd)
        if self.timeline:
            cands = [r for r in (q or []) if r.get("t", 0) <= self.step]
            if cands:
                best_t = max(r.get("t", 0) for r in cands)
                same = [r for r in cands if r.get("t", 0) == best_t]
                key = f"{cmd}@{best_t}"
                i = self._pos.get(key, 0)
                self._pos[key] = i + 1
                return self._answer(same[min(i, len(same) - 1)], cmd)
        elif q:
            i = self._pos.get(cmd, 0)
            if i < len(q):
                self._pos[cmd] = i + 1
                return self._answer(q[i], cmd)
            if self.strict:
                raise ReplayMismatch(f"Replay: command {cmd!r} called more often than recorded ({len(q)}x)")
            return self._answer(q[-1], cmd)
        if self.strict:
            raise ReplayMismatch(f"Replay: command {cmd!r} not recorded (step {self.step})")
        if is_write(cmd):
            return Result(ok=True, stdout="", cmd=cmd)
        return Result(ok=False, stdout="", stderr=f"not recorded: {cmd!r}", cmd=cmd)


class RecordingClient(DFClient):
    """Wrapper: logs every run() as JSONL (command, time, response)."""

    def __init__(self, inner: DFClient, path: str | Path, *, step: Callable[[], int] | None = None):
        super().__init__(inner.registry, inner.clock)
        self.inner = inner
        self.path = Path(path)
        self.step = step
        self.path.parent.mkdir(parents=True, exist_ok=True)

    def _run(self, cmd: str, timeout: float) -> Result:
        res = self.inner.run(cmd, timeout=timeout)
        rec = {"ts": self.clock.now().iso(), "cmd": cmd, "ok": res.ok, "stdout": res.stdout,
               "stderr": res.stderr, "elapsed_s": round(res.elapsed_s, 4)}
        if self.step is not None:
            rec["t"] = self.step()
        with self.path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        return res
