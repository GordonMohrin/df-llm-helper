"""BUG-121 (Run 14 note 101): after the player loads an older save the event log, alarm.txt and follow's cursor stand in the
discarded timeline. The kernel writes TIMELINE_RESET at boot (tests/lua/test_timeline_reset.lua); follow, events and
brief drop the events of the discarded line: those before the last marker with a tick later than the marker's tick_neu,
and those later than the current tick (state), whatever a marker says."""
import json
from pathlib import Path

import pytest
from cli_v2_helpers import append_events, ev, make_runtime, reset_paths

from dfpilot import alarm, brief, events, files, schema, wake

YEAR = schema.TICKS["YEAR"]
DAY = schema.TICKS["DAY"]


def mark(n, tick_neu, n_alt=None, tick_alt=None):
    d = {"n_alt": n_alt if n_alt is not None else n - 1, "tick_alt": tick_alt or tick_neu + 5000, "tick_neu": tick_neu}
    return {"n": n, "tick": tick_neu, "type": "TIMELINE_RESET", "cls": "B",
            "msg": f"game clock jumped back (older save loaded): tick {d['tick_alt']} -> {tick_neu}", "d": d}


def e(n, typ, tick, cls=None, msg="", d=None):
    return {"n": n, "tick": tick, "type": typ, "cls": cls or schema.EVENTS[typ][0], "msg": msg, "d": d or {}}


def write_log(d: Path, evs, name="events.jsonl"):
    Path(d).mkdir(parents=True, exist_ok=True)
    (Path(d) / name).write_bytes("".join(files.dumps(x) + "\n" for x in evs).encode())


# the fort: events of ticks 100..500 are the line both timelines share (the loaded save was made at tick 300 in this model)
OLD = [e(1, "SEASON", 100), e(2, "STOCK_LOW", 200), e(3, "STOCK_LOW", 300),
       e(4, "BREACH", 400, msg="old breach"), e(5, "INTRUDER", 500, msg="old intruder"),
       e(6, "DEATHS_3PLUS", 600, msg="old deaths")]


def ns(evs):
    return [x["n"] for x in evs]


# ---------------------------------------------------------------- files: the marker rule
def test_events_before_the_marker_with_a_later_tick_are_dropped(tmp_path):
    write_log(tmp_path, OLD + [mark(7, 300), e(8, "GATE_FAIL", 310), e(9, "STOCK_LOW", 320)])
    got = files.tail_events(tmp_path)
    assert ns(got) == [1, 2, 3, 7, 8, 9]                       # the shared past stays, the abandoned line goes
    assert ns(list(files.iter_events_rev(tmp_path))) == [9, 8, 7, 3, 2, 1]


def test_without_a_marker_nothing_is_dropped(tmp_path):
    write_log(tmp_path, OLD)
    assert ns(files.tail_events(tmp_path)) == [1, 2, 3, 4, 5, 6]


def test_two_resets_apply_both_cuts(tmp_path):
    # second load went back to tick 150: everything of the first new line after 150 goes as well
    write_log(tmp_path, OLD + [mark(7, 300), e(8, "STOCK_LOW", 310), e(9, "STOCK_LOW", 350),
                               mark(10, 150, n_alt=9), e(11, "STOCK_LOW", 160)])
    assert ns(files.tail_events(tmp_path)) == [1, 10, 11]


def test_the_cut_crosses_the_rotation(tmp_path):
    write_log(tmp_path, OLD, "events.1.jsonl")
    write_log(tmp_path, [mark(7, 300), e(8, "STOCK_LOW", 310)])
    assert ns(files.tail_events(tmp_path)) == [1, 2, 3, 7, 8]


def test_events_newer_than_the_current_tick_are_dropped_without_a_marker(tmp_path):
    write_log(tmp_path, OLD)
    got = files.tail_events(tmp_path, max_tick=350)
    assert ns(got) == [1, 2, 3]
    assert ns(files.tail_events(tmp_path)) == [1, 2, 3, 4, 5, 6]     # callers that pass no cap keep everything


