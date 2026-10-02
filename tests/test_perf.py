"""Spec v3-03: freeze profiler (df_llm_helper/features/perf.py) + watcher auto detection."""
import json

import pytest

from conftest import HOME
from df_llm_helper.client import MAX_REPORT_ID_CMD, MockClient, ReplayClient, Result
from df_llm_helper.config import DEFAULTS, load_config
from df_llm_helper.features import perf
from df_llm_helper.features.perf import (EXTERNAL, LIST_CMD, PROBE_CMD, Bisect, LatencyMonitor, digest_line, parse_list,
                                   recover, sample, state_path, suggest)
from df_llm_helper.store import Store
from df_llm_helper.toolsfs import ToolsDir
from df_llm_helper.waechter import CARAVANS_CMD, CLEAR_CMD, FOOD_CMD, Waechter

FIXV3 = HOME / "fixtures" / "v3" / "perf"
RUNTIMES = json.loads((FIXV3 / "service_runtimes.json").read_text(encoding="utf-8"))
PROTECTED = perf.DEFAULTS["protected"]


class Game:
    """Mock game: repeat-util services; while the culprit is scheduled the game freezes `freeze` s every `period` s."""

    def __init__(self, clock, keys, culprit=None, period=25.0, freeze=11.0, phase=3.0, rate=30.0):
        self.clock, self.keys = clock, list(keys)
        self.on = set(keys)
        self.culprit, self.period, self.freeze, self.phase, self.rate = culprit, period, freeze, phase, rate
        self.t0 = clock.now().epoch
        self.events: list[tuple[float, str, str]] = []
        self.dead = False                                   # simulated lost connection (crash)

    def probe(self, _cmd):
        if self.dead:
            raise ConnectionError("dfhack-run gone")
        t = self.clock.now().epoch
        lat = 0.05
        if self.culprit in self.on:
            pos = (t - self.t0 + self.phase) % self.period
            if pos < self.freeze:
                lat += self.freeze - pos
        self.clock.advance(lat)
        return Result(True, f"{int((self.clock.now().epoch - self.t0) * self.rate)}\n", elapsed_s=lat)

    def listing(self, _cmd):
        return "S " + " ".join(sorted(self.on))

    def cancel(self, cmd):
        key = cmd.split("cancel('", 1)[1].split("'", 1)[0]
        self.on.discard(key)
        self.events.append((self.clock.now().epoch, "off", key))
        return ""

    def start(self, key):
        def fn(_cmd):
            if self.dead:
                raise ConnectionError("dfhack-run gone")
            self.on.add(key)
            self.events.append((self.clock.now().epoch, "on", key))
            return ""
        return fn

    def off_durations(self) -> dict:
        out, since = {}, {}
        for t, kind, k in self.events:
            if kind == "off":
                since[k] = t
            elif k in since:
                out[k] = max(out.get(k, 0), t - since.pop(k))
        return out


def build(tmp_path, clock, keys, culprit, **kw):
    g = Game(clock, keys, culprit, **kw)
    starts = {k: f"claude/{k.removeprefix('claude-')} start" for k in keys}
    resp = {PROBE_CMD: g.probe, LIST_CMD: g.listing}
    resp.update({c: g.start(k) for k, c in starts.items()})
    m = MockClient(resp, clock=clock)
    m.prefix_handlers.append(('lua "require(\'repeat-util\').cancel(', g.cancel))
    tools = ToolsDir(tmp_path, clock)
    tools.path.mkdir(parents=True, exist_ok=True)
    store = Store()
    b = Bisect(m, tools, store, clock, {}, starts, lua_dir=HOME / "lua" / "claude")
    return b, g, m, tools, store


KEYS20 = [f"claude-svc{i:02d}" for i in range(17)] + PROTECTED


# ---- AC1: latency probe on the replay "raster 11 s every 25 s"
def test_ac1_replay_raster_period_and_max(clock):
    rc = ReplayClient.from_file(FIXV3 / "raster_11s_every_25s.jsonl", clock=clock)
    res = sample(rc, clock, n=40, gap=0.6)
    assert len(res.samples) == 40 and len(res.outliers) >= 2
    assert abs(res.period_s - 25) <= 3
    assert abs(res.max_s - 11) <= 1
    assert res.period_ticks and res.tick_rate
    assert "period 25 s" in res.line()


