"""BUG-363 (Run 16b i2, y372): follow placed the fortcore before the player's plan, the draft still had office/farms/dining
('plan check' ERROR '0 free sites'). core_digging also holds for a placed stage 1 that state.proj does not list yet."""
import copy
import json

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import files, plan, schema


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    (d / "bp").mkdir(exist_ok=True)
    (d / "bp" / "c1a1a6b45876c8ac36.json").write_text(json.dumps({"tpl": "fortcore", "params": {"stage": 1}}), "utf-8")
    yield d
    reset_paths()


def test_a_placed_core_without_a_state_row_is_digging_until_it_is_done(save):
    assert plan.core_digging(save, {"proj": []}) is True                    # queued / beyond the 8 rows: old code False
    assert plan.core_digging(save, None) is True
    assert plan.core_digging(save, {"proj": [["c1a1a6b45876c8ac36", "s1.build", 5, ""]]}) is False   # past the dig
    assert plan.core_digging(save, {"proj": [["c1a1a6b45876c8ac36", "s2.dig", 5, ""]]}) is False
    assert plan.core_digging(save, {"proj": [["c1a1a6b45876c8ac36", "s1.dig", 0, "breach:damp"]]}) is False
    done = {"n": 9, "tick": 100, "cls": "A", "type": "PROJECT_DONE", "msg": "x", "d": {"proj": "c1a1a6b45876c8ac36"}}
    (save / "events.jsonl").write_text(json.dumps(done) + "\n", "utf-8")
    assert plan.core_digging(save, {"proj": []}) is False                   # dug: the usual draft
    (save / "events.jsonl").write_text("", "utf-8")
    (save / "bp" / "c1a1a6b45876c8ac36.json").write_text(
        json.dumps({"tpl": "fortcore", "params": {"stage": 1, "retrofit": True}}), "utf-8")
    assert plan.core_digging(save, {"proj": []}) is False                   # a retrofit digs no new floor
    (save / "bp" / "c1a1a6b45876c8ac36.json").unlink()
    assert plan.core_digging(save, {"proj": []}) is False                   # cancelled / never placed: BUG-197 path


def test_the_draft_has_no_rooms_for_a_floor_that_is_not_dug_and_places_nothing(save):
    s = copy.deepcopy(files.read_state(save))
    s["phase"], s["proj"] = "P0", []
    fort = dict(plan.fort_facts(save, s), z4=False)       # the fixture manifest already has a Z4 zone
    assert fort["core_dig"] is True
    before = sorted(p.name for p in (save / "bp").iterdir())
    doc = plan.propose(s, plan.load_phases(), None, decisions={}, applied=plan.applied_builds(save, s), fort=fort)
    # BUG-356 (merged with BUG-363): besides the seal only the surface startup set (no dug floor needed)
    assert all(b["tpl"] == "seal" or (b["tpl"] == "workshops" and (b.get("p") or {}).get("surface")) for se in doc["seasons"] for b in se["build"])
    assert doc["phase_target"] == "P0" and schema.validate("plan", doc) == []
    assert sorted(p.name for p in (save / "bp").iterdir()) == before        # propose only drafts
