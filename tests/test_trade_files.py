"""WP9: trade on the real Lua kernel writes only schema-valid files; fair-play lint is clean.

tests/lua/trade_scenario.lua boots lua/dfllm/kern.lua with lua/dfllm/trade.lua (and a gate test
double) on k_mock's fake DF with the repo's config files:
  stub      act.trade replaced by a 'not implemented' stub -> the visit fails once, gracefully
  proposal  the real act.lua act.trade (A.install_trade) on a click-level fake UI -> one trade
The vanilla UI itself is live-untested; these tests pin the kernel/file contract.
"""
import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
LUA_TESTS = ROOT / "tests" / "lua"
sys.path.insert(0, str(ROOT / "tools"))
import luahost  # noqa: E402

from df_llm_helper import lint, schema  # noqa: E402

needs_lua = pytest.mark.skipif(not luahost.available(), reason="lua53.dll not found")


def sd(out: Path) -> Path:
    return out / "dfllm-runtime" / "region1"


def events(out: Path) -> list[dict]:
    return [json.loads(x) for x in (sd(out) / "events.jsonl").read_text(encoding="utf-8").splitlines() if x]


def caravan(evs: list[dict], phase: str) -> list[dict]:
    return [e for e in evs if e["type"] == "CARAVAN" and e["d"].get("phase") == phase]


def run_scenario(tmp_path_factory, variant: str) -> tuple[Path, dict]:
    out = tmp_path_factory.mktemp(f"trade-{variant}")
    r = luahost.run_file(LUA_TESTS / "trade_scenario.lua", [str(out), variant], timeout=120, paths=[LUA_TESTS])
    assert r.ok, f"exit {r.code}\n{r.out}\n{r.err}"
    assert "scenario done" in r.out
    line = next(x for x in r.out.splitlines() if x.startswith("summary "))
    return out, json.loads(line[len("summary "):])


@pytest.fixture(scope="module")
def stub(tmp_path_factory):
    return run_scenario(tmp_path_factory, "stub")


@pytest.fixture(scope="module")
def proposal(tmp_path_factory):
    return run_scenario(tmp_path_factory, "proposal")


# ---------------------------------------------------------------- fair play
def test_trade_lua_lints_clean():
    assert lint.lua([str(ROOT / "lua" / "dfllm" / "trade.lua")]) == []


def test_act_trade_proposal_lints_clean_as_act_lua():
    src = (ROOT / "lua" / "dfllm" / "act.lua").read_text(encoding="utf-8")   # pasted into act.lua (integration)
    block = src.split("-- BEGIN act.trade")[1].split("-- END act.trade")[0]
    assert lint.lua_source(block, "lua/dfllm/act.lua") == []
    # the same block outside act.lua is caught (the lint really looks at it)
    rules = {f["rule"] for f in lint.lua_source(block, "lua/dfllm/trade.lua")}
    assert {"df-write", "command"} <= rules


def test_trade_lua_never_writes_or_reads_units():
    src = (ROOT / "lua" / "dfllm" / "trade.lua").read_text(encoding="utf-8")
    for banned in ("markForTrade", "removeJob", "addWorker", "linkIntoWorld", "flags1.left", "labors",
                   "getCitizens", "world.units", "pause_state", "simulateInput", "run_command", "reqscript"):
        assert banned not in src.split("-- [live-untested]")[1], banned


def test_commands_used_are_allowlisted():
    from df_llm_helper import fairplay
    for cmd, args in (("logistics", ["now"]), ("fix/stuck-merchants", [])):
        ok, why = fairplay.check_run(cmd, args)
        assert ok, (cmd, why)
    assert not fairplay.check_run("caravan", ["extend"])[0]       # D-08 / DESIGN §11.4


# ---------------------------------------------------------------- stub act (today's act.lua)
@needs_lua
def test_stub_every_file_validates(stub):
    out, _ = stub
    for e in events(out):
        assert schema.validate("event", e) == [], e
    for slot in ("a", "b"):
        doc = json.loads((sd(out) / f"state.{slot}.json").read_text(encoding="utf-8"))
        assert schema.validate("state", doc) == [], doc


@needs_lua
def test_stub_fails_once_and_gracefully(stub):
    out, summary = stub
    evs = events(out)
    assert len(caravan(evs, "arrive")) == 1
    failed = caravan(evs, "failed")
    assert [e["d"]["why"] for e in failed] == ["act_missing"]
    assert not caravan(evs, "retry")
    assert len(caravan(evs, "left")) == 1
    assert caravan(evs, "arrive")[0]["d"]["civ"] == "Guild of Ürist"
    act_fails = [e for e in evs if e["type"] == "ACT_FAIL"]
    assert [e["d"]["fn"] for e in act_fails] == ["trade"]
    assert not [e for e in evs if e["type"] == "KERN_FAULT"]
    assert summary["requested"] is False
    assert summary["paused"] is False and summary["focus"] == "dwarfmode/Default"


@needs_lua
def test_stub_commands_log_and_verb_replies(stub):
    out, _ = stub
    log = (sd(out) / "commands.log").read_text(encoding="utf-8").splitlines()
    rows = [line.split("\t") for line in log]
    assert any(r[2] == "trade" and r[3] == "act.run" and '"logistics","now"' in r[4] and r[5] == "ok" for r in rows)
    replies = {p.stem: json.loads(p.read_text(encoding="utf-8")) for p in (sd(out) / "outbox").glob("*.json")}
    assert set(replies) >= {"tw1", "tw2"}
    for r in replies.values():
        assert schema.validate("outbox", r) == [], r
    assert replies["tw1"]["ok"] is True
    assert replies["tw1"]["data"] == {"want": ["bar:steel", "bolts"], "sell": []}
    assert replies["tw2"]["ok"] is False


# ---------------------------------------------------------------- act.trade proposal
@needs_lua
def test_proposal_trades_with_ratio(proposal):
    out, summary = proposal
    evs = events(out)
    for e in evs:
        assert schema.validate("event", e) == [], e
    traded = caravan(evs, "traded")
    assert len(traded) == 1
    assert traded[0]["d"]["ratio"] >= 150
    assert summary == {"wants": 1, "trades": 1, "misclicks": 0, "wrong_screen": 0, "prompts": 1, "requested": False,
                       "anyone": False, "paused": False, "focus": "dwarfmode/Default"}
    assert not [e for e in evs if e["type"] in ("ACT_FAIL", "KERN_FAULT", "KERNEL_SLOW")]


@needs_lua
def test_proposal_state_and_persist(proposal):
    out, _ = proposal
    docs = [json.loads((sd(out) / f"state.{s}.json").read_text(encoding="utf-8")) for s in ("a", "b")]
    for d in docs:
        assert schema.validate("state", d) == [], d
    best = max(docs, key=lambda d: d["seq"])
    assert best["trade"]["done"] == 1 and best["trade"]["ratio"] >= 150
    assert best["trade"]["caravan"] == 0                # the caravan left before the stop
    persist = json.loads((out / "persist_dump.json").read_text(encoding="utf-8"))
    m = json.loads(persist["dfllm.m.trade"])
    assert m["v"] == 2 and m["done"] == 1
    assert len(persist["dfllm.m.trade"]) < 2048


@needs_lua
def test_proposal_act_sequence_in_commands_log(proposal):
    out, _ = proposal
    ops = [json.loads(r.split("\t")[4])[0] for r in (sd(out) / "commands.log").read_text(encoding="utf-8").splitlines()
           if r.split("\t")[3] == "act.trade"]
    assert ops == ["request_broker", "open", "open", "mark", "offer", "offer", "close", "request_broker"]