def test_ac1_simulated_game_sample(tmp_path, clock):
    b, g, m, tools, store = build(tmp_path, clock, ["claude-raster"], "claude-raster")
    res = sample(m, clock, n=40, gap=0.6)
    assert abs(res.period_s - 25) <= 3 and 10 <= res.max_s <= 11.1


def test_sample_without_hang(clock):
    m = MockClient({PROBE_CMD: "123"}, clock=clock)
    res = sample(m, clock, n=5, gap=0.6)
    assert not res.hang and res.period_s is None and "0 outliers" in res.line()


# ---- AC2: bisect over 20 services
@pytest.mark.parametrize("pos", [0, 1, 7, 9, 10, 15, 16])
def test_ac2_bisect_finds_slow_service_in_6_measurements(tmp_path, clock, pos):
    b, g, m, tools, store = build(tmp_path, clock, KEYS20, KEYS20[pos])
    r = b.run()
    assert r.culprit == KEYS20[pos]
    assert r.measurements <= 6
    assert g.on == set(KEYS20) and r.restored                     # everything back on
    assert not state_path(tools).exists()
    assert store.count_actions("perf", "cancel", 0) == store.count_actions("perf", "restart", 0) > 0


def test_ac2_protected_culprit_and_external(tmp_path, clock):
    b, g, m, tools, store = build(tmp_path, clock, KEYS20, "claude-milguard")
    r = b.run()
    assert r.culprit == "claude-milguard" and r.measurements <= 6 and g.on == set(KEYS20)
    b, g, m, tools, store = build(tmp_path / "x", clock, KEYS20, "something-else")
    g.on.add("something-else")                                     # hang source without a start command
    r = b.run()
    assert r.culprit == EXTERNAL and r.measurements <= 6 and "something-else" in r.untestable
    assert g.on >= set(KEYS20)


def test_bisect_without_outliers_switches_nothing_off(tmp_path, clock):
    b, g, m, tools, store = build(tmp_path, clock, KEYS20, None)
    r = b.run()
    assert r.culprit is None and r.measurements == 1 and not [e for e in g.events if e[1] == "off"]


def test_bisect_dry_run_and_protected_only_in_peace(tmp_path, clock):
    b, g, m, tools, store = build(tmp_path, clock, KEYS20, "claude-watchdog")
    r = b.run(dry=True)
    assert "[dry]" in r.lines[0] and not g.events
    tools.write_flag("alert", "goblins")
    r = b.run()
    prot_off = [k for _, kind, k in g.events if kind == "off" and k in PROTECTED]
    assert not prot_off and r.culprit is None and "no test during an alarm" in "\n".join(r.lines)
    assert g.on == set(KEYS20)


def test_bisect_live_keys_with_services_yaml(tmp_path, clock):
    keys = parse_list((FIXV3 / "list_scheduled.txt").read_text(encoding="utf-8"))
    assert len(keys) == 13 and "claude-raster" in keys
    starts = perf._starts(HOME, load_config(path=tmp_path / "none.yaml"))
    assert starts["claude-raster"] == "claude/raster start" and "claude-watchdog-alert" not in starts
    rt = RUNTIMES["claude-raster"]
    g = Game(clock, keys, "claude-raster", period=rt["period_s"], freeze=rt["freeze_s"])
    resp = {PROBE_CMD: g.probe, LIST_CMD: g.listing}
    resp.update({c: g.start(k) for k, c in starts.items() if k in keys})
    m = MockClient(resp, clock=clock)
    m.prefix_handlers.append(('lua "require(\'repeat-util\').cancel(', g.cancel))
    tools = ToolsDir(tmp_path, clock)
    r = Bisect(m, tools, Store(), clock, {}, starts, lua_dir=HOME / "lua" / "claude").run()
    assert r.culprit == "claude-raster" and r.untestable == ["claude-watchdog-alert"]
    assert g.on == set(keys)
    text = "\n".join(r.lines)
    assert "raster.lua:" in text and "1500 ticks" in text
    assert not any(k == "claude-watchdog-alert" for _, kind, k in g.events)


