"""Round 32 (misc): BUG-519 `squad.sortie` takes `unit` / `move` and `sortie.track_near` is a config knob, BUG-521 PROJECTS_REQUEUED is a runner
event, BUG-522 DEATH carries `dig`, BUG-520 a mood_deadline DECISION may carry `imp`. The kernel sides are tests/lua/test_bug518_unreach_memorial.lua,
test_bug519_sortie_track.lua, test_bug520_mood_impossible.lua, test_bug521_requeue.lua and test_bug522_cavein.lua."""
import json
from pathlib import Path

from dfpilot import fairplay, schema

ROOT = Path(__file__).resolve().parent.parent


def test_bug519_sortie_args_unit_and_move():
    base = {"squad": "A", "target": [1, 2, 3], "approve": True}
    assert schema.validate_args("squad.sortie", base) == []
    assert schema.validate_args("squad.sortie", {**base, "unit": 24878}) == []
    assert schema.validate_args("squad.sortie", {**base, "unit": 24878, "move": True}) == []
    assert schema.validate_args("squad.sortie", {**base, "unit": "x"}) != []
    assert schema.validate_args("squad.sortie", {**base, "unit": -1}) != []
    assert schema.validate_args("squad.sortie", {**base, "move": 1}) != []
    assert schema.validate_args("squad.sortie", {**base, "unit": 7, "gate": "O1"}) == []


def test_bug519_track_near_is_a_config_knob_with_a_limit():
    assert fairplay.SORTIE_LIM["track_near"] == (0, 100)
    cfg = json.loads((ROOT / "config" / "reflex.json").read_text(encoding="utf-8"))
    assert cfg["sortie"]["track_near"] == 25
    lua = (ROOT / "lua" / "dfllm" / "siege.lua").read_text(encoding="utf-8")
    assert "track_near = 25" in lua and "track_near = {0, 100}" in lua


def test_bug519_offered_commands_name_the_unit():
    for name in ("sense", "reflex", "siege"):
        text = (ROOT / "lua" / "dfllm" / f"{name}.lua").read_text(encoding="utf-8")
        assert '"target":[%d,%d,%d],"approve":true' not in text, name       # every squad.sortie command has "unit" now
        assert '"target":[%d,%d,%d],"unit":%d,"approve":true' in text, name


def test_bug521_projects_requeued_event():
    cls, by, spec = schema.EVENTS["PROJECTS_REQUEUED"]
    assert (cls, by) == ("B", "runner")
    d = {"n": 2, "ids": ["c1a1adfb5e77e85301", "c1a1adfb5e77e85302"], "failed": ["c1a1adfb5e77e85303: bp/c1a1adfb5e77e85303.json: missing"],
         "skipped": 1, "tick_alt": 156735937, "tick_neu": 156710269}
    out = []
    spec.errors(d, "d", out)
    assert out == []
    bad = []
    spec.errors({"ids": ["a"]}, "d", bad)                    # n is required
    assert bad
    lua = (ROOT / "lua" / "dfllm" / "util" / "contract.lua").read_text(encoding="utf-8")
    assert "PROJECTS_REQUEUED = {cls = 'B', by = 'runner'}" in lua
    assert "PROJECTS_REQUEUED" in (ROOT / "docs" / "v2" / "CONTRACTS.md").read_text(encoding="utf-8")


def test_bug522_death_dig_and_bug520_decision_imp():
    cls, by, spec = schema.EVENTS["DEATH"]
    out = []
    spec.errors({"unit": 1, "dtype": "CAVEIN", "pos": [15, 13, 141], "dig": ["c1a1ad01 hospital s0 3t risk 15,13,142"]}, "d", out)
    assert out == []
    out = []
    spec.errors({"unit": 1, "dig": "not a list"}, "d", out)
    assert out
    cls, by, spec = schema.EVENTS["DECISION_NEEDED"]
    out = []
    spec.errors({"id": "mood_deadline", "q": "x", "imp": ["bone: no animal can be slaughtered (3 tame: pets, war and hunting animals stay)"]}, "d", out)
    assert out == []
