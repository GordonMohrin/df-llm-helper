"""Spec 02 caravan autopilot: decision, approval, skip without pause, stuck merchants, report."""
import json
import random
import shutil
import subprocess
from pathlib import Path

import pytest

from df_llm_helper.caravan import CaravanPilot, Good, classify, decide, dry_ok, load_wants, parse_list
from df_llm_helper.client import MockClient
from df_llm_helper.clock import FakeClock
from df_llm_helper.fairplay import ExceptionRegistry
from df_llm_helper.planners import TradeItem, plan_trade
from df_llm_helper.store import Store
from df_llm_helper.toolsfs import ToolsDir
from helpers import ROOT

LIVE = ROOT / "fixtures" / "run5_live"
WANTS = load_wants(ROOT / "data" / "trade" / "wants.yaml")
THEIRS = json.loads((LIVE / "handel_list_theirs.json").read_text(encoding="utf-8"))
OURS = json.loads((LIVE / "handel_list_ours.json").read_text(encoding="utf-8"))
SELECT = json.loads((LIVE / "handel_select_dry.json").read_text(encoding="utf-8"))
LUA = shutil.which("lua5.4") or shutil.which("lua")


def test_parse_real_offer_and_classify():
    offer = parse_list(THEIRS, WANTS)
    assert len(offer) == THEIRS["count"]
    cats = {g.category for g in offer}
    assert {"wood", "food", "cloth", "containers"} <= cats
    assert parse_list({"x": 1}, WANTS) is None and parse_list(None, WANTS) is None
    assert classify("BAR", "iron bars", WANTS) == "metal" and classify("BAR", "coke", WANTS) == "fuel"
    assert classify("WEAPON", "iron pick", WANTS) == "tools" and classify("WEAPON", "iron sword", WANTS) == "other"


def test_catten_small_plan_buys_wood_and_food():
    lines = ["0|WOOD|v3|n1|---|willow", "1|WOOD|v3|n1|---|maple", "2|WOOD|v3|n1|---|larch", "3|WOOD|v3|n1|---|pine",
             "4|WOOD|v3|n1|---|oak", "5|MEAT|v10|n5|---|mule meat [5]", "6|PLANT|v20|n5|---|celery [5]",
             "7|CLOTH|v30|n1|---|silk cloth"]
    offer = parse_list({"lines": lines}, WANTS)
    dec, musts = decide(offer, WANTS)
    assert dec == "trade" and musts == {"wood": 5, "food": 10}
    ours = parse_list(OURS, WANTS)
    prio = [w["category"] for w in WANTS]
    plan = plan_trade([TradeItem(f"o{g.idx}", g.name, "crafts", g.value, 1.0, g.qty) for g in ours],
                      [TradeItem(f"t{g.idx}", g.name, g.category, g.value, 1.0, g.qty) for g in offer],
                      ratio=2.0, priorities=prio + ["other"])
    bought = {ln.category for ln in plan.buy}
    assert {"wood", "food"} <= bought and plan.ratio >= 2.0


def test_offer_without_must_is_skip():
    offer = parse_list({"lines": ["0|CLOTH|v30|n1|---|silk cloth", "1|SKIN_TANNED|v5|n1|---|yak leather"]}, WANTS)
    assert decide(offer, WANTS) == ("skip", {})
    assert decide(offer, WANTS, skip_if_empty=False)[0] == "trade"
    assert decide(None, WANTS)[0] == "unknown"


def test_dry_ok_real_select():
    offer = parse_list(THEIRS, WANTS)
    ok, why = dry_ok(SELECT, offer, WANTS, 2.0)
    assert isinstance(ok, bool) and why
    assert dry_ok({"ok": False, "abort": "ratio too small"}, [], WANTS, 2.0)[0] is False
    assert dry_ok({"ratio_x100": 150}, [], WANTS, 2.0) == (False, "Ratio 1.50 < 2.0")
    sel = {"ratio_x100": 240, "buy_top": [{"i": 0, "d": "willow"}]}
    assert dry_ok(sel, [Good(0, "WOOD", 3, 1, "willow", "wood")], WANTS, 2.0)[0] is True
    assert dry_ok({"ratio_x100": 240, "buy_top": [{"i": 9, "d": "silk cloth"}]}, [], WANTS, 2.0)[0] is False
    assert dry_ok(None, [], WANTS, 2.0)[0] is False


