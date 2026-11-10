"""Round 44 (lock): BUG-672 passive plant eaters, BUG-673 unreachable hostiles, BUG-674 the squads screen in an animals-only BREACH, BUG-675 a PEACE
sortie against one wild animal, BUG-676 the operator's release. The Lua halves (with the siege traffic test) are in
tests/lua/test_bug672_676_lockdown.lua; here the contract (schema, verbs, config) and the wake line."""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))

from dfpilot import fairplay, schema, wake                                      # noqa: E402


def test_hostile_released_is_a_class_b_event_of_reflex():
    d = {"n": 4, "id": 29104, "why": "passive", "days": 3, "mode": "BREACH", "inside": 4}
    assert schema.EVENTS["HOSTILE_RELEASED"][:2] == ("B", "reflex")
    assert schema.validate_event_d("HOSTILE_RELEASED", d) == []
    assert schema.validate_event_d("HOSTILE_RELEASED", {"n": 1, "id": 5, "why": "unreachable"}) == []
    assert schema.validate_event_d("HOSTILE_RELEASED", {"n": 1, "id": 5}) != []          # why is required


def test_lockdown_release_verb_needs_approve_and_takes_a_unit():
    assert schema.VERBS["lockdown.release"] == ("reflex", None, True)
    assert schema.validate_args("lockdown.release", {"approve": True}) == []
    assert schema.validate_args("lockdown.release", {"approve": True, "unit": 29104}) == []
    assert schema.validate_args("lockdown.release", {}) != []
    assert schema.validate_args("lockdown.release", {"approve": True, "unit": -1}) != []
    assert schema.validate_args("lockdown.release", {"approve": True, "x": 1}) != []


def test_the_squads_screen_verbs_and_the_sortie_modes_match_the_kernel_contract():
    for v in ("squad.create", "squad.leader", "squad.add", "squad.uniform"):
        assert schema.VERBS[v][1] == ["PEACE", "ALERT", "RECOVERY", "SIEGE", "BREACH"], v
    assert schema.VERBS["squad.sortie"] == ("military", ["PEACE", "ALERT", "SIEGE", "BREACH", "RECOVERY"], True)
    # the zone verb keeps its own list
    assert schema.VERBS["zone.place"][1] == ["PEACE", "ALERT", "RECOVERY", "SIEGE"]


def test_reflex_config_passive_and_unreach_days(tmp_path):
    def errs(doc):
        p = tmp_path / "reflex.json"
        p.write_text(json.dumps(dict({"v": 2}, **doc)), encoding="utf-8")
        return fairplay.reflex_errors(p)
    assert errs({"confine": {"passive_days": 3, "unreach_days": 5}}) == []
    assert errs({"confine": {"passive_days": 0, "unreach_days": 0}}) == []
    assert errs({"confine": {"passive_days": 400}})
    assert errs({"confine": {"unreach_days": -1}})
    real = json.loads((fairplay.REPO / "config" / "reflex.json").read_text(encoding="utf-8"))
    assert real["confine"]["passive_days"] == 3 and real["confine"]["unreach_days"] == 5
    assert "passive_days" in real["about"] and "unreach_days" in real["about"]


def test_lockdown_long_names_the_release_when_only_wild_animals_are_counted():
    d = {"id": "lockdown_long", "days": 380, "mode": "BREACH", "n": 4, "inside": 4,
         "rel": "dfllm cmd lockdown.release '{\"unit\":29104,\"approve\":true}'"}
    h = wake.lockdown_long_hint(d)
    assert "lockdown.release" in h and "no squad to send" in h and "nothing but wild animals is counted" in h, h
    plain = wake.lockdown_long_hint({"id": "lockdown_long", "days": 12, "mode": "SIEGE", "n": 30, "inside": 0})
    assert "lockdown.release" not in plain, plain
