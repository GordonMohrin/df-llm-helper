"""FEATURE-002 item flow budget: `hygiene flow/caps/bins`, `mark --unforbid`, garbage bridge, flow snapshots.
Fixtures are SYNTHETIC (fixtures/v3/hygiene/*: flow_post_siege, report_bridge, piles_bins, caps_crafts)."""
import json
import shutil
import subprocess
from pathlib import Path

import pytest

from df_llm_helper.client import MockClient, Result
from df_llm_helper.clock import FakeClock
from df_llm_helper.fairplay import ExceptionRegistry, FairPlayError, check_command
from df_llm_helper.features import _itemflow as fl
from df_llm_helper.features import hygiene as hy
from df_llm_helper.store import Store
from df_llm_helper.wake import wake_check

ROOT = Path(__file__).resolve().parent.parent
FIX = ROOT / "fixtures" / "v3" / "hygiene"
LUA = shutil.which("lua5.4") or shutil.which("lua")
CRAFTS = ["FIGURINE", "AMULET", "SCEPTER", "CROWN", "RING", "EARRING", "BRACELET"]


def fx(name):
    return (FIX / name).read_text(encoding="utf-8")


@pytest.fixture
def clock():
    return FakeClock(1_790_840_000.0)


def client(clock, status="flow_post_siege.json", report="report_bridge.json", piles="piles_bins.json",
           caps="caps_crafts.json", registry=None, status_fn=None):
    m = MockClient(clock=clock, registry=registry)

    def st(cmd):
        if status_fn is not None:
            return status_fn(cmd)
        return Result.make(cmd, True, fx(status))
    m.prefix_handlers.append(("claude/pilot_hygiene status", st))
    m.set("claude/pilot_hygiene report", fx(report))
    if piles:
        m.set("claude/pilot_hygiene piles", fx(piles))
    if caps:
        m.set("claude/pilot_hygiene caps", fx(caps))
    m.set("claude/gesund krypta", (ROOT / "fixtures" / "run5" / "gesund_krypta.txt").read_text(encoding="utf-8"))
    m.set("claude/pilot_hygiene forbid", json.dumps({"ok": True, "total": 0}))
    m.prefix_handlers.append(("claude/pilot_hygiene bins_order", lambda c: json.dumps(
        {"ok": True, "applied": "--apply" in c, "n": int(c.split()[2]), "wood": 40, "order_id": 777})))
    m.prefix_handlers.append(("claude/pilot_hygiene max_bins", lambda c: json.dumps(
        {"ok": True, "applied": "--apply" in c, "id": int(c.split()[2]), "before": 30, "after": int(c.split()[3])})))
    return m


# ------------------------------------------------------------------ unit: inflow/sink arithmetic (acceptance 6)
def snap(ts, since, next_id, data):
    return {"ts": ts, "since": since, "next_id": next_id, "data": data}


def test_flow_arithmetic_two_snapshots_with_appearing_and_vanishing_types():
    s0 = snap(0, None, 1000, {"GOBLET": [100, 80, 0], "MEAT": [50, 0, 0], "BLOCKS": [10, 10, 0]})
    s1 = snap(7200, 1000, 1300, {"GOBLET": [120, 90, 40], "BLOCKS": [10, 10, 0], "FIGURINE": [30, 30, 30]})
    rows, span = fl.flow_rows([s0, s1], hours=24)
    assert span == 2.0
    g = rows["GOBLET"]
    assert (g.inflow, g.sink, g.net) == (20.0, 10.0, 10.0)        # +40 made, 100 + 40 - 120 = 20 gone, over 2 h
    assert rows["MEAT"].stock == 0 and rows["MEAT"].inflow == 0 and rows["MEAT"].sink == 25.0     # vanished
    c = rows["CRAFTS"]                                               # appeared (FIGURINE -> CRAFTS group)
    assert (c.stock, c.inflow, c.sink, c.kinds) == (30, 15.0, 0.0, {"FIGURINE"})
    assert rows["BLOCKS"].inflow == 0 and rows["BLOCKS"].sink == 0


def test_flow_broken_chain_gives_net_only_and_short_span_no_rate():
    s0 = snap(0, None, 1000, {"GOBLET": [100, 80, 0]})
    s1 = snap(3600, 900, 1300, {"GOBLET": [130, 90, 40]})            # since != previous next_id
    rows, span = fl.flow_rows([s0, s1])
    assert rows["GOBLET"].inflow is None and rows["GOBLET"].net == 30.0
    rows, span = fl.flow_rows([s0, snap(600, 1000, 1100, {"GOBLET": [101, 80, 1]})])
    assert span is None and rows["GOBLET"].net is None


