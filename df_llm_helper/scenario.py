"""F12 scenario runner: replays scenarios/*.jsonl step by step (collector -> guard -> autopilot -> digest
-> runbook diagnosis), deterministic (FakeClock, fixed seeds, temporary tools/ directory).

Scenario lines: {"meta": {...}} | {"t": n, "cmd": ..., "stdout": ...} | {"t": n, "fs": {file: {age_min, content}|null}}
                 | {"t": n, "gamelog": [lines]}
"""
from __future__ import annotations

import os
import random
import shutil
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

from .client import ReplayClient, load_records
from .clock import FakeClock
from .config import Config, load_config
from .pilot import Pilot
from .runbooks import diagnose, load_runbooks
from .store import Store

__all__ = ["StepResult", "ScenarioResult", "run_scenario", "check_expectations"]


@dataclass
class StepResult:
    t: int
    digest: str
    commands: list
    guard_kinds: list
    actions: list
    diagnose: list
    events: list


@dataclass
class ScenarioResult:
    meta: dict
    steps: list = field(default_factory=list)
    tools_dir: Path | None = None
    files_after: dict = field(default_factory=dict)
    flags_after: list = field(default_factory=list)

    @property
    def all_commands(self) -> list:
        return [c for s in self.steps for c in s.commands]

    def digest_text(self) -> str:
        return "\n".join(s.digest for s in self.steps)


def _apply_fs(tools: Path, fs: dict, clock: FakeClock) -> None:
    for name, spec in fs.items():
        p = tools / name
        if spec is None:
            if p.exists():
                p.unlink()
            continue
        if "content" in spec:
            p.write_text(spec["content"], encoding="utf-8")
        elif not p.exists():
            p.write_text("", encoding="utf-8")
        t = clock.now().epoch - float(spec.get("age_min", 0)) * 60
        os.utime(p, (t, t))


def run_scenario(path: Path, *, cfg_overrides: dict | None = None, data_dir: Path | None = None,
                 step_seconds: float = 60.0, keep_dir: bool = False) -> ScenarioResult:
    meta, recs = load_records(path)
    random.seed(meta.get("seed", 0))
    tmp = Path(tempfile.mkdtemp(prefix="df_llm_helper_sc_"))
    tools = tmp / "tools"
    (tools / "scopes").mkdir(parents=True)
    gamelog = tmp / "gamelog.txt"
    gamelog.write_text("", encoding="utf-8")
    over = {"paths": {"tools": str(tools), "scopes": str(tools / "scopes"), "state_db": ":memory:",
                      "gamelog": str(gamelog), "exceptions": str(tmp / "exceptions.jsonl")}}
    if data_dir:
        over["paths"]["data"] = str(data_dir)
    cfg = load_config(path=tmp / "none.yaml", overrides=over)
    if cfg_overrides:
        cfg = Config(load_config(path=tmp / "none.yaml", overrides={**over, **cfg_overrides}).data)
    clock = FakeClock(1_790_840_000.0)
    client = ReplayClient([r for r in recs if "cmd" in r], clock=clock)
    pilot = Pilot(cfg, client, store=Store(":memory:"), clock=clock)
    rbs = load_runbooks(Path(cfg.get("paths.data")) / "runbooks")
    steps = sorted({r["t"] for r in recs if "t" in r})
    res = ScenarioResult(meta=meta, tools_dir=tools)
    try:
        for t in steps:
            client.set_step(t)
            for r in recs:
                if r.get("t") != t:
                    continue
                if "fs" in r:
                    _apply_fs(tools, r["fs"], clock)
                if "gamelog" in r:
                    with gamelog.open("a", encoding="utf-8") as f:
                        f.write("\n".join(r["gamelog"]) + "\n")
            n_calls = len(client.calls)
            ev_before = len(pilot.tools.events_lines(10000))
            rep = pilot.cycle()
            cmds = [c for c in client.calls[n_calls:] if c not in pilot.commands()]
            ctx = pilot.context(rep.snapshot)
            hits = [h.runbook.id for h in diagnose(rbs, ctx)]
            res.steps.append(StepResult(t, rep.digest, cmds, [a.kind for a in rep.guard],
                                        [a.line() for a in rep.actions], hits,
                                        pilot.tools.events_lines(10000)[ev_before:]))
            clock.advance(step_seconds)
        for name in ("last-report-id.txt", "heartbeat.txt", "events.log"):
            p = tools / name
            if p.exists():
                res.files_after[name] = p.read_text(encoding="utf-8")
        res.flags_after = sorted(pilot.tools.flags())
    finally:
        if not keep_dir:
            shutil.rmtree(tmp, ignore_errors=True)
    return res


def check_expectations(res: ScenarioResult) -> list[str]:
    """Checks meta.expect; returns the list of violations (empty = passed)."""
    exp = res.meta.get("expect", {})
    errs = []
    allc = res.all_commands
    dig = res.digest_text()
    for c in exp.get("commands_include", []):
        if c not in allc:
            errs.append(f"Command missing: {c!r} (executed: {allc})")
    for c in exp.get("commands_exclude", []):
        if any(x.startswith(c) for x in allc):
            errs.append(f"Command must not occur: {c!r}")
    for c in exp.get("commands_include_step0", []):
        if c not in res.steps[0].commands:
            errs.append(f"Command missing in step 0 (1 cycle): {c!r} (step 0: {res.steps[0].commands})")
    for s in exp.get("digest_contains", []):
        if s not in dig:
            errs.append(f"Digest does not contain {s!r}")
    for s in exp.get("digest_contains_step1", []):
        if len(res.steps) < 2 or s not in res.steps[1].digest:
            errs.append(f"Digest step 1 does not contain {s!r}")
    for s in exp.get("warn_contains", []):
        if s not in dig:
            errs.append(f"Warning missing in digest: {s!r}")
    for k in exp.get("guard_kinds_step0", []):
        if k not in res.steps[0].guard_kinds:
            errs.append(f"Guard action {k!r} missing in step 0")
    for name, content in exp.get("file_after", {}).items():
        if res.files_after.get(name, "").strip() != content:
            errs.append(f"File {name}: expected {content!r}, got {res.files_after.get(name)!r}")
    ev = "\n".join(e for s in res.steps for e in s.events)
    for s in exp.get("events_contains", []):
        if s not in ev:
            errs.append(f"events.log does not contain {s!r}")
    for f in exp.get("flag_exists_after", []):
        if f not in res.flags_after:
            errs.append(f"Flag {f} missing at the end")
    hits = {h for s in res.steps for h in s.diagnose}
    for rb in exp.get("diagnose_includes", []):
        if rb not in hits:
            errs.append(f"Runbook {rb} not diagnosed (hits: {sorted(hits)})")
    return errs
