"""Round 46b (lever): BUG-712 the python side. `bp.place tpl=fortcore stage=3 retrofit=3` builds the main levers of O1, B1 and B2 as
well as the refuge levers (a bridge whose levers are gone, toppled by a tantrum or never built, has none gate could pull), the
manifest fragment is the same as retrofit=2 (the runner's merge keeps every lever already listed, BUG-713), and the new state key
`ready.ll` and the DECISION_NEEDED `bridge_levers` validate. The Lua side is tests/lua/test_bug712_714_levers.lua."""
import pytest

from dfpilot import schema
from dfpilot.bp import fortcore

P = {"stage": 3, "depth": 3, "refuge": 3, "beds": 8, "aquifer": ""}


def _lever_stage(plan):
    return next(s for s in plan.stages if s.label == "s3.lever")


def _count_tl(stage):
    return sum(1 for it in stage.items if it.key == "Tl")


def test_retrofit_3_builds_the_main_and_the_refuge_levers():
    two = fortcore.build(dict(P, retrofit=2))
    three = fortcore.build(dict(P, retrofit=3))
    assert [s.label for s in three.stages] == ["s3.lrooms", "s3.lever"]
    n2, n3 = _count_tl(_lever_stage(two)), _count_tl(_lever_stage(three))
    assert n2 == 3, "retrofit=2: the three refuge levers"
    assert n3 == n2 + sum(len(v) for v in fortcore.LEVERS.values()) == 9, "retrofit=3: + the six main levers"
    assert three.manifest == two.manifest, "the fragment is the stage's full manifest either way"


def test_retrofit_3_lists_every_manifest_lever_of_the_stage():
    m = fortcore.build(dict(P, retrofit=3)).manifest
    for name in ("O1", "B1", "B2"):
        levers = m["bridges"][name]["levers"]
        assert len(levers) == 3, (name, levers)             # two main levers + the refuge lever
        assert list(fortcore.refuge_levers(fortcore.levels(P)[1])[name]) in levers


def test_retrofit_3_needs_stage_3():
    with pytest.raises(ValueError):
        fortcore.build(dict(P, stage=2, retrofit=3))
    with pytest.raises(ValueError):
        fortcore.build(dict(P, stage=4, retrofit=3))
    fortcore.build(dict(P, stage=3, retrofit=1))             # the old kinds stay


def test_param_range_admits_3_and_not_4():
    assert fortcore.PARAMS["retrofit"] == (0, 0, 3)


def test_new_state_key_and_decision_validate():
    ready = {"lvl": 0, "worn": 80, "cv": 13, "drill_age": -1, "fail": ["levers:B2", "levers:O1"],
             "audit": {"ok": 1, "age": 900, "min_traps": 8}, "open": -1, "ll": ["B2", "O1"]}
    errs = []
    schema.STATE.errors({"v": 2, "wall": 1, "frame": 1, "tick": 1, "paused": False, "mode": "PEACE", "ready": ready}, "$", errs)
    assert not [e for e in errs if "ready" in e], errs
    assert schema.validate_event_d("DECISION_NEEDED", {"id": "bridge_levers", "q": "bridge O1: no lever stands", "bridge": "O1",
                                                       "cause": "none",
                                                       "cmds": ["bp.place tpl=fortcore site=same stage=3 retrofit=3"]}) == []
