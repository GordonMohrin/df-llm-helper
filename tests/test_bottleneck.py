"""Spec 07 bottleneck watcher: graph, bottleneck explanation, wood reserve, validation, line/escalation, backtest."""
import random
from pathlib import Path

import pytest

from conftest import FIX
from dfpilot import yamlmini
from dfpilot.bottleneck import (DEFAULTS, BottleneckWatch, Graph, GraphError, backtest_timeline, find_blockers,
                                load_graph, report_line, starter_budget, stock_value)
from dfpilot.caravan import CaravanPilot
from dfpilot.client import MockClient
from dfpilot.clock import FakeClock
from dfpilot.config import HOME
from dfpilot.store import Store

G = load_graph(HOME / DEFAULTS["graph"])
LIVE = FIX.parent / "run5_live"


def lbl(nid):
    """Label of a graph node as currently stored in the YAML (the graph labels are data, not code)."""
    return G.nodes[nid].get("label", nid)


def goal_lbl(gid):
    return next(g for g in G.goals if g["id"] == gid)["label"]


def stock(**kw):
    s = {"wood": 0, "coke": 0, "coal": 26, "flux": 0, "ore": {"HEMATITE": 16}, "bars": {}, "have": {},
         "chain": 0, "bucket": 0, "mechanism": 5, "blocks": 40}
    s.update(kw)
    return s


def test_wood0_coke0_coal26_bottleneck_wood():
    """Acceptance 1."""
    bs, _ = find_blockers(G, stock())
    assert bs and all(b.node == "wood" for b in bs)
    pick = [b for b in bs if b.goal == goal_lbl("pick")][0]
    assert pick.chain == [lbl("charcoal"), lbl("coke_make"), lbl("forge"), f"15 {lbl('pick')}"]
    line = report_line(bs, stock())
    assert line.startswith(f"Bottleneck: {lbl('wood')} (0). Blocks: {lbl('charcoal')} → {lbl('coke_make')} → {lbl('forge')}") and len(line) <= 160
    assert "Caravan wood" in line and "reserve 12" in line


def test_wood40_coke0_starter_only_above_reserve():
    """Acceptance 2."""
    st = stock(wood=40)
    assert starter_budget(st) == "Starter: burn at most 28 wood (wood 40, reserve 12), coke 0"
    bs, _ = find_blockers(G, st)
    assert not any(b.goal == goal_lbl("pick") for b in bs)          # starter possible -> chain free
    assert starter_budget(stock(wood=10)).startswith("Starter blocked: wood 10 ≤ reserve 12")
    assert starter_budget(stock(wood=40, coke=5)) is None
    bs, _ = find_blockers(G, stock(wood=5))
    assert any(b.node == "wood_spare" and b.label == lbl("wood_spare") and b.value == 5 for b in bs)


def test_coal_reserve_20():
    """Player 01.10.: 20 coal as reserve. Wood is not enough for the starter, coal 15 < 20 -> coal bottleneck."""
    st = stock(wood=12, coal=15)
    bs, _ = find_blockers(G, st)
    assert any(b.node == "coal" and b.value == 15 for b in bs)
    assert not any(b.node == "coal" for b in find_blockers(G, stock(wood=12, coal=21))[0])
    assert all(b.node == "wood" for b in find_blockers(G, stock(wood=0, coal=15))[0])   # emptiest bottleneck first


def test_graph_valid_and_validation_catches_errors(tmp_path):
    """Acceptance 3: no cycles, no unknown nodes."""
    assert G.validate() == [] and len(G.nodes) >= 15 and G.goals
    bad = Graph({"a": {"id": "a", "needs": ["b"]}, "b": {"id": "b", "needs": ["a"]},
                 "c": {"id": "c", "any": ["zzz"]}}, [{"id": "nix"}])
    errs = bad.validate()
    assert any("Cycle" in e for e in errs) and any("zzz" in e for e in errs) and any("nix" in e for e in errs)
    p = tmp_path / "g.yaml"
    p.write_text("nodes:\n  - {id: a, needs: [b]}\n  - {id: b, needs: [a]}\ngoals:\n  - {id: a}\n")
    with pytest.raises(GraphError):
        load_graph(p)
    p.write_text("nodes:\n  - {id: a}\n  - {id: a}\n")
    with pytest.raises(GraphError):
        load_graph(p)