def test_snapshots_roundtrip_in_state_db_and_window():
    st = Store()
    for i in range(4):
        fl.record_snapshot(st, 3600.0 * i, "g1", None if i == 0 else 1000 + i - 1, 1000 + i, {"GOBLET": 10 + i},
                           {"GOBLET": 5}, {"GOBLET": 1} if i else {})
    fl.record_snapshot(st, 99999.0, "other", None, 5, {"X": 1}, {}, {})
    snaps = fl.load_snapshots(st, "g1")
    assert len(snaps) == 4 and snaps[-1]["data"]["GOBLET"] == [13, 5, 1]
    rows, span = fl.flow_rows(snaps, hours=2)                        # window: the last 3 snapshots
    assert span == 2.0 and rows["GOBLET"].inflow == 1.0


# ------------------------------------------------------------------ acceptance 1: post siege, unreachable ignored
def test_post_siege_unreachable_line_and_kpi_uses_reachable(clock):
    m = client(clock)
    st = Store()
    h = hy.Hygiene(m, st, clock)
    lines, meas, rep = h.status()
    assert meas.has_flow and meas.actionable == 13000 and meas.loose == 15190
    assert lines[0].startswith("loose stacks 13k: boulders")
    assert "unreachable 2.2k ignored" in lines[0]
    assert any(ln.startswith("reachable loose 13000; unreachable 2190 ignored (cavern 2190, surface 0, webs 1340)")
               for ln in lines)
    out, info = h.flow()
    assert out[0].startswith("FLOW (no rate yet)")
    unl = [ln for ln in out if "unreachable" in ln and "ignored" in ln]
    assert unl and "webs 1340" in unl[0]
    boulder = [ln for ln in out if "BOULDER" in ln][0]
    assert "11553" in boulder and "11550" in boulder and "never dump" in boulder
    assert not [r for r in st.db.execute("SELECT * FROM warnings").fetchall() if "unreach" in r["text"]]


def test_flow_rates_from_two_measurements_and_crafts_growing_wakes_once(clock, tmp_path):
    base = json.loads(fx("flow_post_siege.json"))
    state = {"n": 0}

    def status(cmd):
        j = dict(base)
        parts = cmd.split()
        if state["n"]:                                   # second measurement: 2 h later, crafts grew
            assert parts[4] == "500000"                   # since = next_id of the first snapshot
            j["since"], j["next_id"] = 500000, 500400
            j["stock"] = {**base["stock"], **{k: base["stock"][k] + 20 for k in CRAFTS}}
            j["new"] = {k: 25 for k in CRAFTS}
        return Result.make(cmd, True, json.dumps(j))
    m = client(clock, status_fn=status)
    st = Store()
    h = hy.Hygiene(m, st, clock)
    h.status()
    state["n"] = 1
    clock.sleep(7200)
    out, info = h.flow(with_caps=True)
    row = [ln for ln in out if "CRAFTS(7)" in ln][0]
    # 7 x 25 = 175 made in 2 h, 7 x 5 = 35 gone: +88/h in, +18/h out
    assert "+88" in row and "+18" in row and "GROWING" in row and "above sale capacity" in row
    assert any("cap above sale capacity" in ln for ln in out)
    wake = [ln for ln in hy.flow_transitions(h, info, clock.now().epoch, False) if "crafts" in ln]
    assert len(wake) == 1 and wake[0].startswith("WAKE hygiene: crafts GROWING")
    assert hy.flow_transitions(h, info, clock.now().epoch, False) == []          # same state: no repeat
    lines = wake_check(_tools(tmp_path, clock), st, clock, emit_existing=True)
    assert sum("crafts GROWING" in ln for ln in lines) == 1


def _tools(tmp_path, clock):
    from df_llm_helper.toolsfs import ToolsDir
    t = tmp_path / "tools"
    t.mkdir(exist_ok=True)
    (t / "events.log").write_text("", encoding="utf-8")
    return ToolsDir(t, clock)


