"""Run 9 care/water FRs (FR-04/26/27/31/33a/34/41/42/44/45/47/48) on the file contracts.

tests/lua/care_fr_scenario.lua boots lua/dfllm/kern.lua with care, water and a fake snapshot on k_mock's fake DF
and the repo's config files (the allowlist with `entomb`), then sends inspect what=tombs / water_sources and
tombs.repair through real inbox files. Every event, outbox reply and state slot must validate; the new class-A
events must come out; entomb must pass the real allowlist. The schema, allowlist and lint parts run without Lua.
"""
import json
import sys
import textwrap
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
LUA_TESTS = ROOT / "tests" / "lua"
sys.path.insert(0, str(ROOT / "tools"))
import luahost  # noqa: E402

from dfpilot import fairplay, schema, wake  # noqa: E402
from dfpilot import lint as L  # noqa: E402

needs_lua = pytest.mark.skipif(not luahost.available(), reason="lua53.dll not found")


# ---------------------------------------------------------------- contract tables
def test_new_class_a_events_validate():
    ok = {"n": 1, "tick": 5, "type": "GHOSTS", "cls": "A", "msg": "1 ghost(s)",
          "d": {"ghosts": 1, "corpses": 2, "old": 1, "units": [6, 7], "causes": ["6:zone_shared", "7:no_coffin"]}}
    assert schema.validate("event", ok) == []
    dry = {"n": 2, "tick": 5, "type": "HOSPITAL_DRY", "cls": "A", "msg": "hospital without accepted water",
           "d": {"why": "no wet well", "patients": 0, "zone": 7, "near": 30, "recipe": "zone the water at 1,2,3"}}
    assert schema.validate("event", dry) == []
    assert schema.validate("event", {**dry, "d": {"patients": 0}}) != []          # why is required
    risk = {"n": 3, "tick": 5, "type": "MOOD_RISK", "cls": "A", "msg": "mood unit 3",
            "d": {"unit": 3, "why": "thirst", "kind": "Fey", "missing": ["bars"], "thirst": 31000, "hunger": 0}}
    assert schema.validate("event", risk) == []
    assert schema.validate("event", {**risk, "d": {"why": "thirst"}}) != []       # unit is required
    assert schema.validate("event", {**risk, "cls": "B"}) != []
    for t in ("GHOSTS", "HOSPITAL_DRY", "MOOD_RISK"):
        assert t in wake.WAKE_TYPES and t in wake.NEXT


def test_verbs_and_acts():
    assert schema.validate_args("tombs.repair", {}) == []
    assert schema.validate_args("tombs.repair", {"now": True}) != []
    for what in ("tombs", "water_sources"):
        assert schema.validate_args("inspect", {"what": what}) == []
    assert schema.VERBS["tombs.repair"] == ("care", None, False)
    for fn in ("tomb_zone", "medic", "hospital_post"):
        assert schema.ACT[fn] == ["care"]


def test_entomb_is_allowlisted_in_one_form_only():
    """FR-45: `entomb --unit <id> --haul-now` (the burial assignment plus its hauling jobs); nothing else."""
    assert fairplay.check_run("entomb", ["--unit", "12", "--haul-now"]) == (True, "ok")
    for args in ([], ["--unit", "12"], ["--unit", "12", "--haul-now", "--tomb", "3"], ["--haul-now"]):
        assert fairplay.check_run("entomb", args)[0] is False, args
    al = fairplay.allowlist()
    assert al["armok_exceptions"] == ["lever"] and "entomb" not in al["blocked"]


def test_lint_labor_writes_only_in_act_medic_and_work_detail():
    src = textwrap.dedent("""
        local I = {}
        function I.medic(id, on)
          local u = df.unit.find(id)
          u.status.labors[df.unit_labor.DIAGNOSE] = on
        end
        function I.other(u) u.status.labors[0] = true end
        return I
    """)
    found = [(f["line"], f["rule"]) for f in L.lua_source(src, "lua/dfllm/act.lua")]
    assert found == [(7, "labor-write")]
    assert "labor-write" in {f["rule"] for f in L.lua_source(src, "lua/dfllm/care.lua")}


# ---------------------------------------------------------------- the real kernel
@pytest.fixture(scope="module")
def run(tmp_path_factory):
    out = tmp_path_factory.mktemp("carefr")
    r = luahost.run_file(LUA_TESTS / "care_fr_scenario.lua", [str(out)], timeout=180, paths=[LUA_TESTS])
    assert r.ok, f"exit {r.code}\n{r.out}\n{r.err}"
    assert "scenario done" in r.out
    return out / "dfllm-runtime" / "region1"


def events(sd: Path) -> list[dict]:
    return [json.loads(line) for line in (sd / "events.jsonl").read_text(encoding="utf-8").splitlines() if line]


@needs_lua
def test_events_validate_and_the_new_class_a_events_come(run):
    evs = events(run)
    for e in evs:
        assert schema.validate("event", e) == [], e
    by = {}
    for e in evs:
        by.setdefault(e["type"], []).append(e)
    assert {"GHOSTS", "HOSPITAL_DRY", "MOOD_RISK"} <= set(by)
    g = by["GHOSTS"][0]
    assert g["cls"] == "A" and g["d"]["ghosts"] == 1 and g["d"]["causes"] == ["6:zone_shared"]
    assert "bank 19,12,5 is reachable" in by["HOSPITAL_DRY"][0]["d"]["recipe"]
    # BUG-017: no bar in the fort at all: the class is named as without a source
    # K3: and the slot says so with its filter and counts
    assert by["MOOD_RISK"][0]["d"] == {"unit": 3, "why": "missing", "kind": "Fey", "missing": ["bars"],
                                       "nosrc": ["bars"], "slots": ["bars x1: none in the fort [0/0/0]"]}
    fails = [e for e in by.get("ACT_FAIL", []) if e["d"]["fn"] in ("run", "tomb_zone", "medic", "hospital_post")]
    assert fails == []


@needs_lua
def test_inspect_and_repair_replies(run):
    replies = {i: json.loads((run / "outbox" / f"c{i}.json").read_text(encoding="utf-8")) for i in range(1, 6)}
    for r in replies.values():
        assert schema.validate("outbox", r) == [], r
        assert r["ok"] is True, r
        assert len(json.dumps(r["data"], separators=(",", ":"))) <= 8192
    tombs = replies[4]["data"]
    assert tombs["coffins"] == 2 and tombs["free"] == 0
    assert {e["u"] for e in tombs["unburied"]} == {6, 7}
    assert tombs["ghosts"] == [[6, tombs["ghosts"][0][1]]]
    assert all(len(c["z"]) == 1 for c in tombs["list"]), "one zone per coffin after the repair"
    water = replies[5]["data"]
    assert water["bodies"][0]["bank"] == [19, 12, 5] and water["bodies"][0]["max"] == 7
    assert replies[3]["data"] == {"queued": 1}


@needs_lua
def test_commands_log_entomb_and_doctors(run):
    log = (run / "commands.log").read_text(encoding="utf-8")
    assert '"entomb","--unit","6","--haul-now"' in log and '"entomb","--unit","7","--haul-now"' in log
    assert log.count("act.medic") == 3 and "act.tomb_zone" in log


@needs_lua
def test_state_slots_validate(run):
    for s in ("a", "b"):
        d = json.loads((run / f"state.{s}.json").read_text(encoding="utf-8"))
        assert schema.validate("state", d) == [], d
