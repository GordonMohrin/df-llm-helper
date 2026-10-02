"""Regression tests for the autopilot bug reports Bugs/BUG-200 .. BUG-220 (recorded game answers under fixtures/bugs/)."""
import json

import pytest

from df_llm_helper.cli import main
from df_llm_helper.store import Store
from helpers import ROOT

BUGS = ROOT / "fixtures" / "bugs"


@pytest.fixture
def cfgfile(tmp_path, tools_dir):
    c = tmp_path / "cfg.yaml"
    c.write_text(f"paths:\n  tools: {tools_dir}\n  scopes: {tools_dir / 'scopes'}\n  state_db: {tmp_path / 's.db'}\n"
                 f"  gamelog: {tmp_path / 'gamelog.txt'}\n  exceptions: {tmp_path / 'ex.jsonl'}\n", encoding="utf-8")
    return str(c)


def cli(capsys, *args):
    rc = main([str(a) for a in args])
    out = capsys.readouterr()
    return rc, out.out + out.err


def db(tmp_path):
    return Store(tmp_path / "s.db")


# ---------------------------------------------------------------- BUG-200 / 201 / 202 (caravan + trade automaton)

def test_bug200_caravan_done_is_terminal(tmp_path, tools_dir, cfgfile, capsys):
    base = ["--config", cfgfile, "--replay-file", BUGS / "BUG-200" / "car_replay.jsonl"]
    rc, out = cli(capsys, *base, "caravan", "--loop", "--interval", "0", "--max-steps", "12")
    assert "Caravan: REVIEW" in out
    rc, out = cli(capsys, *base, "caravan", "--loop", "--interval", "0")
    assert "Caravan: DONE" in out and out.count("claude/advance run") == 1          # was sent twice
    assert out.count("Trade completed") == 1
    (tools_dir / "pause.hold").write_text("alarm hold")
    rc, out = cli(capsys, *base, "caravan", "--loop", "--interval", "0")
    assert "claude/advance run" not in out and out.count("Trade completed") == 1
    assert (tools_dir / "pause.hold").exists()                                       # a foreign hold survives


def test_bug201_trade_approve_reaches_caravan(tmp_path, tools_dir, cfgfile, capsys):
    base = ["--config", cfgfile, "--replay-file", BUGS / "BUG-201" / "car_replay_low.jsonl"]
    cli(capsys, *base, "caravan", "--loop", "--interval", "0", "--max-steps", "12")
    rc, out = cli(capsys, *base, "caravan", "--loop", "--interval", "0")
    assert "NOT approved: Ratio 1.20 < 2.0" in out and "trade approve" in out
    rc, out = cli(capsys, *base, "caravan", "--loop", "--interval", "0")
    assert out.count("NOT approved") == 1                                            # no pile-up
    rc, out = cli(capsys, *base, "trade", "status")
    assert "Caravan autopilot: REVIEW" in out
    rc, out = cli(capsys, *base, "trade", "approve")
    assert rc == 0 and "approved" in out and "caravan" in out
    rc, out = cli(capsys, *base, "caravan", "--loop", "--interval", "0")
    assert "ok claude/handel select --live" in out and "Caravan: DONE" in out
    assert db(tmp_path).get("caravan.state")["flow"]["approved"] is False            # one approval = one trade
    rc, out = cli(capsys, *base, "trade", "approve")
    assert rc == 2 and "Refused" in out


def test_bug202_trade_flow_leaves_done(tmp_path, tools_dir, cfgfile, capsys):
    from dataclasses import asdict

    from df_llm_helper.trade_flow import TradeFlow, TradeObs
    f = TradeFlow(state="DONE", approved=True, log=["RESUME -> DONE"])
    assert f.step(TradeObs(caravan_state="AtDepot"), 10) == [] and f.state == "DONE"
    assert f.step(TradeObs(caravan_state=None), 20) == [] and f.state == "IDLE" and not f.approved and f.log == []
    assert f.step(TradeObs(caravan_state="AtDepot"), 30) == ["claude/advance 0"]   # next caravan is traded
    f2 = TradeFlow(state="FINISH")
    f2.approved = True
    for _ in range(3):
        f2.step(TradeObs(caravan_state="AtDepot"), 40)
    assert f2.state == "DONE" and not f2.approved                                    # no stale approval
    # cli: DONE with the caravan still at the depot says why nothing happens
    db(tmp_path).set("trade.flow", asdict(TradeFlow(state="DONE", log=["RESUME -> DONE"])))
    base = ["--config", cfgfile, "--replay-file", BUGS / "BUG-200" / "car_replay.jsonl"]
    rc, out = cli(capsys, *base, "trade", "step")
    assert "State now: DONE" in out and "trade reset" in out


