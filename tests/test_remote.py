"""Spec v3-06 remote-worker protection (`dfpilot remote`, spec name `dfpilot care remote`): acceptance criteria 1-5,
labor record/return, fish yield, selection property, Lua mock. All `claude/pilot_remote` responses are SYNTHETIC
(fixtures/v3/remote, fixture gap)."""
import copy
import json
import random
import shutil
import subprocess
from pathlib import Path
from types import SimpleNamespace

import pytest

from dfpilot.client import MockClient
from dfpilot.clock import FakeClock
from dfpilot.config import load_config
from dfpilot.features import remote as R
from dfpilot.lint import lint_file
from dfpilot.store import Store

ROOT = Path(__file__).resolve().parent.parent
FIX = ROOT / "fixtures" / "v3" / "remote"
LUA = shutil.which("lua5.4")


def load(name):
    return json.loads((FIX / name).read_text(encoding="utf-8"))


class FakeRiver:
    """Stateful stand-in for the game. tick(): every idle citizen with FISH (not soldier/child/hospital) takes a
    Fish job at once - the run-5 behaviour (re-took fishing after each cancel). Work detail Fisherdwarves holds the
    FISH holders."""

    def __init__(self, status):
        self.s = copy.deepcopy(status)
        self.wd = {"Fisherdwarves": [c["id"] for c in self.s.get("citizens", []) if "FISH" in c["labors"]]}

    def unit(self, uid):
        return next(c for c in self.s["citizens"] if c["id"] == uid)

    def status(self, cmd):
        return json.dumps(self.s)

    def _refuse(self, u):
        if u["squad"]:
            return "soldier: refused"
        if u["child"]:
            return "child: refused"
        if u["hospital"] is not None:
            return "in hospital: refused"
        return None

    def cancel(self, cmd):
        u = self.unit(int(cmd.split()[2]))
        if self._refuse(u):
            return json.dumps({"ok": False, "error": self._refuse(u)})
        job, u["job"] = u["job"], None
        return json.dumps({"ok": True, "id": u["id"], "cancelled": job is not None, "job": job})

    def labor(self, cmd):
        p = cmd.split()
        u, lab, mode = self.unit(int(p[2])), p[3], p[4]
        if self._refuse(u):
            return json.dumps({"ok": False, "error": self._refuse(u)})
        changed = []
        if mode == "off":
            u["labors"] = [x for x in u["labors"] if x != lab]
            for name, mem in self.wd.items():
                if u["id"] in mem and lab == "FISH":
                    mem.remove(u["id"])
                    changed.append(name)
        else:
            if lab not in u["labors"]:
                u["labors"].append(lab)
            for name in (p[5].split(",") if len(p) > 5 else []):
                self.wd[name].append(u["id"])
                changed.append(name)
        return json.dumps({"ok": True, "id": u["id"], "labor": lab, "mode": mode, "work_details": changed})

    def tick(self):
        for u in self.s["citizens"]:
            if u["job"] is None and "FISH" in u["labors"] and not self._refuse(u):
                u["job"] = "Fish"


def setup(status, cfg=None, store=None):
    clock = FakeClock(1_790_000_000)
    game = FakeRiver(status)
    m = MockClient({}, clock=clock)
    rc = R.RemoteCare(m, store or Store(), clock, cfg or {})
    m.set(rc.status_cmd(), game.status)
    m.prefix_handlers += [("claude/pilot_remote cancel ", game.cancel), ("claude/pilot_remote labor ", game.labor)]
    return rc, m, game


def writes(m):
    return [c for c in m.calls if not c.startswith("claude/pilot_remote status")]


