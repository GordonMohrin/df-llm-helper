"""Feature requests FR-01/10/16/17/18/23/25/29/32/39/40/43/46/50 on the Python side: the inbox verbs order.add and
jobs.release, the new inspect targets, the FR-39 crash list shared with lua/dfllm/orderlib.lua, and lint."""
import json
import sys
from pathlib import Path

import pytest
from cli_v2_helpers import FakeKern, inbox_docs, make_runtime, reset_paths

from dfpilot import cmd, lint, schema
from dfpilot.cli import main

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import luahost  # noqa: E402

needs_lua = pytest.mark.skipif(not luahost.available(), reason="no Lua 5.3 for luahost")


@pytest.fixture
def save(tmp_path):
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def run(save, *argv):
    return main(["--runtime", str(save.parent), *argv])


def test_order_add_args():
    """FR-39: a make-item job without item_subtype is refused before anything is written."""
    for job in ("MakeArmor", "MakePants", "MakeShoes", "MakeGloves", "MakeHelm", "MakeWeapon", "MakeAmmo", "MakeShield"):
        errs = schema.validate_args("order.add", {"job": job, "amount": 3, "material_category": ["cloth"]})
        assert errs and "item_subtype" in errs[0], job
    assert schema.validate_args("order.add", {"job": "MakeArmor", "amount": 3, "item_subtype": "ITEM_ARMOR_SHIRT",
                                              "material_category": ["cloth"]}) == []
    assert schema.validate_args("order.add", {"job": "BrewDrink", "amount": 5}) == []
    assert schema.validate_args("order.add", {"job": "MakeArmor", "amount": 0, "item_subtype": "ITEM_ARMOR_SHIRT"})
    assert schema.validate_args("order.add", {"job": "MakeArmor", "amount": 1, "item_subtype": "shirt"})
    assert schema.validate_args("order.add", {"job": "BrewDrink", "amount": 1, "frequency": "Hourly"})


def test_order_add_engrave_slab_args():
    """BUG-078: the memorial slab order names its figure; hf belongs to EngraveSlab only."""
    ok = {"job": "EngraveSlab", "amount": 1, "hf": 6001}
    assert schema.validate_args("order.add", ok) == []
    assert schema.validate_args("order.add", {"job": "EngraveSlab", "amount": 1})
    assert schema.validate_args("order.add", dict(ok, amount=2))
    assert schema.validate_args("order.add", {"job": "ConstructSlab", "amount": 1, "hf": 6001})
    assert schema.validate_args("order.add", dict(ok, hf=-1))


def test_jobs_release_and_inspect_args():
    assert schema.validate_args("jobs.release", {}) == []
    assert schema.validate_args("jobs.release", {"all": True, "preventblocking": False}) == []
    assert schema.validate_args("jobs.release", {"all": "yes"})
    for what in ("orders", "workload", "trade"):
        assert schema.validate_args("inspect", {"what": what}) == [], what
    assert schema.VERBS["order.add"] == ("economy", None, False)
    assert schema.VERBS["jobs.release"] == ("economy", None, False)


def test_cmd_order_add_refused_not_sent(save, capsys):
    assert run(save, "cmd", "order.add", "job=MakeArmor", "amount=10", '--by', 'llm') == cmd.EXIT_BAD
    out = capsys.readouterr().out
    assert out.startswith("refused (not sent)") and "item_subtype" in out
    assert inbox_docs(save) == []


def test_cmd_order_add_sent(save, capsys):
    with FakeKern(save, lambda d: (True, "order 7 MakeArmor x2", {"order": 7})) as k:
        assert run(save, "cmd", "order.add", '{"job":"MakeArmor","amount":2,"item_subtype":"ITEM_ARMOR_SHIRT",'
                   '"material_category":["cloth"]}') == 0
    (doc,) = k.seen
    assert doc["verb"] == "order.add" and doc["args"]["item_subtype"] == "ITEM_ARMOR_SHIRT"


def test_new_events_registered():
    for t, c, by in (("ORDER_BAD", "A", "economy"), ("ORDER_STUCK", "B", "economy"),
                     ("JOBS_SUSPENDED", "B", "economy"), ("DEPOT_MISSING", "A", "trade"),
                     ("TRADE_LEDGER", "B", "trade")):
        assert schema.EVENTS[t][:2] == (c, by), t
    e = {"n": 1, "tick": 5, "type": "ORDER_BAD", "cls": "A", "msg": "x", "d": {"order": 3, "job": "MakeArmor", "dropped": 1}}
    assert schema.validate("event", e) == []
    e["d"] = {"order": "3"}
    assert schema.validate("event", e)


@needs_lua
def test_subtype_jobs_match_orderlib(tmp_path):
    """The Python refusal and the kernel guard know the same job list."""
    f = tmp_path / "probe.lua"
    f.write_text("local OL = require('dfllm.orderlib'); local r = {}; for k in pairs(OL.SUBTYPE_JOBS) do r[#r + 1] = k end; "
                 "table.sort(r); print('jobs ' .. table.concat(r, ','))", encoding="utf-8")
    r = luahost.run_file(f, [], timeout=20)
    assert r.ok, r.out + r.err
    line = next(x for x in r.out.splitlines() if x.startswith("jobs "))
    assert set(line[5:].split(",")) == set(schema.SUBTYPE_JOBS)


def test_new_lua_files_lint_clean():
    files = [str(ROOT / "lua" / "dfllm" / n) for n in ("orderlib.lua", "economy.lua", "act.lua", "military.lua",
                                                      "trade.lua", "runner.lua", "kern.lua")]
    assert lint.lua(files) == []
