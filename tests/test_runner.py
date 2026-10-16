"""WP7 runner: everything it writes (persist docs, state, events) validates against the frozen schemas;
lua/dfllm/runner.lua is lint-clean. The behaviour tests are tests/lua/test_runner.lua (run by test_luahost)."""
import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import luahost  # noqa: E402

from dfpilot import lint, schema  # noqa: E402

pytestmark = pytest.mark.skipif(not luahost.available(), reason="lua53.dll not found")


@pytest.fixture(scope="module")
def dump():
    r = luahost.run_file(ROOT / "tests" / "lua" / "runner_dump.lua", [str(ROOT)], timeout=60,
                         paths=[ROOT / "tests" / "lua"])
    assert r.ok, f"exit {r.code}\n{r.out}\n{r.err}"
    return json.loads(r.out.strip().splitlines()[-1])


def test_persist_state_and_manifest_validate(dump):
    kinds = [s["kind"] for s in dump["snaps"]]
    assert kinds.count("persist.projects") == 2 and "persist.phase" in kinds and "manifest" in kinds
    for s in dump["snaps"]:
        if s["kind"] == "m.runner":
            assert s["doc"]["v"] == 2 and isinstance(s["doc"]["p"], dict) and isinstance(s["doc"]["hist"], dict)
            continue
        assert schema.validate(s["kind"], s["doc"]) == [], s["kind"]


def test_scenario_reached_its_milestones(dump):
    snaps = {s["kind"]: s["doc"] for s in dump["snaps"]}          # last of each kind
    done = {p["id"]: p["done"] for p in snaps["persist.projects"]["list"]}
    assert done.get("cfc1") == 1 and done.get("y3s0b0") == 1 and "cdig" not in done
    assert snaps["persist.phase"]["phase"] in ("P1", "P2")
    assert snaps["manifest"]["burrows"]["Kern+"]["role"] == "kern"
    types = {e["type"] for e in dump["events"]}
    assert {"PROJECT_STAGE", "PROJECT_DONE", "BREACH_STOP", "PHASE", "PROJECT_REQUEST"} <= types


def test_every_event_validates(dump):
    assert dump["events"]
    for ev in dump["events"]:
        assert schema.validate("event", ev) == [], ev


@pytest.fixture(scope="module")
def cavern_dump():
    r = luahost.run_file(ROOT / "tests" / "lua" / "runner_cavern_dump.lua", [str(ROOT)], timeout=60,
                         paths=[ROOT / "tests" / "lua"])
    assert r.ok, f"exit {r.code}\n{r.out}\n{r.err}"
    return json.loads(r.out.strip().splitlines()[-1])


def test_cavern_plug_files_validate(cavern_dump):
    """Run 11: the plug project, its bp document, BREACH_STOP cavern_lake and CAVERN_PLUG queued/done validate."""
    for s in cavern_dump["snaps"]:
        assert schema.validate(s["kind"], s["doc"]) == [], (s["kind"], schema.validate(s["kind"], s["doc"]))
    for ev in cavern_dump["events"]:
        assert schema.validate("event", ev) == [], ev
    types = [e["type"] for e in cavern_dump["events"]]
    stop = next(e for e in cavern_dump["events"] if e["type"] == "BREACH_STOP")
    assert stop["d"]["why"] == "cavern_lake" and stop["d"]["was"] == "damp" and "cavern lake" in stop["msg"]
    phases = [e["d"]["phase"] for e in cavern_dump["events"] if e["type"] == "CAVERN_PLUG"]
    assert phases == ["queued", "done"] and types.count("PROJECT_DONE") == 1
    bp_doc = next(s["doc"] for s in cavern_dump["snaps"] if s["kind"] == "bp")
    assert [st["label"] for st in bp_doc["stages"]] == ["p1.dig", "p1.wall", "p0.dig", "p0.wall"]


@pytest.fixture(scope="module")
def shaft_dump():
    r = luahost.run_file(ROOT / "tests" / "lua" / "runner_shaft_dump.lua", [str(ROOT)], timeout=60,
                         paths=[ROOT / "tests" / "lua"])
    assert r.ok, f"exit {r.code}\n{r.out}\n{r.err}"
    return json.loads(r.out.strip().splitlines()[-1])


def test_shaft_check_events_validate(shaft_dump):
    """Run 11 (c1a14676): the daily shaft check's BREACH_STOP (src check) and CAVERN_PLUG (field state) validate."""
    for s in shaft_dump["snaps"]:
        assert schema.validate(s["kind"], s["doc"]) == [], (s["kind"], schema.validate(s["kind"], s["doc"]))
    for ev in shaft_dump["events"]:
        assert schema.validate("event", ev) == [], ev
    stop = [e["d"] for e in shaft_dump["events"] if e["type"] == "BREACH_STOP"]
    assert [(d["proj"], d["src"], d["state"], d["why"]) for d in stop] == [("c1a14676", "check", "stalled",
                                                                             "cavern_lake")]
    plugs = {e["d"]["proj"]: e["d"] for e in shaft_dump["events"] if e["type"] == "CAVERN_PLUG"}
    assert {k: (d["phase"], d["state"]) for k, d in plugs.items()} == {"c1a14676": ("queued", "stalled"),
                                                                       "e2": ("queued", "done")}


def test_runner_is_lint_clean():
    assert lint.lua([ROOT / "lua" / "dfllm" / "runner.lua"]) == []
