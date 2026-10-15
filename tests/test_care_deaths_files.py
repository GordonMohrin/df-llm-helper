"""FR-64 death causes and death clusters (care) on the file contracts.

tests/lua/deaths_scenario.lua boots lua/dfllm/kern.lua with care, a fake snapshot and a fake economy (stock days) on
k_mock's fake DF and the repo's config files: a patient dies of thirst, a second dwarf dies unseen ("missing") and is
found through the announcement, a third dies of thirst in a Fey mood. Every event and state slot must validate;
DEATH must carry the cause and the evidence, DEATH_CLUSTER / DEATHS_PREVENTABLE must come for the dehydration pair,
status and brief must show the deaths per cause. The contract, wake and status parts also run without Lua.
"""
import json
import sys
from pathlib import Path

import pytest
from cli_v2_helpers import append_events, ev, make_runtime, reset_paths

ROOT = Path(__file__).resolve().parent.parent
LUA_TESTS = ROOT / "tests" / "lua"
sys.path.insert(0, str(ROOT / "tools"))
import luahost  # noqa: E402

from dfpilot import brief, files, schema, wake  # noqa: E402
from dfpilot.events import est_tokens  # noqa: E402

needs_lua = pytest.mark.skipif(not luahost.available(), reason="lua53.dll not found")
CLUSTER_D = {"cause": "dehydrated", "n": 2, "units": [5, 6], "causes": ["5:dehydrated", "6:dehydrated"], "total": 2,
             "days": 28, "patients": 1, "pos": [24, 24, 5], "stock": 1115,
             "hint": "drink 1115 d: forbidden or unreachable? inspect reach, inspect refuge; "
                     "patients: hospital water (inspect water_sources)"}


# ---------------------------------------------------------------- contract tables and config
def test_event_registry():
    assert schema.EVENTS["DEATH_CLUSTER"][:2] == ("B", "care")
    assert schema.EVENTS["DEATHS_PREVENTABLE"][:2] == ("A", "care")
    assert "DEATHS_PREVENTABLE" not in schema.INTERRUPTS, "a wake, not a lockdown"
    ok = {"n": 1, "tick": 5, "type": "DEATHS_PREVENTABLE", "cls": "A", "msg": "2 citizens died of dehydration",
          "d": CLUSTER_D}
    assert schema.validate("event", ok) == []
    assert schema.validate("event", {**ok, "cls": "B"}) != []
    assert schema.validate("event", {**ok, "d": {"n": 2}}) != [], "cause is required"
    assert schema.validate("event", {**ok, "d": {**CLUSTER_D, "units": ["5"]}}) != []
    death = {"n": 2, "tick": 5, "type": "DEATH", "cls": "B", "msg": "citizen 5 died: killed by goblin 77",
             "d": {"unit": 5, "citizen": 1, "cause": "killed", "src": "incident", "why": "incident STRUCK_DOWN",
                   "found": 1, "dtype": "STRUCK_DOWN", "by": "goblin", "killer": 77, "thirst": 100, "hunger": 0,
                   "patient": 1, "pos": [1, 2, 3], "job": "Rest", "revised": 1, "mood": "Fey"}}
    assert schema.validate("event", death) == []
    assert schema.validate("event", {**death, "d": {**death["d"], "found": 2}}) != []
    three = {"n": 3, "tick": 5, "type": "DEATHS_3PLUS", "cls": "A", "msg": "3 citizens died within a day: drowned 3",
             "d": {"n": 3, "ids": [1, 2, 3], "causes": ["1:drowned", "2:drowned", "3:drowned"]}}
    assert schema.validate("event", three) == []