# ---- acceptance 1
def test_fisher_far_away_rescued_and_no_new_fish_job_within_60s():
    rc, m, game = setup(load("status_river.json"), cfg={"labor_pool": {}})
    lines, show = rc.run()
    assert "claude/pilot_remote cancel 4156" in m.calls
    assert "claude/pilot_remote labor 4156 FISH off" in m.calls
    u = game.unit(4156)
    assert u["job"] is None and "FISH" not in u["labors"] and "MINE" in u["labors"]
    assert show and any("Remote rescue: 4156" in ln and "tiles from food/drink" in ln for ln in lines)
    assert any(ln.startswith("Proposal: food stockpile/drink barrel near (192,12,140)") for ln in lines)
    for _ in range(6):                                     # 60 s of game ticks + checks
        rc.clock.advance(10)
        game.tick()
        rc.run()
        assert game.unit(4156)["job"] != "Fish"
    taken = rc.taken()
    assert taken == [{"unit": 4156, "labor": "FISH", "kind": "rescue", "reason": taken[0]["reason"],
                      "ts": 1_790_000_000.0, "work_details": ["Fisherdwarves"]}]
    acts = rc.store.actions()
    assert {(a["rule"], a["action"]) for a in acts} == {("remote_rescue", "cancel_job"), ("remote_rescue", "labor_off")}
    assert all("hunger 62000" in a["detail"] for a in acts)
    # 4281 is hungry (41k) but hauls near the fort -> no action; 344/3449 are fed
    assert not any(" 4281" in c or " 344 " in c or " 3449" in c for c in writes(m))


def test_rescue_repeat_block_per_dwarf():
    st = load("status_river.json")
    rc, m, game = setup(st, cfg={"labor_pool": {}})
    rc.run()
    game.unit(4156)["job"] = "Fish"                      # still fishing (labor gone, job re-appeared)
    rc.clock.advance(60)
    rc.run()
    assert m.calls.count("claude/pilot_remote cancel 4156") == 1
    rc.clock.advance(600)
    rc.run()
    assert m.calls.count("claude/pilot_remote cancel 4156") == 2


# ---- acceptance 2
def test_fifteen_fishers_reduced_to_three_lowest_hunger():
    rc, m, game = setup(load("status_fifteen_fish.json"))
    lines, show = rc.run()
    holders = sorted(u["id"] for u in game.s["citizens"] if "FISH" in u["labors"])
    assert holders == [5000, 5001, 5002] and show
    assert len([a for a in rc.store.actions() if a["rule"] == "remote_pool"]) == 12
    assert all(r["kind"] == "pool" for r in rc.taken()) and len(rc.taken()) == 12
    n = len(writes(m))
    rc.clock.advance(60)
    rc.run()                                             # idempotent
    assert len(writes(m)) == n


def test_pool_ignores_soldiers_and_hospital():
    st = load("status_fifteen_fish.json")
    st["citizens"][14]["squad"] = True                   # highest hunger, soldier
    st["citizens"][13]["hospital"] = 900
    rc, m, game = setup(st)
    rc.run()
    assert "FISH" in game.unit(5014)["labors"] and "FISH" in game.unit(5013)["labors"]
    assert not any(" 5014 " in c or " 5013 " in c for c in writes(m))


# ---- acceptance 3
def test_labor_returned_after_recovery_with_work_detail():
    rc, m, game = setup(load("status_river.json"), cfg={"labor_pool": {}})
    rc.run()
    u = game.unit(4156)
    u.update(x=91, y=96, z=130, hunger=20000, thirst=9000)          # back home, still hungry-ish
    rc.clock.advance(120)
    rc.run()
    assert "FISH" not in u["labors"]
    u["hunger"] = 14000
    rc.clock.advance(120)
    lines, show = rc.run()
    assert "claude/pilot_remote labor 4156 FISH on Fisherdwarves" in m.calls
    assert "FISH" in u["labors"] and 4156 in game.wd["Fisherdwarves"] and rc.taken() == []
    assert show and any("Labors returned: FISH back to 4156" in ln for ln in lines)
    ret = [a for a in rc.store.actions() if a["rule"] == "remote_return"]
    assert len(ret) == 1 and "recovered: hunger 14000" in ret[0]["detail"]


def test_no_return_while_in_hospital_and_manual_restore():
    rc, m, game = setup(load("status_river.json"), cfg={"labor_pool": {}})
    rc.run()
    u = game.unit(4156)
    u.update(hunger=1000, thirst=1000, hospital=900)
    rc.clock.advance(60)
    rc.run()
    assert not any(" FISH on" in c for c in writes(m))
    assert len(rc.taken()) == 1
    u["hospital"] = None
    out = rc.restore_all()
    assert out == ["FISH back to 4156"] and rc.taken() == []


