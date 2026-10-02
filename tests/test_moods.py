"""Spec 03 mood manager: demand (real mood.log lines), NONE decoding, CutGems release, wood 0,
timeout vs. walking time, aftercare, reserves, report <= 6 lines.
Note: `pilot_mood need` responses are synthetic, built from the demand lists in mood.log (fixture gap)."""
import json
import random

import pytest

from conftest import FIX
from df_llm_helper.caravan import boost_wants
from df_llm_helper.client import MockClient
from df_llm_helper.clock import FakeClock
from df_llm_helper.moods import (DEFAULTS, FLAG_HINTS, MoodManager, analyse, case_from_need, decode_none,
                           parse_mood_log_line, reserve_gaps)
from df_llm_helper.store import Store
from df_llm_helper.toolsfs import ToolsDir

LIVE = FIX.parent / "run5_live"


def el(t, q=1, free=0, bound=0, nearest=10, flags=()):
    return {"item_type": t, "quantity": q, "free": free, "bound": bound, "nearest": nearest, "flags1": list(flags)}


def need(uid, elements, timeout=49949, mood="Secretive"):
    return json.dumps({"ok": True, "id": uid, "mood": mood, "timeout": timeout, "elements": elements})


def status(*moods, vorrat=None):
    return json.dumps({"stimmungen": [dict(m) for m in moods], "vorrat": vorrat or {}})


def mgr(tmp_path, responses, cfg=None, store=None):
    clock = FakeClock(10_000)
    m = MockClient(responses, clock=clock)
    tools = ToolsDir(tmp_path, clock)
    return MoodManager(m, tools, store or Store(), clock, {**DEFAULTS, **(cfg or {})}), m, tools


def test_mood_log_lines_parse():
    cases = [parse_mood_log_line(ln) for ln in (LIVE / "mood_log_sample.txt").read_text(encoding="utf-8").splitlines()]
    by = {c.id: c for c in cases}
    assert by[3476].skill == "CARPENTRY" and by[3476].timeout == 49949
    assert [(e.item_type, e.quantity) for e in by[3476].elements][:3] == [("WOOD", 2), ("SMALLGEM", 1), ("NONE", 1)]
    assert [(e.item_type, e.quantity) for e in by[4303].elements][0] == ("ROUGH", 3)
    assert parse_mood_log_line("broken") is None


def test_rough_gems_bound_in_cutgems_released(tmp_path):
    """Acceptance 1: rough gems 6, 4 of them in CutGems jobs, demand 3 -> release jobs, then 3 free."""
    world = {"free": 2, "bound": 4}

    def need_resp(_):
        return need(4303, [el("ROUGH", 3, world["free"], world["bound"]), el("WOOD", 1, 5)])

    def release(_):
        world["free"], world["bound"] = world["free"] + world["bound"], 0
        return json.dumps({"ok": True, "found": 2, "removed": 2, "dry": False})

    mm, m, _ = mgr(tmp_path, {"claude/mood status": status({"id": 4303, "mood": "Secretive", "skill": "CUTGEM"})})
    m.set("claude/pilot_mood need 4303", need_resp)
    m.set("claude/pilot_mood release-cutgems --apply", release)
    out = mm.check()
    assert "claude/pilot_mood release-cutgems --apply" in m.write_calls
    assert any("CutGems jobs removed" in ln for ln in out)
    res = analyse(case_from_need(json.loads(need_resp(None))), DEFAULTS)
    assert world["free"] >= 3 and res["gaps"] == []
    assert mm.store.count_actions("mood", "release-cutgems", 0) == 1


def test_release_not_if_bound_too_small_and_loop_guard(tmp_path):
    mm, m, _ = mgr(tmp_path, {"claude/mood status": status({"id": 1, "mood": "Fey"}),
                              "claude/pilot_mood need 1": need(1, [el("ROUGH", 3, 0, 1)]),
                              "claude/pilot_mood release-cutgems --apply": '{"ok": true}'})
    mm.check()
    assert "claude/pilot_mood release-cutgems --apply" not in m.write_calls
    mm2, m2, _ = mgr(tmp_path, {"claude/mood status": status({"id": 1, "mood": "Fey"}),
                                "claude/pilot_mood need 1": need(1, [el("ROUGH", 3, 0, 5)]),
                                "claude/pilot_mood release-cutgems --apply": '{"ok": true}'})
    for _ in range(5):
        out = mm2.check()
    assert m2.write_calls.count("claude/pilot_mood release-cutgems --apply") == 2
    assert any("loop guard" in ln for ln in out)


