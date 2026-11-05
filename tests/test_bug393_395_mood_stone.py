"""BUG-393..395 (Run 16 i1/i2/i3, 2026-11-04: strange moods kept failing for what the fort lacked). Python side:
BUG-394: follow places the shops of a mood request on the surface when no fortcore room site is free (i1 Bachwald: a Possessed
dwarf waited for 'no Craftsdwarfs' until it was placed by hand, 25 AUTO_FAIL `only 0 free site(s) for workshops`);
BUG-395: the DECISION_NEEDED mood_deadline carries its ready commands to the wake line and is urgent; the care knobs of
BUG-393/395 are in config/baseline.json inside the fair-play limits. The kernel's part (the stone dig, the decision) is
tests/lua/test_bug393_395_mood_stone.lua."""
import json
from pathlib import Path

import pytest
from cli_v2_helpers import make_runtime, reset_paths

from dfpilot import cmd, fairplay, schema, wake

BASELINE = Path(__file__).resolve().parent.parent / "config" / "baseline.json"


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def put_state(save, **parts):
    for slot in "ab":
        p = save / f"state.{slot}.json"
        doc = json.loads(p.read_text("utf-8"))
        doc.update(parts)
        p.write_text(json.dumps(doc), encoding="utf-8")


MOOD = {"skip": "Masons,Jewelers", "add": ""}


def test_workshop_tries_surface_only_for_a_named_selection_in_peace():
    assert wake.workshop_tries(MOOD, "PEACE") == [MOOD, {**MOOD, "surface": 1}]
    assert wake.workshop_tries(MOOD, "ALERT") == [MOOD], "no builders on the surface in a fight"
    assert wake.workshop_tries({"skip": "A", "surface": 1}, "PEACE") == [{"skip": "A", "surface": 1}]
    assert wake.workshop_tries({}, "PEACE") == [{}], "surface=1 alone is the four startup shops, not a plain 12-shop request"
    assert wake.workshop_tries({"add": "Farmers"}, "PEACE")[1] == {"add": "Farmers", "surface": 1}


def test_follow_places_the_mood_shops_on_the_surface_when_no_room_site_is_free(save, monkeypatch):
    put_state(save, mode="PEACE")
    f = wake.Follower(out=lambda s: None, clock=lambda: 1000.0)
    f.dir = save
    tried = []

    def send(verb, args, what, now, **kw):
        tried.append((args["p"], kw.get("need")))
        if not args["p"].get("surface"):
            raise cmd.BpError("site S1: only 0 free site(s) for workshops skip=Masons,Jewelers")
        return "c7"

    monkeypatch.setattr(f, "_send", send)
    args = {"tpl": "workshops", "site": "S1", "p": dict(MOOD), "prio": 1}
    assert f._place_workshops(args, 1000.0, {}, ["Craftsdwarfs"]) == "c7"
    assert [t[0] for t in tried] == [MOOD, {**MOOD, "surface": 1}]
    assert all(t[1] == ["Craftsdwarfs"] for t in tried), "the kernel's `need` goes along"
    assert args["p"] == {**MOOD, "surface": 1}
    assert "BUG-394" in (save / "cli.log").read_text("utf-8")


def test_follow_workshops_room_site_is_still_the_first_choice(save, monkeypatch):
    put_state(save, mode="PEACE")
    f = wake.Follower(out=lambda s: None, clock=lambda: 1000.0)
    f.dir = save
    tried = []
    monkeypatch.setattr(f, "_send", lambda verb, args, what, now, **kw: tried.append(args["p"]) or "c1")
    assert f._place_workshops({"tpl": "workshops", "site": "S1", "p": dict(MOOD)}, 1000.0, {}, None) == "c1"
    assert tried == [MOOD]


