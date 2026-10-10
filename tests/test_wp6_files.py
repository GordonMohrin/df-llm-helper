"""WP6: military, drill and readiness on the real Lua kernel write only schema-valid files.

tests/lua/wp6_scenario.lua boots lua/dfllm/kern.lua (real act.lua, persist, io, repo config) with the
WP5 reflex modules and the WP6 modules on k_mock's fake DF: squads adopted from the UI and filled
through act.squad_add, an audit, a plan with pop ceiling 75, two drills, popcap.lower, a siege with
kill orders and a sortie, RECOVERY and PEACE, all driven through inbox files.
"""
import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
LUA_TESTS = ROOT / "tests" / "lua"
sys.path.insert(0, str(ROOT / "tools"))
import luahost  # noqa: E402

from df_llm_helper import schema  # noqa: E402

pytestmark = pytest.mark.skipif(not luahost.available(), reason="lua53.dll not found")


@pytest.fixture(scope="module")
def run(tmp_path_factory):
    out = tmp_path_factory.mktemp("wp6")
    r = luahost.run_file(LUA_TESTS / "wp6_scenario.lua", [str(out)], timeout=120, paths=[LUA_TESTS])
    assert r.ok, f"exit {r.code}\n{r.out}\n{r.err}"
    assert "scenario done" in r.out
    return out


def sd(out: Path) -> Path:
    return out / "dfllm-runtime" / "region1"


def events(out: Path) -> list[dict]:
    return [json.loads(x) for x in (sd(out) / "events.jsonl").read_text(encoding="utf-8").splitlines() if x]


def of(evs, t):
    return [e for e in evs if e["type"] == t]


def test_every_event_validates_and_no_faults(run):
    evs = events(run)
    for e in evs:
        assert schema.validate("event", e) == [], e
    types = {e["type"] for e in evs}
    for t in ("POPCAP", "READY_CHANGE", "AUDIT", "DRILL_RESULT", "SIEGE_START", "SIEGE_END"):
        assert t in types, t
    for t in ("KERN_FAULT", "ACT_FAIL", "DRILL_FAIL", "GATE_FAIL", "BREACH", "KERNEL_SLOW"):
        assert t not in types, [e for e in evs if e["type"] == t]


def test_drills_levels_and_caps(run):
    evs = events(run)
    assert [e["d"]["pass"] for e in of(evs, "DRILL_RESULT")] == [1, 1]
    for e in of(evs, "DRILL_RESULT"):
        assert 0 <= e["d"]["raised"] <= 900 and e["d"]["worn"] >= 90 and e["d"]["outside"] == 0 and e["d"]["dbl"] == 0
    assert [(e["d"]["from"], e["d"]["to"]) for e in of(evs, "READY_CHANGE")] == [(0, 1), (1, 2), (2, 1), (1, 2)]
    assert of(evs, "READY_CHANGE")[2]["d"]["fail"] == ["redrill"], "a siege needs a new drill"
    assert [(e["d"]["cap"], e["d"]["why"]) for e in of(evs, "POPCAP")] == [
        (55, "R0"), (75, "R2"), (60, "inbox"), (55, "R1"), (60, "inbox")]
    modes = [e["d"]["from"] + ">" + e["d"]["to"] for e in of(evs, "MODE")]
    assert modes == ["PEACE>DRILL", "DRILL>PEACE", "PEACE>SIEGE", "SIEGE>RECOVERY", "RECOVERY>PEACE",
                     "PEACE>DRILL", "DRILL>PEACE"]


