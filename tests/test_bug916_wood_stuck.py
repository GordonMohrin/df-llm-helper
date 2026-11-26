"""NEU16b BUG-916: WOOD_STUCK is in the schema and the contract (the Lua side: tests/lua/test_bug916_wood_stuck.lua)."""
import pathlib

from dfpilot import schema


def test_wood_stuck_event_is_in_the_schema_and_the_contract():
    cls, by, spec = schema.EVENTS["WOOD_STUCK"]
    assert (cls, by) == ("B", "economy")
    for k in ("nw", "loose", "fo", "ff", "d"):
        assert k in spec.req
    for k in ("new", "newnw", "mode"):
        assert k in spec.opt
    lua = (pathlib.Path(__file__).resolve().parent.parent / "lua" / "dfllm" / "util" / "contract.lua").read_text(encoding="utf-8")
    assert "WOOD_STUCK = {cls = 'B', by = 'economy'}" in lua
