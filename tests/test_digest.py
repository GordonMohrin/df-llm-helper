"""F1 digest: token targets, delta, thresholds, property test, determinism."""
import random

import pytest

from conftest import FIX
from df_llm_helper.anomaly import CancelLoop
from df_llm_helper.config import DEFAULTS, load_config
from df_llm_helper.digest import DigestState, build_digest, compute_alerts, inbox_items, tokens
from df_llm_helper.snapshot import fixture_snapshot
from df_llm_helper.toolsfs import FlagInfo, read_text_tolerant
from helpers import snap_for
from make_fixtures import random_responses
from df_llm_helper.client import MockClient
from df_llm_helper.snapshot import collect
from helpers import CMDS

TH = DEFAULTS["thresholds"]
INBOX = [ln for ln in read_text_tolerant(FIX / "scopes_sample" / "inbox-orchestrator.md").splitlines()
         if ln.startswith("- ")]


def test_fixture_digest_within_600_tokens_and_second_call_short():
    s = fixture_snapshot(FIX)
    t1, st = build_digest(s, DigestState(), th=TH, inbox=INBOX, now_hhmm="10:40")
    assert tokens(t1) <= 600
    assert "Hunger" in t1 and "Caravan" in t1 and t1.startswith("Status Y102 Hematite 12")
    for _ in range(5):          # BUG-111: inbox lines beyond the display limit come with the next digests
        t2, st = build_digest(s, st, th=TH, inbox=INBOX, now_hhmm="10:40")
        if t2.startswith("No change"):
            break
        assert ">" in t2 and tokens(t2) <= 600
    assert tokens(t2) <= 30 and t2.startswith("No change")
    assert len(st.inbox_seen) == len(set(INBOX))
    t3, _ = build_digest(s, DigestState(), th=TH)
    assert tokens(t3) <= 600


def test_thresholds_configurable():
    s = fixture_snapshot(FIX)
    th = dict(TH, drink_days_crit=80)
    t, _ = build_digest(s, DigestState(), th=th)
    assert "!! Drinks 76 days (<80)" in t
    t, _ = build_digest(s, DigestState(), th=dict(TH, hunger_crit=50000))
    assert "Hunger" not in t
    cfg = load_config(overrides={"thresholds": {"drink_days_crit": 90}})
    assert cfg.th["drink_days_crit"] == 90 and cfg.th["food_days_crit"] == 30


def _violations(p: dict) -> list[str]:
    """Independently computed expectation: which texts MUST appear in the digest."""
    need = []
    if p["drink_days"] is not None and p["drink_days"] < TH["drink_days_crit"]:
        need.append("Drinks")
    if p["food_days"] is not None and p["food_days"] < TH["food_days_crit"]:
        need.append("Food")
    hungry = sorted([(v, k) for k, v in p["hunger"].items() if v > TH["hunger_crit"]], reverse=True)
    for _, uid in hungry[:4]:
        need.append(str(uid))
    if len(hungry) > 4:
        need.append(f"+{len(hungry) - 4}")
    thirsty = sorted([(v, k) for k, v in p["thirst"].items() if v > TH["thirst_crit"]], reverse=True)
    for _, uid in thirsty[:4]:
        need.append(str(uid))
    if p["enemies"]:
        need.append(f"{p['enemies']} enemies")
    if p["danger_alarm"]:
        need.append("danger alarm")
    if p["civ_alert"]:
        need.append("Civilian alert")
    if p["moods"]:
        need.append("Mood active")
    if p["caravan_state"] in ("Approaching", "AtDepot"):
        need.append("Caravan")
    if p["corpses"]:
        need.append("dwarf corpses")
    if p["stress_high"]:
        need.append("high stress")
    return need


@pytest.mark.parametrize("seed", range(150))
def test_property_no_violation_swallowed(seed):
    rng = random.Random(seed)
    resp, params = random_responses(rng)
    s = collect(MockClient(resp), CMDS)
    # inbox flood against the budget: critical items must not go missing
    t, _ = build_digest(s, DigestState(), th=TH, inbox=INBOX * 3)
    assert tokens(t) <= 600
    for needle in _violations(params):
        assert needle in t, f"seed {seed}: {needle!r} missing in\n{t}"


def test_deterministic_and_stable_order():
    for seed in range(20):
        resp, _ = random_responses(random.Random(seed))
        s1 = collect(MockClient(resp), CMDS)
        s2 = collect(MockClient(resp), CMDS)
        a, _ = build_digest(s1, DigestState(), th=TH, inbox=INBOX)
        b, _ = build_digest(s2, DigestState(), th=TH, inbox=INBOX)
        assert a == b


