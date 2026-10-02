"""Spec 01 siege autopilot: state machine, runner with mock (replay 'Elves 31'), safety."""
import json

import pytest

from df_llm_helper.client import MockClient
from df_llm_helper.clock import FakeClock
from df_llm_helper.siege import DEFAULTS, SiegeFlow, SiegeObs, SiegeRunner, obs_from_status
from df_llm_helper.store import Store
from df_llm_helper.toolsfs import ToolsDir

SID = 33


def status(invaders, members=None, civ=0, berserk=None, name="Wache"):
    members = members if members is not None else [{"id": 3748, "alive": True, "blood_pct": 100, "dist": 5},
                                                   {"id": 4080, "alive": True, "blood_pct": 100, "dist": 5},
                                                   {"id": 3473, "alive": True, "blood_pct": 100, "dist": 5}]
    return json.dumps({"invaders": invaders, "berserk": berserk or [], "civ_alert": civ,
                       "squads": [{"id": 32, "name": "Bergleute", "orders": 0, "members": []},
                                  {"id": SID, "name": name, "orders": 0, "members": members}]})


def elves(n, dist, start=5000):
    return [{"id": start + i, "race": "ELF", "prof": "BOWMAN" if i % 3 else "SWORDSMAN", "dist": dist} for i in range(n)]


def runner(tmp_path, statuses, cfg=None):
    clock = FakeClock(0)
    seq = list(statuses)
    m = MockClient({"claude/advance clock": '{"paused": true}'}, clock=clock)
    m.set("claude/pilot_siege status", lambda c: seq.pop(0) if len(seq) > 1 else seq[0])
    tools = ToolsDir(tmp_path, clock)
    for f in ("alert", "siege"):
        tools.write_flag(f, "Elfen")
    (tmp_path / "pause.hold").write_text("alarm")
    return SiegeRunner(m, tools, Store(), clock, {**DEFAULTS, **(cfg or {})}), m, tools


def test_replay_elfen_31_full_cycle(tmp_path):
    sts = [status(elves(31, 80)), status(elves(31, 80)), status(elves(31, 50)), status(elves(25, 30), civ=0),
           status(elves(12, 20), civ=1), status(elves(4, 10), civ=1), status([], civ=1)]
    r, m, tools = runner(tmp_path, sts)
    flow, log = r.run()
    assert flow.state == "DONE"
    w = m.write_calls
    assert w[0] == "claude/advance 0"
    assert "claude/alert on" in w
    kills = [c for c in w if c.startswith("claude/pilot_siege kill 33 ")]
    assert kills and all("claude/pilot_siege kill 32" not in c for c in w)      # never the miners
    assert w[-3:] == ["claude/pilot_siege clear 33", "claude/alert off", "claude/advance run"]
    assert not tools.flag("alert").exists and not tools.flag("siege").exists and not (tmp_path / "pause.hold").exists()
    steps = [c for c in w if c.startswith("claude/advance ") and c.split()[-1].isdigit() and c != "claude/advance 0"]
    assert steps[0] == "claude/advance 300" and "claude/advance 60" in steps            # adaptive
    lines = flow.summary()
    assert len(lines) <= 12 and lines[0].startswith("Siege finished: 31 attackers")


def test_soldier_low_blood_retreat_and_message(tmp_path):
    weak = [{"id": 3748, "alive": True, "blood_pct": 40, "dist": 5}, {"id": 4080, "alive": True, "blood_pct": 90}]
    r, m, tools = runner(tmp_path, [status(elves(3, 20), members=weak, civ=1)] * 3 + [status([], civ=1)],
                         cfg={"rally": [100, 105, 128]})
    flow, _ = r.run()
    assert "claude/pilot_siege move 33 100 105 128" in m.write_calls
    assert any("Retreat: 3748 blood 40%" in n for n in flow.notify)
    flow2 = SiegeFlow()
    flow2.step(SiegeObs(invaders=elves(2, 10), squad={"id": SID, "members": weak}))
    cmds = flow2.step(SiegeObs(invaders=elves(2, 10), squad={"id": SID, "members": weak}))
    assert any("no rally point" in n for n in flow2.notify) and any("kill" in c for c in cmds)


def test_fleeing_enemy_no_pursuit(tmp_path):
    r, m, tools = runner(tmp_path, [status(elves(5, 75)), status(elves(5, 75)), status(elves(5, 82))])
    flow, _ = r.run()
    assert flow.state == "DONE" and not any("kill" in c for c in m.write_calls)   # never in kill radius, fleeing
    r, m, tools = runner(tmp_path / "b", [status(elves(5, 40)), status(elves(5, 40)), status(elves(5, 72))])
    flow, _ = r.run()
    assert flow.state == "DONE"
    last_kill = max(i for i, c in enumerate(m.write_calls) if "kill" in c)
    assert m.write_calls[last_kill + 1:] [-3:] == ["claude/pilot_siege clear 33", "claude/alert off", "claude/advance run"]


