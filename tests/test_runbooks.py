"""F3 runbooks: schema validator, positive/negative test per runbook, exact dry-run commands, player approval, live run."""
import pytest

from df_llm_helper import yamlmini
from df_llm_helper.client import MockClient
from df_llm_helper.clock import FakeClock
from df_llm_helper.fairplay import ExceptionRegistry
from df_llm_helper.runbooks import (LEGACY_APPROVAL_KEY, RunbookError, diagnose, load_runbooks, plan_commands, run_runbook,
                              validate_runbook)
from helpers import ROOT, ctx_for

RBS = load_runbooks(ROOT / "data" / "runbooks")
BY_ID = {r.id: r for r in RBS}

GE = "EverybodyDoesThis"
# runbook -> (positive context, negative context)
CASES = {
    "rb01_e18_pick": (dict(dig_jobs=120, diggers=1, squad_picks=1, idle=9), dict(dig_jobs=10)),
    "rb01b_e18_foreign": (dict(dig_jobs=40, diggers=1, squad_picks=0, pop=7), dict(dig_jobs=40, diggers=3, squad_picks=2)),
    "rb02_grabstau": (dict(dig_jobs=80, workdetail_modes={"Stonecutters": GE}), dict(dig_jobs=80)),
    "rb03_kochschleife": (dict(cancels=[("Prepare easy meal", "Needs unrotten cookable solid item", 300, 9)]),
                          dict(cancels=[("Prepare easy meal", "Needs unrotten cookable solid item", 5, 2)])),
    "rb04_alarm_burrow": (dict(civ_alert=1, idle=15), dict(civ_alert=0, idle=15)),
    "rb05_waechter_blind": (dict(max_report_id=12, files={"last_report_id": 28181, "events_age_min": 90}),
                            dict(max_report_id=5000, files={"last_report_id": 4990})),
    "rb06_karawane": (dict(caravan_state="AtDepot"), dict(caravan_state=None)),
    "rb06b_karawane_abschluss": (dict(caravan_state="AtDepot", flags={"caravan": {}}), dict(caravan_state="AtDepot")),
    "rb07_stimmung": (dict(moods=["Mestthos"], mood_gaps=["holz 0/10"]), dict(moods=[])),
    "rb08_hospital": (dict(), None),   # the fixture has injured dwarves; negative: see below
    "rb09_aquifer": (None, dict()),
    "rb10_timestream": (dict(timestream=True, drink_days=50), dict(timestream=False, drink_days=50)),
    "rb15_hunger_trotz_essen": (dict(meals=140, hunger={414: 52000, 3473: 47000, 1029: 61000},
                                     cancels=[("Eat", "Could not find path", 12, 3)]),
                                dict(meals=140, hunger={414: 52000})),
    "rb16_abbruchschleife": (dict(cancels=[("Make bed", "Needs logs", 314, 21)]),
                             dict(cancels=[("Make bed", "Needs logs", 20, 3)])),
    "rb17_koks_brennstoff": (dict(cancels=[("Make coke from bituminous coal", "Needs refined coal", 7, 5)]), dict()),
    "rb18_manager_buero": (None, dict()),
    "rb19_dienste_starten": (dict(services={"watchdog": False, "arbeit": False, "trinken": False}),
                             dict(services={"watchdog": False})),
    "rb20_fertigwaren_lager": (dict(), None),
    "rb21_flut": (dict(flags={"wasser": {"text": "Wasser im Fort"}}), dict(flags={"alert": {}})),
}


def _ctx(spec):
    files = spec.pop("files", None) if spec else None
    ctx, snap = ctx_for(files=files, **(spec or {}))
    return ctx, snap


def test_at_least_12_runbooks_and_all_have_cases():
    assert len(RBS) >= 12
    assert set(CASES) == set(BY_ID), set(BY_ID) ^ set(CASES)


