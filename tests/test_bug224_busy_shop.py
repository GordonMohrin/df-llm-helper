"""BUG-224 (live i3 Earthboat: one Carpenters shop with 4-5 waiting jobs, 35 citizens with the CARPENTER labor, most
idle): economy asks for one more shop of that type (PROJECT_REQUEST workshops why=busy types [Carpenters]); follow
places it the way it places the mandatory shops, kept although the fort manifest lists a Carpenters. Fails on 5e9e719."""
import pytest
from cli_v2_helpers import append_events, ev, inbox_docs, make_runtime, reset_paths

from dfpilot import cmd, schema


@pytest.fixture
def save(tmp_path):
    d = make_runtime(tmp_path)
    for p in cmd.bp_files(d):
        p.unlink()
    yield d
    reset_paths()


def test_follow_places_one_more_carpenters_for_a_busy_shop(save):
    from test_cli_wake import F, Clock
    from dfpilot.bp.rooms import MOODABLE_TYPES
    c = Clock()
    f, _ = F(c)
    f.poll()
    d = {"tpl": "workshops", "n": 1, "why": "busy", "types": ["Carpenters"]}
    assert schema.validate_event_d("PROJECT_REQUEST", d) == []
    append_events(save, [ev(9201, "PROJECT_REQUEST",
                            "workshops: one more Carpenters (1 shop, 4 jobs waiting, 30 idle carpenter)", d)])
    f.poll()
    (snap_cmd,) = inbox_docs(save)
    assert snap_cmd["verb"] == "snapshot"
    assert f.jobs["busy"]["params"] == {"skip": ",".join(t for t in MOODABLE_TYPES if t != "Carpenters")}
    assert f.jobs["busy"]["need"] == ["Carpenters"]