# ---- AC3: protected services never off longer than bisect_pause_s, recovery from the state file
def test_ac3_protected_off_at_most_bisect_pause(tmp_path, clock):
    b, g, m, tools, store = build(tmp_path, clock, KEYS20, "claude-watchdog-alert")
    r = b.run()
    durs = g.off_durations()
    assert any(k in durs for k in PROTECTED)
    assert all(durs[k] <= perf.DEFAULTS["bisect_pause_s"] for k in PROTECTED if k in durs)
    assert r.culprit == "claude-watchdog-alert" and g.on == set(KEYS20)


def test_ac3_crash_mid_bisect_recovered_from_state_file(tmp_path, clock):
    b, g, m, tools, store = build(tmp_path, clock, KEYS20, "claude-milguard")
    n = {"probes": 0}
    orig = g.probe

    def dying_probe(cmd):                                  # connection dies during a protected measurement
        n["probes"] += 1
        if any(k not in g.on for k in PROTECTED):
            g.dead = True
        return orig(cmd)
    m.responses[PROBE_CMD] = dying_probe
    with pytest.raises(ConnectionError):
        b.run()
    st = json.loads(state_path(tools).read_text(encoding="utf-8"))
    assert {e["key"] for e in st["off"]} & set(PROTECTED)
    off = set(KEYS20) - g.on
    # the process is gone; the watcher restarts overdue entries (deadline = since + bisect_pause_s)
    g.dead = False
    clock.advance(10)
    assert recover(m, tools, store, clock, overdue_only=True) == []        # not overdue yet, heartbeat ignored
    clock.advance(31)
    w = make_waechter(tmp_path, clock, m)
    w.step()
    assert g.on == set(KEYS20) and not state_path(tools).exists()
    durs = g.off_durations()
    assert all(durs[k] <= perf.DEFAULTS["bisect_pause_s"] + 2.5 for k in off)   # + one watcher tick
    assert "restarted from the state file" in "\n".join(tools.events_lines())
    assert w.store.count_actions("perf", "recover", 0) == len(off)


def test_recover_stale_heartbeat_on_next_run(tmp_path, clock):
    b, g, m, tools, store = build(tmp_path, clock, KEYS20, None)
    g.on.discard("claude-svc03")
    state_path(tools).parent.mkdir(parents=True, exist_ok=True)
    state_path(tools).write_text(json.dumps({"heartbeat": clock.now().epoch, "off": [
        {"key": "claude-svc03", "start": "claude/svc03 start", "since": clock.now().epoch,
         "deadline": clock.now().epoch + 600}]}), encoding="utf-8")
    assert recover(m, tools, store, clock) == []                  # bisect still alive (fresh heartbeat)
    clock.advance(31)
    assert recover(m, tools, store, clock)                         # heartbeat stale -> restart
    assert "claude-svc03" in g.on and not state_path(tools).exists()


# ---- AC4: watcher auto detection
def make_waechter(tmp_path, clock, client=None, clear=None):
    tools = ToolsDir(tmp_path, clock)
    tools.set_last_report_id(90)
    tools.touch_heartbeat()
    m = client or MockClient({}, clock=clock)
    m.responses.update({MAX_REPORT_ID_CMD: "100", FOOD_CMD: "S 50 0 10 100 20", CARAVANS_CMD: "0",
                        CLEAR_CMD: clear or "R 0 dwarfmode/Default fc=1 yt=1"})
    m.prefix_handlers.append(('lua "local last=', lambda c: ""))
    return Waechter(m, tools, clock, Store(), DEFAULTS)


def test_ac4_perf_flag_only_after_5_outliers_in_5_min(tmp_path, clock):
    slow = {"n": 0}

    def clear(_cmd):
        lat = 10.5 if slow["n"] > 0 else 0.05
        slow["n"] -= 1
        return Result(True, "R 0 dwarfmode/Default fc=1 yt=1", elapsed_s=lat)
    w = make_waechter(tmp_path, clock, clear=clear)
    for i in range(4):                                     # 4 outliers, 25 s apart
        slow["n"] = 1
        for _ in range(12):
            w.step()
            clock.advance(2)
    assert not w.tools.flag("perf").exists
    slow["n"] = 1
    w.step()
    flag = w.tools.flag("perf")
    assert flag.exists and flag.text.startswith("Game hangs:") and "max 10.5 s" in flag.text
    assert "period" in flag.text and len(flag.text) <= 120
    assert w.store.count_actions("perf", "perf_flag", 0) == 1
    w.tools.delete_flag("perf")
    slow["n"] = 1
    w.step()
    assert not w.tools.flag("perf").exists                 # loop protection: not again within flag_repeat_min