class World:
    """Small game world for the mock: reacts to trade commands."""

    def __init__(self, offer_lines, caravan_state="AtDepot"):
        self.paused, self.broker, self.open = False, False, False
        self.caravan = caravan_state
        self.offer = offer_lines

    def status(self, _):
        cars = [] if self.caravan is None else [{"name": "Catten", "state": self.caravan, "time_remaining": 0
                                                 if self.caravan == "Leaving" else 1500}]
        return json.dumps({"caravans": cars, "broker": {"in_depot": self.broker, "job": "TradeAtDepot"},
                           "focus": ["dwarfmode/Trade/Default" if self.open else "dwarfmode/Default"],
                           "trade_ui": {"open": self.open}})

    def handle(self, mc):
        mc.set("claude/handel status", self.status)
        mc.set("claude/advance clock", lambda c: json.dumps({"paused": self.paused}))
        mc.set("claude/handel list 0", lambda c: json.dumps({"which": 0, "count": len(self.offer), "lines": self.offer}))
        mc.set("claude/handel select --dry", lambda c: json.dumps(
            {"ok": True, "ratio_x100": 250, "buy_top": [{"i": 0, "d": self.offer[0].split("|")[-1]}]}))

        def eff(cmd):
            if cmd == "claude/advance 0":
                self.paused = True
            elif cmd == "claude/advance run":
                self.paused = False
            elif cmd.startswith("claude/handel broker"):
                self.broker = True
            elif cmd == "claude/handel open --live":
                self.open = True
            elif cmd in ("claude/handel finish --live",):
                self.open = False
            return ""
        for c in ["claude/advance 0", "claude/advance run", "quicksave", "claude/handel prep --live",
                  "claude/handel broker --live --force-job", "claude/handel plan", "claude/handel mark --live",
                  "claude/handel open --live", "claude/handel select --live", "claude/handel confirm --live",
                  "claude/handel accept --live", "claude/handel finish --live", "claude/handel release --live",
                  "claude/handel abort --live"]:
            mc.set(c, (lambda cc: (lambda _: eff(cc)))(c))


def pilot(tmp_path, world, registry=None):
    clock = FakeClock(0)
    mc = MockClient({}, clock=clock)
    world.handle(mc)
    tools = ToolsDir(tmp_path, clock)
    tools.write_flag("caravan", "Caravan")
    (tmp_path / "pause.hold").write_text("caravan")
    return CaravanPilot(mc, tools, Store(), clock, {}, ROOT, registry=registry), mc, tools


def drive(cp, n=30, **kw):
    states = []
    for _ in range(n):
        s, _ = cp.step(**kw)
        states.append(s)
        if s in ("done", "skip", "abort", "failed", "idle"):
            break
        cp.clock.advance(5)
    return states


def test_full_trade_with_must_goods(tmp_path):
    w = World(["0|WOOD|v3|n1|---|willow", "1|MEAT|v10|n5|---|mule meat [5]"])
    cp, mc, tools = pilot(tmp_path, w)
    states = drive(cp)
    assert states[-1] == "done"
    w_calls = mc.write_calls
    assert w_calls.index("quicksave") < w_calls.index("claude/handel select --live") < w_calls.index("claude/handel confirm --live")
    assert w_calls[-1] == "claude/advance run" and not tools.flag("caravan").exists
    rep = cp.report()
    assert len(rep) <= 8 and any("Must-have goods in offer: wood 1, food 5" in r for r in rep)
    assert any(r.startswith("approved") for r in rep)


def test_skip_without_must_no_long_pause(tmp_path):
    w = World(["0|CLOTH|v30|n1|---|silk cloth"])
    cp, mc, tools = pilot(tmp_path, w)
    states = drive(cp)
    assert states[-1] == "skip"
    assert "claude/handel select --live" not in mc.write_calls and mc.write_calls[-1] == "claude/advance run"
    assert not tools.flag("caravan").exists and not (tmp_path / "pause.hold").exists()


def test_abort_mid_trade_mentions_quicksave(tmp_path):
    w = World(["0|WOOD|v3|n1|---|willow"])
    cp, mc, tools = pilot(tmp_path, w)
    for _ in range(8):
        s, _ = cp.step()
        if s == "review" or cp._load().flow.get("state") in ("SELECT_LIVE", "CONFIRM"):
            break
    w.caravan = "Leaving"
    s, _ = cp.step()
    assert s == "abort" and any("quicksave" in r for r in cp.report())
    assert "claude/handel release --live" in mc.write_calls