def test_limit_counts_what_survives(tmp_path):
    write_log(tmp_path, OLD + [mark(7, 300), e(8, "STOCK_LOW", 310)])
    assert ns(files.tail_events(tmp_path, limit=2)) == [7, 8]
    assert ns(files.tail_events(tmp_path, limit=4)) == [2, 3, 7, 8]


def test_cls_filter_does_not_resurrect_the_old_line(tmp_path):
    write_log(tmp_path, OLD + [mark(7, 300), e(8, "GATE_FAIL", 310)])
    assert ns(files.tail_events(tmp_path, cls="A")) == [8]           # BREACH #4, INTRUDER #5, DEATHS_3PLUS #6 are gone


# ---------------------------------------------------------------- dfllm events
def test_events_command_hides_the_discarded_line(tmp_path, capsys):
    write_log(tmp_path, OLD + [mark(7, 300), e(8, "GATE_FAIL", 310, msg="new gate")])
    args = type("A", (), {"cls": "A", "type": None, "since": 0, "limit": 30, "json": False})()
    events.run(args, tmp_path)
    out = capsys.readouterr().out
    assert "new gate" in out and "old breach" not in out and "old intruder" not in out and "old deaths" not in out


def test_events_command_caps_at_the_state_tick(save, capsys):
    now = json.loads((save / "state.b.json").read_text("utf-8"))["t"]["abs"]       # the slot with the higher seq
    far = now + files.TICK_SLACK + 1
    write_log(save, [e(1, "STOCK_LOW", now - 100), e(2, "BREACH", now + 400, msg="soon after the state"),
                     e(3, "INTRUDER", far, msg="far ahead of the state")])      # no marker: an older kernel
    assert files.tick_cap(save) == now + files.TICK_SLACK
    args = type("A", (), {"cls": "A", "type": None, "since": 0, "limit": 30, "json": False})()
    events.run(args, save)
    out = capsys.readouterr().out
    assert "soon after the state" in out and "far ahead of the state" not in out    # the slack covers a state a little behind


# ---------------------------------------------------------------- follow's tail
def test_tail_drops_the_old_line_inside_one_batch(tmp_path):
    write_log(tmp_path, OLD[:3])
    t = files.EventTail(tmp_path, None)
    assert t.last_n == 3 and t.poll() == []
    append_events_raw(tmp_path, OLD[3:] + [mark(7, 300), e(8, "GATE_FAIL", 310)])
    got = t.poll()
    assert ns(got) == [7, 8]                                     # BREACH/INTRUDER/DEATHS_3PLUS of the abandoned line: never seen
    assert t.last_n == 8                                         # the cursor passed them


def test_tail_replay_from_an_older_cursor_skips_the_old_line(tmp_path):
    write_log(tmp_path, OLD + [mark(7, 300), e(8, "GATE_FAIL", 310)])
    t = files.EventTail(tmp_path, 0)
    assert ns(t.poll()) == [1, 2, 3, 7, 8]
    t2 = files.EventTail(tmp_path, 4)                            # the cursor stands inside the abandoned line
    assert ns(t2.poll()) == [7, 8]


def test_tail_caps_at_the_current_tick(tmp_path):
    write_log(tmp_path, OLD[:3])
    now = [300]
    t = files.EventTail(tmp_path, None, tick_fn=lambda: now[0])
    append_events_raw(tmp_path, [e(4, "BREACH", 400), e(5, "STOCK_LOW", 300 + files.TICK_SLACK + 1)])
    got = t.poll()
    assert ns(got) == [4]                                        # 400 is within the slack of a state a little behind
    assert t.last_n == 5


def test_tail_marker_after_rotation(tmp_path):
    write_log(tmp_path, OLD[:5])
    t = files.EventTail(tmp_path, None)
    (tmp_path / "events.jsonl").rename(tmp_path / "events.1.jsonl")
    write_log(tmp_path, [e(6, "DEATHS_3PLUS", 600), mark(7, 300), e(8, "GATE_FAIL", 310)])
    assert ns(t.poll()) == [7, 8]


def append_events_raw(d, evs):
    p = Path(d) / "events.jsonl"
    with open(p, "ab") as f:
        f.write("".join(files.dumps(x) + "\n" for x in evs).encode())