# ------------------------------------------------------------------ acceptance 3: caps
def test_caps_audit_crafts_cap_above_sale_capacity_and_other_verdicts():
    caps = json.loads(fx("caps_crafts.json"))
    lines = fl.caps_audit(caps, hy.DEFAULTS["flow"])
    assert any("450 per kind x 7 kinds = 3150 > sale capacity 800" in ln and "cap above sale capacity" in ln
               for ln in lines)
    assert any("stock 3300 = 4.1x the sale capacity" in ln for ln in lines)
    assert any("GOBLET < 60, stock 420 - cap exceeded" in ln for ln in lines)
    assert any("BLOCKS < 400, stock 700 - cap exceeded" in ln for ln in lines)
    assert any("BARREL < 10, stock 30 [empty] - cap counts differently" in ln for ln in lines)
    assert any("BED < 40, stock 10 - cap above stock" in ln for ln in lines)
    assert any("FIGURINE < 450, stock 450 (400 in containers) - cap counts differently" in ln for ln in lines)
    assert fl.caps_audit(None, {})[0].startswith("caps: not readable")


def test_cli_caps_and_flow_read_only(clock, monkeypatch, capsys):
    import df_llm_helper.cli as cli
    from df_llm_helper.config import load_config
    from df_llm_helper.pilot import Pilot
    m = client(clock)
    monkeypatch.setattr(cli, "_pilot", lambda args: Pilot(load_config(overrides={}), m, store=Store(), clock=clock))
    assert cli.main(["hygiene", "caps"]) == 0
    assert "cap above sale capacity" in capsys.readouterr().out
    assert cli.main(["hygiene", "flow", "--caps", "--dry-run"]) == 0
    out = capsys.readouterr().out
    assert "FLOW" in out and "garbage bridge #4406" in out
    assert m.write_calls == []


# ------------------------------------------------------------------ acceptance 4: bins
def test_bin_plan_needs_8_bins_warns_mismatch(clock):
    piles = json.loads(fx("piles_bins.json"))
    plan = fl.bin_plan({"GOBLET": 369, "FIGURINE": 200, "RING": 210, "BOULDER": 9999}, piles, hy.DEFAULTS["flow"])
    assert plan["loose_total"] == 779 and plan["need"] == 8 and plan["bins_total"] == 30
    assert plan["max_bins_sum"] == 147 and plan["mismatch"] and plan["target"]["id"] == 900
    lines = fl.bin_lines(plan)
    assert "need 8 bins (wood cost 8 logs" in lines[0]
    assert any(ln.startswith("! max_bins sum 147 > bins that exist 30") for ln in lines)


def _bins_status(base_reach):
    j = json.loads(fx("flow_post_siege.json"))
    j["reach_type"] = base_reach
    return json.dumps(j)


def test_bins_apply_refused_without_exception_and_one_order_with_it(clock, tmp_path):
    reach = {"GOBLET": 369, "FIGURINE": 200, "RING": 210}
    m = client(clock, status_fn=lambda c: Result.make(c, True, _bins_status(reach)))
    h = hy.Hygiene(m, Store(), clock)
    out = h.bins()                                                   # dry run
    assert any(ln.startswith("[dry] would order 8 bins") for ln in out) and m.write_calls == []
    out = h.bins(apply=True)
    assert "exception-register entry FP14" in out[-1] and m.write_calls == []
    reg = ExceptionRegistry(tmp_path / "exc.jsonl", now_iso="2026-10-03T10:00:00Z")
    reg.add("FP14", "bin planner", "ja, Kisten bauen")
    m2 = client(clock, registry=reg, status_fn=lambda c: Result.make(c, True, _bins_status(reach)))
    st = Store()
    out = hy.Hygiene(m2, st, clock).bins(apply=True)                # biggest pile #900: max_bins 30 >= 12 + 8
    orders = [c for c in m2.write_calls if "bins_order" in c]
    assert orders == ["claude/pilot_hygiene bins_order 8 --reserve 10 --apply"]
    assert not [c for c in m2.write_calls if "max_bins" in c] and any("unchanged" in ln for ln in out)
    assert any("ordered 8 bins" in ln for ln in out)
    m3 = client(clock, registry=reg, status_fn=lambda c: Result.make(c, True, _bins_status(reach)))
    out = hy.Hygiene(m3, st, clock).bins(apply=True, pile=902)       # pile #902: 8 bins + 8 > max_bins 15
    assert [c for c in m3.write_calls if "max_bins" in c] == ["claude/pilot_hygiene max_bins 902 16 --apply"]
    assert any("max_bins 30 -> 16" in ln for ln in out)
    assert [a["action"] for a in st.actions()] == ["bins_order", "bins_order", "max_bins"]