def test_stuck_caravan_release_needs_register(tmp_path):
    w = World([], caravan_state="Leaving")
    cp, mc, tools = pilot(tmp_path, w)
    cp.step(game_tick=1000)
    cp.step(game_tick=4000)
    assert not any("pilot_caravan" in c for c in mc.calls)
    assert any("FP09" in r for r in cp.report())
    reg = ExceptionRegistry(tmp_path / "ex.jsonl")
    reg.add("FP09", "stuck merchants", "yes, standing permission")
    cp2, mc2, tools2 = pilot(tmp_path / "b", World([], caravan_state="Leaving"), registry=reg)
    mc2.set("claude/pilot_caravan release --apply", '{"ok": true, "released": 4}')
    cp2.step(game_tick=1000)
    cp2.step(game_tick=1500)
    assert not any("pilot_caravan" in c for c in mc2.calls)            # not long enough yet
    cp2.step(game_tick=3100)
    assert "claude/pilot_caravan release --apply" in mc2.calls
    assert any("4 units" in r for r in cp2.report())
    assert (tmp_path / "b" / "out" / "caravan-release.log").exists()
    cp2.step(game_tick=9000)
    assert mc2.calls.count("claude/pilot_caravan release --apply") == 1


def test_orphan_flag_and_idle(tmp_path):
    cp, mc, tools = pilot(tmp_path, World([], caravan_state=None))
    from conftest import set_age
    set_age(tools.flag_path("caravan"), cp.clock, 10)
    s, log = cp.step()
    assert s == "idle" and not tools.flag("caravan").exists
    s, _ = pilot(tmp_path / "x", World([], caravan_state="Approaching"))[0].step()
    assert s == "waiting"


def test_dry_run_no_writes(tmp_path):
    cp, mc, tools = pilot(tmp_path, World(["0|WOOD|v3|n1|---|willow"]))
    s, log = cp.step(dry=True)
    assert mc.write_calls == [] and log and all(x.startswith("[dry]") for x in log)


@pytest.mark.skipif(not LUA, reason="lua5.4 missing")
@pytest.mark.parametrize("seed", range(25))
def test_lua_release_only_merchants_property(tmp_path, seed):
    rng = random.Random(seed)
    units = []
    for i in range(rng.randint(1, 25)):
        u = {"id": i + 1, "merchant": rng.random() < 0.4, "citizen": rng.random() < 0.4, "pet": rng.random() < 0.2,
             "fort": rng.random() < 0.2, "left": rng.random() < 0.1}
        units.append(u)
    f = tmp_path / "u.json"
    f.write_text(json.dumps(units))
    r = subprocess.run([LUA, str(ROOT / "tests" / "lua_mock" / "dfhack_mock.lua"), str(ROOT / "lua" / "pilot_caravan.lua"),
                        "release", "--apply"], capture_output=True, text=True, timeout=20, env={"MOCK_UNITS": str(f)})
    left = json.loads([ln for ln in r.stdout.splitlines() if ln.startswith("LEFT ")][0][5:])
    for u in units:
        if u["id"] in left and not u["left"]:
            assert u["merchant"] and not u["citizen"] and not u["pet"] and not u["fort"], u
        if u["merchant"] and not (u["citizen"] or u["pet"] or u["fort"]):
            assert u["id"] in left


def test_cli_caravan(tmp_path, tools_dir, capsys):
    from conftest import FIX
    from df_llm_helper.cli import main
    c = tmp_path / "c.yaml"
    c.write_text(f"paths:\n  tools: {tools_dir}\n  scopes: {tools_dir / 'scopes'}\n  state_db: {tmp_path / 's.db'}\n"
                 f"  gamelog: {tmp_path / 'g'}\n", encoding="utf-8")
    assert main(["--config", str(c), "--mock", str(FIX), "caravan", "--dry-run"]) == 0
    assert "Caravan:" in capsys.readouterr().out
    main(["--config", str(c), "--mock", str(FIX), "caravan", "status"])
    main(["--config", str(c), "--mock", str(FIX), "caravan", "reset"])
    assert "reset" in capsys.readouterr().out