# ---------------------------------------------------------------- BUG-203 / BUG-219 (dry runs write nothing; siege errors)

def test_bug203_dry_runs_write_no_warnings(tmp_path, tools_dir, cfgfile, capsys):
    from conftest import FIX
    cli(capsys, "--config", cfgfile, "--mock", FIX, "siege", "--dry-run")
    cli(capsys, "--config", cfgfile, "--mock", FIX, "mood", "reserve", "--dry-run")
    base = ["--config", cfgfile, "--replay-file", BUGS / "BUG-201" / "car_replay_low.jsonl"]
    for _ in range(3):
        cli(capsys, *base, "caravan", "--dry-run", "--loop", "--interval", "0")
    assert db(tmp_path).take_warnings() == []
    assert not (tools_dir / "notify.flag").exists()


def test_bug203_mood_reserve_real_run_still_warns(tmp_path, tools_dir, cfgfile, capsys):
    from conftest import FIX
    rc, out = cli(capsys, "--config", cfgfile, "--mock", FIX, "mood", "reserve")
    if "missing" in out:                                   # the fixture has gaps -> the real run records them
        assert [w["key"] for w in db(tmp_path).take_warnings()] == ["mood:reserve"]


def test_bug219_unreadable_siege_status_is_an_error_not_an_abort(tmp_path, tools_dir, cfgfile, capsys):
    from conftest import FIX
    rcs = []
    for extra in ([], ["--once"], ["--dry-run"], ["--once", "--dry-run"]):
        rc, out = cli(capsys, "--config", cfgfile, "--mock", FIX, "siege", *extra)
        rcs.append(rc)
        assert "ABORTED" not in out and "ERROR" in out and "not readable" in out
    assert rcs == [2, 2, 2, 2]
    assert db(tmp_path).take_warnings() == [] and not (tools_dir / "notify.flag").exists()


def test_bug219_status_lost_during_siege_still_aborts():
    from df_llm_helper.client import MockClient
    from df_llm_helper.clock import FakeClock
    from df_llm_helper.siege import SiegeRunner, exit_code
    from df_llm_helper.store import Store
    from df_llm_helper.toolsfs import ToolsDir
    import tempfile
    from pathlib import Path
    clock = FakeClock(0)
    mc = MockClient({}, clock=clock)
    answers = iter([json.dumps({"invaders": [{"id": 9, "race": "GOBLIN", "dist": 200}],
                                "squads": [{"id": 33, "name": "Wache", "orders": 0,
                                            "members": [{"id": 1, "alive": True, "blood_pct": 100, "dist": 5}]}]})])
    mc.set("claude/pilot_siege status", lambda c: next(answers, "not json"))
    mc.set("claude/advance clock", '{"paused": true}')
    store = Store()
    tools = ToolsDir(Path(tempfile.mkdtemp()), clock)
    flow, log = SiegeRunner(mc, tools, store, clock, {"poll_s": 0.0, "max_wait_s": 0.0}).run()
    assert flow.state == "ABORT" and exit_code(flow) == 1 and store.take_warnings()


# ---------------------------------------------------------------- BUG-204 (offline --grid runs keep the state clean)

def test_bug204_grid_runs_do_not_touch_state(tmp_path, tools_dir, cfgfile, capsys):
    g = ROOT / "fixtures" / "v3" / "grid"
    cli(capsys, "--config", cfgfile, "reach", "--grid", g / "reach_p1p2_built.grid")
    cli(capsys, "--config", cfgfile, "digcheck", "131", "100", "70", "122", "77", "--grid", g / "dig_north_opening.grid")
    rc, out = cli(capsys, "--config", cfgfile, "perimeter", "--grid", g / "perimeter_j109_open.grid")
    assert "forbidden" in out
    s = db(tmp_path)
    assert s.take_warnings() == [] and s.actions() == []
    for k in ("reach.last", "reach.last_ts", "digcheck.unreported", "perimeter.sig", "perimeter.last", "perimeter.last_ts"):
        assert s.get(k) is None, k


