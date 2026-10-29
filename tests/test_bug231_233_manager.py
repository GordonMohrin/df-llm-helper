"""BUG-231..233 (live Guildcleans, run 15, y372-y373, pop 20): the manager had no office zone, so none of the 22 manager
work orders was validated for ~330 days; the office project waited for the chair and table those orders made. The Python
side: the status line says what happens and what the kernel does about it ('manager: N orders unvalidated for D days: no
office (chair+table needed) -> kernel adds workshop tasks: ...'), the wake hint and RULES ask for no click a player
without hands cannot make, follow places the workshop economy asks for (why=manager), the office comes with P0 and its
zone before its furniture, the new act/event/state fields are in the contracts, the knobs are range-checked. Every test
fails on 6dc0f19."""
import json
from pathlib import Path

import pytest
from cli_v2_helpers import append_events, ev, inbox_docs, install_fake_bp, make_runtime, reset_paths

from dfpilot import brief, cmd, fairplay, schema, wake
from dfpilot.bp import rooms

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def put_orders(save, orders):
    for slot in "ab":
        p = save / f"state.{slot}.json"
        doc = json.loads(p.read_text("utf-8"))
        doc["orders"] = orders
        assert schema.validate("state", doc) == [], schema.validate("state", doc)
        p.write_text(json.dumps(doc), encoding="utf-8")


def test_status_says_why_and_what_the_kernel_does(save):
    """Live y373: `orders: 13 unvalidated, oldest 58 d: the manager has no office zone` and nothing about a way out."""
    put_orders(save, {"n": 22, "bad": 0, "stuck": 0, "unval": 22, "uval_d": 330, "mgr": "no office (chair+table needed)",
                      "byp": "kernel adds workshop tasks: chair, table, door x3"})
    out = brief.status_text(save)
    assert ("manager: 22 orders unvalidated for 330 days: no office (chair+table needed) -> kernel adds workshop tasks: "
            "chair, table, door x3") in out, out
    # the kernel's request for a shop shows the same way; byp alone (an absent manager) still has a line
    put_orders(save, {"n": 2, "bad": 0, "stuck": 0, "byp": "no Carpenters: workshop requested for chair, table"})
    assert "manager: orders held -> no Carpenters: workshop requested for chair, table" in brief.status_text(save)


def test_state_event_and_act_contracts():
    st = {"n": 1, "bad": 0, "stuck": 0, "byp": "b" * 81}
    assert schema.ACT["ws_task"] == ["economy"]
    assert schema.EVENTS["MANAGER_BYPASS"][:2] == ("B", "economy")
    e = {"n": 4, "tick": 9, "type": "MANAGER_BYPASS", "cls": "B", "msg": "manager orders held 6 d",
         "d": {"days": 6, "n": 2, "tasks": "chair (wood) at 412, table (wood) at 412", "why": "no office (chair+table needed)"}}
    assert schema.validate("event", e) == []
    assert schema.validate("event", dict(e, d={"days": 6})) != []
    from dfpilot.schema import STATE
    assert "byp" in STATE.opt["orders"].opt and st["byp"]
    lua = (ROOT / "lua" / "dfllm" / "util" / "contract.lua").read_text("utf-8")
    assert "ws_task = {'economy'}" in lua and "MANAGER_BYPASS = {cls = 'B', by = 'economy'}" in lua and "byp = str(80)" in lua
    text = (ROOT / "docs" / "v2" / "CONTRACTS.md").read_text("utf-8")
    assert "`ws_task(bld_id, job, mat)`" in text and "| MANAGER_BYPASS | B | economy |" in text


def test_nothing_asks_for_a_click_at_a_workshop():
    """RULES §7 and the wake hint told the game session to add the task at a workshop by hand: impossible for it."""
    rules = (ROOT / "RULES.md").read_text("utf-8")
    assert "add the task at a workshop by hand" not in rules
    assert "MANAGER_BYPASS" in rules and "`orders.bypass_days`" in rules
    hint = wake.next_hint("DECISION_NEEDED", {"d": {"id": "manager_office"}})
    assert "workshop tasks itself" in hint and "by hand" not in hint and "bp.place tpl=office site=S1" in hint
    eco = (ROOT / "lua" / "dfllm" / "economy.lua").read_text("utf-8")
    assert "add it at a workshop by hand" not in eco


def test_follow_places_the_workshop_the_bypass_asks_for(save, monkeypatch):
    from test_cli_wake import F, Clock
    install_fake_bp(monkeypatch)
    for p in cmd.bp_files(save):
        p.unlink()
    from dfpilot.bp.rooms import MOODABLE_TYPES
    c = Clock()
    f, out = F(c)
    f.poll()
    append_events(save, [ev(9201, "PROJECT_REQUEST", "workshops: no Carpenters workshop for the tasks the manager holds back",
                            {"tpl": "workshops", "n": 1, "why": "manager", "types": ["Carpenters"]})])
    f.poll()
    (snap_cmd,) = inbox_docs(save)
    assert snap_cmd["verb"] == "snapshot"
    assert f.jobs["manager"]["need"] == ["Carpenters"]
    assert f.jobs["manager"]["params"] == {"skip": ",".join(t for t in MOODABLE_TYPES if t != "Carpenters")}


def test_the_office_is_a_p0_build_with_its_zone_first():
    """BUG-232: the office was a P1 deliverable after dining, its zone stage behind its chair and table."""
    doc = json.loads((ROOT / "plans" / "year1.json").read_text("utf-8"))
    assert schema.validate("phases", doc) == []
    p0 = [d.get("tpl") for d in doc["phases"][0]["deliver"] if d["k"] == "proj"]
    assert p0 == ["fortcore", "office", "farms"]
    assert all(d.get("tpl") != "office" for p in doc["phases"][1:] for d in p["deliver"])
    P = rooms.office({"role": "manager", "burrow": "Kern+"})
    assert [s.label for s in P.stages] == ["dig", "zone", "build", "burrow"]
    rules = (ROOT / "RULES.md").read_text("utf-8")
    assert "| P0 | baseline; probe stair" in rules and "office (manager: zone first" in rules


def test_zone_place_takes_an_office_and_the_new_knobs_are_checked(tmp_path):
    assert "office" in schema.ZONE_TYPES
    assert schema.validate_args("zone.place", {"type": "office", "bbox": [1, 1, 5, 2, 1, 5]}) == []
    cfg = json.loads((ROOT / "config" / "baseline.json").read_text("utf-8"))
    eco = cfg["economy"]
    assert {k: eco["orders"][k] for k in ("bypass_days", "bypass_max", "bypass_open")} == \
        {"bypass_days": 5, "bypass_max": 4, "bypass_open": 8}
    assert eco["office"]["zone"] is True
    assert fairplay.economy_errors() == []
    eco["orders"]["bypass_days"] = 200
    eco["office"]["zone"] = 1
    p = tmp_path / "baseline.json"
    p.write_text(json.dumps(cfg), encoding="utf-8")
    errs = fairplay.economy_errors(p)
    assert "config/baseline.json: economy.orders.bypass_days: int 0..112 expected, got 200" in errs, errs
    assert any("economy.office.zone" in e for e in errs), errs
