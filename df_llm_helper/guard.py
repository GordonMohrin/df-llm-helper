"""F8 guard: deadman (heartbeat), tempo governor, watcher self-check, flags.

Pure state machine decide(inputs, state, cfg) -> (actions, new state). Execution: GuardRunner.
The governor NEVER makes the game faster (exception: return to normal fps after the deadman ends).
"""
from __future__ import annotations

import shutil
import subprocess
import sys
from dataclasses import asdict, dataclass, field
from typing import Any

from .rules import SET_FPS_CMD

__all__ = ["GuardInputs", "GuardState", "GuardAction", "decide", "GuardRunner", "ProcessProbe",
           "snapshot_unreadable"]


@dataclass
class GuardInputs:
    heartbeat_age_min: float | None = None
    last_report_id: int | None = None
    max_report_id: int | None = None
    events_size: int | None = None
    events_age_min: float | None = None
    guard_running: bool | None = None
    drink_days: int | None = None
    food_days: int | None = None
    danger: bool = False
    moods: int = 0
    caravan_active: bool = False
    pop: int | None = None
    timestream: bool | None = None
    fps: float | None = None
    normal_fps: float | None = None
    paused: bool | None = None
    stale_flags: list = field(default_factory=list)
    no_data: bool = False           # BUG-106: game state unreadable (claude/status failed) -> fail closed
    stale_hold: str = ""            # BUG-224: warning text of a stale pause.hold ('' = none)
    stale_hold_key: str = ""        # reason + write time of that hold (reported once per hold)


@dataclass
class GuardState:
    slowed: bool = False
    supply_low: bool = False
    lag_cycles: int = 0
    last_max_report_id: int | None = None
    guard_down_reported: bool = False
    events_stale_reported: bool = False
    gates_acked: list = field(default_factory=list)
    gates_hit: list = field(default_factory=list)
    blind_resets: int = 0
    no_heartbeat_reported: bool = False
    tempo_off_pending: int = 0
    normal_fps_seen: float | None = None       # last known NORMAL_FPS from claude/config (for the end of the deadman)
    stale_hold_reported: str = ""               # BUG-224: key of the stale pause.hold already reported

    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, d: dict | None) -> "GuardState":
        if not d:
            return cls()
        known = {k: v for k, v in d.items() if k in cls.__dataclass_fields__}
        return cls(**known)


@dataclass
class GuardAction:
    kind: str           # set_fps | tempo_off | reset_report_id | event | warn
    value: Any = None
    level: str = "info"  # info | warn | crit
    reason: str = ""

    def line(self) -> str:
        return f"{self.kind}={self.value} ({self.reason})" if self.value is not None else f"{self.kind} ({self.reason})"


def snapshot_unreadable(snap) -> bool:
    """True if the game state could not be read (no snapshot, claude/status failed or no population): decisions that
    need the game state must then refuse instead of treating missing values as 'all fine' (BUG-106)."""
    if snap is None:
        return True
    if any(str(f).startswith("claude/status") for f in (getattr(snap, "failed", None) or [])):
        return True
    return getattr(snap, "pop_total", None) is None


def tempo_blockers(inp: GuardInputs, st: GuardState, g: dict) -> list[str]:
    reasons = []
    if inp.no_data:
        reasons.append("no_data")
    if st.slowed:
        reasons.append("deadman")
    if inp.danger:
        reasons.append("danger")
    if inp.moods:
        reasons.append("mood")
    if inp.caravan_active:
        reasons.append("caravan")
    if st.supply_low:
        reasons.append("supplies")
    if inp.heartbeat_age_min is None or inp.heartbeat_age_min > g["agents_active_min"]:
        reasons.append("no_supervision")
    for gate in g.get("pop_gates", []):
        if inp.pop is not None and inp.pop >= gate and gate not in st.gates_acked:
            reasons.append(f"pop_gate_{gate}")
    return reasons