# ---- acceptance 4: property
def _rand(rng, i):
    return {"id": i, "name": f"D{i}", "x": rng.randint(0, 250), "y": rng.randint(0, 250), "z": rng.randint(100, 150),
            "hunger": rng.randint(0, 70000), "thirst": rng.randint(0, 70000),
            "job": rng.choice([None, "Fish", "GatherPlants", "Dig", "Haul", "Eat"]), "squad": rng.random() < 0.25,
            "child": rng.random() < 0.15, "hospital": rng.choice([None, None, None, 900]),
            "labors": [lab for lab in ("FISH", "HERBALISM", "MINE", "PLANT") if rng.random() < 0.4]}


def test_property_soldiers_children_never_selected_no_change_in_hospital():
    rng = random.Random(11)
    for _ in range(150):
        cits = [_rand(rng, 100 + k) for k in range(rng.randint(0, 40))]
        st = {"ok": True, "citizens": cits, "supplies": [{"kind": "food", "x": 90, "y": 95, "z": 130}], "fish": 5}
        cfg = {"labor_pool": {"FISH": rng.randint(0, 5)}}
        for t in R.rescue_targets(R.obs_from_status(st), {**R.DEFAULTS, **cfg}):
            assert R.selectable(t["unit"])
        for u, _ in R.pool_targets(R.obs_from_status(st), {**R.DEFAULTS, **cfg}):
            assert R.selectable(u)
        rc, m, game = setup(st, cfg=cfg)
        rc.run()
        bad = {c["id"] for c in cits if c["squad"] or c["child"] or c["hospital"] is not None}
        for c in writes(m):
            assert int(c.split()[2]) not in bad, c


# ---- acceptance 5: escalation dedupe
def test_escalation_once_per_dwarf_and_level():
    st = load("status_river.json")
    st["citizens"][0]["job"] = "Haul"                     # no rescue action, only warnings
    st["citizens"][0]["x"] = 95
    rc, m, game = setup(st, cfg={"labor_pool": {}})
    lines, show = rc.run()
    crit = [ln for ln in lines if ln.startswith("!! critical: 4156")]
    assert len(crit) == 1 and "hopeless" not in crit[0] and show
    assert not rc.run()[0][0].startswith("!!")
    lines2, _ = rc.run()
    assert not any(ln.startswith("!! critical: 4156") for ln in lines2)
    game.unit(4156)["hunger"] = 66000
    lines3, _ = rc.run()
    assert [ln for ln in lines3 if "only moving the dwarf by hand" in ln]
    assert not any("by hand" in ln for ln in rc.run()[0])
    game.unit(4156)["hunger"] = 1000                      # recovered -> dedupe reset
    rc.run()
    game.unit(4156)["hunger"] = 56000
    assert any(ln.startswith("!! critical: 4156") for ln in rc.run()[0])
    warns = [w for w in rc.store.take_warnings() if w["key"] == "remote:crit:4156"]
    assert warns and warns[0]["level"] == "crit"


# ---- fish yield, dry run, status, check hook
def test_fish_yield_proposal_after_an_hour_without_fish():
    rc, m, game = setup(load("status_fifteen_fish.json"), cfg={"labor_pool": {}})
    rc.run()
    rc.clock.advance(3700)
    lines, show = rc.run()
    assert show and any(ln.startswith("Proposal: fishing yields 0.0 fish/h") for ln in lines)
    game.s["fish"] = 40
    rc.clock.advance(3700)
    assert any(ln.startswith("Fish 40 (+") for ln in rc.run()[0])


def test_dry_run_writes_nothing():
    rc, m, game = setup(load("status_river.json"))
    lines, _ = rc.run(dry=True)
    assert not writes(m) and not rc.store.actions() and rc.taken() == []
    assert any("[dry] cancel 4156" in ln for ln in lines)


def test_status_and_unreadable():
    rc, m, game = setup(load("status_river.json"))
    out = rc.status()
    assert any(ln.startswith("4156 ") and "job Fish" in ln for ln in out)
    assert "FISH: 3 civilians (pool 3)" in out
    rc2, m2, _ = setup({"ok": False})
    assert "not readable" in rc2.status()[0] and "not readable" in rc2.run()[0][0]