def test_wake_hint_for_the_preventable_cluster():
    assert "DEATHS_PREVENTABLE" in wake.WAKE_TYPES and "DEATHS_PREVENTABLE" not in wake.URGENT
    assert "inspect" in wake.NEXT["DEATHS_PREVENTABLE"] and "reach" in wake.NEXT["DEATHS_PREVENTABLE"]
    e = {"n": 12, "tick": 1213201, "type": "DEATHS_PREVENTABLE", "cls": "A", "d": CLUSTER_D,
         "msg": "2 citizens died of dehydration within 28 d; drink 1115 d: forbidden or unreachable? inspect reach, "
                "inspect refuge; patients: hospital water (inspect water_sources); units 5, 6 (1 patient)"}
    line = wake.wake_line({"DEATHS_PREVENTABLE": {"c": 1, "n0": 12, "e": e}},
                          {"t": {"y": 3, "tick": 10, "season": 0, "tps": 400, "paused": False}, "mode": "PEACE"})
    assert est_tokens(line) <= wake.WAKE_TOKENS
    assert "DEATHS_PREVENTABLE: 2 citizens died of dehydration" in line and "next: dfllm cmd inspect" in line


def test_state_care_died_validates():
    base = json.loads((ROOT / "tests/fixtures/v2/runtime/region7/state.a.json").read_text(encoding="utf-8"))
    base["care"]["died"] = {"dehydrated": 2, "mood": 1}
    assert schema.validate("state", base) == []
    bad = json.loads(json.dumps(base))
    bad["care"]["died"]["killed"] = -1
    assert schema.validate("state", bad) != []
    bad["care"]["died"] = [["killed", 1]]
    assert schema.validate("state", bad) != []


def test_config_defaults():
    care = json.loads((ROOT / "config/baseline.json").read_text(encoding="utf-8"))["care"]
    assert {k: care[k] for k in ("death_window", "death_same", "death_any", "death_every", "death_recheck",
                                 "death_thirst", "death_hunger", "death_reports")} == {
        "death_window": 33600, "death_same": 2, "death_any": 3, "death_every": 1200, "death_recheck": 100800,
        "death_thirst": 50000, "death_hunger": 75000, "death_reports": 400}


# ---------------------------------------------------------------- status and brief on the fixture
@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def test_status_and_brief_show_the_deaths_per_cause(save):
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    st["care"]["died"] = {"mood": 1, "dehydrated": 2, "killed": 1}
    assert schema.validate("state", st) == []
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")
    out = brief.status_text(save)
    assert "deaths (season) dehydrated 2, killed 1, mood 1" in out, out
    assert est_tokens(out) <= brief.STATUS_TOKENS
    now = st["t"].get("abs", st["t"]["y"] * 403200 + st["t"]["tick"])
    append_events(save, [
        ev(9001, "DEATH", "citizen 5 died: dehydrated (incident THIRST; thirst 18879; patient)",
           {"unit": 5, "citizen": 1, "cause": "dehydrated", "patient": 1, "found": 1}, tick=now - 900),
        ev(9002, "DEATH", "citizen 6 died: unknown (not found yet, missing in the unit list)",
           {"unit": 6, "citizen": 1, "cause": "unknown", "found": 0}, tick=now - 800),
        ev(9003, "DEATH", "citizen 6 found dead: dehydrated (incident THIRST; thirst 20130)",
           {"unit": 6, "citizen": 1, "cause": "dehydrated", "found": 1, "revised": 1}, tick=now - 500),
        ev(9004, "DEATH", "citizen 7 died: killed by goblin 77 (incident STRUCK_DOWN)",
           {"unit": 7, "citizen": 1, "cause": "killed", "by": "goblin", "found": 1}, tick=now - 400),
        ev(9005, "DEATH", "citizen 2 died: drowned (incident DROWN)",
           {"unit": 2, "citizen": 1, "cause": "drowned", "found": 1}, tick=now - 200000),     # last year
        ev(9006, "DEATH_CLUSTER", "2 citizens died of dehydration within 28 d; units 5, 6",
           {"cause": "dehydrated", "n": 2, "units": [5, 6]}, tick=now - 500),
        ev(9007, "DEATHS_PREVENTABLE", "2 citizens died of dehydration within 28 d; units 5, 6",
           {"cause": "dehydrated", "n": 2, "units": [5, 6]}, tick=now - 500),
    ])
    text = brief.brief_text(save)
    assert est_tokens(text) <= brief.BRIEF_TOKENS
    # the fixture's own DEATH (unit 1388, an old cause token) stays; the revised DEATH of unit 6 wins over the first
    assert "## deaths (last season)\ndehydrated 2: 5 patient, 6 | combat 1: 1388 | killed 1: 7 by goblin" in text, text
    assert "drowned" not in text.split("## deaths (last season)")[1].split("\n")[1], "older than a season"
    assert "DEATHS_PREVENTABLE 2 citizens died of dehydration" in text
    digest = [x for x in text.splitlines() if x.startswith(("DEATH x", "DEATH_CLUSTER x"))]
    assert digest and all("[" not in x for x in digest), "the cause is in the msg: no d suffix"
    assert text.index("DEATH_CLUSTER x1") < text.index("DEATH x")


