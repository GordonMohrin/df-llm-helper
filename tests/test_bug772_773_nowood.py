"""BUG-773 / BUG-772 (Run 16c i3 Lancemoment y372: no tree, limestone only): a treeless fort (state stock.nowood) calls for the farm below
FOOD_EARLY_D food days, not only below 60; `plan check` / `plan apply` rank on the sites snapshot `plan propose` ranked on (sidecar
<draft>.snap), a rejection there is tried once more on the newest snapshot."""
import os
import sys
from pathlib import Path

from dfpilot import cmd, files, plan

sys.path.insert(0, str(Path(__file__).resolve().parent / "bp"))
from bp_fixtures import fort_world  # noqa: E402


def test_treeless_fort_calls_for_the_farm_early():
    s = {"stock": {"food_d": 100, "drink_d": 200}}
    assert plan.farm_low(s) is None, "a fort with trees is not short at 100 days"
    s["stock"]["nowood"] = 1
    assert plan.farm_low(s) == ("food", 100)
    s["stock"]["food_d"] = plan.FOOD_EARLY_D
    assert plan.farm_low(s) is None
    s["stock"]["food_d"] = 40
    assert plan.farm_low(s) == ("food", 40)


def test_food_draft_names_the_treeless_reason_and_drafts_the_farm():
    s = {"mode": "PEACE", "pop": {"cit": 16}, "stock": {"food_d": 110, "drink_d": 200, "nowood": 1}}
    fort = {"farms": {"open": False, "site": "room"}}
    b, note = plan.food_draft(s, fort, [], None)
    assert b and b["tpl"] == "farms" and b["site"] == "S1" and "p" not in b, (b, note)
    assert "treeless fort" in note and f"< {plan.FOOD_EARLY_D}" in note, note
    s["stock"].pop("nowood")
    assert plan.food_draft(s, fort, [], None) == (None, "")


def _snap(w, sid, tick, mtime, save):
    doc = w.snapshot(purpose="sites")
    doc["id"], doc["tick"] = sid, tick
    p = save / "snap" / f"{sid}.json"
    p.parent.mkdir(parents=True, exist_ok=True)
    files.write_json_atomic(p, doc)
    os.utime(p, (mtime, mtime))
    return doc


def test_check_and_apply_rank_on_the_proposed_snapshot(tmp_path):
    w, _ = fort_world(big=True)
    save = tmp_path
    _snap(w, "c1a1aaaa", 1000, 1000, save)
    _snap(w, "c1a1bbbb", 2000, 2000, save)
    cmd.pin_snapshot(save, None)
    assert cmd.sites_snapshot(save)["id"] == "c1a1bbbb"
    draft = save / "plan.draft.json"
    draft.write_text("{}")
    files.write_json_atomic(draft.with_name("plan.draft.json.snap"), {"id": "c1a1aaaa", "tick": 1000})
    pin = plan.draft_pin(draft, save)
    assert pin == {"id": "c1a1aaaa", "tick": 1000}, pin
    cmd.pin_snapshot(save, pin["id"])
    try:
        assert cmd.sites_snapshot(save)["id"] == "c1a1aaaa", "ranks on the proposed map, not the newest"
        res, note = plan._pin_retry(save, pin, lambda: ([], "ok"))
        assert res == ([], "ok") and "proposed sites snapshot c1a1aaaa" in note and "no new ranking" in note, note
        # a rejection on the pinned one is tried again on the newest snapshot
        seen = []

        def failing():
            sid = cmd.sites_snapshot(save)["id"]
            seen.append(sid)
            return (["0 free sites for fortcore"] if sid == "c1a1aaaa" else []), sid

        monkey_stale = cmd.snapshot_stale
        cmd.snapshot_stale = lambda *a, **k: None
        try:
            res, note = plan._pin_retry(save, pin, failing)
        finally:
            cmd.snapshot_stale = monkey_stale
        assert seen == ["c1a1aaaa", "c1a1bbbb"], seen
        assert res == ([], "c1a1bbbb") and "ranked again on the newest c1a1bbbb: accepted" in note, (res, note)
    finally:
        cmd.pin_snapshot(save, None)


def test_a_pinned_snapshot_that_is_gone_or_a_year_old_is_not_used(tmp_path):
    w, _ = fort_world(big=True)
    save = tmp_path
    _snap(w, "c1a1aaaa", 1000, 1000, save)
    _snap(w, "c1a1bbbb", 1000 + 403200 * 2, 2000, save)
    draft = save / "plan.draft.json"
    draft.write_text("{}")
    files.write_json_atomic(draft.with_name("plan.draft.json.snap"), {"id": "c1a1aaaa", "tick": 1000})
    assert plan.draft_pin(draft, save) is None, "two years older than the newest"
    files.write_json_atomic(draft.with_name("plan.draft.json.snap"), {"id": "c1a1gone", "tick": 1000})
    assert plan.draft_pin(draft, save) is None, "pruned"
    cmd.pin_snapshot(save, "c1a1gone")
    try:
        assert cmd.sites_snapshot(save)["id"] == "c1a1bbbb", "a pin on a missing file falls back to the newest"
    finally:
        cmd.pin_snapshot(save, None)