# ---------------------------------------------------------------- BUG-207 / BUG-214 (digcheck: nothing checked, R1, inputs)

def test_bug207_digcheck_never_ok_for_zero_tiles(tmp_path, tools_dir, cfgfile, capsys):
    st = tmp_path / "stages.lua"
    st.write_text("add('N11_Wohn1', 120, 90, 90, 95, 95)\n", encoding="utf-8")
    base = ["--config", cfgfile, "--mock", ROOT / "fixtures" / "run5"]
    rc, out = cli(capsys, *base, "digcheck", "--stages", st, "--stage", "NOPE")
    assert rc == 2 and "refused" in out and "stage 'NOPE' not found" in out and " ok " not in out
    rc, out = cli(capsys, *base, "digcheck", "--csv", BUGS / "BUG-207" / "empty.csv", "-c", "128,140,99")
    assert rc == 2 and "nothing to check" in out
    rc, out = cli(capsys, *base, "digcheck", "--csv", BUGS / "BUG-207" / "b.csv", "-c", "128,140,99")
    assert rc == 2 and "not a '#dig' blueprint" in out


def test_bug207_r1_also_for_unrevealed_tiles(tmp_path, tools_dir, cfgfile, capsys):
    rc, out = cli(capsys, "--config", cfgfile, "--replay-file", BUGS / "BUG-207" / "l_d_r1.jsonl",
                  "digcheck", "103", "90", "90", "95", "95")
    assert rc == 2 and "refused" in out and "R1 x36" in out and "36 unrevealed" in out


def test_bug214_digcheck_inputs_are_usage_errors(tmp_path, tools_dir, cfgfile, capsys):
    base = ["--config", cfgfile, "--mock", ROOT / "fixtures" / "run5"]
    for args, msg in ((["--csv", "nofile.csv", "-c", "1,2,3"], "--csv file not found: nofile.csv"),
                      (["--stages", "nofile.lua", "--stage", "N1"], "--stages file not found: nofile.lua"),
                      (["--csv", BUGS / "BUG-207" / "empty.csv", "-c", "1,2"], "-c needs x,y,z"),
                      (["--csv", BUGS / "BUG-207" / "empty.csv", "-c", "x,y,z"], "-c needs x,y,z")):
        rc, out = cli(capsys, *base, "digcheck", *args)
        assert rc == 2 and msg in out and "Traceback" not in out, out


# ---------------------------------------------------------------- BUG-205 / BUG-206 / BUG-214 (water)

def test_bug205_water_check_outside_the_map_is_not_ok(tmp_path, tools_dir, cfgfile, capsys):
    rc, out = cli(capsys, "--config", cfgfile, "--replay-file", BUGS / "BUG-205" / "l_wc_e1.jsonl",
                  "water", "check", "9999", "9999", "9999")
    assert rc == 1 and out.startswith("unsafe") and "outside the map" in out
    rc, out = cli(capsys, "--config", cfgfile, "--replay-file", BUGS / "BUG-205" / "l_wc_e2.jsonl",
                  "water", "check", "-5", "-5", "-5")
    assert rc == 1 and "outside the map" in out
    from df_llm_helper.client import MockClient
    from df_llm_helper.water import WaterWatch
    mc = MockClient({"claude/status": json.dumps({"map_size": {"x": 192, "y": 192, "z": 153}})})
    v = WaterWatch(mc, None, None, None, {}).check(200, 10, 10)
    assert v.result == "unsafe" and "outside the map (192x192x153)" in v.line()
    assert not any("pilot_water" in c for c in mc.calls)


@pytest.mark.parametrize("n", [1, 2])
def test_bug206_no_emergency_wall_behind_the_front(tmp_path, tools_dir, cfgfile, capsys, n):
    rc, out = cli(capsys, "--config", cfgfile, "--replay-file", BUGS / "BUG-206" / f"water_{n}.jsonl", "water", "watch")
    assert "!! Water in the fort" in out
    assert "rb21_flut --param x=128" not in out and "lie behind the front" in out


def test_bug206_wall_between_front_and_fort_still_proposed():
    from df_llm_helper.water import DEFAULTS, fort_center, notwand_for
    c = fort_center(DEFAULTS)
    assert c == [93, 85, 133]
    assert notwand_for([150, 99, 128], [[128, 99, 128]], c) == [128, 99, 128]     # front outside, wall inside
    assert notwand_for([120, 99, 128], [[128, 99, 128]], c) is None