# ---------------------------------------------------------------- the real kernel
@pytest.fixture(scope="module")
def run(tmp_path_factory):
    out = tmp_path_factory.mktemp("deaths")
    r = luahost.run_file(LUA_TESTS / "deaths_scenario.lua", [str(out)], timeout=180, paths=[LUA_TESTS])
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
    assert not [e for e in evs if e["type"] in ("KERN_FAULT", "ACT_FAIL")]
    for s in ("a", "b"):
        d = json.loads((run / f"state.{s}.json").read_text(encoding="utf-8"))
        assert schema.validate("state", d) == [], d
        assert d["care"]["died"] == {"dehydrated": 2, "mood": 1}


@needs_lua
def test_death_causes_and_evidence(run):
    deaths = [e for e in events(run) if e["type"] == "DEATH"]
    assert [(e["d"]["unit"], e["d"]["cause"], e["d"]["found"]) for e in deaths] == [
        (5, "dehydrated", 1), (6, "unknown", 0), (6, "dehydrated", 1), (4, "mood", 1)]
    assert deaths[0]["msg"] == "citizen 5 died: dehydrated (incident THIRST; thirst 18879; patient)"
    assert deaths[1]["msg"] == "citizen 6 died: unknown (not found yet, missing in the unit list)"
    assert "thirst" not in deaths[1]["d"] and "dtype" not in deaths[1]["d"], "a missing dwarf's cause stays hidden"
    assert deaths[2]["d"]["revised"] == 1 and deaths[2]["msg"].startswith("citizen 6 found dead: dehydrated")
    assert deaths[3]["msg"] == "citizen 4 died: mood (in a Fey mood; incident THIRST; thirst 75004)"
    assert all("NONE" not in e["msg"] for e in deaths), "Run 9: 'died (NONE) [cause=NONE]'"


@needs_lua
def test_clusters(run):
    evs = events(run)
    cl = [e for e in evs if e["type"] == "DEATH_CLUSTER"]
    pv = [e for e in evs if e["type"] == "DEATHS_PREVENTABLE"]
    assert len(pv) == 1 and pv[0]["cls"] == "A" and pv[0]["d"] == CLUSTER_D
    assert [e["d"]["cause"] for e in cl] == ["dehydrated", "mixed"]
    assert cl[0]["msg"] == pv[0]["msg"] and len(pv[0]["msg"].encode()) <= 200
    assert cl[1]["msg"] == "3 citizens died within 28 d: dehydrated 2, mood 1; units 5, 6, 4 (1 patient)"


@needs_lua
def test_status_and_brief_on_the_kernel_files(run, monkeypatch, tmp_path):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    out = brief.status_text(run)
    assert "deaths (season) dehydrated 2, mood 1" in out, out
    text = brief.brief_text(run)
    assert "dehydrated 2: 5 patient, 6 | mood 1: 4" in text, text
    assert "DEATHS_PREVENTABLE 2 citizens died of dehydration" in text