def test_berserk_citizen_only_reported(tmp_path):
    r, m, tools = runner(tmp_path, [status([], berserk=[{"id": 4155}])])
    flow, _ = r.run()
    assert not any("kill" in c for c in m.write_calls)
    f = SiegeFlow()
    f.step(SiegeObs(invaders=[], berserk=[{"id": 4155}], squad={"id": SID, "members": []}))
    assert f.notify == ["Citizen 4155 berserk: NO kill order (citizen); keep civilians away"]


def test_max_steps_abort_clears_orders_and_dry_run(tmp_path):
    r, m, tools = runner(tmp_path, [status(elves(3, 20), civ=1)], cfg={"max_steps": 4})
    flow, _ = r.run()
    assert flow.state == "ABORT" and "claude/pilot_siege clear 33" in m.write_calls
    assert tools.flag("notify").exists and "loop guard" in tools.flag("notify").text
    r, m, tools = runner(tmp_path / "d", [status(elves(3, 20))])
    flow, log = r.run(dry=True)
    assert m.write_calls == [] and all(x.startswith("[dry] ") for x in log) and log


def test_losses_abort_and_missing_squad(tmp_path):
    full = [{"id": i, "alive": True, "blood_pct": 100} for i in (1, 2, 3, 4)]
    f = SiegeFlow()
    f.step(SiegeObs(invaders=elves(5, 20), squad={"id": SID, "members": full}))
    cmds = f.step(SiegeObs(invaders=elves(5, 20), squad={"id": SID, "members": full[:1]}))
    assert f.state == "ABORT" and "claude/advance 0" in cmds and "claude/pilot_siege clear 33" in cmds
    g = SiegeFlow()
    g.step(SiegeObs(invaders=elves(2, 20), squad=None))
    assert g.state == "ABORT" and "not found" in g.notify[0]
    assert SiegeFlow(state="DONE").step(SiegeObs()) == []


def test_exception_still_clears_orders(tmp_path):
    clock = FakeClock(0)
    calls = {"n": 0}

    def st(c):
        calls["n"] += 1
        if calls["n"] > 2:
            raise RuntimeError("DF gone")
        return status(elves(3, 20), civ=1)
    m = MockClient({"claude/advance clock": '{"paused": true}'}, clock=clock)
    m.set("claude/pilot_siege status", st)
    r = SiegeRunner(m, ToolsDir(tmp_path, clock), Store(), clock, DEFAULTS)
    with pytest.raises(RuntimeError):
        r.run()
    assert m.write_calls[-1] == "claude/pilot_siege clear 33"


def test_obs_parsing_and_unreadable(tmp_path):
    o = obs_from_status(json.loads(status(elves(1, 9), name="Die Wache")), "Wache")
    assert o.squad["id"] == SID and o.invaders[0]["id"] == 5000
    assert obs_from_status(None, "Wache").ok is False
    clock = FakeClock(0)
    m = MockClient({}, clock=clock)
    r = SiegeRunner(m, ToolsDir(tmp_path, clock), Store(), clock, DEFAULTS)
    flow, _ = r.run()
    assert flow.state == "ABORT" and "not readable" in flow.notify[0]


def test_cli_siege(tmp_path, tools_dir, capsys):
    from conftest import FIX
    from df_llm_helper.cli import main
    c = tmp_path / "c.yaml"
    c.write_text(f"paths:\n  tools: {tools_dir}\n  scopes: {tools_dir / 'scopes'}\n  state_db: {tmp_path / 's.db'}\n"
                 f"  gamelog: {tmp_path / 'g'}\n", encoding="utf-8")
    rc = main(["--config", str(c), "--mock", str(FIX), "siege", "--dry-run"])
    out = capsys.readouterr().out
    assert "Siege ABORTED" in out or "no attackers" in out


def test_alert_on_sent_only_once_per_step():
    """Close attackers while the civilian alert is off: PREPARE and ENGAGE run in the same step, 'alert on' once."""
    flow = SiegeFlow()
    cmds = flow.step(SiegeObs(invaders=elves(2, 30), squad={"id": SID, "members": [{"id": 1, "alive": True}]}))
    assert cmds.count("claude/alert on") == 1
    assert cmds[0] == "claude/advance 0" and any(c.startswith("claude/pilot_siege kill 33") for c in cmds)
