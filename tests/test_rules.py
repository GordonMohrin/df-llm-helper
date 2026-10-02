"""F2 autopilot: every rule (true/false, action, verify, cooldown), dry-run spy, loop protection, conflicts."""
from pathlib import Path

import pytest

from df_llm_helper import yamlmini
from df_llm_helper.client import MockClient
from df_llm_helper.clock import FakeClock
from df_llm_helper.config import DEFAULTS
from df_llm_helper.rules import Engine, RuleError, find_conflicts, load_rules, render, validate_rule
from df_llm_helper.store import Store
from df_llm_helper.toolsfs import ToolsDir
from helpers import ROOT, ctx_for

RULES = load_rules(ROOT / "data" / "rules")
BY_ID = {r.id: r for r in RULES}


def engine(rule_ids, tmp_path, *, dry=False, cfg=None):
    clock = FakeClock(1_790_840_000)
    store = Store()
    tools = ToolsDir(tmp_path, clock)
    client = MockClient({}, clock=clock)
    rules = [BY_ID[i] for i in rule_ids]
    return Engine(rules, client, store, tools, clock, cfg=cfg or DEFAULTS, dry_run=dry), client, store, tools, clock


# (rule, context parameters positive, negative, expected commands/resources)
CASES = [
    ("stale_flag_generic", dict(flags={"migranten": {"age_min": 45}}), dict(flags={"migranten": {"age_min": 5}}),
     ["flag:migranten"]),
    ("stale_mood_flag", dict(flags={"mood": {"age_min": 60}}), dict(flags={"mood": {"age_min": 60}}, moods=["X"]),
     ["flag:mood"]),
    ("stale_alert_flag", dict(flags={"alert": {"age_min": 60, "text": "Pferd tot"}}),
     dict(flags={"alert": {"age_min": 60}}, enemies=2), ["flag:alert"]),
    ("stale_caravan_flag", dict(flags={"caravan": {"age_min": 60}}, caravan_state=None),
     dict(flags={"caravan": {"age_min": 60}}, caravan_state="AtDepot"), ["flag:caravan"]),
    ("food_flag_clear", dict(flags={"food": {"age_min": 2}}, meals=80, drinks=100),
     dict(flags={"food": {"age_min": 2}}, meals=10, drinks=100), ["flag:food"]),
    ("service_restart", dict(services={"watchdog": False}), dict(services={}), ["claude/watchdog start"]),
    ("fps_drift", dict(fps=100), dict(fps=250), ['lua "df.global.enabler.fps=250"']),
    ("civ_alert_on_danger", dict(danger_alarm=1, civ_alert=0, enemies=1),
     dict(danger_alarm=0, civ_alert=0), ["claude/alert on", 'claude/schau say "Alarm: enemy in the fort, civilian alert on"']),
    ("caravan_at_depot", dict(caravan_state="AtDepot"), dict(caravan_state="Approaching"),
     ["flag:caravan", "claude/advance 0"]),
    ("drink_low_trinken", dict(drink_days=10, services={"trinken": False}),
     dict(drink_days=10, services={"trinken": True}), ["claude/trinken start"]),
    ("drink_low_once", dict(drink_days=10), dict(drink_days=60), ["claude/trinken once"]),
    ("drink_low_no_plants", dict(drink_days=10, plants=0), dict(drink_days=10, plants=30), []),
]


def _targets(recs):
    return [r.cmd or r.resource for r in recs if r.kind not in ("verify", "warn", "propose")]


@pytest.mark.parametrize("rid,pos,neg,expected", CASES, ids=[c[0] for c in CASES])
def test_each_rule_true_false_action(rid, pos, neg, expected, tmp_path):
    eng, client, store, tools, clock = engine([rid], tmp_path)
    for name in (pos.get("flags") or {}):
        tools.write_flag(name, "x")
    ctx, _ = ctx_for(**pos)
    recs = eng.cycle(ctx)
    assert recs, f"{rid}: condition expected to be true"
    assert _targets(recs) == expected
    # cooldown: immediately again -> no action
    assert eng.cycle(ctx) == []
    clock.advance(BY_ID[rid].cooldown_s + 1)
    # negative
    eng2, *_ = engine([rid], tmp_path / "neg")
    ctxn, _ = ctx_for(**neg)
    assert [r for r in eng2.cycle(ctxn) if r.kind != "verify"] == []


def test_civ_alert_off_is_only_a_proposal(tmp_path):
    eng, client, store, *_ = engine(["civ_alert_off_calm"], tmp_path)
    ctx, _ = ctx_for(civ_alert=1)
    recs = eng.cycle(ctx)
    assert recs and recs[0].kind == "propose" and client.calls == []
    assert any("Proposal" in w["text"] for w in store.take_warnings())


def test_verify_success_and_failure(tmp_path):
    eng, client, store, tools, clock = engine(["food_flag_clear"], tmp_path)
    tools.write_flag("food", "knapp")
    ctx, _ = ctx_for(flags={"food": {"age_min": 2}}, meals=80, drinks=100)
    good = lambda: ctx_for(meals=80, drinks=100)[0]  # noqa: E731  (Flag weg)
    recs = eng.cycle(ctx, refresh=good)
    assert [r.value for r in recs if r.kind == "verify"] == ["ok"]
    eng2, _, store2, tools2, _ = engine(["service_restart"], tmp_path / "b")
    ctx2, _ = ctx_for(services={"watchdog": False})
    recs = eng2.cycle(ctx2, refresh=lambda: ctx_for(services={"watchdog": False})[0])
    assert [r.value for r in recs if r.kind == "verify"] == ["fail"]
    assert store2.rule_state("service_restart")["verify_fail"] == 1
    assert any("check" in w["text"] for w in store2.take_warnings())