def test_fp14_gate_blocks_bin_writes_without_entry():
    with pytest.raises(FairPlayError):
        check_command("claude/pilot_hygiene bins_order 8 --apply")
    with pytest.raises(FairPlayError):
        check_command("claude/pilot_hygiene max_bins 900 20 --apply")
    check_command("claude/pilot_hygiene bins_order 8 --dry")        # dry run is free


# ------------------------------------------------------------------ acceptance 5: garbage bridge
def test_bridge_landing_hint_and_wake_only_on_change(clock, monkeypatch, capsys, tmp_path):
    import df_llm_helper.cli as cli
    from df_llm_helper.config import load_config
    from df_llm_helper.pilot import Pilot
    st = Store()
    m = client(clock)
    monkeypatch.setattr(cli, "_pilot", lambda args: Pilot(load_config(overrides={}), m, store=st, clock=clock))
    assert cli.main(["hygiene", "zones"]) == 0
    out = capsys.readouterr().out
    assert "garbage bridge #4406" in out and "654 items on the landing" in out and "pull the lever (player action)" in out
    assert "lever #4410" in out and "raised" in out
    assert "WAKE hygiene: garbage bridge #4406" in out
    assert cli.main(["hygiene", "zones"]) == 0
    out2 = capsys.readouterr().out
    assert "654 items on the landing" in out2 and "WAKE" not in out2
    assert len(wake_check(_tools(tmp_path, clock), st, clock, emit_existing=True)) == 1


# ------------------------------------------------------------------ acceptance 2: legacy forbidden pile (Lua)
def run_lua(tmp_path, items, *args, buildings=None, env=None):
    ip = tmp_path / "items.json"
    ip.write_text(json.dumps(items), encoding="utf-8")
    e = {"MOCK_ITEMS": str(ip), "PATH": "/usr/bin:/bin"}
    for name, data in (("MOCK_BUILDINGS", buildings),):
        if data is not None:
            p = tmp_path / f"{name}.json"
            p.write_text(json.dumps(data), encoding="utf-8")
            e[name] = str(p)
    e.update(env or {})
    r = subprocess.run([LUA, str(FIX / "hygiene_mock.lua"), str(ROOT / "lua" / "pilot_hygiene.lua"), *args],
                       capture_output=True, text=True, timeout=30, env=e)
    assert r.returncode == 0, r.stderr
    lines = r.stdout.strip().splitlines()
    tail = {ln.split(" ", 1)[0]: json.loads(ln.split(" ", 1)[1]) for ln in lines[1:]}
    return json.loads(lines[0]), tail


def legacy_items():
    items = []
    for i in range(160):                           # forbidden animal/goblin corpses and parts near the dump zone
        items.append({"id": 1000 + i, "type": "CORPSE" if i % 2 else "CORPSEPIECE", "x": 20 + i % 40, "y": 20 + i // 40,
                      "z": 130, "forbid": True, "race": 100})
    for i in range(134):                           # forbidden dwarf corpses: never touched
        items.append({"id": 5000 + i, "type": "CORPSE", "x": 20 + i % 40, "y": 40 + i // 40, "z": 130,
                      "forbid": True, "race": 572})
    items += [{"id": 9000, "type": "CORPSEPIECE", "x": 70, "y": 70, "z": 130, "forbid": True, "bone": True},
              {"id": 9001, "type": "CORPSE", "x": 71, "y": 70, "z": 120, "forbid": True, "reach": False},
              {"id": 9002, "type": "GOBLET", "x": 72, "y": 70, "z": 130, "forbid": True},
              {"id": 9003, "type": "CORPSE", "x": 73, "y": 70, "z": 130}]          # not forbidden: normal mark
    return items


ZONE = [{"id": 538, "x1": 18, "y1": 18, "x2": 19, "y2": 19, "z": 130}]


