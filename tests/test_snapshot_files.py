"""snapshot.lua on the real kernel writes schema-valid snap files that Python reads (CONTRACTS §9.10)
and that bp.topo.audit accepts; the inbox `snapshot` verb replies with the command id."""
import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
LUA_TESTS = ROOT / "tests" / "lua"
sys.path.insert(0, str(ROOT / "tools"))
import luahost  # noqa: E402

from df_llm_helper import files, lint, schema  # noqa: E402

needs_lua = pytest.mark.skipif(not luahost.available(), reason="lua53.dll not found")


@pytest.fixture(scope="module")
def run(tmp_path_factory):
    out = tmp_path_factory.mktemp("snap")
    r = luahost.run_file(LUA_TESTS / "snapshot_scenario.lua", [str(out)], timeout=120, paths=[LUA_TESTS])
    assert r.ok, f"exit {r.code}\n{r.out}\n{r.err}"
    assert "scenario done" in r.out
    return out / "dfllm-runtime" / "region1"


def test_snapshot_lua_lints_clean():
    assert lint.lua([str(ROOT / "lua" / "dfllm" / "snapshot.lua")]) == []


@needs_lua
def test_snap_files_validate_and_events(run):
    evs = files.tail_events(run, 0)
    ready = {e["d"]["id"]: e for e in evs if e["type"] == "SNAPSHOT_READY"}
    assert set(ready) == {"c300", "c301"}
    for e in evs:
        assert schema.validate("event", e) == [], e
    for sid, e in ready.items():
        doc = files.read_snapshot(run / e["d"]["path"])
        assert doc is not None, schema.validate("snapshot", files.read_json(run / e["d"]["path"]))
        assert doc["id"] == sid
    audit = files.read_snapshot(run / ready["c300"]["d"]["path"])
    assert audit["purpose"] == "audit" and audit["bbox"] == [0, 0, 10, 10, 8, 11]
    assert audit["rows"]["z10"][2] == "####===####"
    assert audit["rows"]["z11"][0] == "?" * 11
    assert audit["bridges"] == {"O1": "down"}
    assert audit["traps"] == [[5, 4, 10, "W", 2, 1]]
    assert files.latest_snapshot(run, "audit")["id"] == "c300"


@needs_lua
def test_snapshot_verb_replies(run):
    rep = {p.stem: json.loads(p.read_text(encoding="utf-8")) for p in (run / "outbox").glob("*.json")}
    assert rep["c300"]["ok"] is True and rep["c300"]["data"] == {"id": "c300"}
    assert rep["c301"]["ok"] is True
    assert rep["c302"]["ok"] is False
    for r in rep.values():
        assert schema.validate("outbox", r) == [], r


@needs_lua
def test_topo_audit_runs_on_the_exported_snapshot(run):
    from df_llm_helper.bp import topo
    snap = files.latest_snapshot(run, "audit")
    man = {"v": 2, "bridges": {"O1": {"role": "outer", "fp": [4, 2, 10, 6, 2, 10], "levers": [[8, 5, 10], [9, 5, 10]]}},
           "zones": {"Z3": [[2, 5, 10, 9, 7, 10]]}, "edge": [[5, 0, 10]]}
    res = topo.audit(snap, man)
    assert set(res) >= {"ok", "fails", "min_traps", "bypass", "refuge_sep", "civ_sep", "caverns"}
    args = dict(res, snap=snap["id"])
    assert schema.validate_args("audit", args) == []