def test_check_hook_quiet_when_nothing_happens(tmp_path):
    st = load("status_fifteen_fish.json")
    st["citizens"] = st["citizens"][:3]
    rc, m, game = setup(st)
    cfg = load_config(path=tmp_path / "none.yaml")
    assert cfg.get("remote_care.far_tiles") == 40 and cfg.get("remote_care.labor_pool") == {"FISH": 3}
    pilot = SimpleNamespace(cfg=cfg, client=m, store=rc.store, clock=rc.clock)
    assert R.check_hook(pilot, None, False) == []
    game.unit(5000).update(hunger=60000, job="Fish", x=200)
    out = R.check_hook(pilot, None, False)
    assert any("Remote rescue: 5000" in ln for ln in out)


def test_distance_and_cli_help(capsys):
    assert R.distance({"x": 0, "y": 0, "z": 0}, {"x": 10, "y": 4, "z": 2}) == 16
    assert R.nearest_supply({"x": 0, "y": 0, "z": 0}, []) == (None, None)
    from dfpilot.cli import main
    with pytest.raises(SystemExit) as e:
        main(["remote", "--help"])
    out = capsys.readouterr().out
    assert e.value.code == 0 and "care remote" in out.replace("\n", " ")


# ---- Lua
def test_pilot_remote_lua_lint_clean():
    f = ROOT / "lua" / "pilot_remote.lua"
    assert lint_file(f) == [] and "LIVE-UNTESTED" in f.read_text(encoding="utf-8")


UNITS = [{"id": 4156, "x": 192, "y": 12, "z": 140, "hunger": 62000, "job": "Fish", "labors": ["FISH", "MINE"]},
         {"id": 344, "labors": ["FISH"]}, {"id": 10, "squad": True, "labors": ["FISH"], "job": "Fish"},
         {"id": 11, "adult": False}, {"id": 12, "x": 2, "y": 2, "z": 130, "labors": ["FISH"]}]


def _lua(tmp_path, script, *args):
    p = tmp_path / "units.json"
    p.write_text(json.dumps(UNITS), encoding="utf-8")
    r = subprocess.run([LUA, str(ROOT / "tests" / "lua_mock" / "remote_mock.lua"), str(ROOT / "lua" / script), *args],
                       capture_output=True, text=True, timeout=20, env={"MOCK_REMOTE": str(p), "PATH": "/usr/bin:/bin"})
    assert r.returncode == 0, r.stderr
    lines = r.stdout.strip().splitlines()
    return json.loads(lines[0]), json.loads(lines[-1].removeprefix("STATE "))


@pytest.mark.skipif(not LUA, reason="lua5.4 not installed")
def test_lua_status_and_actions(tmp_path):
    out, _ = _lua(tmp_path, "pilot_remote.lua", "status", "FISH,MINE")
    obs = R.obs_from_status(out)
    assert obs.ok and obs.fish == 3 and obs.supplies[0]["kind"] == "food"
    u12 = next(c for c in obs.citizens if c["id"] == 12)
    assert u12["hospital"] == 900
    out, st = _lua(tmp_path, "pilot_remote.lua", "cancel", "4156")
    assert out["cancelled"] and st["units"]["4156"]["job"] == "none"
    out, st = _lua(tmp_path, "pilot_remote.lua", "labor", "4156", "FISH", "off")
    assert out["work_details"] == ["Fisherdwarves"] and st["units"]["4156"]["labors"] == ["MINE"]
    assert st["wds"]["Fisherdwarves"] == [344]
    for uid, err in (("10", "soldier"), ("11", "child"), ("12", "in hospital")):
        out, st = _lua(tmp_path, "pilot_remote.lua", "labor", uid, "FISH", "off")
        assert not out["ok"] and err in out["error"]
    out, _ = _lua(tmp_path, "pilot_remote.lua", "labor", "4156", "BREW", "off")
    assert not out["ok"]


@pytest.mark.skipif(not LUA, reason="lua5.4 not installed")
def test_lua_tools_status_shape(tmp_path):
    from dfpilot.features import tools as T
    out, _ = _lua(tmp_path, "pilot_tools.lua", "status")
    obs = T.obs_from_status(out)
    assert obs.ok and obs.work_weapons == 2 and obs.miners == 1
    assert next(c for c in obs.citizens if c["id"] == 12)["hospital"] == 900
