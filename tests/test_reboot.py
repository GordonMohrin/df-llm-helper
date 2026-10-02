"""Spec 09 restart: service list, order, idempotence, waiting for the map, detection, load helper."""
from pathlib import Path

import pytest

from conftest import FIX
from dfpilot import yamlmini
from dfpilot.client import MockClient, SERVICES_CMD
from dfpilot.clock import FakeClock
from dfpilot.config import HOME
from dfpilot.reboot import (DEFAULTS, STATE_CMD, Reboot, ServicesError, load_commands, load_services,
                            order_services, parse_repeat, repeat_query, validate_services)
from dfpilot.store import Store

SVCS = load_services(HOME / DEFAULTS["services_file"])
Q = repeat_query(SVCS)


class World:
    """Simulates repeat-util: start commands set the key; map loaded only after n queries."""

    def __init__(self, running=(), map_after=0, broken=()):
        self.running = set(running)
        self.map_after = map_after
        self.polls = 0
        self.broken = set(broken)
        self.starts = []

    def client(self, clock):
        m = MockClient({"claude/config": '{"FORT_X": 104}', "claude/advance 0": "{}", "claude/advance run": "{}"},
                       clock=clock)
        m.set(STATE_CMD, self.state)
        m.set(Q, lambda c: " ".join(f"{s.key}={'true' if s.key in self.running else 'false'}" for s in SVCS if s.key))
        for s in SVCS:
            if s.start:
                m.set(s.start, self._starter(s))
        return m

    def state(self, _):
        self.polls += 1
        return f"{'true' if self.polls > self.map_after else 'false'} 123456"

    def _starter(self, s):
        def f(_):
            self.starts.append(s.name)
            if s.name not in self.broken:
                self.running.add(s.key)
            return '{"ok": true}'
        return f


def make(world, cfg=None):
    clock = FakeClock(0)
    m = world.client(clock)
    return Reboot(m, Store(), clock, {**DEFAULTS, **(cfg or {})}, HOME), m, clock


def test_all_stopped_all_running_after_in_dependency_order():
    """Acceptance 1."""
    w = World()
    rb, m, _ = make(w)
    out = rb.run()
    startable = [s for s in SVCS if s.key and s.start]
    assert {s.key for s in startable} <= w.running
    assert out[0].startswith(f"Restart: {len(startable)} services started")
    order = [c for c in m.write_calls]
    assert order[0] == "claude/advance 0" and order[-1] == "claude/advance run"
    assert m.calls.index("claude/config") < m.calls.index("claude/watchdog start")         # config before services
    assert w.starts.index("watchdog") < w.starts.index("ueberwacher")
    assert w.starts.index("watchdog") < w.starts.index("milguard")
    assert "tempo" not in w.starts and any("tempo off" in ln and "decision 6" in ln for ln in out)
    assert len(rb.store.actions()) == len(startable) + 2
    assert any(x["key"] == "reboot:ok" for x in rb.store.take_warnings())


def test_running_services_not_started_twice():
    """Acceptance 2."""
    w = World(running={"claude-watchdog", "claude-arbeit"})
    rb, m, _ = make(w)
    rb.run()
    assert "watchdog" not in w.starts and "arbeit" not in w.starts and "orders" in w.starts
    w.starts.clear()
    out = rb.run()
    assert w.starts == [] and out[0].startswith("Restart: all") and "claude/advance 0" not in m.write_calls[-1:]


def test_waits_for_map_loaded():
    """Acceptance 3: save loaded, map not yet -> wait; start only once isMapLoaded."""
    w = World(map_after=3)
    rb, m, clock = make(w)
    out = rb.run()
    assert w.polls == 4 and clock.now().epoch >= 6 and w.starts and out[0].startswith("Restart:")
    w2 = World(map_after=100)
    rb2, m2, _ = make(w2, {"wait_s": 10})
    out = rb2.run()
    assert "map not loaded" in out[0] and w2.starts == [] and m2.write_calls == []


def test_every_service_has_check_and_validation():
    """Acceptance 4 (self-test)."""
    raw = yamlmini.load_file(HOME / DEFAULTS["services_file"])["services"]
    assert validate_services(raw) == []
    assert all(s.key or s.check for s in SVCS)
    bad = [{"name": "a"}, {"name": "b", "key": "k", "depends": ["zz"]}, {"name": "b", "key": "k2"},
           {"name": "c", "key": "k3", "start": None}]
    errs = validate_services(bad)
    assert any("a: no check command" in e for e in errs) and any("zz" in e for e in errs)
    assert any("duplicate" in e for e in errs) and any("c: start missing" in e for e in errs)
    from dfpilot.reboot import Service
    with pytest.raises(ServicesError):
        order_services([Service("x", "k", "s", depends=["y"]), Service("y", "k2", "s", depends=["x"])])


def test_broken_service_keeps_paused_and_warns():
    w = World(broken={"raster"})
    rb, m, _ = make(w)
    out = rb.run()
    assert "NOT running: raster" in out[0] and "claude/advance run" not in m.write_calls
    assert any(x["key"] == "reboot:fail" and x["level"] == "crit" for x in rb.store.take_warnings())


def test_precondition_config_fails():
    w = World()
    rb, m, _ = make(w)
    m.responses.pop("claude/config")                                # config not readable -> precondition missing
    out = rb.run()
    assert "precondition missing (config)" in out[0] and w.starts == [] and "claude/advance run" not in m.write_calls


def test_detect_loaded_and_parse_and_dry():
    rb, m, _ = make(World())
    assert rb.detect_loaded(1000, 500) is False
    assert rb.detect_loaded(2000, 600) is False
    assert rb.detect_loaded(50, 610) is True                    # frame_counter drops
    assert rb.detect_loaded(60, 3) is True                      # report id drops
    assert rb.detect_loaded(None, None) is False
    assert parse_repeat("claude-watchdog=true claude-x=false") == {"claude-watchdog": True, "claude-x": False}
    assert SERVICES_CMD and Q.startswith('lua "local r=require')
    w = World()
    rb2, m2, _ = make(w)
    out = rb2.run(dry=True)
    assert m2.write_calls == [] and w.starts == [] and any(ln.startswith("[dry] claude/watchdog start") for ln in out)
    assert load_commands(DEFAULTS)[0] == 'lua -f tools/embark/findclick.lua "Continue active game"'


def test_cli_reboot(tmp_path, tools_dir, capsys):
    from dfpilot.cli import main
    c = tmp_path / "c.yaml"
    c.write_text(f"paths:\n  tools: {tools_dir}\n  scopes: {tools_dir / 'scopes'}\n  state_db: {tmp_path / 's.db'}\n"
                 f"  gamelog: {tmp_path / 'g'}\nreboot:\n  wait_s: 0\n", encoding="utf-8")
    assert main(["--config", str(c), "--mock", str(FIX), "reboot", "validate"]) == 0
    assert "all with check command" in capsys.readouterr().out
    assert main(["--config", str(c), "--mock", str(FIX), "reboot", "load"]) == 1
    assert "at the player's request" in capsys.readouterr().out
    main(["--config", str(c), "--mock", str(FIX), "reboot", "--dry-run"])
    assert "map not loaded" in capsys.readouterr().out              # fixture without map state: no start