@pytest.mark.skipif(not LUA, reason="lua5.4 not installed")
def test_lua_legacy_pile_status_dry_and_apply(tmp_path):
    items = legacy_items()
    out, tail = run_lua(tmp_path, items, "status", "0", "1000", buildings=ZONE)
    assert out["forb_corpses"] == {"other": 160, "bone": 1, "dwarf": 134}
    out, tail = run_lua(tmp_path, items, "mark", "300", "CORPSE,CORPSEPIECE,REMAINS", "--unforbid", "--dry",
                        buildings=ZONE)
    assert out["unforbid"] is True and out["candidates"] == 160 and out["marked"] == 0
    assert sorted(out["ids"]) == list(range(1000, 1160)) and not tail["STATE"]
    assert len(tail["FORBIDDEN"]) == 160 + 134 + 3
    out, tail = run_lua(tmp_path, items, "mark", "300", "CORPSE,CORPSEPIECE,REMAINS", "--unforbid", "--apply",
                        buildings=ZONE)
    assert out["marked"] == 160 and sorted(tail["STATE"]) == list(range(1000, 1160))
    still = set(tail["FORBIDDEN"])
    assert set(range(5000, 5134)) <= still and {9000, 9001, 9002} <= still and not still & set(range(1000, 1160))
    assert out["refused"]["dwarf"] == 134 and out["refused"]["bone"] == 1 and out["refused"]["unreachable"] == 1


@pytest.mark.skipif(not LUA, reason="lua5.4 not installed")
def test_lua_status_flow_fields_and_since(tmp_path):
    items = [{"id": 1, "type": "GOBLET", "x": 20, "y": 20, "z": 130, "n": 1},
             {"id": 7, "type": "GOBLET", "x": 21, "y": 20, "z": 130},
             {"id": 8, "type": "THREAD", "x": 22, "y": 20, "z": 120, "reach": False},
             {"id": 9, "type": "BOULDER", "x": 23, "y": 20, "z": 131, "outside": True, "reach": False},
             {"id": 10, "type": "BAR", "x": 24, "y": 20, "z": 130, "n": 5, "trader": True},
             {"id": 11, "type": "BIN", "x": 25, "y": 20, "z": 130},
             {"id": 12, "type": "RING", "x": 25, "y": 20, "z": 130, "container": 11}]
    out, _ = run_lua(tmp_path, items, "status", "0", "100", "7", env={"MOCK_NEXT_ID": "13"})
    assert out["stock"] == {"GOBLET": 2, "THREAD": 1, "BOULDER": 1, "BIN": 1, "RING": 1}   # trader bar is no stock
    assert out["new"] == {"GOBLET": 1, "THREAD": 1, "BOULDER": 1, "BIN": 1, "RING": 1}
    assert out["reach_type"] == {"GOBLET": 2, "BIN": 1}
    assert out["unreach"] == {"cavern": 1, "surface": 1, "thread": 1}
    assert out["next_id"] == 13 and out["since"] == 7