@pytest.mark.parametrize("rid", sorted(CASES))
def test_positive_and_negative(rid):
    pos, neg = CASES[rid]
    if pos is not None:
        ctx, _ = _ctx(dict(pos))
        if rid == "rb09_aquifer":
            pass
        assert rid in [h.runbook.id for h in diagnose(RBS, ctx)], rid
    if neg is not None:
        ctx, snap = _ctx(dict(neg))
        assert rid not in [h.runbook.id for h in diagnose(RBS, ctx)], rid


def test_special_positive_negative_by_context_edit():
    ctx, snap = _ctx({})
    ctx["injured"] = []
    assert "rb08_hospital" not in [h.runbook.id for h in diagnose(RBS, ctx)]
    ctx["aquifer_z"] = [106, 107]
    ctx["orders_unvalidated"], ctx["orders_total"] = 5, 18
    ids = [h.runbook.id for h in diagnose(RBS, ctx)]
    assert "rb09_aquifer" in ids and "rb18_manager_buero" in ids
    ctx["full_stockpiles"] = []
    assert "rb20_fertigwaren_lager" not in [h.runbook.id for h in diagnose(RBS, ctx)]


def test_confidence_signals_raise_and_sorting():
    ctx, _ = _ctx(dict(dig_jobs=120, diggers=1, squad_picks=1, idle=9))
    hits = diagnose(RBS, ctx)
    e18 = [h for h in hits if h.runbook.id == "rb01_e18_pick"][0]
    assert e18.confidence >= 0.8 and "pick carriers" in " ".join(e18.reasons)
    assert hits == sorted(hits, key=lambda h: (-h.confidence, h.runbook.id))
    assert "--dry-run" in e18.line()


EXPECTED_DRY = {
    "rb01_e18_pick": (dict(squad_id=32), ["claude/mil status", "claude/mil workmode 32 on --apply", "WAIT 90 s",
                                          "claude/mil equip --squad 32",
                                          "VERIFY: pick_holders >= 2 or diggers >= 3 (<= 90 s)"]),
    "rb06_karawane": ({}, ["claude/advance 0", "quicksave", "claude/handel prep --live",
                           "claude/handel broker --live --force-job", "claude/handel plan", "claude/handel mark --live",
                           "claude/handel open --live", "claude/handel open --live", "claude/handel select --dry"]),
    "rb10_timestream": ({}, ["claude/tempo off", "claude/tempo status", "VERIFY: not timestream (<= 30 s)"]),
    "rb19_dienste_starten": ({}, ["claude/watchdog start", "claude/ueberwacher start", "claude/arbeit start",
                                  "claude/trinken start", "claude/essen start", "claude/orders start",
                                  "claude/gesund start", "claude/auslastung start", "claude/mil guard start",
                                  "claude/tempo off"]),
    "rb01b_e18_foreign": (dict(item_ids="187405,187429"),
                          ['lua "for _,id in ipairs({187405,187429}) do df.item.find(id).flags.foreign=false end"']),
}


@pytest.mark.parametrize("rid", sorted(EXPECTED_DRY))
def test_dry_run_exact_commands(rid):
    params, expected = EXPECTED_DRY[rid]
    ctx, _ = _ctx({})
    cmds = [c for c in plan_commands(BY_ID[rid], ctx, params) if not c.startswith("MANUAL")]
    if rid in ("rb06_karawane", "rb19_dienste_starten", "rb01b_e18_foreign"):
        cmds = [c for c in cmds if not c.startswith("VERIFY")]
    assert cmds == expected


def test_every_runbook_dry_run_executes_no_write():
    ctx, _ = _ctx({})
    params = {"squad_id": 32, "item_ids": "1,2", "x": 128, "y": 99, "z": 128}
    for rb in RBS:
        mc = MockClient({})
        res = run_runbook(rb, mc, lambda: dict(ctx), clock=FakeClock(), dry_run=True,
                          params={k: v for k, v in params.items() if k in rb.params},
                          registry=ExceptionRegistry(None))
        assert mc.calls == []
        assert res.status in ("dry", "approval"), (rb.id, res.status)


