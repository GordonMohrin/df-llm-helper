"""WP1: every file the real Lua kernel writes validates against df_llm_helper.schema (CONTRACTS §8-§10).

tests/lua/kern_scenario.lua boots lua/dfllm/kern.lua on k_mock's fake DF globals, runs modes, inbox
commands, faults and demotions into a temp DF folder, stops, and dumps the persistent site data.
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
    out = tmp_path_factory.mktemp("kern")
    r = luahost.run_file(LUA_TESTS / "kern_scenario.lua", [str(out)], timeout=120, paths=[LUA_TESTS])
    assert r.ok, f"exit {r.code}\n{r.out}\n{r.err}"
    assert "scenario done" in r.out
    return out


def save_dir(out: Path) -> Path:
    return out / "dfllm-runtime" / "region1"


def load(p: Path):
    return json.loads(p.read_text(encoding="utf-8"))


def test_state_slots_validate(run):
    sd = save_dir(run)
    docs = [load(sd / f"state.{s}.json") for s in "ab"]
    for d in docs:
        assert schema.validate("state", d) == [], d
        assert len(json.dumps(d, separators=(",", ":"))) <= 4096
    a, b = docs
    assert a["seq"] % 2 == 1 and b["seq"] % 2 == 0
    best = max(docs, key=lambda d: d["seq"])
    assert best["k"]["disabled"] == ["test_bad"]
    assert "economy" in best["k"]["slow"]
    assert best["pop"] == {"cit": 12, "adults": 10, "soldiers": 2, "cap": 55, "gate_cap": 55}
    assert best["bridges"] == {"O1": "down", "B1": "up"}
    assert best["owners"]["tempo"] in ("mode", "inbox")


def test_heartbeat_validates(run):
    hb = load(save_dir(run) / "heartbeat")
    assert schema.validate("heartbeat", hb) == []


def test_every_event_line_validates_and_numbers_increase(run):
    lines = (save_dir(run) / "events.jsonl").read_bytes().split(b"\n")
    assert lines[-1] == b"", "file ends with a newline"
    events = [json.loads(x) for x in lines[:-1]]
    for ev in events:
        assert schema.validate("event", ev) == [], ev
    ns = [e["n"] for e in events]
    assert ns == sorted(ns) and len(set(ns)) == len(ns)
    types = {e["type"] for e in events}
    for t in ("BOOT", "MODE", "CMD", "KERN_FAULT", "KERNEL_SLOW", "ACT_FAIL", "PAUSE", "SEASON", "DEATH",
              "PROJECT_REQUEST", "UNLOAD"):
        assert t in types, t
    assert b"\r" not in b"".join(lines)


def test_outbox_replies_validate(run):
    ob = save_dir(run) / "outbox"
    replies = {p.stem: load(p) for p in ob.glob("*.json")}
    for r in replies.values():
        assert schema.validate("outbox", r) == [], r
    assert set(replies) == {f"c{i}" for i in range(1, 10)}, sorted(replies)
    assert replies["c1"]["ok"] and replies["c1"]["data"] == {"job": 3}
    assert replies["c2"]["ok"] and replies["c2"]["data"] == {"year": 3, "builds": 1}
    assert replies["c4"]["ok"] and schema.validate("state", replies["c4"]["data"]) == []
    # selftest full: everything passes except the check that sees the deliberately disabled test_bad
    assert replies["c5"]["data"] == {"pass": 8, "fail": 1} and "no_disabled" in replies["c5"]["msg"], replies["c5"]
    assert replies["c6"] == {"id": "c6", "ok": False, "msg": "bad json", "verb": "?", "tick": replies["c6"]["tick"]}
    assert replies["c7"]["msg"] == "unknown verb"
    assert replies["c8"]["msg"] == "paused for 2 s"
    assert replies["c9"]["msg"] == "lever not allowed in RECOVERY"
    assert not list(ob.glob("*.tmp")) and not list((save_dir(run) / "inbox").glob("*"))


def test_restore_and_active(run):
    rt = run / "dfllm-runtime"
    r = load(rt / "restore.json")
    assert schema.validate("restore", r) == [], r
    assert r["active"] == 0 and r["orig"]["gfps"] == 250
    assert not (rt / "ACTIVE").exists(), "ACTIVE is deleted at unload"


def test_persist_documents_validate(run):
    raw = load(run / "persist_dump.json")
    kinds = {"dfllm": "persist.marker", "dfllm.mode": "persist.mode", "dfllm.kern": "persist.kern",
             "dfllm.restore": "restore", "dfllm.plan": "persist.plan"}
    for key, kind in kinds.items():
        assert key in raw, key
        doc = json.loads(raw[key])
        assert schema.validate(kind, doc) == [], (key, doc)
    assert json.loads(raw["dfllm.mode"])["mode"] == "RECOVERY"
    assert json.loads(raw["dfllm.kern"])["disabled"] == ["test_bad"]
    assert set(raw) <= {"dfllm", "dfllm.mode", "dfllm.kern", "dfllm.restore", "dfllm.plan", "dfllm.m.selftest"}


def test_perf_csv_and_logs(run):
    sd = save_dir(run)
    rows = (sd / "perf.csv").read_text(encoding="utf-8").splitlines()
    assert rows[0] == "wall,tick,mode,tps,pop,units,items,ms_s,gap_max_ms,gaps3,mods"
    assert len(rows) >= 5
    for row in rows[1:]:
        f = row.split(",")
        assert len(f) == 11 and all(x.lstrip("-").isdigit() for x in f[:2] + f[3:10]), row
        assert f[2] in schema.MODES
    for line in (sd / "commands.log").read_text(encoding="utf-8").splitlines():
        assert len(line.split("\t")) == 6, line
    for line in (sd / "kern.log").read_text(encoding="utf-8").splitlines():
        assert len(line.split("\t")) == 5, line
