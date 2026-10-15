"""FR-61 coffin provisioner (care) on the file contracts.

tests/lua/coffins_scenario.lua boots lua/dfllm/kern.lua with care, runner and a fake snapshot on k_mock's fake DF and
the repo's config files: 4 unburied citizens, no coffin, only soft stone, 60 logs, a mason's and a carpenter's
workshop, one free dug hall. The provisioner must queue 14 coffins (4 + reserve 10) with tomb zones through
runner.coffins (no quickfort orders), order them in wood, and show itself in inspect what=tombs and in the state's
care slot; every event, outbox reply and state slot must validate. The contract and status parts run without Lua.
"""
import json
import sys
from pathlib import Path

import pytest
from cli_v2_helpers import make_runtime, reset_paths

ROOT = Path(__file__).resolve().parent.parent
LUA_TESTS = ROOT / "tests" / "lua"
sys.path.insert(0, str(ROOT / "tools"))
import luahost  # noqa: E402

from dfpilot import brief, files, schema  # noqa: E402

needs_lua = pytest.mark.skipif(not luahost.available(), reason="lua53.dll not found")


# ---------------------------------------------------------------- contract tables and config
def test_care_may_queue_work_orders():
    assert schema.ACT["workorder"] == ["economy", "water", "care"]


def test_state_care_coffins_validates():
    base = json.loads((ROOT / "tests/fixtures/v2/runtime/region7/state.a.json").read_text(encoding="utf-8"))
    assert schema.validate("state", base) == [], "the care slot without the provisioner stays valid"
    base["care"]["coffins"] = {"want": 35, "short": 10, "stock": 2, "order": 8, "proj": "cof1209609"}
    assert schema.validate("state", base) == []
    bad = json.loads(json.dumps(base))
    bad["care"]["coffins"]["proj"] = "x" * 41
    assert schema.validate("state", bad) != []
    bad = json.loads(json.dumps(base))
    del bad["care"]["coffins"]["order"]
    assert schema.validate("state", bad) != []
    bad = json.loads(json.dumps(base))
    bad["care"]["coffins"]["extra"] = 1
    assert schema.validate("state", bad) != []


def test_config_defaults():
    care = json.loads((ROOT / "config/baseline.json").read_text(encoding="utf-8"))["care"]
    assert care["coffins"] is True and care["coffin_reserve"] == 10
    assert {k: care[k] for k in ("coffin_batch", "coffin_scan_r", "coffin_min_side", "coffin_entrance_r",
                                 "coffin_retry", "coffin_wood_keep", "coffin_wake", "coffin_prio")} == {
        "coffin_batch": 30, "coffin_scan_r": 16, "coffin_min_side": 4, "coffin_entrance_r": 10,
        "coffin_retry": 3600, "coffin_wood_keep": 20, "coffin_wake": 2400, "coffin_prio": 3}


# ---------------------------------------------------------------- status
@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def test_status_shows_the_provisioner(save):
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    st["care"]["coffins"] = {"want": 35, "short": 10, "stock": 2, "order": 8, "proj": "cof1209609"}
    assert schema.validate("state", st) == []
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")
    out = brief.status_text(save)
    assert "tombs 9 moods 1 | coffins want 35 short 10 stock 2 order 8 proj cof1209609" in out, out
    assert len(out) // 4 <= brief.STATUS_TOKENS * 2
    st["care"]["coffins"] = {"want": 9, "short": 0, "stock": 0, "order": 0, "proj": ""}
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")
    assert "coffins want" not in brief.status_text(save), "enough free tombs and nothing open: no line"


# ---------------------------------------------------------------- the real kernel
@pytest.fixture(scope="module")
def run(tmp_path_factory):
    out = tmp_path_factory.mktemp("coffins")
    r = luahost.run_file(LUA_TESTS / "coffins_scenario.lua", [str(out)], timeout=180, paths=[LUA_TESTS])
    assert r.ok, f"exit {r.code}\n{r.out}\n{r.err}"
    assert "scenario done" in r.out
    return out / "dfllm-runtime" / "region1"


def events(sd: Path) -> list[dict]:
    return [json.loads(line) for line in (sd / "events.jsonl").read_text(encoding="utf-8").splitlines() if line]


@needs_lua
def test_events_and_state_validate(run):
    evs = events(run)
    for e in evs:
        assert schema.validate("event", e) == [], e
    fails = [e for e in evs if e["type"] == "ACT_FAIL" and e["d"]["fn"] in ("workorder", "quickfort", "tomb_zone")]
    assert fails == []
    assert not [e for e in evs if e["type"] == "PROJECT_REQUEST" and e["d"]["tpl"] == "tombs"], \
        "the provisioner placed the coffins itself: nothing for follow"
    for s in ("a", "b"):
        d = json.loads((run / f"state.{s}.json").read_text(encoding="utf-8"))
        assert schema.validate("state", d) == [], d
    d = json.loads((run / "state.a.json").read_text(encoding="utf-8"))
    cf = d["care"]["coffins"]
    assert (cf["want"], cf["short"], cf["order"]) == (14, 0, 14) and cf["proj"].startswith("cof")


@needs_lua
def test_inspect_tombs_shows_the_provisioner(run):
    r1 = json.loads((run / "outbox" / "c1.json").read_text(encoding="utf-8"))
    r2 = json.loads((run / "outbox" / "c2.json").read_text(encoding="utf-8"))
    for r in (r1, r2):
        assert schema.validate("outbox", r) == [], r
        assert r["ok"] is True and len(json.dumps(r["data"], separators=(",", ":"))) <= 8192
    p1 = r1["data"]["prov"]
    assert (p1["want"], p1["bodies"], p1["found"], p1["mat"], p1["stone"], p1["wood"]) == (14, 4, 14, "wood", 0, 60)
    assert p1["site"] == "6x7 at 24,22,5" and p1["seeds"] == ["core 25,25,5"]
    assert "coffins want 14, short 14, stock 0, on order 14, project cof" in r1["msg"]
    p2 = r2["data"]["prov"]
    assert (p2["planned"], p2["short"], p2["order"], p2["make"], p2["pend"]) == (14, 0, 14, 0, 1)
    assert p2["proj"] == p1["proj"], "one project, no second placement"
    assert r2["data"]["coffins"] == 14


@needs_lua
def test_commands_log_orders_wood_and_places_without_quickfort_orders(run):
    log = (run / "commands.log").read_text(encoding="utf-8").splitlines()
    wo = [line for line in log if "\tact.workorder\t" in line]
    assert len(wo) == 1 and "\tcare\t" in wo[0] and '"job":"ConstructCoffin"' in wo[0]
    assert '"material_category":["wood"]' in wo[0] and '"amount_total":14' in wo[0] and '"tag":"dfllm:coffin"' in wo[0]
    qf = [line for line in log if "\tact.quickfort\t" in line]
    assert qf and all('"command":"run"' in line for line in qf), "no quickfort orders: care chose the material"
    assert '"mode":"build"' in qf[0] and '"cells":14' in qf[0]
    persist = json.loads((run.parent.parent / "persist_dump.json").read_text(encoding="utf-8"))
    docs = [json.loads(v) for k, v in persist.items() if k.startswith("dfllm.bp.cof")]
    assert len(docs) == 1
    d = docs[0]
    assert d["tpl"] == "tombs" and [s["mode"] for s in d["stages"]] == ["build", "zone"]
    assert d["stages"][0]["orders"] == 0
    zone = [c[3] for ch in d["stages"][1]["chunks"] for c in ch["cells"]]
    assert zone == ["T(1x1)"] * 14
