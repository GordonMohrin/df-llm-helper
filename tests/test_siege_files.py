"""WP5: the files the real kernel writes with sense/threat/siege/gate validate against df_llm_helper.schema.

tests/lua/siege_scenario.lua boots lua/dfllm/kern.lua (real act.lua: lever script, removeJob, civ-alert)
on k_mock's fake DF with the WP5 modules and drives ALERT, INVASION, SIEGE, BREACH, RECOVERY, PEACE,
a DRILL and lever verbs into a temp DF folder.
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
    out = tmp_path_factory.mktemp("siege")
    r = luahost.run_file(LUA_TESTS / "siege_scenario.lua", [str(out)], timeout=120, paths=[LUA_TESTS])
    assert r.ok, f"exit {r.code}\n{r.out}\n{r.err}"
    assert "scenario done" in r.out
    return out


def sd(out: Path) -> Path:
    return out / "dfllm-runtime" / "region1"


def events(out: Path) -> list[dict]:
    return [json.loads(x) for x in (sd(out) / "events.jsonl").read_text(encoding="utf-8").splitlines()]


def test_every_event_validates(run):
    evs = events(run)
    for ev in evs:
        assert schema.validate("event", ev) == [], ev
    types = {e["type"] for e in evs}
    for t in ("ALERT_START", "ALERT_END", "INVASION", "SIEGE_START", "WEALTH", "GATE_FAIL", "BREACH",
              "SIEGE_STATUS", "SIEGE_END", "GATE", "LEVER", "MODE"):
        assert t in types, t
    assert "KERN_FAULT" not in types and "ACT_FAIL" not in types


def test_mode_sequence_and_breach_timing(run):
    evs = events(run)
    modes = [e["d"]["from"] + ">" + e["d"]["to"] for e in evs if e["type"] == "MODE"]
    assert modes == ["PEACE>ALERT", "ALERT>PEACE", "PEACE>SIEGE", "SIEGE>BREACH", "BREACH>RECOVERY",
                     "RECOVERY>PEACE", "PEACE>DRILL", "DRILL>PEACE"]
    tick = {m: e["tick"] for m, e in zip(modes, [e for e in evs if e["type"] == "MODE"])}
    assert 900 <= tick["SIEGE>BREACH"] - tick["PEACE>SIEGE"] <= 930
    gf = next(e for e in evs if e["type"] == "GATE_FAIL")
    assert gf["d"] == {"bridge": "O1", "want": "up", "why": "no_worker"} and gf["tick"] == tick["SIEGE>BREACH"]
    br = next(e for e in evs if e["type"] == "BREACH")
    assert br["d"] == {"why": "gate_fail", "bridge": "O1"}
    end = next(e for e in evs if e["type"] == "SIEGE_END")
    assert end["d"]["killed"] == 6 and end["d"]["lost"] == 0 and end["d"]["hostiles"] == 6
    assert 8400 <= tick["RECOVERY>PEACE"] - tick["BREACH>RECOVERY"] <= 8440
    assert sum(1 for e in evs if e["type"] == "GATE_FAIL") == 1, "no repeated A events"


def test_state_slots_validate(run):
    docs = [json.loads((sd(run) / f"state.{s}.json").read_text(encoding="utf-8")) for s in "ab"]
    for d in docs:
        assert schema.validate("state", d) == [], d
        assert len(json.dumps(d, separators=(",", ":"))) <= 4096
    best = max(docs, key=lambda d: d["seq"])
    assert best["bridges"] == {"O1": "up", "B1": "down", "B2": "down"}
    assert best["threat"] == {"vis": 0, "armed": 0}
    assert best["pop"] == {"cit": 5, "adults": 4, "soldiers": 1}


def test_outbox_lever_replies(run):
    ob = sd(run) / "outbox"
    rep = {p.stem: json.loads(p.read_text(encoding="utf-8")) for p in ob.glob("*.json")}
    for r in rep.values():
        assert schema.validate("outbox", r) == [], r
    assert rep["c1"]["ok"] is False and rep["c1"]["msg"] == "lever not allowed in BREACH"
    assert rep["c2"]["ok"] is True and isinstance(rep["c2"]["data"]["job"], int)
    assert rep["c3"]["ok"] is False and rep["c3"]["msg"] == "no bridge Z9"


def test_commands_log_origins(run):
    rows = [ln.split("\t") for ln in (sd(run) / "commands.log").read_text(encoding="utf-8").splitlines()]
    by = {}
    for r in rows:
        assert len(r) == 6, r
        by.setdefault(r[3], set()).add(r[2])
    assert by["act.pull"] == {"gate"}
    assert by["act.cancel_own_lever_job"] == {"gate"}
    assert by["act.civ_alert"] == {"siege"} and by["act.alert_burrows"] == {"siege"}
    assert all(r[5] == "ok" for r in rows if r[3] in ("act.pull", "act.civ_alert", "act.alert_burrows"))


def test_persist_documents(run):
    raw = json.loads((run / "persist_dump.json").read_text(encoding="utf-8"))
    assert schema.validate("persist.mode", json.loads(raw["dfllm.mode"])) == []
    for key in ("dfllm.m.siege", "dfllm.m.gate", "dfllm.m.threat"):
        doc = json.loads(raw[key])
        assert doc["v"] == 2, key
    gate = json.loads(raw["dfllm.m.gate"])
    assert gate["kpi"]["dbl"] == 0
    assert gate["br"]["O1"]["want"] == "up"
