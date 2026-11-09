"""Round 39 (economy blockers; offline, live-untested): BUG-611 (no traps without trap parts). The Lua parts have their own tests
(tests/lua/test_bug607_612_econ.lua, test_trade_act.lua)."""
from __future__ import annotations

from dfpilot import plan, schema

from test_bug581_585_f37_econ import _draft, hospital_state  # noqa: F401 (fixture)


def test_noparts_reason_needs_no_free_mechanism_and_no_way_to_make_one():
    assert plan.noparts_reason({"stock": {"mfree": 0, "mroute": "no stone"}})
    assert "Mechanics" in plan.noparts_reason({"stock": {"mfree": 0, "mroute": "no Mechanics"}})
    assert plan.noparts_reason({"stock": {"mfree": 3, "mroute": "no stone"}}) == ""          # parts stand
    assert plan.noparts_reason({"stock": {"mfree": 0, "mroute": "ordered"}}) == ""           # on the way
    assert plan.noparts_reason({"stock": {"mfree": 0}}) == ""                                # no shortfall
    assert plan.noparts_reason({"stock": {}}) == "" and plan.noparts_reason(None) == ""       # an older kernel


def test_traps_are_left_out_without_trap_parts_whatever_the_stone():
    fort = {"nostone": "", "noparts": "no trap parts (mechanisms) and no stone to make them from"}
    doc = _draft([{"tpl": "traps", "site": "S1"}, {"tpl": "bedrooms", "site": "S1"}, {"tpl": "temple", "site": "S1"}])
    note = plan.drop_impossible(doc, None, fort)
    # the temple needs stone, not parts: it stays; the traps go
    assert [b["tpl"] for b in doc["seasons"][0]["build"]] == ["bedrooms", "temple"] and "traps" in note and "trap parts" in note
    warn = plan.stone_gate(_draft([{"tpl": "traps", "site": "S1"}, {"tpl": "temple", "site": "S1"}]), None, fort)
    assert len(warn) == 1 and warn[0].startswith("traps") and "no trap parts" in warn[0]
    ok = _draft([{"tpl": "traps", "site": "S1"}])
    assert plan.drop_impossible(ok, None, {"nostone": "", "noparts": ""}) == "" and len(ok["seasons"][0]["build"]) == 1


def test_a_new_hospital_bench_waits_for_a_mechanism_too(hospital_state, tmp_path):
    hospital_state["s"] = {}
    doc = _draft([{"tpl": "hospital", "site": "S1", "p": {"beds": 6}}])
    notes = plan.hospital_table(tmp_path, doc, None, {"nostone": "", "noparts": "no trap parts (mechanisms) and no stone to make them from"})
    assert doc["seasons"][0]["build"][0]["p"] == {"beds": 6, "bench": 0} and notes


def test_the_mechanism_state_keys_are_in_the_schema():
    for k in ("stock.mfree", "stock.mroute"):
        assert schema.STATE_OWNERS[k] == "economy"