@pytest.mark.skipif(not LUA, reason="lua5.4 not installed")
def test_lua_report_bridge_piles_caps_and_bin_order(tmp_path):
    items = [{"id": i, "type": "CORPSE", "x": 131, "y": 106, "z": 141} for i in range(1, 6)]
    items += [{"id": 50, "type": "BIN", "x": 60, "y": 60, "z": 130}, {"id": 51, "type": "GOBLET", "x": 61, "y": 60, "z": 130},
              {"id": 52, "type": "BIN", "x": 10, "y": 10, "z": 130}, {"id": 53, "type": "WOOD", "x": 11, "y": 10, "z": 130, "n": 12},
              {"id": 54, "type": "FIGURINE", "x": 12, "y": 10, "z": 130},
              {"id": 55, "type": "FIGURINE", "x": 60, "y": 60, "z": 130, "container": 50}]
    blds = [{"id": 538, "kind": "Civzone", "x1": 130, "y1": 105, "x2": 132, "y2": 107, "z": 141},
            {"id": 4406, "kind": "Bridge", "x1": 130, "y1": 105, "x2": 132, "y2": 107, "z": 141, "raised": True,
             "levers": [4410]},
            {"id": 495, "kind": "Stockpile", "x1": 60, "y1": 60, "x2": 62, "y2": 61, "z": 130,
             "cats": ["finished_goods"], "max_bins": 5}]
    st = tmp_path / "st.json"
    st.write_text(json.dumps({"forbid_other_dead_items": 1}), encoding="utf-8")
    out, _ = run_lua(tmp_path, items, "report", buildings=blds, env={"MOCK_STANDING": str(st)})
    b = out["bridges"][0]
    assert (b["id"], b["state"], b["items"], b["levers"], b["zone"]) == (4406, "raised", 5, [4410], 538)
    assert out["standing"] == {"forbid_other_dead_items": True}
    out, _ = run_lua(tmp_path, items, "piles", buildings=blds)
    p = out["piles"][0]
    assert (p["id"], p["tiles"], p["free"], p["bins"], p["bins_empty"], p["max_bins"]) == (495, 6, 4, 1, 0, 5)
    assert out["bins"] == {"total": 2, "empty": 1, "in_pile": 1, "outside": 1, "in_job": 0} and out["wood"] == 12
    orders = tmp_path / "o.json"
    orders.write_text(json.dumps([{"id": 1, "job": "MakeCrafts", "left": 3, "total": 8,
                                   "conds": [{"cmp": "LessThan", "value": 450, "type": "FIGURINE"}]}]), encoding="utf-8")
    out, _ = run_lua(tmp_path, items, "caps", buildings=blds, env={"MOCK_ORDERS": str(orders)})
    assert out["orders"][0]["conds"][0] == {"cmp": "LessThan", "flags": "", "subtype": -1, "type": "FIGURINE", "value": 450}
    assert out["stock"]["FIGURINE"] == {"stock": 2, "in_container": 1, "loose": 1}
    out, tail = run_lua(tmp_path, items, "bins_order", "3", "--reserve", "5", buildings=blds)
    assert out["ok"] and not out["applied"] and not tail["ORDERS"]
    out, _ = run_lua(tmp_path, items, "bins_order", "8", "--reserve", "5", "--apply", buildings=blds)
    assert out["ok"] is False and "not enough free logs: 12 < 8" in out["reason"]
    out, tail = run_lua(tmp_path, items, "bins_order", "3", "--apply", buildings=blds)
    assert out["applied"] and [o["job"] for o in tail["ORDERS"]] == ["ConstructBin"]
    assert tail["ORDERS"][0]["freq"] == "OneTime" and tail["ORDERS"][0]["total"] == 3 and tail["ORDERS"][0]["mc"] == "wood"
    open_o = tmp_path / "open.json"
    open_o.write_text(json.dumps([{"id": 5, "job": "ConstructBin", "left": 2, "total": 4}]), encoding="utf-8")
    out, tail = run_lua(tmp_path, items, "bins_order", "3", "--apply", buildings=blds, env={"MOCK_ORDERS": str(open_o)})
    assert out["ok"] is False and "still open (#5" in out["reason"] and len(tail["ORDERS"]) == 1
    out, tail = run_lua(tmp_path, items, "max_bins", "495", "9", buildings=blds)
    assert not out["applied"] and tail["MAXBINS"] == [[495, 5]]
    out, tail = run_lua(tmp_path, items, "max_bins", "495", "9", "--apply", buildings=blds)
    assert out["before"] == 5 and tail["MAXBINS"] == [[495, 9]]


# ------------------------------------------------------------------ hygiene mark --unforbid through Python
def test_cycle_unforbid_dry_lists_ids_apply_logs(clock):
    m = client(clock)
    m.set("claude/pilot_hygiene report", fx("report_bridge.json"))
    ids = list(range(1000, 1160))

    def mark(cmd):
        return json.dumps({"ok": True, "unforbid": True, "applied": "--apply" in cmd, "candidates": 160,
                           "marked": 160 if "--apply" in cmd else 0, "ids": ids,
                           "refused": {"dwarf": 134, "bone": 0, "boulder": 0, "unreachable": 0}})
    m.prefix_handlers.append(("claude/pilot_hygiene mark", mark))
    st = Store()
    h = hy.Hygiene(m, st, clock)
    out = h.cycle(unforbid=True)
    assert any(ln.startswith("[dry] would unforbid + dump-mark 160") for ln in out)
    assert out[-1] == "ids: " + ",".join(map(str, ids)) and m.write_calls == []
    cmd = [c for c in m.calls if c.startswith("claude/pilot_hygiene mark")][-1]
    assert "--unforbid" in cmd and cmd.endswith("--dry") and "CORPSE" in cmd
    out = h.cycle(apply=True, unforbid=True)
    assert any("Unforbid + dump-marked 160" in ln for ln in out)
    assert st.actions()[-1]["action"] == "unforbid"


