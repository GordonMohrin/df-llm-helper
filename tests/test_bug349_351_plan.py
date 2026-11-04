"""Run 15 year plans that could not move on.
BUG-349 (Guildcleans y388-y390, i2): `plan check` refused P3 -> P5 'while the perimeter is open 468 d' with seal@S1 first in
seasons[0]; the seal (hatch 77,100,123, wall 130,93,130 'no item') stood stuck 4500 / 2300 d and B2's lever was lost, so the
fort stayed at P3 every year; propose drafted the raise its own check refused. The seal_stalled question did not say the
offered bp.cancel is safe (the player did not dare to send #7282/#7283).
BUG-350 (Inkintense y381, i1): an older save was loaded at y378 (TIMELINE_RESET); the y378 explore shafts lived only in the
discarded timeline, their bp files stayed and blocked every explore site ('taken by y378s0b1, y378s1b0, ...').
BUG-351 (Drillchamber y381/y384, i4): propose drafted the stone dig bedrooms@S1 n=4 and its own check refused it ('only 0
free site(s) for bedrooms n=4 (0 ranked)'), an ERROR without a build to insert."""
import copy
import json

import pytest
from cli_v2_helpers import FIX, make_runtime, reset_paths

from dfpilot import cmd, files, plan, schema, wake


@pytest.fixture
def save(tmp_path, monkeypatch):
    monkeypatch.setenv("DFLLM_CONFIG", str(tmp_path / "config"))
    d = make_runtime(tmp_path)
    yield d
    reset_paths()


def _write_state(save, st):
    base = json.loads((save / "state.a.json").read_text("utf-8"))      # the fixture's other slot: b stays the newer one
    st = dict(st, seq=base["seq"] + 10)
    assert schema.validate("state", st) == [], schema.validate("state", st)
    (save / "state.b.json").write_text(files.dumps(st), encoding="utf-8")
    return st


def _open(save, pd, pw="1 way in", phase="P3", **extra):
    st = json.loads((save / "state.a.json").read_text("utf-8"))      # fresh each time (no sched/proj of a call before)
    st["phase"] = phase
    st["ready"] = {"lvl": 0, "worn": 0, "cv": 3, "drill_age": -1, "audit": {"ok": 1, "age": 9000, "min_traps": 35},
                   "fail": ["open_perimeter"], "open": 1, "pd": pd, "pw": pw}
    st.update(extra)
    return _write_state(save, st)


def _raise(save, to="P5"):
    prev = json.loads((save / "plan.json").read_text("utf-8"))
    doc = copy.deepcopy(prev)
    doc["phase_target"] = to
    return prev, doc


def _perim(errs, warn):
    return [e for e in errs if e.startswith("perimeter")], [w for w in warn if w.startswith("perimeter")]


STUCK = {"seal": {"proj": "y374s1b0", "n": 1, "paused": 0, "stuck": 1, "days": 4500, "more": 1}}


# ---------------------------------------------------------------- BUG-349
def test_bug349_a_seal_stuck_for_a_year_waives_the_raise(save):
    """i2 y388: open 468 d, the seal stuck 4500 d: the raise P3 -> P5 is a warning (old: the ERROR, P3 for ever)."""
    st = _open(save, 468, sched=STUCK)
    prev, doc = _raise(save)
    e, w = _perim(*plan.check(doc, st, decisions={}, banned=plan.BANNED, prev=prev))
    assert e == []
    assert len(w) == 1 and "while seal y374s1b0 stuck 4500 d: raising phase_target P3 -> P5 is waived (BUG-349" in w[0], w


def test_bug349_short_open_or_no_seal_effort_still_refuses(save):
    st = _open(save, 50, sched=STUCK)                                 # i1 y378: 50 d open: seal first
    prev, doc = _raise(save)
    e, _ = _perim(*plan.check(doc, st, decisions={}, banned=plan.BANNED, prev=prev))
    assert len(e) == 1 and e[0].startswith("perimeter: raising phase_target P3 -> P5 while the perimeter is open for 50 "
                                           "days"), e
    assert e[0].endswith("; after 365 d open (in 315 d) with a seal stuck, set aside or first in this plan's due season "
                         "the raise is waived (BUG-349)"), e[0]
    st = _open(save, 468)                                             # a year open, but no seal tried at all
    e, _ = _perim(*plan.check(doc, st, decisions={}, banned=plan.BANNED, prev=prev))
    assert len(e) == 1 and "after 365 d open with a seal stuck" in e[0], e
    st = _open(save, 468, sched=dict(STUCK, seal=dict(STUCK["seal"], days=40)))   # its seal is stuck a short time only
    assert _perim(*plan.check(doc, st, decisions={}, banned=plan.BANNED, prev=prev))[0]


