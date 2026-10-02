"""Spec v3-10 camera director profiles: profile switch -> weight file + schau reload, Monte Carlo (idle soldiers /
sparring < 1 % in ambient), attack -> combat within 2 s and back, stats sum 100 %, no action outside
dwarfmode/Default or with pause.hold, Lua hook agrees with the Python mirror. Fixtures are SYNTHETIC."""
import json
import random
import shutil
import subprocess

import pytest

from dfpilot.client import MockClient
from dfpilot.clock import FakeClock
from dfpilot.config import HOME
from dfpilot.features import camera as cam
from dfpilot.store import Store
from dfpilot.toolsfs import ToolsDir

FIX = HOME / "fixtures" / "v3" / "camera"
LUA = shutil.which("lua5.4") or shutil.which("lua")
PROFILES = ["ambient", "combat", "build", "events", "calm"]


def units_j109():
    d = json.loads((FIX / "jobs_j109.json").read_text(encoding="utf-8"))
    out = []
    for g in d["groups"]:
        for _ in range(g["n"]):
            out.append({"id": len(out) + 1, "job": g["job"], "soldier": bool(g.get("soldier"))})
    return out


class Schau:
    """Simulated claude/schau: 'profile reload' reads the weight file like schau.lua does."""

    def __init__(self, tools, status="schau_status_default.json"):
        self.tools = tools
        self.st = json.loads((FIX / status).read_text(encoding="utf-8"))

    def client(self, clock):
        m = MockClient(clock=clock)
        m.set("claude/schau status", lambda c: json.dumps(self.st))
        m.set("claude/schau profile reload", self.reload)
        m.prefix_handlers.append(("claude/schau mode ", self.mode))
        return m

    def reload(self, _):
        p = json.loads((self.tools.path / "schau_profile.json").read_text(encoding="utf-8"))
        self.st["profile"] = p["name"]
        return json.dumps({"ok": True, "profile": p["name"]})

    def mode(self, c):
        self.st["mode"] = c.split()[-1]
        return json.dumps({"ok": True, "mode": self.st["mode"]})


@pytest.fixture
def world(tmp_path):
    clock = FakeClock(1_790_840_000.0)
    tools = ToolsDir(tmp_path / "tools", clock)
    tools.path.mkdir(parents=True)
    sch = Schau(tools)
    m = sch.client(clock)
    d = cam.Director(m, Store(), clock, tools, {}, home=HOME)
    return d, sch, m, clock, tools


def test_all_profiles_load_and_differ():
    loaded = {n: cam.load_profile(n, cam.DEFAULTS, HOME) for n in PROFILES}
    assert sorted(cam.profile_names(cam.DEFAULTS, HOME)) == sorted(PROFILES)
    assert loaded["combat"]["mode"] == "combat" and loaded["events"]["mode"] == "events"
    assert loaded["calm"]["dwell_s"] == [40, 40] and loaded["ambient"]["dwell_s"] == [18, 24]
    assert loaded["ambient"]["variety_factor"] == 0.3 and loaded["ambient"]["soldier_idle_weight"] == 0.005
    w = {n: cam.weights_payload(p) for n, p in loaded.items()}
    assert w["build"]["job_weights"] != w["ambient"]["job_weights"]
    amb = {e["p"]: e["w"] for e in w["ambient"]["job_weights"]}
    assert amb["^PlaceItemInTomb"] == 8 and amb["^GiveWater"] == 7 and amb["^Haul"] == 1 and amb["^Sleep"] == 0


@pytest.mark.parametrize("name", ["nope", "../ambient", ""])
def test_unknown_or_bad_profile_refused(name):
    with pytest.raises(cam.ProfileError):
        cam.load_profile(name, cam.DEFAULTS, HOME)


def test_profile_cycle_and_invalid_weights(tmp_path):
    (tmp_path / "a.yaml").write_text("name: a\nextends: b\nmode: auto\n", encoding="utf-8")
    (tmp_path / "b.yaml").write_text("name: b\nextends: a\n", encoding="utf-8")
    (tmp_path / "c.yaml").write_text("mode: auto\njob_weights:\n  - {p: '^Dig', w: -1}\n", encoding="utf-8")
    cfg = {**cam.DEFAULTS, "profiles_dir": str(tmp_path)}
    with pytest.raises(cam.ProfileError):
        cam.load_profile("a", cfg, HOME)
    with pytest.raises(cam.ProfileError):
        cam.load_profile("c", cfg, HOME)


