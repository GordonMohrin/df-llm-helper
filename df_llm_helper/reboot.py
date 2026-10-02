"""Spec 09: restart and load runbook (`python -m df_llm_helper reboot`).

After a load/restart the repeat-util permanent jobs no longer run. reboot:
  1. Map loaded? (otherwise wait, at most wait_s; never start services without a map)
  2. Detection 'game loaded': frame_counter drops or report id drops (kv reboot.last)
  3. Check the services from data/services.yaml (one repeat-util query), start missing ones in dependency order
     (preconditions like config first), never start running ones twice
  4. The game stays paused until all mandatory services run, then `claude/advance run`
  5. Status report line 'Restart: N services started' (warning) + action log
Load helper (title menu via findclick.lua) only with reboot.auto_load = true (the player's wish), not tested live.
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path

from . import yamlmini
from .client import register_read

__all__ = ["DEFAULTS", "Service", "load_services", "validate_services", "order_services", "repeat_query",
           "parse_repeat", "STATE_CMD", "Reboot", "load_commands"]

DEFAULTS = {"services_file": "data/services.yaml", "auto_load": False, "wait_s": 20, "poll_s": 2, "auto_in_check": True,
            "findclick": "tools/embark/findclick.lua", "load_texts": ["Continue active game", "autosave 1"]}
STATE_CMD = 'lua "print(tostring(dfhack.isMapLoaded()) .. \' \' .. tostring(df.global.world.frame_counter))"'


@dataclass
class Service:
    name: str
    key: str | None = None
    start: str | None = None
    check: str | None = None
    depends: list = field(default_factory=list)
    kind: str = "service"
    note: str = ""


class ServicesError(ValueError):
    pass


def validate_services(items: list) -> list[str]:
    errs, names = [], set()
    for i, d in enumerate(items):
        if not isinstance(d, dict) or not d.get("name"):
            errs.append(f"Line {i + 1}: name missing")
            continue
        if d["name"] in names:
            errs.append(f"{d['name']}: duplicate")
        names.add(d["name"])
        if not d.get("key") and not d.get("check"):
            errs.append(f"{d['name']}: no check command (key or check)")
        if d.get("start") is None and d.get("kind", "service") == "service" and not d.get("note"):
            errs.append(f"{d['name']}: start missing without justification (note)")
    for d in items:
        for dep in (d.get("depends") or []) if isinstance(d, dict) else []:
            if dep not in names:
                errs.append(f"{d.get('name')}: unknown dependency {dep}")
    return errs


def load_services(path: Path) -> list[Service]:
    d = yamlmini.load_file(path) or {}
    items = d.get("services") or []
    errs = validate_services(items)
    if errs:
        raise ServicesError(f"{path}: " + "; ".join(errs))
    return order_services([Service(**{k: v for k, v in x.items() if k in Service.__dataclass_fields__}) for x in items])


def order_services(svcs: list[Service]) -> list[Service]:
    """Topological by depends, otherwise file order; cycle -> ServicesError."""
    by = {s.name: s for s in svcs}
    out, state = [], {}

    def visit(s: Service, stack: list):
        if state.get(s.name) == 2:
            return
        if state.get(s.name) == 1:
            raise ServicesError("Cycle: " + " -> ".join(stack + [s.name]))
        state[s.name] = 1
        for d in s.depends:
            visit(by[d], stack + [s.name])
        state[s.name] = 2
        out.append(s)
    for s in svcs:
        visit(s, [])
    return out


def repeat_query(svcs: list[Service]) -> str:
    keys = ",".join(f"'{s.key}'" for s in svcs if s.key)
    return ('lua "local r=require(\'repeat-util\') local t={} for _,k in ipairs({' + keys
            + '}) do t[#t+1]=k..\'=\'..tostring(r.isScheduled(k)) end print(table.concat(t,\' \'))"')


def parse_repeat(text: str) -> dict:
    return {k: v == "true" for k, v in re.findall(r"([\w-]+)=(true|false)", text or "")}


def load_commands(cfg: dict) -> list[str]:
    """Title menu: 'Continue active game' -> click the save (text from load_texts)."""
    return [f'lua -f {cfg["findclick"]} "{t}"' for t in cfg["load_texts"]]


class Reboot:
    def __init__(self, client, store, clock, cfg: dict, home: Path):
        self.client, self.store, self.clock = client, store, clock
        self.cfg = {**DEFAULTS, **(cfg or {})}
        self.services = load_services(home / self.cfg["services_file"])
        register_read(STATE_CMD)
        register_read(repeat_query(self.services))

    def state(self) -> tuple[bool | None, int | None]:
        r = self.client.run(STATE_CMD)
        m = re.search(r"(true|false)\s+(\d+)", r.stdout or "") if r.ok else None
        if not m:
            return None, None
        return m.group(1) == "true", int(m.group(2))

    def detect_loaded(self, frame: int | None, report_id: int | None) -> bool:
        """frame_counter or report id dropped compared to the last run -> save was reloaded."""
        last = self.store.get("reboot.last") or {}
        loaded = (frame is not None and last.get("frame") is not None and frame < last["frame"]) or \
                 (report_id is not None and last.get("report") is not None and report_id < last["report"])
        self.store.set("reboot.last", {"frame": frame if frame is not None else last.get("frame"),
                                       "report": report_id if report_id is not None else last.get("report")})
        return bool(loaded)

    def running(self) -> dict:
        r = self.client.run(repeat_query(self.services))
        return parse_repeat(r.stdout if r.ok else "")

    def _wait_map(self) -> bool:
        waited = 0.0
        while True:
            loaded, _ = self.state()
            if loaded:
                return True
            if waited >= self.cfg["wait_s"]:
                return False
            self.clock.sleep(self.cfg["poll_s"])
            waited += self.cfg["poll_s"]

    def run(self, *, dry: bool = False) -> list[str]:
        now = self.clock.now().epoch
        if not self._wait_map():
            return [f"Restart: map not loaded (after {self.cfg['wait_s']} s) - no services started, try again later"]
        run = self.running()
        missing = [s for s in self.services if s.key and s.start and not run.get(s.key)]
        manual = [s for s in self.services if s.key and not s.start and not run.get(s.key)]
        out = []
        if not missing:
            out.append(f"Restart: all {sum(1 for s in self.services if s.key and s.start)} services running")
            out += [f"{s.name} off: {s.note}" for s in manual]
            return out
        log = []

        def do(cmd: str, what: str) -> bool:
            if dry:
                log.append("[dry] " + cmd)
                return True
            r = self.client.run(cmd)
            self.store.log_action(now, "reboot", "reboot", what, "service", cmd, False, r.ok, "after load")
            log.append(("ok " if r.ok else "ERROR ") + cmd)
            return r.ok
        do("claude/advance 0", "pause")
        failed_pre = []
        for s in self.services:                       # preconditions first (order = dependencies)
            if s.kind == "precondition" and s.check:
                r = self.client.run(s.check)
                if not r.ok:
                    failed_pre.append(s.name)
        if failed_pre:
            out.append(f"Restart: precondition missing ({', '.join(failed_pre)}) - services NOT started, game paused")
            if not dry:
                self.store.warn(now, "reboot", "reboot:pre", out[-1], "crit")
            return out + log
        started = []
        for s in self.services:
            if s in missing:
                if do(s.start, s.name):
                    started.append(s.name)
        after = run if dry else self.running()
        still = [s.name for s in missing if not dry and not after.get(s.key)]
        if still:
            out.append(f"Restart: {len(started)} services started, NOT running: {', '.join(still)} - game stays paused")
            if not dry:
                self.store.warn(now, "reboot", "reboot:fail", out[-1], "crit")
        else:
            do("claude/advance run", "run")
            out.append(f"Restart (dry run): would start {len(started)} services ({', '.join(started)}) - nothing started"
                       if dry else f"Restart: {len(started)} services started ({', '.join(started)})")   # BUG-216
            if not dry:
                self.store.warn(now, "reboot", "reboot:ok", out[-1], "warn")
        out += [f"{s.name} off: {s.note}" for s in manual]
        return out + log