def decide(inp: GuardInputs, state: GuardState, g: dict) -> tuple[list[GuardAction], GuardState]:
    """g = cfg['guard']. Deterministic, without side effects."""
    st = GuardState.from_dict(state.to_dict())
    acts: list[GuardAction] = []
    if inp.normal_fps:
        st.normal_fps_seen = inp.normal_fps
    normal = inp.normal_fps or st.normal_fps_seen or g["normal_fps"]

    # (a) deadman with hysteresis
    hb = inp.heartbeat_age_min
    if hb is None:
        if not st.no_heartbeat_reported:
            acts.append(GuardAction("warn", None, "warn", "heartbeat.txt missing: the orchestrator should call 'python -m df_llm_helper heartbeat'"))
            st.no_heartbeat_reported = True
    else:
        st.no_heartbeat_reported = False
        if hb > g["heartbeat_slow_min"] and not st.slowed:
            st.slowed = True
            acts.append(GuardAction("set_fps", g["slow_fps"], "crit", f"DEADMAN: no heartbeat for {int(hb)} min"))
            acts.append(GuardAction("event", f"DEADMAN: no orchestrator heartbeat for {int(hb)} min -> fps {g['slow_fps']}",
                                    "crit", "deadman"))
        elif st.slowed and hb < g["heartbeat_ok_min"]:
            st.slowed = False
            acts.append(GuardAction("set_fps", int(normal), "info", "heartbeat is back"))
            acts.append(GuardAction("event", f"Heartbeat is back -> fps {int(normal)}", "info", "deadman_ende"))
        elif st.slowed and inp.fps is not None and inp.fps > g["slow_fps"]:
            acts.append(GuardAction("set_fps", g["slow_fps"], "warn", "deadman active, fps was raised"))

    # (c) watcher self-check: last-report-id
    last, mx = inp.last_report_id, inp.max_report_id
    if last is not None and mx is not None and mx >= 0:
        if last > mx:
            st.blind_resets += 1
            acts.append(GuardAction("reset_report_id", mx, "crit",
                                    f"Watcher blind: last-report-id {last} > highest report {mx} (new game?)"))
            acts.append(GuardAction("event", f"Watcher blind: last-report-id {last} > max {mx} -> set to {mx}; "
                                             f"restart the watcher (python -m df_llm_helper waechter)", "crit", "blind"))
            st.lag_cycles = 0
        elif mx - last > g["report_lag_crit"]:
            st.lag_cycles += 1
            if st.lag_cycles == 2:
                acts.append(GuardAction("warn", None, "crit", f"Watcher is not reading reports: {mx - last} unread "
                                                              f"(2 cycles). Check/restart python -m df_llm_helper waechter"))
        else:
            st.lag_cycles = 0
    st.last_max_report_id = mx if mx is not None else st.last_max_report_id

    # watcher process
    if inp.guard_running is False:
        if not st.guard_down_reported:
            acts.append(GuardAction("warn", None, "crit", "Watcher is not running: "
                                    "start python -m df_llm_helper waechter --loop (replaces unpause-guard.ps1)"))
            st.guard_down_reported = True
    elif inp.guard_running is True:
        st.guard_down_reported = False

    # is events.log growing?
    if inp.events_size is None:
        if not st.events_stale_reported:
            acts.append(GuardAction("warn", None, "warn", "tools/events.log missing (watcher is not writing)"))
            st.events_stale_reported = True
    elif inp.events_age_min is not None and inp.events_age_min > g["events_stale_min"] and inp.paused is False:
        if not st.events_stale_reported:
            acts.append(GuardAction("warn", None, "warn", f"events.log unchanged for {int(inp.events_age_min)} min "
                                                          f"while the game is running"))
            st.events_stale_reported = True
    else:
        st.events_stale_reported = False

    # (b) tempo governor, supplies with hysteresis
    days = [d for d in (inp.drink_days, inp.food_days) if d is not None]
    if days:
        low = min(days)
        if not st.supply_low and low < g["tempo_supply_days"]:
            st.supply_low = True
        elif st.supply_low and low >= g["tempo_supply_days"] + g["tempo_supply_hyst"]:
            st.supply_low = False
    for gate in g.get("pop_gates", []):
        if inp.pop is not None and inp.pop >= gate and gate not in st.gates_hit:
            st.gates_hit.append(gate)
            acts.append(GuardAction("warn", None, "crit", f"Pop gate {gate} reached: check guard/armor/alarm drill, "
                                                         f"then 'python -m df_llm_helper guard ack-gate {gate}'"))
    blockers = tempo_blockers(inp, st, g)
    if inp.timestream and blockers:
        n = st.tempo_off_pending
        st.tempo_off_pending += 1
        if n % 5 == 0:   # again only after 5 cycles (no flapping)
            acts.append(GuardAction("tempo_off", "off", "warn" if n == 0 else "info",
                                    "Time lapse off: " + ", ".join(blockers)))
            acts.append(GuardAction("event", "Time lapse off (" + ", ".join(blockers) + ")", "info", "governor"))
        if n == 2:
            acts.append(GuardAction("warn", None, "crit", "claude/tempo off has no effect (timestream still on): "
                                                          "check claude/tempo status"))
    else:
        st.tempo_off_pending = 0

    # BUG-224: a pause.hold nobody needs any more freezes the game silently -> one critical warning per hold
    if inp.stale_hold:
        if st.stale_hold_reported != inp.stale_hold_key:
            st.stale_hold_reported = inp.stale_hold_key
            acts.append(GuardAction("warn", None, "crit", inp.stale_hold))
            acts.append(GuardAction("event", inp.stale_hold, "crit", "stale_hold"))
    else:
        st.stale_hold_reported = ""

    # (d) report stale flags (the autopilot deletes them)
    if inp.stale_flags:
        acts.append(GuardAction("info", ",".join(inp.stale_flags), "info", "stale flags"))
    return acts, st


def target_fps(st: GuardState, inp: GuardInputs, g: dict) -> int:
    return int(g["slow_fps"]) if st.slowed else int(inp.normal_fps or g["normal_fps"])


