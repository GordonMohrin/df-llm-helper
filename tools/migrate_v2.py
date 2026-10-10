"""Migrate the DF install from v1 to df-llm-helper v2 (DESIGN §9). Idempotent, dry run by default, reversible.

  python tools/migrate_v2.py             print every step and what --apply would do (changes nothing)
  python tools/migrate_v2.py --apply     do the open steps (refused while Dwarf Fortress runs; --force overrides)
  python tools/migrate_v2.py --revert    undo the steps recorded in <DF>/_archive-v1/migrate_v2.journal.json

Steps, in order: stop the v1 processes (waechter, runde.py --follow, repo B supervisor, unpause-guard); disable the
scheduled task DF-Aufsicht; dfhack-config/script-paths.txt: the repo B lua line becomes +<repo A>\\lua;
dfhack-config/init/onMapLoad.init runs only `dfllm boot`; move hack/scripts/claude and df-llm-helper-runtime to
<DF>/_archive-v1/. Opt-in: --plugins moves the automelt, channel-safely and confirm DLLs to hack/plugins/_disabled/
(DESIGN §9 step 4); --repoint-task points DF-Aufsicht at `pythonw -m df_llm_helper supervise --once` (the task stays
disabled until the live slot S9). Nothing is deleted; edited files are copied to _archive-v1/migrate_v2/ first.
Prefs files are not touched. Stdlib only.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable

DEFAULT_DF = r"E:\Program Files (x86)\Steam\steamapps\common\Dwarf Fortress"
REPO_A = Path(__file__).resolve().parent.parent
TASK = "DF-Aufsicht"
NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)
V1_PROCS = [re.compile(p, re.I) for p in (
    r"-m\s+(df_llm_helper|dfpilot)\s+waechter\b",      # python -m df_llm_helper waechter --loop (and the old dfpilot)
    r"runde\.py\b.*--follow",                          # repo B tools/aufsicht/runde.py --follow
    r"aufsicht[\\/]+supervisor\.py",                   # repo B supervisor (--loop runs)
    r"unpause-guard\.ps1")]                            # the v1 PowerShell guard
ONMAPLOAD_TEXT = ("# df-llm-helper v2 (tools/migrate_v2.py; undo with --revert).\n"
                  "# Only the v2 kernel boots on map load; it does nothing on saves without the dfllm marker.\n"
                  "dfllm boot\n")
PLUGINS = ("automelt", "channel-safely", "confirm")
SUPERVISE_ARGS = "-m df_llm_helper supervise --once"


# ---------------------------------------------------------------- Windows side (tests use a fake)
class WinSys:
    @staticmethod
    def _run(cmd: list, timeout: float = 60) -> tuple[int, str]:
        try:
            r = subprocess.run(cmd, capture_output=True, timeout=timeout, creationflags=NO_WINDOW)
        except (OSError, subprocess.SubprocessError) as e:
            return -1, f"{type(e).__name__}: {e}"
        return r.returncode, (r.stdout or b"").decode("utf-8", "replace") + (r.stderr or b"").decode("utf-8", "replace")

    def _ps(self, script: str, timeout: float = 60) -> tuple[int, str]:
        return self._run(["powershell", "-NoProfile", "-NonInteractive", "-Command", script], timeout)

    def df_running(self) -> bool | None:
        rc, out = self._run(["tasklist", "/FI", "IMAGENAME eq Dwarf Fortress.exe", "/FO", "CSV", "/NH"], 30)
        if rc != 0:
            return None
        return '"dwarf fortress.exe"' in out.lower()

    def processes(self) -> list[dict] | None:
        rc, out = self._ps("Get-CimInstance Win32_Process -Filter \"Name like 'python%' or Name like 'powershell%' "
                           "or Name like 'pwsh%'\" | Select-Object ProcessId, CommandLine | ConvertTo-Json -Compress")
        if rc != 0:
            return None
        try:
            d = json.loads(out) if out.strip() else []
        except ValueError:
            return None
        d = [d] if isinstance(d, dict) else d
        return [{"pid": int(p["ProcessId"]), "cmd": p.get("CommandLine") or ""} for p in d]

    def kill(self, pid: int) -> tuple[bool, str]:
        rc, out = self._run(["taskkill", "/PID", str(pid), "/F"], 30)
        return rc == 0, out.strip()[:120]

    def task_state(self, name: str) -> str | None:
        rc, out = self._ps(f"(Get-ScheduledTask -TaskName {_q(name)} -ErrorAction Stop).State")
        return out.strip() if rc == 0 and out.strip() else None

    def task_enable(self, name: str, on: bool) -> tuple[bool, str]:
        rc, out = self._run(["schtasks", "/Change", "/TN", name, "/ENABLE" if on else "/DISABLE"], 60)
        return rc == 0, out.strip()[:160]

    def task_action(self, name: str) -> dict | None:
        rc, out = self._ps(f"(Get-ScheduledTask -TaskName {_q(name)} -ErrorAction Stop).Actions | Select-Object "
                           "-First 1 Execute, Arguments, WorkingDirectory | ConvertTo-Json -Compress")
        try:
            return json.loads(out) if rc == 0 else None
        except ValueError:
            return None

    def task_set_action(self, name: str, a: dict) -> tuple[bool, str]:
        wd = f" -WorkingDirectory {_q(a['WorkingDirectory'])}" if a.get("WorkingDirectory") else ""
        rc, out = self._ps(f"$a = New-ScheduledTaskAction -Execute {_q(a['Execute'])} "
                           f"-Argument {_q(a.get('Arguments') or '')}{wd}; "
                           f"Set-ScheduledTask -TaskName {_q(name)} -Action $a | Out-Null")
        return rc == 0, out.strip()[:160]


def _q(s: str) -> str:
    return "'" + str(s).replace("'", "''") + "'"


# ---------------------------------------------------------------- context, helpers
@dataclass
class Ctx:
    df: Path
    repo_a: Path
    repo_b: Path
    task: str = TASK
    sys: Any = field(default_factory=WinSys)
    force: bool = False
    out: Callable[[str], None] = print
    clock: Callable[[], float] = time.time

    @property
    def archive(self) -> Path:
        return self.df / "_archive-v1"

    @property
    def journal(self) -> Path:
        return self.archive / "migrate_v2.journal.json"

    def rel(self, p: Path) -> str:
        try:
            return str(Path(p).relative_to(self.df))
        except ValueError:
            return str(p)


def _norm(p: str) -> str:
    return os.path.normcase(os.path.normpath(p.strip().strip('"'))).rstrip("\\/")


def _sha(b: bytes | None) -> str | None:
    return None if b is None else hashlib.sha256(b).hexdigest()


def _read(p: Path) -> bytes | None:
    try:
        return p.read_bytes()
    except FileNotFoundError:
        return None


def _write_atomic(p: Path, data: bytes) -> None:
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_name("." + p.name + ".migrate.tmp")
    tmp.write_bytes(data)
    os.replace(tmp, p)


def _commands(text: str) -> list[str]:
    return [ln.strip() for ln in text.splitlines() if ln.strip() and not ln.strip().startswith("#")]


# ---------------------------------------------------------------- steps
class Step:
    name = ""
    optin: str | None = None          # CLI flag name that enables an opt-in step

    def check(self, c: Ctx) -> tuple[str, str]:           # 'done' | 'todo' | 'n/a' | 'blocked', detail
        raise NotImplementedError

    def apply(self, c: Ctx) -> tuple[bool, str, dict]:     # ok, detail, journal data
        raise NotImplementedError

    def revert(self, c: Ctx, d: dict) -> tuple[str, str]:  # 'reverted' | 'done' | 'manual' | 'conflict' | 'failed'
        raise NotImplementedError


class StopProcs(Step):
    name = "stop-v1-processes"

    @staticmethod
    def found(c: Ctx) -> list[dict] | None:
        ps = c.sys.processes()
        if ps is None:
            return None
        return [p for p in ps if p["pid"] != os.getpid() and any(rx.search(p["cmd"]) for rx in V1_PROCS)]

    def check(self, c):
        ps = self.found(c)
        if ps is None:
            return "blocked", "cannot list processes"
        if not ps:
            return "done", "no v1 process running"
        return "todo", "; ".join(f"pid {p['pid']}: {p['cmd'][:100]}" for p in ps)

    def apply(self, c):
        stopped, errs = [], []
        for p in self.found(c) or []:
            ok, msg = c.sys.kill(p["pid"])
            (stopped if ok else errs).append(p if ok else f"pid {p['pid']}: {msg}")
        detail = f"stopped {len(stopped)}" + (f"; FAILED {'; '.join(errs)}" if errs else "")
        return not errs, detail, {"stopped": stopped}

    def revert(self, c, d):
        cmds = [p["cmd"] for p in d.get("stopped", [])]
        return "manual", ("not restarted (v1 is retired); start by hand if needed: " + " | ".join(cmds)) if cmds \
            else "nothing was stopped"


class DisableTask(Step):
    name = "disable-task"

    def check(self, c):
        s = c.sys.task_state(c.task)
        if s is None:
            return "n/a", f"task {c.task} not found"
        return ("done", f"{c.task} is Disabled") if s == "Disabled" else ("todo", f"{c.task} is {s} -> Disabled")

    def apply(self, c):
        before = c.sys.task_state(c.task)
        ok, msg = c.sys.task_enable(c.task, False)
        return ok, msg or "disabled", {"before": before}

    def revert(self, c, d):
        if d.get("before") in (None, "Disabled"):
            return "done", "it was disabled before migrate_v2"
        if c.sys.task_state(c.task) != "Disabled":
            return "done", "already enabled"
        ok, msg = c.sys.task_enable(c.task, True)
        return ("reverted" if ok else "failed"), msg or "enabled"


class RepointTask(Step):
    name, optin = "repoint-task", "repoint_task"

    @staticmethod
    def target(c: Ctx, cur: dict | None) -> dict:
        exe = ((cur or {}).get("Execute") or "").strip().strip('"')
        if not exe.lower().endswith("pythonw.exe"):
            exe = str(Path(sys.executable).with_name("pythonw.exe"))
        return {"Execute": exe, "Arguments": SUPERVISE_ARGS, "WorkingDirectory": str(c.repo_a)}

    @staticmethod
    def same(a: dict | None, b: dict | None) -> bool:
        def key(x):
            return tuple(str((x or {}).get(k) or "").strip().strip('"').casefold()
                         for k in ("Execute", "Arguments", "WorkingDirectory"))
        return a is not None and b is not None and key(a) == key(b)

    def check(self, c):
        cur = c.sys.task_action(c.task)
        if cur is None:
            return "n/a", f"task {c.task} not found"
        t = self.target(c, cur)
        if self.same(cur, t):
            return "done", f"{c.task} runs supervise"
        return "todo", (f"{cur.get('Execute')} {cur.get('Arguments')} -> {t['Execute']} {t['Arguments']} "
                        f"(in {t['WorkingDirectory']})")

    def apply(self, c):
        cur = c.sys.task_action(c.task)
        t = self.target(c, cur)
        ok, msg = c.sys.task_set_action(c.task, t)
        return ok, msg or "repointed (task state unchanged)", {"before": cur, "after": t}

    def revert(self, c, d):
        cur = c.sys.task_action(c.task)
        if self.same(cur, d.get("before")):
            return "done", "already the old action"
        if not self.same(cur, d.get("after")) and not c.force:
            return "conflict", "task action changed after migrate_v2 (--force to restore anyway)"
        ok, msg = c.sys.task_set_action(c.task, d["before"])
        return ("reverted" if ok else "failed"), msg or "old action restored"


class FileEdit(Step):
    rel = ""

    def new_text(self, c: Ctx, old: str) -> str:
        raise NotImplementedError

    def _new(self, c: Ctx) -> tuple[Path, bytes | None, bytes]:
        p = c.df / self.rel
        old = _read(p)
        new = self.new_text(c, (old or b"").decode("utf-8", "surrogateescape"))
        return p, old, new.encode("utf-8", "surrogateescape")

    def check(self, c):
        p, old, new = self._new(c)
        if old == new:
            return "done", f"{self.rel} is up to date"
        was = set(_commands((old or b"").decode("utf-8", "replace")))
        now = set(_commands(new.decode("utf-8", "replace")))
        diff = [f"-{x}" for x in sorted(was - now)] + [f"+{x}" for x in sorted(now - was)]
        return "todo", f"{self.rel}: " + ("  ".join(diff) or "comments only")

    def apply(self, c):
        p, old, new = self._new(c)
        bk = None
        if old is not None:
            bk = c.archive / "migrate_v2" / f"{p.name}.{int(c.clock())}.orig"
            n = 1
            while bk.exists():
                bk, n = bk.with_name(f"{p.name}.{int(c.clock())}-{n}.orig"), n + 1
            _write_atomic(bk, old)
        _write_atomic(p, new)
        return True, f"wrote {self.rel}" + (f" (original: {c.rel(bk)})" if bk else " (new file)"), \
            {"file": self.rel, "backup": c.rel(bk) if bk else None, "before": _sha(old), "after": _sha(new)}

    def revert(self, c, d):
        p = c.df / d["file"]
        cur = _sha(_read(p))
        if cur == d["before"]:
            return "done", f"{d['file']} is already the original"
        if cur != d["after"] and not c.force:
            return "conflict", f"{d['file']} changed after migrate_v2 (--force to restore anyway)"
        if d["backup"] is None:
            p.unlink(missing_ok=True)
            return "reverted", f"removed {d['file']} (did not exist before)"
        _write_atomic(p, (c.df / d["backup"]).read_bytes())
        return "reverted", f"restored {d['file']} from {d['backup']}"


class ScriptPaths(FileEdit):
    name, rel = "script-paths", os.path.join("dfhack-config", "script-paths.txt")

    def new_text(self, c, old):
        nl = "\r\n" if "\r\n" in old else "\n"
        a_line, na, nb = "+" + str(c.repo_a / "lua"), _norm(str(c.repo_a / "lua")), _norm(str(c.repo_b / "lua"))
        out, have_a = [], False
        for ln in old.splitlines():
            s = ln.strip()
            t = _norm(s[1:] if s[:1] in "+-" else s) if s and not s.startswith("#") else None
            if t in (na, nb):                     # repo B line -> repo A line; keep a single repo A line
                if not have_a:
                    out.append(a_line)
                    have_a = True
                continue
            out.append(ln)
        if not have_a:
            out.append(a_line)
        return nl.join(out) + nl


class OnMapLoad(FileEdit):
    name, rel = "onmapload-init", os.path.join("dfhack-config", "init", "onMapLoad.init")

    def new_text(self, c, old):
        if _commands(old) == ["dfllm boot"]:
            return old
        return ONMAPLOAD_TEXT.replace("\n", "\r\n") if "\r\n" in old else ONMAPLOAD_TEXT


class Move(Step):
    def __init__(self, name: str, src: str, dst: str | None = None, optin: str | None = None):
        self.name, self.src, self.dst, self.optin = name, src, dst, optin

    def paths(self, c: Ctx) -> tuple[Path, Path]:
        return c.df / self.src, (c.df / self.dst) if self.dst else c.archive / self.src

    def check(self, c):
        s, d = self.paths(c)
        if s.exists() and d.exists():
            return "blocked", f"both {c.rel(s)} and {c.rel(d)} exist"
        if s.exists():
            return "todo", f"move {c.rel(s)} -> {c.rel(d)}"
        if d.exists():
            return "done", f"already in {c.rel(d)}"
        return "n/a", f"{c.rel(s)} not present"

    def apply(self, c):
        s, d = self.paths(c)
        d.parent.mkdir(parents=True, exist_ok=True)
        os.rename(s, d)                            # same volume: a rename, nothing is copied or deleted
        return True, f"moved to {c.rel(d)}", {"src": c.rel(s), "dst": c.rel(d)}

    def revert(self, c, d):
        s, a = c.df / d["src"], c.df / d["dst"]
        if s.exists() and a.exists():
            return "conflict", f"both {d['src']} and {d['dst']} exist"
        if s.exists():
            return "done", f"{d['src']} is already back"
        if not a.exists():
            return "failed", f"{d['dst']} is missing"
        s.parent.mkdir(parents=True, exist_ok=True)
        os.rename(a, s)
        return "reverted", f"moved back to {d['src']}"


def all_steps() -> list[Step]:
    plug = [Move(f"plugin-{p}", f"hack/plugins/{p}.plug.dll", f"hack/plugins/_disabled/{p}.plug.dll", "plugins")
            for p in PLUGINS]
    return [StopProcs(), DisableTask(), RepointTask(), ScriptPaths(), OnMapLoad(),
            Move("archive-claude-scripts", "hack/scripts/claude"),
            Move("archive-v1-runtime", "df-llm-helper-runtime")] + plug


# ---------------------------------------------------------------- journal, runner
def load_journal(c: Ctx) -> dict:
    try:
        j = json.loads(c.journal.read_text(encoding="utf-8"))
        if isinstance(j, dict) and isinstance(j.get("entries"), list):
            return j
    except (OSError, ValueError):
        pass
    return {"v": 2, "tool": "migrate_v2", "entries": []}


def save_journal(c: Ctx, j: dict) -> None:
    _write_atomic(c.journal, json.dumps(j, ensure_ascii=False, indent=1).encode("utf-8"))


def migrate(c: Ctx, apply: bool, optins: set[str]) -> int:
    steps = [s for s in all_steps() if s.optin is None or s.optin in optins]
    skipped = [s for s in all_steps() if s.optin is not None and s.optin not in optins]
    c.out(f"migrate_v2: {'APPLY' if apply else 'DRY RUN (nothing changes; --apply to migrate, --revert to undo)'}")
    c.out(f"  DF {c.df}\n  repo A {c.repo_a}\n  repo B {c.repo_b}")
    if apply:
        running = c.sys.df_running()
        if running is not False and not c.force:
            c.out("REFUSED: Dwarf Fortress is running (or its state is unknown); close it or pass --force")
            return 2
    j = load_journal(c) if apply else None
    count: dict[str, int] = {}
    bad = 0
    for i, s in enumerate(steps, 1):
        st, detail = s.check(c)
        line = f"[{i}/{len(steps)}] {s.name}: {st} - {detail}"
        if apply and st == "todo":
            try:
                ok, msg, data = s.apply(c)
            except OSError as e:
                ok, msg, data = False, f"{type(e).__name__}: {e}", None
            line += f"\n      -> {'ok' if ok else 'FAILED'}: {msg}"
            st = "applied" if ok else "failed"
            if ok:
                j["entries"].append({"step": s.name, "wall": int(c.clock()), "data": data, "reverted": None})
                save_journal(c, j)
        elif not apply and st == "todo":
            line += "\n      -> would apply"
        bad += st in ("failed", "blocked")
        count[st] = count.get(st, 0) + 1
        c.out(line)
    if skipped:
        c.out("opt-in, not selected: " + ", ".join(f"{s.name} (--{s.optin.replace('_', '-')})" for s in skipped))
    c.out("summary: " + ", ".join(f"{n} {k}" for k, n in sorted(count.items())))
    return 1 if bad else 0


def revert(c: Ctx) -> int:
    j = load_journal(c)
    todo = [e for e in reversed(j["entries"]) if not e.get("reverted")]
    c.out(f"migrate_v2: REVERT {len(todo)} applied step(s) from {c.rel(c.journal)}")
    if not todo:
        c.out("nothing to revert")
        return 0
    running = c.sys.df_running()
    if running is not False and not c.force:
        c.out("REFUSED: Dwarf Fortress is running (or its state is unknown); close it or pass --force")
        return 2
    by_name = {s.name: s for s in all_steps()}
    bad = 0
    for i, e in enumerate(todo, 1):
        s = by_name.get(e["step"])
        try:
            st, detail = s.revert(c, e["data"]) if s else ("failed", "unknown step")
        except OSError as ex:
            st, detail = "failed", f"{type(ex).__name__}: {ex}"
        if st in ("reverted", "done", "manual"):
            e["reverted"] = int(c.clock())
            save_journal(c, j)
        bad += st in ("conflict", "failed")
        c.out(f"[{i}/{len(todo)}] {e['step']}: {st} - {detail}")
    return 1 if bad else 0


def main(argv: list[str] | None = None, ctx: Ctx | None = None) -> int:
    ap = argparse.ArgumentParser(prog="migrate_v2", description="Migrate the DF install from v1 to df-llm-helper v2: "
                                 "dry run by default, idempotent, reversible with --revert.")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--apply", action="store_true", help="change the install (default: dry run)")
    g.add_argument("--revert", action="store_true", help="undo the journaled steps")
    ap.add_argument("--force", action="store_true", help="run although DF runs; restore files edited since")
    ap.add_argument("--plugins", action="store_true", help="also move automelt/channel-safely/confirm DLLs")
    ap.add_argument("--repoint-task", action="store_true", help="also point DF-Aufsicht at dfllm supervise --once")
    ap.add_argument("--df", default=os.environ.get("DFLLM_DF") or DEFAULT_DF)
    ap.add_argument("--repo-a", default=str(REPO_A))
    ap.add_argument("--repo-b", default=str(REPO_A.parent / "dwarf-fortress"))
    ap.add_argument("--task", default=TASK)
    a = ap.parse_args(argv)
    if ctx is None:
        if hasattr(sys.stdout, "reconfigure"):
            sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        ctx = Ctx(df=Path(a.df), repo_a=Path(a.repo_a), repo_b=Path(a.repo_b), task=a.task)
    ctx.force = a.force
    if a.revert:
        return revert(ctx)
    return migrate(ctx, a.apply, {k for k in ("plugins", "repoint_task") if getattr(a, k)})


if __name__ == "__main__":
    sys.exit(main())