def test_dry_run_never_writes(tmp_path):
    eng, client, store, tools, clock = engine([r.id for r in RULES], tmp_path, dry=True)
    tools.write_flag("food", "x")
    ctx, _ = ctx_for(flags={"food": {"age_min": 99}, "alert": {"age_min": 99}, "migranten": {"age_min": 99}},
                     meals=80, drinks=100, fps=100, services={"watchdog": False, "trinken": False},
                     danger_alarm=1, civ_alert=0, caravan_state="AtDepot", drink_days=5, plants=0)
    recs = eng.cycle(ctx)
    assert len(recs) >= 6 and all(r.dry_run for r in recs)
    assert client.calls == [] and client.write_calls == []
    assert tools.flag("food").exists          # file untouched
    assert store.rule_state("food_flag_clear")["last_fire"] is None


def test_endless_loop_protection(tmp_path):
    eng, client, store, tools, clock = engine(["service_restart"], tmp_path)
    ctx, _ = ctx_for(services={"watchdog": False})
    n = 0
    for _ in range(10):
        recs = eng.cycle(ctx)
        n += sum(1 for r in recs if r.cmd == "claude/watchdog start" and r.ok)
        clock.advance(601)
    assert n == 3      # max_per_hour 3, then disabled
    st = store.rule_state("service_restart")
    assert st["disabled"] == 1 and "1 h" not in (st["reason"] or "x 1 h")
    assert any("disabled" in w["text"] and w["level"] == "crit" for w in store.take_warnings())


def test_conflicts_detected_on_load(tmp_path):
    p = tmp_path / "r.yaml"
    p.write_text(yamlmini.dumps([
        {"id": "a", "why": "w", "when": "True", "do": [{"service": {"name": "watchdog", "op": "start"}}]},
        {"id": "b", "why": "w", "when": "True", "do": [{"service": {"name": "watchdog", "op": "stop"}}]},
        {"id": "c", "why": "w", "when": "True", "do": [{"set_fps": 30}], "mutex_with": ["d"]},
        {"id": "d", "why": "w", "when": "True", "do": [{"set_fps": 250}], "mutex_with": ["c"]},
    ]), encoding="utf-8")
    res = find_conflicts(load_rules(p))
    assert any(x.startswith("CONFLICT: a") for x in res)
    assert any(x.startswith("declared") and "c (fps=30)" in x for x in res)
    assert not [x for x in find_conflicts(RULES) if x.startswith("CONFLICT")]


@pytest.mark.parametrize("bad,msg", [
    ({"id": "x", "why": "w", "when": "True"}, "do"),
    ({"id": "x", "when": "True", "do": [{"cmd": "a"}]}, "why"),
    ({"id": "x", "why": "w", "when": "a.__class__", "do": [{"cmd": "a"}]}, "privat"),
    ({"id": "x", "why": "w", "when": "True", "do": [{"teleport": "a"}]}, "unknown action"),
    ({"id": "x", "why": "w", "when": "True", "do": [{"cmd": "a", "warn": "b"}]}, "exactly one"),
    ({"id": "x", "why": "w", "when": "True", "do": [{"service": "x"}]}, "name/op"),
    ({"id": "x", "why": "w", "when": "True", "do": [{"cmd": "{a.__x}"}]}, "placeholder"),
    ({"id": "x", "why": "w", "when": "True", "do": [{"cmd": "a"}], "class": "boese"}, "class"),
    ({"id": "x", "why": "w", "when": "True", "do": [{"cmd": "a"}], "foo": 1}, "unknown fields"),
    ({"id": "x", "why": "w", "when": "True", "do": "cmd"}, "list"),
    ("text", "mapping"),
])
def test_rule_validation(bad, msg):
    with pytest.raises(RuleError, match=msg):
        validate_rule(bad, "t.yaml")


def test_duplicate_ids_and_file_shape(tmp_path):
    p = tmp_path / "r.yaml"
    p.write_text("- {id: a, why: w, when: 'True', do: [{cmd: x}]}\n- {id: a, why: w, when: 'True', do: [{cmd: y}]}\n")
    with pytest.raises(RuleError, match="duplicate"):
        load_rules(p)
    p.write_text("id: a\n")
    with pytest.raises(RuleError, match="list"):
        load_rules(p)


def test_render_placeholders():
    assert render("fps {x * 2} {{lit}} {l}", {"x": 15.0, "l": [1, 2]}) == "fps 30 {lit} 1,2"
    assert render("{missing}", {}) == ""


def test_write_flag_and_fairplay_in_actions(tmp_path):
    eng, client, store, tools, clock = engine(["caravan_at_depot"], tmp_path)
    ctx, _ = ctx_for(caravan_state="AtDepot")
    eng.cycle(ctx)
    assert tools.flag("caravan").exists and "Caravan at the depot" in tools.flag("caravan").text
    assert client.calls == ["claude/advance 0"]
    assert any("rb06_karawane" in w["text"] for w in store.take_warnings())


def test_disabled_rules_by_config(tmp_path):
    cfg = dict(DEFAULTS, autopilot=dict(DEFAULTS["autopilot"], disabled_rules=["fps_drift"]))
    eng, client, *_ = engine(["fps_drift"], tmp_path, cfg=cfg)
    ctx, _ = ctx_for(fps=100)
    assert eng.cycle(ctx) == [] and client.calls == []