def test_missing_param_is_clear_error():
    ctx, _ = _ctx({})
    res = run_runbook(BY_ID["rb01_e18_pick"], MockClient({}), lambda: ctx, clock=FakeClock(), dry_run=True)
    assert res.status == "precondition" and "required parameter missing: squad_id" in res.log[0]


def test_player_approval_required(tmp_path):
    rb = BY_ID["rb01b_e18_foreign"]
    ctx, _ = _ctx({})
    mc = MockClient({})
    res = run_runbook(rb, mc, lambda: ctx, clock=FakeClock(), dry_run=False, params={"item_ids": "187405"},
                      registry=ExceptionRegistry(tmp_path / "ex.jsonl"))
    assert res.status == "approval" and mc.calls == []
    res = run_runbook(rb, mc, lambda: ctx, clock=FakeClock(), dry_run=True, params={"item_ids": "187405"}, registry=None)
    assert res.status == "approval"
    reg = ExceptionRegistry(tmp_path / "ex.jsonl")
    reg.add("FP08", "E18", "ja, mach foreign=false", objects=[187405])
    res = run_runbook(rb, mc, lambda: ctx, clock=FakeClock(), dry_run=False, params={"item_ids": "187405"},
                      registry=reg)
    assert res.status == "manual" and mc.calls == []    # manual step first (ask the player)


def test_live_run_verify_polling_and_timeout():
    rb = BY_ID["rb10_timestream"]
    clock = FakeClock(0)
    mc = MockClient({"claude/tempo status": "{}"}, clock=clock)
    state = {"n": 0}

    def ctx_fn():
        state["n"] += 1
        c, _ = ctx_for(timestream=state["n"] < 3)
        return c
    res = run_runbook(rb, mc, ctx_fn, clock=clock, dry_run=False)
    assert res.status == "done" and res.ok and mc.calls == ["claude/tempo off", "claude/tempo status"]
    res = run_runbook(rb, MockClient({"claude/tempo status": "{}"}, clock=clock), lambda: ctx_for(timestream=True)[0],
                      clock=clock, dry_run=False)
    assert res.status == "verify_failed" and "Do not repeat blindly" in res.log[-1]


def test_live_run_precondition_step_fail_and_internal():
    clock = FakeClock(0)
    ctx_danger, _ = ctx_for(enemies=2)
    res = run_runbook(BY_ID["rb06_karawane"], MockClient({}), lambda: ctx_danger, clock=clock, dry_run=False)
    assert res.status == "precondition" and "danger" in res.log[0]
    mc = MockClient({}, fail={"claude/tempo off": 1})
    res = run_runbook(BY_ID["rb10_timestream"], mc, lambda: ctx_for(timestream=True)[0], clock=clock, dry_run=False)
    assert res.status == "step_failed"
    calls = []
    res = run_runbook(BY_ID["rb05_waechter_blind"], MockClient({}), lambda: ctx_for()[0], clock=clock, dry_run=False,
                      internal=lambda a: calls.append(a) or "ok")
    assert calls == ["reset_report_id"] and res.status == "manual"
    ctx, _ = ctx_for()
    res = run_runbook(BY_ID["rb19_dienste_starten"], MockClient({}), lambda: ctx, clock=clock, dry_run=False)
    assert res.status == "done" and len(res.commands) == 10