def test_bug214_water_arguments(tmp_path, tools_dir, cfgfile, capsys):
    base = ["--config", cfgfile, "--mock", ROOT / "fixtures" / "run5", "water"]
    for args in (["check", "1", "2"], ["check"], ["check", "a", "b", "c"], ["check", "1.5", "2", "3"],
                 ["check", "100", "100", "130", "5", "6"]):
        rc, out = cli(capsys, *base, *args)
        assert rc == 2 and "usage: water check X Y Z" in out, (args, out)
    rc, out = cli(capsys, *base, "lint-cmd")
    assert rc == 2 and "usage: water lint-cmd" in out


# ---------------------------------------------------------------- BUG-211 / BUG-212 / BUG-214 (defense)

def test_bug211_stats_ignore_job_cancels_and_sparring(tmp_path, capsys):
    from df_llm_helper.features import defense as D
    lines = (BUGS / "BUG-211" / "gamelog_samples.txt").read_text(encoding="utf-8").splitlines()
    s = D.gamelog_stats(lines)
    assert s == {"trap_lines": 0, "caught": 0, "hits": 0, "load_msgs": 3, "attack_lines": 0}
    assert not any(x.startswith("!!") for x in D.stats_lines(s))
    big = tmp_path / "gamelog.txt"
    big.write_text("filler line\n" * 2000 + "\n".join(lines) + "\n", encoding="utf-8")
    rc, out = cli(capsys, "defense", "stats", "--gamelog", big, "--tail", "7")
    assert rc == 0 and "reload problems 3" in out and "invasion announcements 0" in out and "!!" not in out
    for bad in ("0", "-5"):
        rc, out = cli(capsys, "defense", "stats", "--gamelog", big, "--tail", bad)
        assert rc == 2 and "--tail must be >= 1" in out
    got, cut = D.tail_lines(big, None, 200)                      # bounded read
    assert cut and len(got) < 30 and got[-1].startswith("The Elite Wrestler")


def test_bug212_design_name_and_lane_len_validated(tmp_path, capsys):
    terr = ROOT / "fixtures" / "v3" / "defense" / "plateau_z133.txt"
    out_dir = tmp_path / "o" / "sub"
    for name in ("../escape", "my def", "a/b", ""):
        rc, out = cli(capsys, "defense", "design", "--terrain", terr, "--out", out_dir, "--name", name)
        assert rc == 2 and "--name must be" in out, name
    assert not (tmp_path / "o" / "escape.csv").exists()
    rc, out = cli(capsys, "defense", "design", "--terrain", terr, "--lane-len", "0")
    assert rc == 2 and "--lane-len must be >= 3" in out
    import time
    t0 = time.time()
    rc, out = cli(capsys, "defense", "design", "--terrain", terr, "--lane-len", "9999")
    assert rc == 1 and "walkable tiles" in out and time.time() - t0 < 3
    rc, out = cli(capsys, "defense", "design", "--terrain", terr, "--out", out_dir, "--name", "my_def-2")
    assert rc == 0 and (out_dir / "my_def-2.csv").exists() and "quickfort run claude/my_def-2.csv" in out


def test_bug214_defense_missing_files(capsys):
    rc, out = cli(capsys, "defense", "design", "--terrain", "nofile.txt")
    assert rc == 2 and "--terrain file not found: nofile.txt" in out and "Traceback" not in out
    rc, out = cli(capsys, "defense", "status", "--file", "nofile.json")
    assert rc == 2 and "--file file not found" in out


# ---------------------------------------------------------------- BUG-217 / BUG-214 (perimeter seal + allow)

def _dump(path, cmd):
    for ln in path.read_text(encoding="utf-8").splitlines():
        d = json.loads(ln)
        if d["cmd"] == cmd:
            return json.loads(d["stdout"])
    raise KeyError(cmd)


def test_bug217_seal_explains_stair_entry_without_inside_floor(tmp_path):
    from df_llm_helper.client import MockClient
    from df_llm_helper.clock import FakeClock
    from df_llm_helper.features import perimeter as P
    from df_llm_helper.features._grid import Grid
    from df_llm_helper.toolsfs import ToolsDir
    g = Grid.from_dump(_dump(BUGS / "BUG-217" / "l_dump.jsonl", "claude/pilot_reach dump 96 91 133 102 97 133"))
    acc = P.Access([(99, 94, 133)], core=True, notrap=True)
    walls, notes = P.seal_walls(g, acc)
    assert walls == [] and notes and "seal by hand" in notes[0] and "(99,94,z133)" in notes[0]
    clock = FakeClock(0)
    per = P.Perimeter(MockClient({}, clock=clock), ToolsDir(tmp_path, clock), Store(), clock, {})
    rc, lines = per.seal([acc], grid=g)
    assert rc == 1 and "no automatic proposal" in lines[0] and "nothing to do" not in lines[0]