def test_bug349_a_seal_set_aside_or_planned_now_or_only_levers_lost(save):
    prev, doc = _raise(save)
    st = _open(save, 468, proj=[["c1a1a485b71c19f201", "seal.build", 0, "set aside 192 d: stalled (bp.resume)"]])
    e, w = _perim(*plan.check(doc, st, decisions={}, banned=plan.BANNED, prev=prev))
    assert e == [] and "while seal c1a1a485b71c19f201 set aside 192 d:" in w[0], w
    st = _open(save, 468)
    sealed = copy.deepcopy(doc)
    sealed["seasons"][st["t"]["season"]]["build"].append({"tpl": "seal", "site": "S1", "p": {"at": "last"}})
    e, w = _perim(*plan.check(sealed, st, decisions={}, banned=plan.BANNED, prev=prev))
    assert e == [] and "while seal@S1 in this plan:" in w[0], w
    late = copy.deepcopy(doc)                                         # a seal in a later season is not "now"
    late["seasons"][3]["build"].append({"tpl": "seal", "site": "S1", "p": {"at": "last"}})
    assert _perim(*plan.check(late, st, decisions={}, banned=plan.BANNED, prev=prev))[0]
    st = _open(save, 1168, pw="levers lost: B2")                      # i2 y390: nothing a seal can close
    e, w = _perim(*plan.check(doc, st, decisions={}, banned=plan.BANNED, prev=prev))
    assert e == [] and "while nothing a seal closes (levers lost: B2):" in w[0], w


def test_bug349_propose_keeps_the_phase_its_check_refuses(save):
    prev = json.loads((save / "plan.json").read_text("utf-8"))
    phases = json.loads((FIX / "phases.json").read_text("utf-8"))
    st = _open(save, 50)
    doc = plan.propose(st, phases, prev, decisions={}, tinfo={t: {"params": {}, "about": ""} for t in ("seal", "explore")})
    assert doc["phase_target"] == "P3", doc["phase_target"]           # old: P5, refused by its own check
    assert "FR-70: phase_target stays P3 (not P5): the perimeter is open 50 d (1 way in): seal first; waived after 365 d " \
           "with the seal stuck (BUG-349)" in doc["notes"], doc["notes"]
    assert schema.validate("plan", doc) == []
    st = _open(save, 468, sched=STUCK)                                # waived: the raise stays in the draft
    doc = plan.propose(st, phases, prev, decisions={}, tinfo={t: {"params": {}, "about": ""} for t in ("seal", "explore")})
    assert doc["phase_target"] == "P5"


def test_bug349_seal_stalled_hint_says_the_cancel_is_safe():
    d = {"id": "seal_stalled", "proj": "y374s1b0", "mat": "hatch 77,100,123", "n": 5508, "how": "recommended and safe",
         "cmd": "dfllm cmd bp.cancel '{\"proj\":\"y374s1b0\"}' then dfllm cmd bp.place "
                "'{\"tpl\":\"seal\",\"site\":\"S1\",\"p\":{\"at\":\"refuge\"}}'"}
    h = wake.next_hint("DECISION_NEEDED", {"d": d})
    assert "; fix (safe: the bp.cancel drops only unbuilt pieces): dfllm cmd bp.cancel" in h, h
    assert h.endswith("until it stands that way in is open (max-pop held; the phase may rise past it after 365 d, "
                      "BUG-349)"), h


# ---------------------------------------------------------------- BUG-350
def _ev(n, typ, tick, d):
    return {"n": n, "tick": tick, "type": typ, "cls": schema.EVENTS[typ][0], "msg": typ, "d": d}


def _timeline(sv):
    evs = [_ev(1, "PROJECT_DONE", 100, {"proj": "old", "tpl": "explore"}),          # done before the save point
           _ev(2, "PROJECT_DONE", 500, {"proj": "lost", "tpl": "explore"}),         # only in the discarded timeline
           _ev(3, "PROJECT_DONE", 520, {"proj": "both", "tpl": "explore"}),
           _ev(4, "TIMELINE_RESET", 300, {"kind": "clock", "n_alt": 3, "tick_alt": 520, "tick_neu": 300}),
           _ev(5, "PROJECT_DONE", 400, {"proj": "both", "tpl": "explore"})]         # done again in the live one
    (sv / "events.jsonl").write_text("".join(files.dumps(e) + "\n" for e in evs), encoding="utf-8")
    (sv / "events.1.jsonl").write_text("", encoding="utf-8")