@pytest.mark.parametrize("bad,msg", [
    ({"title": "t", "symptom": {"when": "True"}, "steps": [{"cmd": "x"}], "verify": {"when": "True"},
      "needs_player_approval": False}, "id"),
    ({"id": "x", "title": "t", "symptom": {"when": "True"}, "steps": [{"cmd": "x"}], "verify": {"when": "True"}},
     "needs_player_approval"),
    ({"id": "x", "title": "t", "symptom": {"when": "True"}, "steps": [], "verify": {"when": "True"},
      "needs_player_approval": False}, "steps"),
    ({"id": "x", "title": "t", "symptom": {"when": "True"}, "steps": [{"cmd": "x"}], "verify": {},
      "needs_player_approval": False}, "verify"),
    ({"id": "x", "title": "t", "symptom": {"confidence": 0.5}, "steps": [{"cmd": "x"}], "verify": {"when": "True"},
      "needs_player_approval": False}, "symptom.when"),
    ({"id": "x", "title": "t", "symptom": {"when": "True", "confidence": 2}, "steps": [{"cmd": "x"}],
      "verify": {"when": "True"}, "needs_player_approval": False}, "confidence"),
    ({"id": "x", "title": "t", "symptom": {"when": "True"}, "steps": [{"cmd": "x", "manual": "y"}],
      "verify": {"when": "True"}, "needs_player_approval": False}, "exactly one"),
    ({"id": "x", "title": "t", "symptom": {"when": "True"}, "steps": [{"action": "sprengen"}],
      "verify": {"when": "True"}, "needs_player_approval": False}, "internal action"),
    ({"id": "x", "title": "t", "symptom": {"when": "True"}, "steps": [{"cmd": "x"}], "verify": {"when": "True"},
      "needs_player_approval": True}, "approval_action"),
    ({"id": "x", "title": "t", "symptom": {"when": "import os"}, "steps": [{"cmd": "x"}], "verify": {"when": "True"},
      "needs_player_approval": False}, "symptom"),
    ({"id": "x", "title": "t", "symptom": {"when": "True"}, "steps": [{"wait_s": "lang"}], "verify": {"when": "True"},
      "needs_player_approval": False}, "wait_s"),
    ({"id": "x", "title": "t", "symptom": {"when": "True"}, "steps": [{"cmd": "x"}], "verify": {"when": "True"},
      "needs_player_approval": False, "extra": 1}, "unknown fields"),
])
def test_schema_validator_rejects(bad, msg):
    with pytest.raises(RunbookError, match=msg):
        validate_runbook(bad, "t.yaml")


def test_duplicate_runbook_ids(tmp_path):
    d = {"id": "x", "title": "t", "symptom": {"when": "True"}, "steps": [{"cmd": "x"}], "verify": {"when": "True"},
         "needs_player_approval": False}
    (tmp_path / "a.yaml").write_text(yamlmini.dumps(d))
    (tmp_path / "b.yaml").write_text(yamlmini.dumps(d))
    with pytest.raises(RunbookError, match="duplicate"):
        load_runbooks(tmp_path)


def test_runbook_commands_respect_fairplay():
    from df_llm_helper.fairplay import check_command, FairPlayError
    ctx, _ = _ctx({})
    for rb in RBS:
        params = {"squad_id": 32, "item_ids": "1,2", "x": 128, "y": 99, "z": 128}
        for c in plan_commands(rb, ctx, {k: v for k, v in params.items() if k in rb.params}):
            if c.startswith(("MANUAL", "WAIT", "CHECK", "HELPER", "VERIFY")):
                continue
            if rb.needs_player_approval:
                with pytest.raises(FairPlayError):
                    check_command(c)
            else:
                check_command(c)