# ---------------------------------------------------------------- alarm.txt
def test_alarm_items_after_the_clock_are_ignored(tmp_path):
    (tmp_path / "alarm.txt").write_text(
        "DEFCON 1 | mode BREACH | unacked 1 | last 9 | ack 0 | lockdown breach (gates)\n"
        "8\t1\t100\tINTRUDER\tacked\told\n9\t2\t900\tBREACH_X\tunacked\tdiscarded\n", "utf-8")
    assert [it["n"] for it in alarm.read_alarm(tmp_path)["items"]] == [8, 9]
    got = alarm.read_alarm(tmp_path, max_tick=300)
    assert [it["n"] for it in got["items"]] == [8] and got["ignored"] == 1


# ---------------------------------------------------------------- follow, brief and status on the fixture fort
@pytest.fixture
def save(tmp_path):
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


class Clock:
    def __init__(self, t=1_000_000.0):
        self.t = t

    def __call__(self):
        return self.t


def _discarded_line(save):
    """The fixture fort's clock is 1332160. The abandoned line ran far ahead (A events at 1.4M), the loaded save restarted
    at 1331000; the kernel's marker comes with the first events of the new line."""
    append_events(save, [e(8813, "BREACH", 1_400_000, msg="old breach", d={"why": "inside"}),
                         e(8814, "INTRUDER", 1_410_000, msg="old intruder"),
                         e(8815, "DEATHS_3PLUS", 1_420_000, msg="old deaths", d={"n": 3}),
                         mark(8816, 1_331_000, n_alt=8815, tick_alt=1_420_000),
                         e(8817, "GATE_FAIL", 1_331_100, msg="B1 new line", d={"bridge": "B1", "why": "no_worker"})])


def test_follow_replay_wakes_only_for_the_new_line(save):
    _discarded_line(save)
    c = Clock()
    out = []
    f = wake.Follower(out=out.append, clock=c, since=8812)
    f.poll()
    c.t += 11
    f.poll()
    text = " ".join(out)
    assert "GATE_FAIL" in text and "BREACH" not in text and "INTRUDER" not in text and "DEATHS_3PLUS" not in text


def test_follow_in_flight_never_wakes_for_the_old_line(save):
    c = Clock()
    out = []
    f = wake.Follower(out=out.append, clock=c)
    f.poll()
    _discarded_line(save)
    f.poll()
    c.t += 11
    f.poll()
    text = " ".join(out)
    assert "GATE_FAIL" in text and "BREACH" not in text and "INTRUDER" not in text


def test_follow_forgets_the_auto_jobs_of_the_old_line(save):
    c = Clock()
    f = wake.Follower(out=lambda s: None, clock=c)
    f.poll()
    f.jobs = {"replies": {"c1": {"since": c.t}}}
    f.plan_auto = {"first_y": 3, "tried_y": 9}
    append_events(save, [mark(8813, 1_331_000, n_alt=8812)])
    f.poll()
    assert f.jobs == {} and f.plan_auto == {}


def test_brief_and_status_ignore_the_class_a_events_of_the_old_line(save):
    _discarded_line(save)
    ctx = brief.Ctx(save)
    types = [x["type"] for x in ctx.a]
    assert "BREACH" not in types and "INTRUDER" not in types and "DEATHS_3PLUS" not in types
    assert "GATE_FAIL" in types
    assert any(x["type"] == "TIMELINE_RESET" for x in ctx.b)
    text = brief.brief_text(save)
    assert "old breach" not in text and "old intruder" not in text and "old deaths" not in text
    assert "TIMELINE_RESET" in text


def test_brief_digest_names_the_reset(save):
    _discarded_line(save)
    digest = brief.sec_digest(brief.Ctx(save))
    assert digest[0].startswith("TIMELINE_RESET x1")


def test_schema_knows_the_marker():
    assert schema.EVENTS["TIMELINE_RESET"][:2] == ("B", "kern")
    doc = {"n": 5, "tick": 100, "type": "TIMELINE_RESET", "cls": "B", "msg": "m",
           "d": {"n_alt": 4, "tick_alt": 900, "tick_neu": 100}}
    assert schema.validate("event", doc) == []
    bad = dict(doc, d={"n_alt": 4, "tick_alt": 900})
    assert schema.validate("event", bad)