class ProcessProbe:
    """Checks whether the PowerShell watcher is running. None = unknown (e.g. Linux test). Not tested live."""

    def __init__(self, pattern: str = "unpause-guard"):
        self.pattern = pattern

    def running(self) -> bool | None:
        try:
            if sys.platform.startswith("win"):
                ps = shutil.which("powershell") or "powershell"
                out = subprocess.run([ps, "-NoProfile", "-Command",
                                      "Get-CimInstance Win32_Process | Select-Object -ExpandProperty CommandLine"],
                                     capture_output=True, timeout=20).stdout.decode("utf-8", "replace")
            else:
                out = subprocess.run(["ps", "-eo", "args"], capture_output=True, timeout=10).stdout.decode("utf-8", "replace")
            return self.pattern.lower() in out.lower()
        except Exception:
            return None


class GuardRunner:
    """Collects inputs (files + snapshot), decides, executes actions (or dry-run)."""

    def __init__(self, client, store, tools, clock, cfg: dict, probe: ProcessProbe | Any = None):
        self.client, self.store, self.tools, self.clock, self.cfg = client, store, tools, clock, cfg
        self.probe = probe

    def inputs(self, snap) -> GuardInputs:
        size, age = self.tools.events_info()
        stale = [n for n, f in self.tools.flags().items()
                 if f.exists and f.age_min is not None and f.age_min > self.cfg["flags"]["stale_min"]]
        alive = self.tools.path / "out" / "waechter.alive"
        if alive.exists():                       # df-llm-helper watcher (replaces unpause-guard.ps1)
            age = self.tools.age_min(alive)
            running = age is not None and age < float(self.cfg["guard"].get("waechter_dead_min", 2))
        else:
            running = self.probe.running() if self.probe is not None else None
        from . import holds as hl
        hc = self.cfg.get("holds") if hasattr(self.cfg, "get") else None
        sh = hl.stale_hold(self.tools, self.store, danger=bool(snap.danger) if snap is not None else False, cfg=hc)
        sh_text = hl.stale_text(sh, getattr(snap, "paused", None)) if sh is not None else ""
        sh_key = ""
        if sh is not None:
            try:
                sh_key = f"{sh.reason}@{int(self.tools.flag_path('pause.hold').stat().st_mtime)}"
            except OSError:
                sh_key = sh.reason
        return GuardInputs(
            stale_hold=sh_text, stale_hold_key=sh_key,
            heartbeat_age_min=self.tools.heartbeat_age_min(), last_report_id=self.tools.last_report_id(),
            max_report_id=snap.max_report_id if snap is not None else None, events_size=size, events_age_min=age,
            guard_running=running,
            drink_days=getattr(snap, "drink_days", None), food_days=getattr(snap, "food_days", None),
            danger=bool(snap.danger) if snap is not None else False,
            moods=len(snap.alerts.moods_active) if snap is not None else 0,
            caravan_active=bool(snap.caravan_active) if snap is not None else False,
            pop=getattr(snap, "pop_total", None), timestream=getattr(snap, "timestream", None),
            fps=getattr(snap, "fps", None), normal_fps=getattr(snap, "normal_fps", None),
            paused=getattr(snap, "paused", None), stale_flags=sorted(stale), no_data=snapshot_unreadable(snap))

    def cycle(self, snap, *, dry_run: bool = False) -> tuple[list[GuardAction], GuardState, dict]:
        g = self.cfg["guard"]
        state = GuardState.from_dict(self.store.get("guard.state"))
        inp = self.inputs(snap)
        acts, new = decide(inp, state, g)
        now = self.clock.now().epoch
        for a in acts:
            cmd = None
            ok = True
            if a.kind == "set_fps":
                cmd = SET_FPS_CMD.format(n=int(a.value))
            elif a.kind == "tempo_off":
                cmd = "claude/tempo off"
            if not dry_run:
                if cmd:
                    ok = self.client.run(cmd).ok
                elif a.kind == "reset_report_id":
                    self.tools.set_last_report_id(int(a.value))
                elif a.kind == "event":
                    self.tools.append_event("CRITICAL" if a.level == "crit" else "info", str(a.value), "HELPER-GUARD")
                if a.kind in ("warn", "set_fps", "reset_report_id", "tempo_off") and a.level in ("warn", "crit"):
                    self.store.warn(now, "guard", f"guard:{a.kind}:{a.reason[:30]}", a.reason, a.level)
            if a.kind == "warn" and not cmd:      # a pure warning is in the warnings table already (BUG-314: no 'warn=None')
                continue
            act = a.kind if a.value is None else f"{a.kind}={a.value}"
            self.store.log_action(now, "guard", "guard", act, a.kind, cmd or "", dry_run, ok, a.reason)
        if not dry_run:
            self.store.set("guard.state", new.to_dict())
        info = {"slowed": new.slowed, "target_fps": target_fps(new, inp, g),
                "timestream_allowed": not tempo_blockers(inp, new, g), "blockers": tempo_blockers(inp, new, g)}
        self.store.set("guard.info", info) if not dry_run else None
        return acts, new, info