def test_state_slots_validate_with_wp6_keys(run):
    docs = [json.loads((sd(run) / f"state.{s}.json").read_text(encoding="utf-8")) for s in "ab"]
    for d in docs:
        assert schema.validate("state", d) == [], d
        assert len(json.dumps(d, separators=(",", ":"))) <= 4096
    best = max(docs, key=lambda d: d["seq"])
    assert best["mil"] == {"squads": 3, "soldiers": 8, "worn": 100, "cv": 13, "metal_pct": 0, "on_station": 0}
    assert best["ready"]["lvl"] == 2 and best["ready"]["fail"] == ["option_a", "metal<20%"]
    assert best["ready"]["audit"]["ok"] == 1 and best["ready"]["audit"]["min_traps"] == 35
    assert 0 <= best["ready"]["drill_age"] <= 3000
    assert best["pop"] == {"cit": 50, "adults": 50, "soldiers": 8, "cap": 60, "gate_cap": 60}


def test_outbox_replies(run):
    ob = sd(run) / "outbox"
    rep = {p.stem: json.loads(p.read_text(encoding="utf-8")) for p in ob.glob("*.json")}
    for r in rep.values():
        assert schema.validate("outbox", r) == [], r
    assert rep["a1"]["ok"] and rep["a1"]["data"] == {"lvl": 1}
    assert rep["d1"]["ok"] and rep["d3"]["ok"]
    assert not rep["d2"]["ok"] and "not allowed in DRILL" in rep["d2"]["msg"]
    assert rep["c1"]["ok"] and rep["c1"]["data"] == {"cap": 60}
    assert not rep["s1"]["ok"] and "PEACE" in rep["s1"]["msg"]
    assert rep["s2"]["ok"] and rep["s2"]["msg"].startswith("sortie B")
    assert not list((sd(run) / "inbox").glob("*.json")), "every inbox file consumed"


def test_commands_log_owners_and_orders(run):
    lines = [x.split("\t") for x in (sd(run) / "commands.log").read_text(encoding="utf-8").splitlines() if x]
    acts = [(c[2], c[3][4:], c[4]) for c in lines if c[3].startswith("act.")]
    for origin, fn, _ in acts:
        assert origin in schema.ACT[fn], (origin, fn)
    mil = [(fn, args) for origin, fn, args in acts if origin == "military"]
    assert {fn for fn, _ in mil} <= {"squad_add", "squad_routine", "squad_order", "run"}, "adopted: no create"
    assert len([1 for fn, _ in mil if fn == "squad_add"]) == 5, "3 leaders from the UI + 5 recruits = 8"
    routines = {json.loads(a)[1] for fn, a in mil if fn == "squad_routine"}
    assert routines == {"Constant training", "Ready"}, "never Off duty"
    kills = [json.loads(a) for fn, a in mil if fn == "squad_order" and '"kill"' in a]
    assert kills and all(k[1]["units"] == [201, 202, 203, 204, 205, 206] for k in kills)
    assert {k[0] for k in kills} == {303}, "kill orders only to the crossbow squad C"
    assert not [1 for origin, _, _ in acts if origin == "drill"], "drill writes nothing itself"
    assert {fn for origin, fn, _ in acts if origin == "readiness"} == {"popcap"}


def test_persist_validates(run):
    raw = json.loads((run / "persist_dump.json").read_text(encoding="utf-8"))
    drill = json.loads(raw["dfllm.drill"])
    assert schema.validate("persist.drill", drill) == [], drill
    assert drill["streak_fail"] == 0 and [e["pass"] for e in drill["last"]] == [1, 1]
    for k in ("dfllm.m.military", "dfllm.m.readiness", "dfllm.m.drill"):
        assert json.loads(raw[k])["v"] == 2, k
    mil = json.loads(raw["dfllm.m.military"])
    assert sorted(mil["sq"]) == ["A", "B", "C"] and mil["posture"] == "TRAIN"
    rd = json.loads(raw["dfllm.m.readiness"])
    assert rd["cap"] == 60 and rd["lvl"] == 2 and rd["inbox"]["cap"] == 60
    assert "t0" not in json.loads(raw["dfllm.m.drill"]), "no drill left running"
    mode = json.loads(raw["dfllm.mode"])
    assert schema.validate("persist.mode", mode) == [] and mode["mode"] == "PEACE"
