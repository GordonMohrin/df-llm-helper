"""FR-22/24/33/37/54/56/57, FR-59/60: the files the real kernel writes with seal.lua validate against dfpilot.schema,
and Python shows them (status line, inspect replies, the verb perimeter.record).

tests/lua/seal_scenario.lua boots lua/dfllm/kern.lua (real act.lua: burrows screen paint) on the seal_world map
and drives REFUGE_FAIL + the interior burrow, SEAL/SEAL_LEAK after a lever pull, PERIMETER_BROKEN after a siege,
CUTOFF after a wall line and the five inspect views into a temp DF folder.
"""
import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
LUA_TESTS = ROOT / "tests" / "lua"
sys.path.insert(0, str(ROOT / "tools"))
import luahost  # noqa: E402

from dfpilot import brief, files, lint, schema  # noqa: E402

needs_lua = pytest.mark.skipif(not luahost.available(), reason="lua53.dll not found")


@pytest.fixture(scope="module")
def run(tmp_path_factory):
    out = tmp_path_factory.mktemp("seal")
    r = luahost.run_file(LUA_TESTS / "seal_scenario.lua", [str(out)], timeout=180, paths=[LUA_TESTS])
    assert r.ok, f"exit {r.code}\n{r.out}\n{r.err}"
    assert "scenario done" in r.out
    return out / "dfllm-runtime" / "region1"


def by_type(evs, t):
    return [e for e in evs if e["type"] == t]


def reply(run, cid):
    return json.loads((run / "outbox" / f"{cid}.json").read_text(encoding="utf-8"))


def test_seal_lua_lints_clean():
    assert lint.lua([str(ROOT / "lua" / "dfllm" / "seal.lua")]) == []


def test_contract_names():
    assert [m[0] for m in schema.MODULES].index("seal") == [m[0] for m in schema.MODULES].index("snapshot") + 1
    for t, cls in (("CUTOFF", "A"), ("SEAL_LEAK", "A"), ("PERIMETER_BROKEN", "A"), ("REFUGE_FAIL", "A"),
                   ("SEAL", "B"), ("REACH", "B")):
        assert schema.EVENTS[t][:2] == (cls, "seal")
    assert schema.ACT["burrow_tiles"] == ["seal"]
    for what in ("reach", "entrances", "defense", "perimeter", "refuge"):
        assert schema.validate_args("inspect", {"what": what}) == []
    assert schema.validate_args("inspect", {"what": "nope"}) != []
    assert schema.VERBS["perimeter.record"] == ("seal", None, False)          # FR-60
    assert schema.validate_args("perimeter.record", {}) == []
    assert schema.validate_args("perimeter.record", {"all": True}) != []
    assert schema.validate("event", {"n": 1, "tick": 5, "type": "CUTOFF", "cls": "A", "msg": "x",
                                     "d": {"cls": "food", "n": 3, "pos": [1, 2, 3], "why": "wall"}}) == []


@needs_lua
def test_every_event_and_reply_validates(run):
    evs = files.tail_events(run, 0)
    for e in evs:
        assert schema.validate("event", e) == [], e
    for p in sorted((run / "outbox").glob("*.json")):
        doc = json.loads(p.read_text(encoding="utf-8"))
        assert schema.validate("outbox", doc) == [], p.name
        assert len(json.dumps(doc.get("data"), separators=(",", ":"))) <= 8192, p.name
    st = files.read_state(run)
    assert st is not None and schema.validate("state", st) == []


@needs_lua
def test_class_a_events(run):
    evs = files.tail_events(run, 0)
    f = by_type(evs, "REFUGE_FAIL")
    assert len(f) == 1 and f[0]["d"]["burrow"] == "Kern+" and f[0]["d"]["fallback"] == "Innen+"
    assert "drink 0<3" in f[0]["d"]["why"]
    leaks = by_type(evs, "SEAL_LEAK")
    assert [(e["d"]["pos"], e["d"]["why"]) for e in leaks] == [([30, 30, 9], "lever"), ([40, 26, 9], "siege")]
    assert "wall 40,26,9 missing" in leaks[1]["msg"]       # the destroyed shaft-head wall of Run 9
    pb = by_type(evs, "PERIMETER_BROKEN")
    assert len(pb) == 1 and pb[0]["d"]["pos"] == [40, 26, 9] and pb[0]["d"]["requeued"] == 1
    cut = by_type(evs, "CUTOFF")
    assert len(cut) == 1
    d = cut[0]["d"]
    assert (d["cls"], d["n"], d["why"], d["pos"][0]) == ("food", 1, "wall", 33)
    assert any(e["d"].get("sealed") == 0 for e in by_type(evs, "SEAL"))


@needs_lua
def test_inspect_replies(run):
    r = reply(run, "i1")
    assert r["ok"] and r["data"]["cut"] == {"food": 0, "drink": 0, "bed": 0} and r["data"]["flags"] == []
    assert r["data"]["classes"]["drink"]["n"] == 30          # FR-59: 10 on the floor + 20 in a barrel
    r = reply(run, "i2")
    assert r["ok"] and r["msg"].startswith("LEAK at 20,25,9 (Bridge down)") and r["data"]["routes"] == 1
    r = reply(run, "i3")
    b = r["data"]["bridges"][0]
    assert (b["name"], b["state"], b["walk"]["through"]) == ("O1", "down", "open")
    assert b["levers"][0]["linked"] == 1 and b["levers"][0]["pos"] == [25, 22, 9]
    r = reply(run, "i4")
    au = r["data"]["burrows"]
    assert au["Kern+"]["ok"] == 0 and au["Innen+"]["ok"] == 1 and au["Innen+"]["tiles"] > 100
    assert r["data"]["choice"]["ALERT"] == {"want": "Kern+", "burrow": "Innen+"}
    r = reply(run, "i5")
    assert r["ok"] and r["data"]["by"]["wall"] == 1 and r["data"]["diff"]["gone"] == ["40,26,9"]
    r = reply(run, "i6")
    assert r["data"]["cut"]["food"] == 1
    assert reply(run, "i7")["ok"] is False


@needs_lua
def test_interior_burrow_painted_through_act(run):
    lines = (run / "commands.log").read_text(encoding="utf-8").splitlines()
    paint = [x for x in lines if "\tact.burrow_tiles\t" in x]
    assert paint and all(x.split("\t")[2] == "seal" and x.endswith("\tok") for x in paint)
    assert '"Innen+"' in paint[0]


@needs_lua
def test_status_prints_the_alert_burrow(run):
    st = files.read_state(run)
    assert st["alert"]["want"] == "Kern+" and st["alert"]["burrow"] == "Innen+" and st["alert"]["ok"] == 0
    out = brief.status_text(run)
    assert f"alert Innen+ {st['alert']['tiles']}t" in out and "(Kern+ refused: Kern+:" in out


@needs_lua
def test_perimeter_record_verb(run):
    """FR-60: perimeter.record goes through the inbox (seal's verb), the next entrance check serves it and
    inspect perimeter shows the result."""
    r = reply(run, "i8")
    assert r["ok"] and r["verb"] == "perimeter.record" and r["data"]["queued"] == 1
    p = reply(run, "i9")
    assert p["ok"] and p["data"]["queued"] == 0
    rec = p["data"]["rec"]
    assert rec["n"] == p["data"]["n"] and rec["added"] >= 0