def test_ac4_old_outliers_expire():
    mon = LatencyMonitor({})
    for i in range(4):
        mon.add(1000 + i * 25, 11.0)
    mon.add(1000 + 400, 11.0)                              # 5th outlier, but the first ones are > 5 min old
    for t in range(1000 + 100, 1000 + 400, 2):
        mon.add(t, 0.05)
    assert not mon.should_flag(1000 + 401)


def test_ac4_rate_must_exceed_warn_pct():
    mon = LatencyMonitor({})
    for t in range(0, 300):
        mon.add(t, 2.0 if t % 50 == 0 else 0.05)           # 6 outliers in 300 samples = 2 %
    assert mon.stats(300)["outliers"] == 6 and not mon.should_flag(300)


# ---- AC5: digest line <= 120 characters
def test_ac5_digest_line_length():
    assert len(digest_line({"per_min": 2.0, "max_s": 10.5, "period_s": 25.0})) <= 120
    assert digest_line({"per_min": 2.0, "max_s": 10.5, "period_s": 25.0}).startswith(
        "Game hangs: 2.0 outliers/min (max 10.5 s, period 25 s)")
    assert len(digest_line({"per_min": 1e9, "max_s": 1e12, "period_s": 1e15})) <= 120


# ---- heuristics + CLI + check hook
def test_suggest_has_line_reference():
    s = suggest("claude-kohle", HOME / "lua" / "claude", tick_rate=60, period_s=25)
    assert s[0].startswith("Proposal for claude-kohle") and "no automatic Lua patch" in s[0]
    assert any("kohle.lua:" in x for x in s) and any("1500 ticks / 60 ticks/s = 25 s" in x for x in s)
    assert suggest("claude-unknown", HOME / "lua" / "claude")[0].startswith("Proposal")


def test_check_hook_and_cli(tmp_path, tools_dir, capsys):
    from df_llm_helper.cli import main
    from conftest import FIX
    c = tmp_path / "c.yaml"
    c.write_text(f"paths:\n  tools: {tools_dir}\n  scopes: {tools_dir / 'scopes'}\n  state_db: {tmp_path / 's.db'}\n"
                 f"  gamelog: {tmp_path / 'g'}\n", encoding="utf-8")
    base = ["--config", str(c), "--mock", str(FIX)]
    assert main(base + ["perf", "sample", "--n", "3", "--gap", "0"]) == 0
    assert "Sample 3" in capsys.readouterr().out
    assert main(base + ["perf", "bisect", "--dry-run"]) == 0
    (tools_dir / "perf.flag").write_text("Game hangs: 2.0 outliers/min (max 10.5 s, period 25 s) -> python -m df_llm_helper perf bisect")
    assert main(base + ["perf", "status", "--clear"]) == 0
    out = capsys.readouterr().out
    assert "perf.flag: Game hangs" in out and "perf.flag deleted" in out

    class P:
        pass
    p = P()
    clock = __import__("df_llm_helper.clock", fromlist=["FakeClock"]).FakeClock()
    p.tools, p.client, p.store, p.clock = ToolsDir(tools_dir, clock), MockClient({}), Store(), clock
    assert perf.check_hook(p, None, True) == []
    p.tools.write_flag("perf", "Game hangs: 1.0 outliers/min (max 3.0 s)")
    assert perf.check_hook(p, None, False) == ["Game hangs: 1.0 outliers/min (max 3.0 s)"]


def test_list_command_uses_list_scheduled_and_parses_live_output():
    """Live 02.10.: DF 53 repeat-util has no `scheduled` table (nil -> 'No repeat-util services found')."""
    assert "listScheduled" in LIST_CMD and "r.scheduled" in LIST_CMD          # new API first, old tables as fallback
    live = "S claude-arbeit claude-gesund claude-tempo control-panel/fix/general-strike control-panel/fix/stuck-instruments"
    assert parse_list(live) == ["claude-arbeit", "claude-gesund", "claude-tempo"]   # '/' keys are not ours