def test_switch_writes_weight_file_and_status_shows_profile(world):
    """Acceptance 1."""
    d, sch, m, clock, tools = world
    out = d.switch("build")
    f = tools.path / "schau_profile.json"
    data = json.loads(f.read_text(encoding="utf-8"))
    assert data["name"] == "build" and data["job_weights"][0] == {"p": "^ConstructBuilding", "w": 10, "cat": "build"}
    assert m.calls[-2:] == ["claude/schau profile reload", "claude/schau mode auto"]
    assert "ambient -> build" in out[0]
    d.switch("ambient")
    assert json.loads(f.read_text(encoding="utf-8"))["name"] == "ambient"
    st = d.status()
    assert st[0] == "Camera profile: ambient" and "profile ambient" in st[1]
    assert d.store.actions()[-1]["rule"] == "camera"


def test_monte_carlo_idle_soldiers_and_sparring_below_one_percent():
    """Acceptance 2: 1000 picks in ambient."""
    p = cam.load_profile("ambient", cam.DEFAULTS, HOME)
    units = units_j109()
    for seed in range(5):
        counts = cam.simulate(units, p, n=1000, seed=seed)
        bad = counts.get("soldier_idle", 0) + counts.get("sparring", 0)
        assert sum(counts.values()) == 1000
        assert bad / 1000 < 0.01, counts
    builtin_like = {**p, "soldier_idle_weight": 1.0}            # without the filter soldiers would dominate
    c2 = cam.simulate(units, builtin_like, n=1000, seed=0)
    assert c2.get("soldier_idle", 0) / 1000 > 0.05


def test_monte_carlo_shows_variety():
    p = cam.load_profile("ambient", cam.DEFAULTS, HOME)
    counts = cam.simulate(units_j109(), p, n=1000, seed=3)
    for cat in ("burial", "build", "furniture", "harvest", "water"):
        assert counts.get(cat, 0) > 10, counts
    assert counts.get("rest", 0) == 0


def test_attack_switches_to_combat_within_two_seconds_and_back(world):
    """Acceptance 3."""
    d, sch, m, clock, tools = world
    d.switch("build")
    t0 = clock.now().epoch
    tools.write_flag("siege", "Goblins")
    out = d.watch(iterations=2)                    # poll every 1 s
    assert d.current() == "combat" and sch.st["mode"] == "combat"
    sw = [a for a in d.store.actions() if a["resource"] == "combat"][0]
    assert sw["ts"] - t0 <= 2.0 and "attack" in out[0]
    d.watch(iterations=3)
    assert d.current() == "combat"                 # stays while the attack lasts (no flapping)
    tools.delete_flag("siege")
    d.watch(iterations=1)
    assert d.current() == "build" and d.store.get("camera.auto_prev") is None


@pytest.mark.parametrize("status,flag", [("schau_status_menu.json", None), ("schau_status_default.json", "pause.hold")])
def test_no_action_outside_default_focus_or_with_pause_hold(tmp_path, status, flag):
    """Acceptance 5."""
    clock = FakeClock(0)
    tools = ToolsDir(tmp_path / "tools", clock)
    tools.path.mkdir(parents=True)
    if flag:
        tools.write_flag(flag, "main thread")
    sch = Schau(tools, status)
    m = sch.client(clock)
    d = cam.Director(m, Store(), clock, tools, {}, home=HOME)
    out = d.switch("build")
    assert out[0].startswith("Camera: no action")
    assert not (tools.path / "schau_profile.json").exists()
    assert m.write_calls == [] and d.store.actions() == []
    tools.write_flag("siege", "x")
    d.tick()
    assert d.current() == "ambient" and m.write_calls == []


def test_stats_sum_to_100():
    """Acceptance 4."""
    st = json.loads((FIX / "schau_status_default.json").read_text(encoding="utf-8"))
    sh = cam.shares(st["cats"])
    assert sum(v for _, v in sh) == 100 and sh[0][0] == "build"
    rng = random.Random(7)
    for _ in range(200):
        counts = {f"c{i}": rng.randint(0, 50) for i in range(rng.randint(1, 12))}
        sh = cam.shares(counts)
        if sum(counts.values()):
            assert abs(sum(v for _, v in sh) - 100) <= 1
    assert cam.shares({}) == [] and cam.shares([]) == []