def test_runbook_engine_edge_cases(tmp_path):
    rb = validate_runbook({
        "id": "rbx", "title": "t", "needs_player_approval": False, "kb": [],
        "symptom": {"when": "x > 1", "confidence": 0.5, "explain": "x={x}",
                    "signals": [{"when": "y + 'a'", "add": 0.3}, {"when": "x > 5", "add": 0.3}]},
        "params": {"ziel": {"default": "{x * 10}"}, "fix": 7},
        "preconditions": [{"when": "x < 100", "msg": "zu gross"}],
        "steps": [{"cmd": "claude/status"}, {"wait_s": 5}, {"check": "x > 1", "msg": "x klein"},
                  {"cmd": "claude/tempo off", "allow_fail": True}, {"action": "heartbeat"},
                  {"cmd": "claude/dig 130 {ziel} 1 2 2 d"}],
        "verify": {"when": "x > 1", "timeout_s": 10, "poll_s": 5}}, "t.yaml")
    hits = diagnose([rb], {"x": 6, "y": 1})
    assert hits[0].confidence == 0.8 and hits[0].reasons == ["x=6"]   # broken signal ignored
    assert diagnose([rb], {"x": "a"}) == []                             # type error -> no hit
    cmds = plan_commands(rb, {"x": 6})
    assert cmds[:5] == ["claude/status", "WAIT 5 s", "CHECK: x > 1", "claude/tempo off", "HELPER: heartbeat"]
    assert cmds[5] == "claude/dig 130 60 1 2 2 d"
    clock = FakeClock(0)
    mc = MockClient({"claude/status": "{}"}, clock=clock, fail={"claude/tempo off": 1})
    res = run_runbook(rb, mc, lambda: {"x": 6}, clock=clock, dry_run=False)
    assert res.status == "done" and clock.now().epoch == 5 and "(internal action heartbeat skipped)" in res.log
    res = run_runbook(rb, mc, lambda: {"x": 200}, clock=clock, dry_run=False)
    assert res.status == "precondition" and "zu gross" in res.log[0]
    n = {"i": 0}

    def shrinking():
        n["i"] += 1
        return {"x": 6 if n["i"] == 1 else 0}
    res = run_runbook(rb, MockClient({"claude/status": "{}"}), shrinking, clock=clock, dry_run=False)
    assert res.status == "step_failed" and "x klein" in res.log[-1]
    rb2 = validate_runbook({"id": "rby", "title": "t", "needs_player_approval": False,
                            "symptom": {"when": "True"}, "steps": [{"cmd": "createitem {x}"}],
                            "verify": {"when": "True"}}, "t.yaml")
    res = run_runbook(rb2, MockClient({}), lambda: {"x": 1}, clock=clock, dry_run=False)
    assert res.status == "step_failed" and "FP01" in res.log[0]


@pytest.mark.parametrize("bad,msg", [
    ({"steps": [{"cmd": "{a.__b}"}]}, "placeholder"),
    ({"steps": "x"}, "non-empty list"),
    ({"steps": ["x"]}, "mapping"),
    ({"steps": [{"check": "a.__b"}]}, "privat"),
    ({"preconditions": [{"msg": "x"}]}, "when"),
    ({"preconditions": [{"when": "a.__b"}]}, "precondition"),
    ({"verify": {"when": "a.__b"}}, "verify"),
    ({"params": [1]}, "params"),
    ({"rollback": [{"bogus": 1}]}, "exactly one"),
    ({"symptom": "x"}, "symptom.when"),
])
def test_schema_validator_more(bad, msg):
    base = {"id": "x", "title": "t", "symptom": {"when": "True"}, "steps": [{"cmd": "x"}],
            "verify": {"when": "True"}, "needs_player_approval": False}
    base.update(bad)
    with pytest.raises(RunbookError, match=msg):
        validate_runbook(base, "t.yaml")
    with pytest.raises(RunbookError, match="mapping"):
        validate_runbook([1], "t.yaml")


def test_legacy_approval_key_is_accepted_as_alias():
    d = {"id": "rbz", "title": "t", "symptom": {"when": "True"}, "steps": [{"manual": "x"}],
         "verify": {"when": "True"}, LEGACY_APPROVAL_KEY: True, "approval_action": "FP08"}
    rb = validate_runbook(d)
    assert rb.needs_player_approval is True
    d2 = dict(d)
    d2.pop(LEGACY_APPROVAL_KEY)
    d2["needs_player_approval"] = False
    assert validate_runbook(d2).needs_player_approval is False