def test_wood_zero_boosts_trade_and_no_charcoal(tmp_path):
    """Acceptance 2: wood 0 (Staekud 4197) -> message, shopping list with wood first, no charcoal start."""
    mm, m, _ = mgr(tmp_path, {"claude/mood status": status({"id": 4197, "mood": "Fey", "skill": "CARPENTRY"}),
                              "claude/pilot_mood need 4197": need(4197, [el("WOOD", 1, 0, 0, None),
                                                                         el("NONE", 1, flags=["bone"])])})
    out = mm.check()
    assert any("Wood missing" in ln and "NO charcoal" in ln for ln in out)
    assert mm.store.get("trade.boost") == ["wood"] and mm.store.get("mood.block_charcoal") is True
    assert not any("charcoal" in c.lower() or "holzkohle" in c.lower() for c in m.write_calls)
    wants = [{"category": "fuel", "must": True}, {"category": "cloth"}, {"category": "wood", "must": False}]
    b = boost_wants(wants, mm.store.get("trade.boost"))
    assert b[0] == {"category": "wood", "must": True} and len(b) == 3
    assert boost_wants(wants, None) is wants


@pytest.mark.parametrize("seed", range(60))
def test_property_none_never_silently_ignored(seed):
    """Acceptance 3: every NONE element is decoded or reported as 'unknown'."""
    rng = random.Random(seed)
    pool = list(FLAG_HINTS) + ["foo_bar", "unrotten", "improvable", "allow_buryable"]
    elements = []
    for _ in range(rng.randint(1, 6)):
        if rng.random() < 0.5:
            elements.append(el("NONE", rng.randint(1, 3), flags=rng.sample(pool, rng.randint(0, 3))))
        else:
            elements.append(el(rng.choice(["WOOD", "ROUGH", "BAR", "SMALLGEM"]), rng.randint(1, 3), rng.randint(0, 4)))
    res = analyse(case_from_need(json.loads(need(1, elements))), DEFAULTS)
    nones = [e for e in elements if e["item_type"] == "NONE"]
    assert len(res["notes"]) == len(nones)
    for e in nones:
        d = decode_none(e["flags1"])
        assert d and (any(FLAG_HINTS[f] in d for f in e["flags1"] if f in FLAG_HINTS) or d.startswith("unknown"))
        if d.startswith("unknown"):
            assert any(d in g for g in res["gaps"])


def test_timeout_shorter_than_walk_warns(tmp_path):
    """Acceptance 4: timeout < walking time -> 'will fail'."""
    mm, m, _ = mgr(tmp_path, {"claude/mood status": status({"id": 7, "mood": "Possessed"}),
                              "claude/pilot_mood need 7": need(7, [el("BOULDER", 1, 50, 0, 150)], timeout=2000)})
    out = mm.check()
    assert any("will fail" in ln for ln in out)
    assert any(w["key"] == "mood:fail:7" and w["level"] == "crit" for w in mm.store.take_warnings())
    mm2, _, _ = mgr(tmp_path, {"claude/mood status": status({"id": 8, "mood": "Possessed"}),
                               "claude/pilot_mood need 8": need(8, [el("BOULDER", 1, 50, 0, 20)], timeout=49000)})
    assert not any("fail" in ln for ln in mm2.check())


def test_wood_held_by_the_mood_job_is_not_missing(tmp_path):
    """Live false positive: the mood already picked up its wood (item attached to the job, in_job, so never 'free')
    -> must not report 'wood missing', must not boost trade or block charcoal."""
    held = el("WOOD", 2, 0, 0, 5)
    held["held"] = 2
    mm, m, _ = mgr(tmp_path, {"claude/mood status": status({"id": 4197, "mood": "Fey", "skill": "CARPENTRY"}),
                              "claude/pilot_mood need 4197": need(4197, [held])})
    out = mm.check()
    assert out == ["Mood 4197 (Secretive), 49949 ticks: material ok"], out
    assert not mm.store.get("trade.boost") and not mm.store.get("mood.block_charcoal")
    # partly held: only the part that is still missing is reported
    part = el("WOOD", 3, 0, 0, 5)
    part["held"] = 1
    res = analyse(case_from_need(json.loads(need(1, [part]))), DEFAULTS)
    assert res["gaps"] == ["wood missing 2 (need 3, free 0, held by the mood 1, bound 0)"] and res["wood_missing"]
    # nothing held (older pilot_mood without the field): behaviour unchanged
    res = analyse(case_from_need(json.loads(need(1, [el("WOOD", 1, 0)]))), DEFAULTS)
    assert res["gaps"] == ["wood missing 1 (need 1, free 0, bound 0)"]


