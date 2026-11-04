"""Run 15 Guildcleans (i2) BUG-348: DECISION_NEEDED kill_lone_intruder #7150 and siege_long offered squad.sortie with a ready
command and no word on the armour (the player held back by Gordon's 80 % rule, worn 43 %). The kernel side
(military.sortie_advice, d.worn/d.need/d.rec) is tested in tests/lua/test_military.lua and test_bug331_siege_long.lua; here
the wake hints that carry the word."""
from dfpilot import wake

CMD = "dfllm cmd squad.sortie '{\"squad\":\"B\",\"target\":[1,136,117],\"approve\":true}'"


def test_bug348_hints_say_whether_the_sortie_is_recommended():
    low = {"cmd": CMD, "worn": 43, "need": 80, "rec": 0}
    high = {"cmd": CMD, "worn": 85, "need": 80, "rec": 1}
    for hint, extra in ((wake.lone_hint, {"id": "kill_lone_intruder"}), (wake.siege_long_hint, {"id": "siege_long"}),
                        (wake.sortie_hint, {"id": "intruder_sortie", "hl": 1})):
        h = hint({**extra, **low})
        assert "sortie NOT recommended: worn 43% < 80%" in h and CMD in h, h
        h = hint({**extra, **high})
        assert "sortie recommended: worn 85% >= 80%" in h, h
        h = hint({**extra, "cmd": CMD})                       # an older kernel: no advice, the hint stays as it was
        assert "recommended" not in h and CMD in h, h


def test_bug348_armour_note_needs_both_numbers():
    assert wake.armour_note({}) == ""
    assert wake.armour_note({"worn": 50}) == ""
    assert wake.armour_note({"worn": "50", "need": 80}) == ""