def test_loop_protection(world):
    d, sch, m, clock, tools = world
    d.cfg["max_switches_per_hour"] = 3
    for n in ["build", "calm", "events"]:
        d.switch(n)
    assert "loop protection" in d.switch("ambient")[0]


def test_hold_hint(world):
    d, sch, *_ = world
    sch.st["hold_s"] = 30
    out = d.switch("calm")
    assert "director paused 30 s" in out[1]


def test_check_hook_no_df_call_without_attack(world, cfg):
    from dfpilot.pilot import Pilot
    d, sch, m, clock, tools = world
    p = Pilot(cfg, m, store=d.store, clock=clock, tools=tools)
    n = len(m.calls)
    assert cam.check_hook(p, None, False) == [] and len(m.calls) == n
    tools.write_flag("alert", "x")
    assert cam.check_hook(p, None, False)[0].startswith("Camera: profile ambient -> combat")
    assert cam.check_hook(p, None, True) == []


@pytest.mark.skipif(not LUA, reason="lua5.4 not installed")
@pytest.mark.parametrize("name", PROFILES)
def test_lua_hook_matches_python_mirror(tmp_path, name):
    p = cam.load_profile(name, cam.DEFAULTS, HOME)
    (tmp_path / "tools").mkdir()
    (tmp_path / "tools" / "schau_profile.json").write_text(json.dumps(cam.weights_payload(p)), encoding="utf-8")
    jobs = ["PlaceItemInTomb", "ConstructBuilding", "ConstructBed", "GiveWater", "Spar", "StoreItemInStockpile",
            "Dig", "Sleep", "MakeCrafts", "Foo"]
    r = subprocess.run([LUA, str(FIX / "schau_mock.lua"), str(HOME / "lua" / "claude" / "schau.lua"), *jobs, "-",
                        "=soldier"], capture_output=True, text=True, timeout=20, env={"MOCK_HOME": str(tmp_path)})
    assert r.returncode == 0, r.stderr
    lines = r.stdout.splitlines()
    assert lines[0] == f"LOAD true {name}"
    for ln in lines[1:-1]:
        _, job, w, c = ln.split()
        jj = None if job in ("-", "=soldier") else job
        pw, pc = cam.weight(p, jj, job == "=soldier")
        assert abs(float(w) - pw) < 1e-6 and (c if c != "nil" else None) == pc, ln
    assert lines[-1] == "STATUS builtin"


@pytest.mark.skipif(not LUA, reason="lua5.4 not installed")
def test_lua_without_profile_file_keeps_builtin(tmp_path):
    r = subprocess.run([LUA, str(FIX / "schau_mock.lua"), str(HOME / "lua" / "claude" / "schau.lua"),
                        "PlaceItemInTomb", "=soldier"], capture_output=True, text=True, timeout=20,
                       env={"MOCK_HOME": str(tmp_path)})
    lines = r.stdout.splitlines()
    assert lines[0].startswith("LOAD false") and lines[1] == "W PlaceItemInTomb 8.0000 nil"
    assert lines[2] == "W =soldier 0.0050 soldier_idle"


def test_cli_profile_list_and_refusal(world, monkeypatch, capsys):
    import dfpilot.cli as cli
    from dfpilot.config import load_config
    from dfpilot.pilot import Pilot
    d, sch, m, clock, tools = world
    monkeypatch.setattr(cli, "_pilot", lambda a: Pilot(load_config(overrides={"paths": {"tools": str(tools.path)}}),
                                                       m, store=d.store, clock=clock, tools=tools))
    assert cli.main(["camera", "profile"]) == 0
    assert "ambient" in capsys.readouterr().out
    assert cli.main(["camera", "profile", "nope"]) == 2
    assert cli.main(["camera", "profile", "calm"]) == 0
    assert "-> calm" in capsys.readouterr().out
    assert cli.main(["camera", "stats"]) == 0
    assert "%" in capsys.readouterr().out


def test_attack_never_starts_a_stopped_director(world):
    d, sch, m, clock, tools = world
    sch.st["running"] = False
    tools.write_flag("siege", "x")
    assert "director not running" in d.tick()[0]
    assert d.current() == "ambient" and m.write_calls == []
