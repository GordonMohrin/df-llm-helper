"""BUG-742: the plan's population ceiling follows the kernel's defense_short hold (state ready.dh) instead of a second number."""
from test_bug377_379_defense import propose, save, world  # noqa: F401  (fixtures)

from dfpilot import plan


def _state(worn=28, dh=None, pop=43, wpk=None):
    s = {"pop": {"cit": pop, "soldiers": 8}, "mil": {"soldiers": 8, "worn": worn},
         "ready": {"audit": {"min_traps": 0}}, "traps": {"n": 0}}
    if dh is not None:
        s["ready"]["dh"] = dh
    if wpk is not None:
        s["ready"]["wpk"] = wpk
    return s


def test_kernel_defense_hold_reads_the_state():
    assert plan.kernel_defense_hold(_state(dh=47)) == 47
    assert plan.kernel_defense_hold(_state()) is None
    assert plan.kernel_defense_hold(_state(dh=0)) is None
    assert plan.kernel_defense_hold(None) is None


def test_defense_cap_is_never_below_the_kernel_hold():
    # the kernel stepped the hold to 47 (one wave of room after relax_days): the plan must not hold 43
    assert plan.defense_cap(_state(dh=47), 100) == 47
    # the cap argument still wins
    assert plan.defense_cap(_state(dh=47), 45) == 45
    # no kernel hold: the citizens now
    assert plan.defense_cap(_state(), 100) == 43


def test_defense_cap_keeps_the_kernel_hold_while_the_plan_sees_no_gap():
    # worn swung over the line at this look (the kernel's clear_days has not passed): no plan gap, the kernel still holds 43
    s = _state(worn=80, dh=43, pop=43)
    s["ready"]["audit"] = {"min_traps": 60}
    s["ready"]["tt"] = 20
    s["traps"] = {"n": 60}
    assert plan.defense_gaps(s) == []
    assert plan.defense_cap(s, 100) == 43


def test_defense_gaps_reads_the_median_worn_the_kernel_publishes():
    s = _state(worn=21, pop=60, wpk=76)
    s["ready"]["audit"] = {"min_traps": 60}
    s["ready"]["tt"] = 20
    s["traps"] = {"n": 60}
    assert plan.defense_gaps(s) == []                 # the instant 21 % is a refit's swing, the 45-day median is 76 %
    s["ready"]["wpk"] = 28
    assert any(g.startswith("armor worn 28") for g in plan.defense_gaps(s))


def test_propose_follows_the_kernel_hold_in_the_same_year(save):
    """Run 16a i1: the plan said 100 (no gap read at this look) while the kernel held 43: one ceiling, the kernel's number."""
    s = world(save, pop=48)
    s["ready"] = {"lvl": 0, "worn": 90, "cv": 8, "drill_age": -1, "fail": [], "dh": 52,
                  "audit": {"ok": 1, "age": 900, "min_traps": 40}}
    s["mil"] = {"soldiers": 10, "worn": 90, "squads": 3, "cv": 8, "kit": {"n": 10, "full": 10, "armor": 10, "weapon": 10}}
    doc, _ = propose(save, s)
    assert doc["policy"]["pop_ceiling"] == 52, doc["policy"]       # old: 100
    assert "defense_short 52" in doc["notes"], doc["notes"]
    s["ready"].pop("dh")                                            # the kernel lets go: the policy ceiling again
    doc, _ = propose(save, s)
    assert doc["policy"]["pop_ceiling"] == 100
