"""Round 30 (defense): BUG-481 the plan side of the trap shortfall (`plan.defense_gaps` names `traps short N<T` from the kernel's
`ready.tt`, the BUG-377 rules then hold growth), and the contract of the new events and state keys (REFUGE_PLUG, SIEGE_UNREADY
ts, ready ts/tt/rg, DECISION_NEEDED refuge_levers). The Lua side is tests/lua/test_bug478_481_*.lua, test_bug479_*.lua."""
import copy

from dfpilot import plan, schema


def state(min_traps=8, tt=29, n=28, cit=100):
    return {"phase": "P5", "pop": {"cit": cit, "soldiers": 14},
            "ready": {"lvl": 0, "worn": 80, "cv": 13, "drill_age": -1, "fail": ["traps_short"], "tt": tt,
                      "audit": {"ok": 1, "age": 900, "min_traps": min_traps}},
            "mil": {"soldiers": 14, "worn": 90, "squads": 3, "cv": 13, "kit": {"n": 14, "full": 14, "armor": 14, "weapon": 14}},
            "traps": {"m": 29, "n": n}}


def test_defense_gaps_name_the_trap_shortfall():
    s = state()
    assert plan.defense_gaps(s) == ["traps short 8<29"]
    s["ready"]["audit"]["min_traps"], s["traps"]["n"] = 40, 45
    assert plan.defense_gaps(s) == []
    s["traps"]["n"] = 12                                   # the armed traps in all are fewer than the weakest path
    assert plan.defense_gaps(s) == ["traps short 12<29"]
    s = state()
    del s["ready"]["tt"]                                   # an older kernel: no target, no gap (as before)
    assert plan.defense_gaps(s) == []
    s = state(min_traps=0)
    assert plan.defense_gaps(s) == ["traps 0"], "no armed trap at all is still BUG-377's hole"


def test_the_shortfall_holds_the_population_like_the_other_gaps():
    s = state()
    assert plan.defense_on(s, "P5") == ["traps short 8<29"]
    assert plan.defense_cap(s, 120) == 100                 # the citizens now, never above the cap
    assert plan.defense_on(state(cit=12), "P5") == [], "a young fort draws no hold"


def test_new_events_and_state_keys_validate():
    assert schema.validate_event_d("REFUGE_PLUG", {"proj": "rp1", "n": 8, "pos": [6, 6, 5], "closer": "hatch", "near": 14,
                                                   "breach": 0}) == []
    assert schema.validate_event_d("REFUGE_PLUG", {"proj": "rp1", "n": 8, "lifted": 1}) == []
    assert schema.validate_event_d("REFUGE_PLUG", {"n": 8}), "proj is required"
    assert schema.validate_event_d("SIEGE_UNREADY", {"fails": ["traps_short"],
                                                     "ts": "traps short: 8 armed on the weakest path < 29"}) == []
    assert schema.validate_event_d("DECISION_NEEDED", {"id": "refuge_levers", "q": "bridge O1: no linked lever inside the refuge",
                                                       "bridge": "O1",
                                                       "cmds": ["bp.place tpl=fortcore site=same stage=3 retrofit=2"]}) == []
    assert "REFUGE_PLUG" in schema.EVENTS and schema.EVENTS["REFUGE_PLUG"][0] == "A"


def test_ready_state_keys_validate():
    ready = {"lvl": 0, "worn": 80, "cv": 13, "drill_age": -1, "fail": ["traps_short"],
             "audit": {"ok": 1, "age": 900, "min_traps": 8}, "open": -1, "tt": 29, "rg": ["O1"],
             "ts": "traps short: 8 armed on the weakest path < 29 for ~35 invaders"}
    errs = []
    schema.STATE.errors({"v": 2, "wall": 1, "frame": 1, "tick": 1, "paused": False, "mode": "PEACE", "ready": ready}, "$", errs)
    assert not [e for e in errs if "ready" in e], errs
    bad = dict(ready, tt=-3)
    errs = []
    schema.STATE.errors({"ready": bad}, "$", errs)
    assert any("ready.tt" in e or "tt" in e for e in errs), errs