def test_duplicate_elements_summed():
    c = case_from_need(json.loads(need(1, [el("ROUGH", 1, 1), el("ROUGH", 1, 1), el("CLOTH", 20000, 1)])))
    res = analyse(c, DEFAULTS)
    assert res["gaps"] == ["rough gems missing 1 (need 2, free 1, bound 0)"]


def test_report_max_6_lines_many_moods(tmp_path):
    """Acceptance 5: report <= 6 lines, even with many moods."""
    ms = [{"id": i, "mood": "Fey"} for i in range(1, 6)]
    resp = {"claude/mood status": status(*ms)}
    for i in range(1, 6):
        resp[f"claude/pilot_mood need {i}"] = need(i, [el("WOOD", 2, 0), el("NONE", 1, flags=["xyz"])], timeout=100)
    mm, _, _ = mgr(tmp_path, resp)
    assert len(mm.check()) <= 6
    assert len(mm.check(dry=True)) <= 6


def test_aftercare_flag_deleted_and_failure_bumps_reserve(tmp_path):
    st = Store()
    mm, m, tools = mgr(tmp_path, {"claude/mood status": status({"id": 5, "mood": "Fey", "skill": "CARPENTRY"}),
                                  "claude/pilot_mood need 5": need(5, [el("WOOD", 1, 0)])}, store=st)
    tools.write_flag("mood", "Mood 5")
    mm.check()
    assert st.get("trade.boost") == ["wood"]
    m.set("claude/mood status", status({"id": 5, "mood": "Berserk", "skill": "CARPENTRY", "insane": True}))
    out = mm.check()
    assert any("FAILED" in ln for ln in out) and st.get("mood.reserve_extra") == {"wood": 2}
    assert len([ln for ln in mm.check() if "FAILED" in ln]) == 0           # report only once
    m.set("claude/mood status", status())
    out = mm.check()
    assert not tools.flag("mood").exists and any("mood.flag deleted" in ln for ln in out)
    assert st.get("trade.boost") == [] and st.get("mood.block_charcoal") is False


def test_unreadable_need_reported(tmp_path):
    mm, _, _ = mgr(tmp_path, {"claude/mood status": status({"id": 9, "mood": "Fey"})})
    assert any("not readable" in ln for ln in mm.check())


def test_reserve_gaps_real_status_and_threshold(tmp_path):
    vorrat = json.loads((FIX / "mood_status.txt").read_text(encoding="utf-8"))["vorrat"]
    g = reserve_gaps(vorrat, 23, DEFAULTS)
    assert "wood 0/10" in g and "rough gems 0/4" in g and not any(x.startswith("cut gems") for x in g)
    assert reserve_gaps(vorrat, 19, DEFAULTS) == []
    assert "wood 0/12" in reserve_gaps(vorrat, 23, DEFAULTS, {"wood": 2})
    mm, _, _ = mgr(tmp_path, {"claude/mood status": (FIX / "mood_status.txt").read_text(encoding="utf-8"),
                              "claude/status": (FIX / "status.txt").read_text(encoding="utf-8")})
    out = mm.reserve()
    assert out[0].startswith("Mood reserve missing") and "wood 0/10" in out[0]


def test_cli_mood(tmp_path, tools_dir, capsys):
    from df_llm_helper.cli import main
    c = tmp_path / "c.yaml"
    c.write_text(f"paths:\n  tools: {tools_dir}\n  scopes: {tools_dir / 'scopes'}\n  state_db: {tmp_path / 's.db'}\n"
                 f"  gamelog: {tmp_path / 'g'}\n", encoding="utf-8")
    assert main(["--config", str(c), "--mock", str(FIX), "mood", "--dry-run"]) == 0
    assert "no running mood" in capsys.readouterr().out
    assert main(["--config", str(c), "--mock", str(FIX), "mood", "reserve"]) == 0
    assert "Mood reserve missing" in capsys.readouterr().out
