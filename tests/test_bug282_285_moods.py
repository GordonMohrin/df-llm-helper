"""BUG-282..285 (Run 15: four strange moods failed in three forts within ~3 game years; Drillchamber's fey glassmaker and
Possessed carpenter got no MOOD_CRITICAL at all, Guildcleans' two only at hunger 60,000 / thirst 50,000). The Python side:
the new event fields, act and state key are in the contracts, follow places only the shops a mood asks for at prio 1,
status and brief show the MOOD line at the top, plan propose puts the moods' trade tokens first, the knobs are checked.
The Lua suites (tests/lua/test_mood_emergency.lua, test_kern_act.lua) prove the kernel side. Every test fails on 64df679."""
import json
from pathlib import Path

import pytest
from cli_v2_helpers import append_events, ev, inbox_docs, install_fake_bp, make_runtime, reset_paths

from dfpilot import brief, cmd, fairplay, files, guide, plan, schema, wake
from dfpilot.events import est_tokens

ROOT = Path(__file__).resolve().parents[1]
LINE = ("MOOD Nomal Rigothushrir Fey needs glass x2: have 0/1; missing glass x2 (none in the fort); no GlassFurnace, "
        "time unknown (DF starts it at the claim)")


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def put_state(save, **keys):
    for slot in "ab":
        p = save / f"state.{slot}.json"
        st = json.loads(p.read_text("utf-8"))
        st.update(keys)
        assert schema.validate("state", st) == [], schema.validate("state", st)
        p.write_text(files.dumps(st), encoding="utf-8")


def crit(d):
    return {"n": 5, "tick": 100, "type": "MOOD_CRITICAL", "cls": "A", "msg": "[unit 26535 workshop,material] " + LINE,
            "d": d}


def test_contracts_event_act_state():
    d = {"unit": 26535, "why": "workshop", "reasons": ["workshop", "material"], "kind": "Fey", "name": "Nomal",
         "missing": ["glass"], "left": -1, "need": "GlassFurnace", "ask": "GlassFurnace", "slots": ["glass x2: none"],
         "webs": "collect webs queued at Loom 412", "lsrc": "est"}
    assert schema.validate("event", crit(d)) == []
    assert schema.validate("event", crit(dict(d, left="soon"))) != []
    assert schema.ACT["mood_task"] == ["care"]
    assert schema.STATE_OWNERS["mood"] == "care"
    base = json.loads((ROOT / "tests/fixtures/v2/runtime/region7/state.b.json").read_text("utf-8"))
    base["mood"] = [{"u": 26535, "t": LINE, "left": -1, "why": "workshop", "buy": ["glass"]}]
    assert schema.validate("state", base) == []
    base["mood"] = [{"u": 1, "t": "x" * 201}]
    assert schema.validate("state", base) != []
    base["mood"] = [{"u": 1, "t": "x"}] * 5
    assert schema.validate("state", base) != []
    lua = (ROOT / "lua/dfllm/util/contract.lua").read_text("utf-8")
    assert "mood_task = {'care'}" in lua and "['mood'] = 'care'" in lua and "mood = arr(obj({u = NAT, t = str(200)}" in lua
    text = (ROOT / "docs/v2/CONTRACTS.md").read_text("utf-8")
    assert "`mood_task(bld_id, job)`" in text and "`runner.mood_types(sid, types)`" in text and "| `mood?` |" in text


def test_follow_places_only_the_mood_shops_at_prio_1(save, monkeypatch):
    """Drillchamber y375: care's {tpl=workshops, why=mood} was placed as the whole 12-shop template at prio 4 (27 days)."""
    from test_cli_wake import F, Clock
    install_fake_bp(monkeypatch)
    for p in cmd.bp_files(save):
        p.unlink()
    from dfpilot.bp.rooms import MOODABLE_TYPES
    c = Clock()
    f, out = F(c)
    f.poll()
    append_events(save, [ev(9301, "PROJECT_REQUEST", "workshops for a strange mood (unit 26535), first: GlassFurnace,Butchers",
                            {"tpl": "workshops", "n": 2, "why": "mood", "types": ["GlassFurnace", "Butchers"]})])
    f.poll()
    (snap_cmd,) = inbox_docs(save)
    assert snap_cmd["verb"] == "snapshot"
    job = f.jobs["mood"]
    assert job["need"] == ["GlassFurnace", "Butchers"] and job["prio"] == 1
    assert job["params"] == {"skip": ",".join(t for t in MOODABLE_TYPES if t != "GlassFurnace"), "add": "Butchers"}
    assert "mood" in wake.PLACE_KEYS
    # a placed set and a new set of mood shops: no cooldown for the new one
    job["placed"] = "c1"
    append_events(save, [ev(9302, "PROJECT_REQUEST", "workshops for a strange mood (unit 26396), first: Loom",
                            {"tpl": "workshops", "n": 1, "why": "mood", "types": ["Loom"]})])
    f.poll()
    assert f.jobs["mood"]["need"] == ["Loom"]


