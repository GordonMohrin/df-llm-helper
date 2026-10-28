"""BUG-150 (live tests i1 and i2, 2026-10-28): verb replies named the verb twice ('ERR ... view: view: no saved player
position', 'resume: resume: the game is not paused', 'zone.place: zone.place: the box overlaps'): the Lua verbs put their
name in front of the message and cmd.fmt_reply did it again. The CP437 half (unit names in view replies) is in
tests/lua/test_bug150_151_view.lua."""
from dfpilot.cmd import fmt_reply


def test_a_verb_prefix_in_the_message_is_not_repeated():
    assert fmt_reply("c1", "view", {"ok": False, "msg": "view: no saved player position"}) == \
        "ERR c1 view: no saved player position"
    assert fmt_reply("c2", "resume", {"ok": False, "msg": "resume: the game is not paused"}) == \
        "ERR c2 resume: the game is not paused"
    assert fmt_reply("c3", "zone.place", {"ok": False, "msg": "zone.place: the box overlaps zone 7"}) == \
        "ERR c3 zone.place: the box overlaps zone 7"


def test_other_messages_stay_as_they_are():
    assert fmt_reply("c4", "inspect", {"ok": True, "msg": "trash: 3 loose item(s)", "data": {"n": 1}}) == \
        'ok c4 inspect: trash: 3 loose item(s) {"n":1}'
    assert fmt_reply("c5", "view", {"ok": True, "msg": "viewing: camera on 1,2 z3"}) == "ok c5 view: viewing: camera on 1,2 z3"
    assert fmt_reply("c6", "view", {"ok": True, "msg": "view:x"}) == "ok c6 view: view:x"
    assert fmt_reply("c7", "view", {"ok": True}) == "ok c7 view: "