@pytest.mark.parametrize("seed", range(80))
def test_property_line_short_and_blockers_empty(seed):
    rng = random.Random(seed)
    st = {"wood": rng.choice([0, 0, 5, 40, None]), "coke": rng.choice([0, 3, 30, None]),
          "coal": rng.choice([0, 26, None]), "ore": rng.choice([{}, {"HEMATITE": 9}]),
          "bars": rng.choice([{}, {"IRON": 40}]), "have": rng.choice([{}, {"WEAPON:ITEM_WEAPON_PICK": 20}]),
          "chain": rng.choice([0, 2, None]), "bucket": rng.choice([0, 2]), "mechanism": rng.choice([0, 3, None]),
          "blocks": rng.choice([0, 30])}
    st = {k: v for k, v in st.items() if v is not None}
    bs, _ = find_blockers(G, st)
    assert len(report_line(bs, st)) <= 160
    for b in bs:                                                   # bottleneck is really empty/below reserve
        v = stock_value(st, G.nodes[b.node].get("stock"), DEFAULTS)
        assert v is None or v <= DEFAULTS["wood_reserve"] or b.node not in ("wood", "wood_spare")


def test_escalation_after_20_days_and_trade_feed(tmp_path):
    """Acceptance 4 (escalation) + shopping list -> caravan."""
    clock = FakeClock(0)
    st = Store()
    bw = BottleneckWatch(MockClient({}, clock=clock), st, clock, DEFAULTS, HOME)
    out = bw.run(stock(), game_day=100.0)
    assert out[0].startswith(f"Bottleneck: {lbl('wood')}") and not any("escalate" in ln for ln in out)
    assert st.get("trade.boost_bottleneck") == ["wood"]
    assert not any("escalate" in ln for ln in bw.run(stock(), game_day=119.0))
    out = bw.run(stock(), game_day=121.0)
    assert any("for 21 game days: escalate" in ln for ln in out)
    assert any(w["key"] == "bottleneck:esc:wood" and w["level"] == "crit" for w in st.take_warnings())
    full = stock(wood=40, coke=30, bars={"IRON": 40}, have={"WEAPON:ITEM_WEAPON_PICK": 20}, chain=2, bucket=3)
    out = bw.run(full, game_day=122.0)
    assert out[0] == "No bottleneck in the production chains" and st.get("bottleneck.since") == {}
    assert st.get("trade.boost_bottleneck") == []
    st.set("trade.boost_bottleneck", ["fuel"])
    st.set("trade.boost", ["wood"])
    cp = CaravanPilot(MockClient({}), None, st, clock, {}, HOME)
    assert [w["category"] for w in cp.wants[:2]] == ["wood", "fuel"] and cp.wants[1]["must"] is True
    assert len(st.actions()) >= 2                                   # every change is logged


def test_mood_block_and_unreadable():
    clock = FakeClock(0)
    st = Store()
    st.set("mood.block_charcoal", True)
    bw = BottleneckWatch(MockClient({}, clock=clock), st, clock, DEFAULTS, HOME)
    assert any("spec 03" in ln for ln in bw.run(stock(wood=40), dry=True))
    assert "not readable" in bw.run()[0]
    bw2 = BottleneckWatch(MockClient({"claude/material status": '{"stock": {"wood": 0, "coke": 0, "coal": 3}}'},
                                     clock=clock), Store(), clock, DEFAULTS, HOME)
    assert bw2.run(dry=True)[0].startswith(f"Bottleneck: {lbl('wood')}")


def test_backtest_run5_timeline():
    """Acceptance 5: reconstructed timeline of run 5 (chronik.md/material.md) -> report >= 30 min before the diagnosis."""
    tl = yamlmini.load_file(LIVE / "engpass_timeline.yaml")
    r = backtest_timeline(tl, G)
    assert r["manual"] == "11:30" and r["lead_min"] >= 30 and r["line"].startswith(f"Bottleneck: {lbl('wood')}")
    known = [e for e in tl if "coke" in e["stock"]]                  # only entries with known coke
    r2 = backtest_timeline(known, G)
    assert r2["first_detect"] == "10:45" and r2["lead_min"] == 45


def test_cli_bottleneck(tmp_path, tools_dir, capsys):
    from dfpilot.cli import main
    c = tmp_path / "c.yaml"
    c.write_text(f"paths:\n  tools: {tools_dir}\n  scopes: {tools_dir / 'scopes'}\n  state_db: {tmp_path / 's.db'}\n"
                 f"  gamelog: {tmp_path / 'g'}\n", encoding="utf-8")
    assert main(["--config", str(c), "--mock", str(FIX), "bottleneck", "validate"]) == 0
    assert "Graph ok" in capsys.readouterr().out
    assert main(["--config", str(c), "--mock", str(FIX), "bottleneck", "--dry-run"]) == 0
    assert "Bottleneck" in capsys.readouterr().out