def test_follow_keeps_the_plain_mood_request_without_types(save, monkeypatch):
    from test_cli_wake import F, Clock
    install_fake_bp(monkeypatch)
    c = Clock()
    f, out = F(c)
    f.poll()
    append_events(save, [ev(9303, "PROJECT_REQUEST", "workshops for a strange mood (unit 4, WEAVING)",
                            {"tpl": "workshops", "n": 1, "why": "mood"})])
    f.poll()
    assert "workshops" in f.jobs and "mood" not in f.jobs
    assert "mood" in wake.PLACE_KEYS                # (the typed key exists beside it)


def test_status_and_brief_show_the_mood_line_first(save):
    put_state(save, mood=[{"u": 26535, "t": LINE, "left": -1, "why": "workshop", "buy": ["glass"]},
                          {"u": 26396, "t": "MOOD Minkot Possessed needs cloth(silk) x1: have 0/1, 12 d left", "left": 12}])
    out = brief.status_text(save)
    lines = out.splitlines()
    assert lines[1] == LINE, out
    assert "MOOD Minkot Possessed" in lines[2]
    assert est_tokens(out) <= brief.STATUS_TOKENS
    b = brief.brief_text(save).splitlines()
    assert b[1] == LINE and b[2].startswith("MOOD Minkot")


def test_status_without_a_mood_is_unchanged(save):
    assert "MOOD " not in brief.status_text(save)
    assert brief.mood_items(brief.Ctx(save, full=False)) == []


def test_plan_propose_puts_the_mood_tokens_first():
    doc = {"trade": {"want": ["bar:iron", "cloth"]}, "seasons": [{"build": []} for _ in range(4)], "notes": ""}
    s = {"stock": {}, "mood": [{"u": 1, "t": "x", "buy": ["cloth:silk", "cloth"]}, {"u": 2, "t": "y", "buy": ["gem"]}]}
    plan.draft_supply(doc, s, [0, 0, 0, 0], 0, None)
    assert doc["trade"]["want"][:3] == ["cloth:silk", "cloth", "gem"]
    assert doc["trade"]["want"].count("cloth") == 1 and "bar:iron" in doc["trade"]["want"]
    assert plan.mood_buys({}) == []


def test_guide_and_wake_name_the_days_left():
    f = {"a": [crit({"unit": 26535, "why": "timer", "left": 4, "kind": "Fey", "missing": ["glass"]})], "b": [],
         "now": 100, "state": {}}
    steps = guide._mood(f, {}, False)
    assert steps and "4 d left" in steps[0].why and "thirst" not in steps[0].why
    assert "days left" in wake.NEXT["MOOD_CRITICAL"]


def test_the_knobs_are_range_checked(tmp_path):
    base = json.loads((ROOT / "config/baseline.json").read_text("utf-8"))
    for k in ("mood_crit_nows", "mood_crit_wait", "mood_crit_left", "mood_timer", "mood_crit_every", "mood_crit_wall_s",
              "mood_act_every"):
        assert k in fairplay.CARE_LIM and k in base["care"], k
    p = tmp_path / "baseline.json"
    p.write_text(json.dumps({"care": {"mood_crit_left": 0, "mood_timer": 5, "mood_crit_wait": "x"}}))
    errs = fairplay.care_errors(p)
    assert len(errs) == 3, errs


def test_rules_row_names_the_new_emergency():
    rules = (ROOT / "RULES.md").read_text("utf-8")
    assert "BUG-282" in rules and "collect webs" in rules
    assert len(rules.splitlines()) <= 300
