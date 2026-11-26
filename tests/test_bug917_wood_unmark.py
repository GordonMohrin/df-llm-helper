"""NEU16c BUG-917: WOOD_UNMARK and act tree_unmark are in the schema and the contract (the Lua side: tests/lua/test_bug917_wood_unmark.lua)."""
import pathlib

from dfpilot import schema


def test_wood_unmark_event_and_act_are_in_the_schema_and_the_contract():
    cls, by, spec = schema.EVENTS["WOOD_UNMARK"]
    assert (cls, by) == ("B", "economy")
    assert "ph" in spec.req
    for k in ("n", "off", "des", "sample", "band", "run", "new", "newnw", "trees", "days", "why"):
        assert k in spec.opt
    lua = (pathlib.Path(__file__).resolve().parent.parent / "lua" / "dfllm" / "util" / "contract.lua").read_text(encoding="utf-8")
    assert "WOOD_UNMARK = {cls = 'B', by = 'economy'}" in lua
    assert "tree_unmark = {'economy'}" in lua