def test_delta_new_resolved_still_and_trends():
    s1 = snap_for(drink_days=20, idle=2, pop=24)
    t1, st = build_digest(s1, DigestState(), th=TH)
    assert "Drinks 20 days" in t1
    s2 = snap_for(drink_days=80, idle=12, pop=26, enemies=2)
    t2, st = build_digest(s2, st, th=TH)
    assert "resolved: Drinks" in t2 and "2 enemies" in t2
    assert "Population +2" in t2 and "Idle" in t2
    s3 = snap_for(drink_days=80, idle=12, pop=26, enemies=2)
    t3, st = build_digest(s3, st, th=TH, now_hhmm="11:00")
    assert t3.startswith("No change since 11:00") and "Danger" in t3
    s4 = snap_for(drink_days=80, idle=12, pop=25, enemies=2)
    t4, _ = build_digest(s4, st, th=TH)
    assert "Population -1" in t4
    # signature: only a relevant change reports again (drink_days in steps of 5)
    sa = snap_for(drink_days=22)
    ta, sta = build_digest(sa, DigestState(), th=TH)
    tb, _ = build_digest(snap_for(drink_days=21), sta, th=TH)
    assert tb.startswith("No change")
    tc, _ = build_digest(snap_for(drink_days=12), sta, th=TH)
    assert "Drinks 12 days" in tc


def test_scope_filter_and_flags_and_warnings():
    s = snap_for(drink_days=10, enemies=3, caravan_state=None)
    t, _ = build_digest(s, DigestState(), th=TH, scope="trinken")
    assert "Drinks" in t and "enemies" not in t
    flags = {"alert": FlagInfo("alert", True, 3.0, "Goblins!"), "food": FlagInfo("food", False)}
    t, _ = build_digest(s, DigestState(), th=TH, flags=flags,
                        warnings=[{"level": "crit", "key": "x", "source": "guard", "text": "DEADMAN", "ts": 1}])
    assert "alert.flag open (3 min): Goblins!" in t and "[guard] DEADMAN" in t


def test_new_game_detected():
    s1 = snap_for()
    _, st = build_digest(s1, DigestState(), th=TH)
    s2 = snap_for(fort="Neufort", embark=(103, 5))
    t, st2 = build_digest(s2, st, th=TH)
    assert "NEW GAME" in t and st2.game_id == "Neufort|103|5"


def test_inbox_dedupe_and_truncation():
    lines = ["- from bau, 01.10. 10:00 (Y1): " + "x" * 300, "- from bau, 01.10. 10:01 (Y1): " + "x" * 300,
             "- from a, 01.10. 10:02: short"]
    items, hashes, skipped = inbox_items(lines, set(), 6, 110)
    assert len(items) == 2 and len(hashes) == 3 and all(len(i.text) <= 110 for i in items)
    items, _, _ = inbox_items(lines, set(hashes), 6, 110)
    assert items == []
    items, _, skipped = inbox_items([f"- from x, 1:{i:02d}: m{i}" for i in range(10)], set(), 3, 110)
    assert len(items) == 3 and skipped == 7 and items[0].text.endswith("m9")


def test_fetch_failure_and_parse_errors_reported():
    m = MockClient({})
    s = collect(m, ["claude/status", "claude/report"])
    t, _ = build_digest(s, DigestState(), th=TH)
    assert "Query failed" in t


def test_cancel_loops_with_hint_and_budget_cut():
    s = snap_for()
    loops = [CancelLoop("Make bed", "Needs logs", 314, 21)]
    t, _ = build_digest(s, DigestState(), th=TH, cancels=loops, hint=lambda c: "kb bett_ohne_holz")
    assert "Cancel loop Make bed: Needs logs 314x (21 dwarves) -> kb bett_ohne_holz" in t
    t, _ = build_digest(s, DigestState(), th=TH, inbox=INBOX * 5, max_tokens=150, inbox_max=50)
    assert tokens(t) <= 150 and "truncated" in t and "Hunger" in t


def test_compute_alerts_misc():
    s = snap_for(stress_high=2, corpses=1)
    s.alerts.refuge_ok = False
    s.errors.append("x: broken")
    keys = {a.key for a in compute_alerts(s, TH)}
    assert {"stress", "corpses", "refuge", "parse"} <= keys