def test_follow_workshops_without_any_site_names_both_errors(save, monkeypatch):
    put_state(save, mode="PEACE")
    f = wake.Follower(out=lambda s: None, clock=lambda: 1000.0)
    f.dir = save

    def send(verb, args, what, now, **kw):
        raise cmd.BpError("site S1: only 0 free site(s) for workshops" + (" surface" if args["p"].get("surface") else ""))

    monkeypatch.setattr(f, "_send", send)
    with pytest.raises(cmd.BpError, match=r"only 0 free site\(s\) for workshops; BUG-394: surface=1 too: .*surface"):
        f._place_workshops({"tpl": "workshops", "site": "S1", "p": dict(MOOD)}, 1000.0, {}, None)
    put_state(save, mode="ALERT")
    with pytest.raises(cmd.BpError) as ei:
        f._place_workshops({"tpl": "workshops", "site": "S1", "p": dict(MOOD)}, 1000.0, {}, None)
    assert "BUG-394" not in str(ei.value), "ALERT: only the room try"


def test_the_starter_and_plain_requests_do_not_take_the_surface_path(save, monkeypatch):
    put_state(save, mode="PEACE")
    f = wake.Follower(out=lambda s: None, clock=lambda: 1000.0)
    f.dir = save
    used = []
    monkeypatch.setattr(f, "_place_workshops", lambda *a, **k: used.append("w") or "cw")
    sent = []
    monkeypatch.setattr(f, "_send", lambda verb, args, what, now, **kw: sent.append(args) or "c2")
    monkeypatch.setattr(wake.files, "read_snapshot", lambda p: {"bbox": [0, 0, 0, 1, 1, 0]})
    f._place("starter", {"tpl": "workshops", "site": "S1", "path": "snap/x.json", "params": {"skip": "A"}, "since": 0}, 1000.0)
    assert used == [] and len(sent) == 1, "the PLAN_EXHAUSTED starter keeps its own placement"
    f._place("mood", {"tpl": "workshops", "site": "S1", "path": "snap/x.json", "params": dict(MOOD), "since": 0}, 1000.0)
    assert used == ["w"]


CMDS = ["dfllm cmd trade.want '{\"add\":[\"stone\",\"bar:iron\"]}'",
        "dfllm cmd bp.place '{\"tpl\":\"workshops\",\"site\":\"S1\",\"p\":{\"only\":\"Jewelers,Craftsdwarfs\",\"surface\":1}}'"]


def test_mood_deadline_commands_pass_the_schema_and_each_is_a_valid_command():
    d = {"id": "mood_deadline", "q": "Udil Fey: 8 d to insanity, still short: bars", "opts": ["trade.want", "workshops"],
         "cmds": CMDS, "auto": ["stone dig", "caravans asked"]}
    assert schema.validate_event_d("DECISION_NEEDED", d) == []
    for line in CMDS:
        verb, _, raw = line.removeprefix("dfllm cmd ").partition(" ")
        assert schema.validate_args(verb, json.loads(raw.strip("'"))) == [], line


def test_mood_deadline_reaches_the_wake_line_with_its_first_command_and_is_urgent():
    d = {"id": "mood_deadline", "q": "x", "opts": ["trade.want", "workshops"], "cmds": CMDS, "auto": ["caravans asked"]}
    e = {"type": "DECISION_NEEDED", "cls": "A", "d": d}
    h = wake.next_hint("DECISION_NEEDED", e)
    assert CMDS[0] in h and "caravans asked" in h and "workshops" in h
    assert wake.urgent_game(e)
    assert wake.next_hint("DECISION_NEEDED", {"type": "DECISION_NEEDED", "cls": "A", "d": {"id": "mood_deadline"}}) == \
        wake.NEXT["DECISION_NEEDED"], "no commands: the plain hint"


def test_the_care_knobs_are_in_the_baseline_inside_the_fairplay_limits(tmp_path):
    care = json.loads(BASELINE.read_text("utf-8"))["care"]
    for k in ("stone_dig", "stone_r", "stone_probes", "stone_wet", "stone_tries", "stone_retry", "mood_decide"):
        assert k in care, k
        assert k in fairplay.CARE_LIM, k
    assert fairplay.care_errors(BASELINE) == []
    bad = json.loads(BASELINE.read_text("utf-8"))
    bad["care"]["stone_wet"] = 0
    p = tmp_path / "baseline.json"
    p.write_text(json.dumps(bad), encoding="utf-8")
    assert any("stone_wet" in x for x in fairplay.care_errors(p))