def test_bug217_bug214_perimeter_allow(tmp_path, tools_dir, cfgfile, capsys):
    base = ["--config", cfgfile, "--mock", ROOT / "fixtures" / "run5", "perimeter", "allow"]
    rc, out = cli(capsys, *base, "9999", "-5", "70000", "--note", "x")
    assert rc == 2 and "Refused" in out and "outside the map" in out
    rc, out = cli(capsys, *base, "100", "100", "130", "--note", "near core")
    assert rc == 0 and "WARNING" in out and "tolerance of the core" in out
    rc, out = cli(capsys, *base, "99", "94", "132", "--note", "trap stair T1")
    rc, out = cli(capsys, *base)
    assert "allowed: 99,94,132  (trap stair T1)" in out and "9999" not in out
    for bad in (["1", "2"], ["a", "b", "c"]):
        rc, out = cli(capsys, *base, *bad)
        assert rc == 2 and "usage: perimeter allow X Y Z" in out and "Traceback" not in out
    rc, out = cli(capsys, "--config", cfgfile, "--mock", ROOT / "fixtures" / "run5", "perimeter", "--grid", "nonexistent.grid")
    assert rc == 2 and "grid file not found: nonexistent.grid" in out


# ---------------------------------------------------------------- BUG-208 / BUG-209 / BUG-214 (reach)

def test_bug208_missing_points_file_is_an_error(tmp_path, tools_dir, cfgfile, capsys):
    rc, out = cli(capsys, "--config", cfgfile, "--mock", ROOT / "fixtures" / "run5", "reach", "--points", "C:/does/not/exist.yaml")
    assert rc == 2 and "points file not found" in out and "Reachable" not in out


def test_bug208_point_outside_the_map_is_a_config_error():
    from df_llm_helper.client import MockClient
    from df_llm_helper.clock import FakeClock
    from df_llm_helper.features import reach as R
    start, pts = R.load_points(BUGS / "BUG-208" / "pts_test.yaml", R.DEFAULTS["mandatory"])
    clock = FakeClock(0)
    mc = MockClient({"claude/status": json.dumps({"map_size": {"x": 192, "y": 192, "z": 153}})}, clock=clock)
    mc.prefix_handlers.append(("claude/pilot_reach check", lambda c: json.dumps(
        {"ok": True, "results": [True, True, False, False, True]})))
    mc.prefix_handlers.append(("claude/pilot_reach dump", lambda c: json.dumps({"ok": False})))
    w = R.ReachWatch(mc, Store(), clock, {}, points=pts, start=start)
    status, causes, lines = w.run(dry=True)
    assert status["OutOfMap"] is None and "OutOfMap" not in lines[0]
    assert any("config error: point OutOfMap (999,999,z999) is outside the map (192x192x153)" in ln for ln in lines)
    assert any(ln.startswith("Aussen (150,150,z130): cause unknown") and "check the points file" in ln for ln in lines)


def test_bug209_point_on_a_wall_is_a_data_error_not_a_removal(tmp_path, tools_dir, cfgfile, capsys):
    rc, out = cli(capsys, "--config", cfgfile, "--replay-file", BUGS / "BUG-209" / "l_r1.jsonl", "reach",
                  "--points", BUGS / "BUG-209" / "reach_run5_old.yaml")
    assert "Kitchens (point on a wall tile: fix the points file)" in out
    assert "lies ON a wall tile" in out and "remove it" not in out
    w = db(tmp_path).take_warnings()
    assert [x["level"] for x in w] == ["warn"]                                     # no false CRIT every check


def test_bug214_reach_wall_arguments(tmp_path, tools_dir, cfgfile, capsys):
    rc, out = cli(capsys, "--config", cfgfile, "--mock", ROOT / "fixtures" / "run5", "reach", "what-if", "--wall", "a", "b", "c")
    assert rc == 2 and "usage: reach what-if --wall X Y Z" in out and "Traceback" not in out