def test_bug350_projects_of_a_discarded_timeline(save):
    _timeline(save)
    assert files.discarded_projects(save) == {"lost"}
    assert plan.done_projects(save) >= {"old", "both"} and "lost" not in plan.done_projects(save)


def test_bug350_their_bp_files_block_no_site(save):
    """i1 y381: the y378 explores' bp files held every explore site; the kernel never had them in the game that runs."""
    site = {"id": "S1", "anchor": [45, 56, 25], "rot": 1, "score": 900, "why": "x"}
    held = cmd.emit_at("explore", {}, site, "S1", "lost")
    files.write_json_atomic(save / "bp" / "lost.json", held)
    _timeline(save)
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    _write_state(save, dict(st, proj=[["fortcore", "s2.build", 64, ""]]))
    assert cmd.stale_bps(save) == {"lost"}
    assert plan.explore_room(save, [site], {}) == 1                   # old: 0 ('taken by lost')
    # the kernel lists it after all (a live project): it holds its site
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    _write_state(save, dict(st, proj=[["fortcore", "s2.build", 64, ""], ["lost", "dig", 0, ""]]))
    assert cmd.stale_bps(save) == set() and plan.explore_room(save, [site], {}) == 0
    # a full list (8 rows, the state's cap) may leave a live one out: nothing is ignored then
    st = json.loads((save / "state.b.json").read_text("utf-8"))
    _write_state(save, dict(st, proj=[[f"p{i}", "dig", 0, ""] for i in range(8)]))
    assert cmd.stale_bps(save) == set() and plan.explore_room(save, [site], {}) == 0


def test_bug350_one_timeline_ignores_nothing(save):
    (save / "events.jsonl").write_text(files.dumps(_ev(1, "PROJECT_DONE", 500, {"proj": "x", "tpl": "explore"})) + "\n",
                                       encoding="utf-8")
    assert files.discarded_projects(save) == set() and cmd.stale_bps(save) == set()


# ---------------------------------------------------------------- BUG-351
def test_bug351_stone_dig_without_a_free_site_is_left_out(save, monkeypatch):
    prev = json.loads((save / "plan.json").read_text("utf-8"))
    doc = copy.deepcopy(prev)
    doc["year"] = prev["year"] + 1
    doc["seasons"] = [{"build": [copy.deepcopy(plan.STONE_DIG), {"tpl": "farms", "site": "S1"}]},
                      {"build": []}, {"build": []}, {"build": []}]
    doc["notes"] = "draft; rock: 8 free boulders < 22 wanted (rock orders, walls): bedrooms@S1 n=4 first (a stone dig)"

    def none(*a, **k):
        raise cmd.BpError("no ranked site for bedrooms")
    monkeypatch.setattr(plan, "rank_sites", none)
    line = plan.fit_stone_dig(save, doc, prev)
    assert [b["tpl"] for b in doc["seasons"][0]["build"]] == ["farms"]          # old: bedrooms n=4 -> check ERROR
    assert line.startswith("stone dig bedrooms@S1 n=4 left out: 0 free site(s) (0 ranked; no ranked site for bedrooms); "
                           "stone: a stockroom or explore dig, trade.want stone"), line
    assert "bedrooms@S1 n=4 first" not in doc["notes"] and "no bedrooms site for a stone dig" in doc["notes"]
    assert "; BUG-351: stone dig bedrooms@S1 n=4 left out" in doc["notes"]
    assert schema.validate("plan", doc) == []
    # a free site: the stone dig stays
    doc["seasons"][0]["build"].insert(0, copy.deepcopy(plan.STONE_DIG))
    monkeypatch.setattr(plan, "rank_sites", lambda *a, **k: ([{"id": "S1", "anchor": [45, 56, 25], "rot": 0}], "s1"))
    monkeypatch.setattr(plan, "explore_room", lambda *a, **k: 1)
    assert plan.fit_stone_dig(save, doc, prev) is None
    assert doc["seasons"][0]["build"][0] == plan.STONE_DIG