def test_cycle_unforbid_refuses_old_lua(clock):
    m = client(clock)
    m.prefix_handlers.append(("claude/pilot_hygiene mark", lambda c: json.dumps(
        {"ok": True, "applied": False, "candidates": 3, "marked": 0, "refused": {}})))
    out = hy.Hygiene(m, Store(), clock).cycle(apply=True, unforbid=True)
    assert "does not know --unforbid" in out[-1] and m.write_calls == []


def test_status_reports_legacy_forbidden_and_standing_order(clock):
    j = json.loads(fx("flow_post_siege.json"))
    j["forb_corpses"] = {"other": 160, "bone": 3, "dwarf": 134}
    m = client(clock, status_fn=lambda c: Result.make(c, True, json.dumps(j)))
    lines, _, _ = hy.Hygiene(m, Store(), clock).status(record=False)
    leg = [ln for ln in lines if ln.startswith("forbidden reachable non-dwarf corpses: 160")]
    assert leg and "3 bones/skins kept" in leg[0] and "134 dwarf/named never touched" in leg[0]
    assert any(ln.startswith("standing order forbid_other_dead_items=1") for ln in lines)


# ------------------------------------------------------------------ check hook: wake lines on state changes only
def test_check_hook_wakes_on_bridge_once(clock, cfg):
    from df_llm_helper.pilot import Pilot
    m = client(clock)
    p = Pilot(cfg, m, store=Store(), clock=clock)
    lines = hy.check_hook(p, None, False)
    assert sum("garbage bridge #4406" in ln for ln in lines) == 1
    clock.sleep(3600)
    lines = hy.check_hook(p, None, False)
    assert not [ln for ln in lines if "garbage bridge" in ln]


# ------------------------------------------------------------------ rule 6: muell dump keeps bones
_MUELL_SETUP = """
df.item_type = { [0] = 'CORPSE', [1] = 'CORPSEPIECE', CORPSE = 0, CORPSEPIECE = 1 }
df.building_type = { Stockpile = 1, Civzone = 2 }
df.civzone_type = { [3] = 'Dump' }
df.general_ref_type = { CONTAINED_IN_ITEM = 1 }
df.global.plotinfo.race_id = 572
local zone = { x1 = 10, y1 = 10, x2 = 12, y2 = 12, z = 130, type = 3, getType = function() return 2 end }
df.global.world.buildings.all = { zone }
local function item(id, t, bone, race)
  return { id = id, _t = t, race = race or 100, corpse_flags = { bone = bone },
           flags = { on_ground = true, dump = false, forbid = false }, getType = function(s) return s._t end }
end
MOCK_LIST = { item(1, 1, true), item(2, 1, false), item(3, 0, false), item(4, 0, false, 572) }
df.global.world.items.all = MOCK_LIST
dfhack.items.getGeneralRef = function() return nil end
dfhack.items.getPosition = function(it) return 20 + it.id, 20, 130 end
dfhack.buildings.findAtTile = function() return nil end
dfhack.maps.getWalkableGroup = function() return 7 end
dfhack.matinfo.decode = function() return nil end
"""


@pytest.mark.skipif(not LUA, reason="lua5.4 not installed")
def test_muell_dump_never_dumps_bones(tmp_path):
    mock = ROOT / "tests" / "lua_mock" / "claude_mock.lua"
    home = tmp_path / "home"
    (home / "tools" / "out").mkdir(parents=True)
    setup = tmp_path / "setup.lua"
    setup.write_text(_MUELL_SETUP, encoding="utf-8")
    after = tmp_path / "after.lua"
    after.write_text("local d = {} for _, it in ipairs(MOCK_LIST) do if it.flags.dump then d[#d + 1] = it.id end end "
                     "print('DUMPED ' .. table.concat(d, ','))\n", encoding="utf-8")
    r = subprocess.run([LUA, str(mock), str(ROOT / "lua" / "claude" / "muell.lua"), "dump", "10"], capture_output=True,
                       text=True, timeout=10, env={"PATH": "/usr/bin:/bin", "DF_LLM_HELPER_HOME": str(home),
                                                   "MOCK_HOME": str(home), "MOCK_SETUP": str(setup),
                                                   "MOCK_AFTER": str(after)})
    assert r.returncode == 0, r.stderr
    out = r.stdout.strip().splitlines()
    j = json.loads(out[0])
    assert j["marked"] == 2 and j["uebersprungen"]["knochen"] == 1 and j["uebersprungen"]["dwarf"] == 1
    assert out[-1] == "DUMPED 2,3"
