"""NEU7 (docs/v2/NEU7-vorrat.md, BUG-854..859): the standing container reserve (Lua side: tests/lua/test_bug854_reserve.lua), the wood truth
(tests/lua/test_bug855_wood.lua), here: the status texts, the config, the ladder that stops repeating refused commands, the popup wake of `wait` and
the trade.want add / remove changes that survive the plan draft."""
import json
import time

import pytest
from test_neu1_wertung_leiter import cfg_dir, ev, run_dir, state  # noqa: F401  (fixtures and helpers of the ladder tests)

from dfpilot import alarm, brief, fairplay, files, leiter, plan, session
from dfpilot.events import DAY, YEAR

Y = 400


class FakeCtx:
    def __init__(self, s, full=True):
        self.s, self.full = s, full


def text(st):
    return " ".join(t for _, t in brief.supply_items(FakeCtx({"stock": st})))


# ---------------------------------------------------------------- BUG-855 / BUG-856: the status texts
def test_status_names_built_in_logs_apart():
    txt = text({"drink_d": 50, "food_d": 50, "wood": 0, "woodt": 25, "woodb": 336})
    assert "wood 0 (25 loose unusable; 336 built in)" in txt, txt
    assert "usable of" not in txt
    only_built = text({"drink_d": 50, "food_d": 50, "wood": 0, "woodt": 0, "woodb": 14})
    assert "wood 0 (14 built in)" in only_built, only_built
    old = text({"drink_d": 50, "food_d": 50, "wood": 0, "woodt": 204})
    assert "wood 0 usable of 204" in old, "without built-in logs the NEU4 wording stays"


def test_drink_line_names_the_units_it_does_not_count():
    items = brief.supply_items(FakeCtx({"stock": {"drink_d": 0, "food_d": 50, "dfar": 74, "dall": 32}}))
    line = [t for _, t in items if t.startswith("drink 0d counts only usable units")]
    assert line and "74 out of reach" in line[0] and "would be 32 d" in line[0], items
    assert not [t for _, t in brief.supply_items(FakeCtx({"stock": {"drink_d": 0, "food_d": 50}})) if "counts only usable" in t]


# ---------------------------------------------------------------- the config
def test_config_creserve_and_wguard_are_checked(tmp_path):
    base = json.loads(open(fairplay.BASELINE_PATH, encoding="utf-8").read())
    assert base["economy"]["creserve"]["min_batch"] == 10 and base["economy"]["wguard"]["low"] == 40
    assert fairplay.economy_errors() == []
    base["economy"]["creserve"]["total_cap"] = 0
    base["economy"]["creserve"]["bogus"] = 1
    base["economy"]["wguard"]["low"] = "x"
    p = tmp_path / "b.json"
    p.write_text(json.dumps(base), encoding="utf-8")
    errs = fairplay.economy_errors(p)
    assert any("creserve.total_cap" in x for x in errs) and any("creserve.bogus" in x for x in errs) and any("wguard.low" in x for x in errs), errs


# ---------------------------------------------------------------- BUG-857: the ladder does not repeat a refused command
def _cli(save, wall, what, args, result):
    with open(save / "cli.log", "a", encoding="utf-8", newline="\n") as f:
        f.write("\t".join([str(int(wall)), "cli", what, json.dumps(args), result]) + "\n")


def _refuse(save, verb, args, reason, ago=60, cid="c1"):
    now = time.time() - ago
    _cli(save, now, f"verb:{verb}", args, f"sent {cid}")
    _cli(save, now + 1, f"reply:{verb}", {"id": cid}, "ERR " + reason)


def test_refused_tombs_repair_is_blocked_with_the_reason_and_the_ladder_moves_on(tmp_path, cfg_dir):  # noqa: F811
    d = run_dir(tmp_path)
    s = state(care={"ghosts": 2, "corpses_old": 3, "tombs_free": 2}, pop={"cit": 40}, ready={"lvl": 1, "open": 0, "fail": []})
    lz = leiter.compute(d, s)
    assert lz["tracks"]["wohl"]["cmd"] == "dfllm cmd tombs.repair" and not lz["tracks"]["wohl"]["blocked"]
    _refuse(d, "tombs.repair", {}, "tombs.repair: not repairable: memorial slab")
    lz = leiter.compute(d, s)
    b = lz["tracks"]["wohl"]["blocked"]
    assert "tombs.repair abgelehnt" in b and "not repairable: memorial slab" in b, b
    out = "\n".join(leiter.lines(lz))
    assert "NAECHST Wohl" not in out and "BLOCKIERT Wohl I" in out and "-> FR" in out, out
    # a later ok reply of the same command clears it
    now = time.time()
    _cli(d, now, "verb:tombs.repair", {}, "sent c2")
    _cli(d, now + 1, "reply:tombs.repair", {"id": "c2"}, "ok queued: the next care run repairs the tombs")
    assert not leiter.compute(d, s)["tracks"]["wohl"]["blocked"]


def test_refused_seal_is_matched_by_template_and_only_inside_the_window(tmp_path, cfg_dir):  # noqa: F811
    d = run_dir(tmp_path)
    s = state(ready={"lvl": 0, "open": 2, "fail": ["open_perimeter"]}, mode="PEACE")
    _refuse(d, "bp.place", {"tpl": "workshops", "site": "S1"}, "refused: workshops: no site")           # another template: no evidence
    assert "abgelehnt" not in leiter.compute(d, s)["tracks"]["wehr"]["blocked"]
    _refuse(d, "bp.place", {"tpl": "seal", "site": "S1", "p": {"at": "last"}}, "refused: seal: nothing to close (81,87,142 open route)", cid="c3")
    b = leiter.compute(d, s)["tracks"]["wehr"]["blocked"]
    assert "bp.place seal abgelehnt" in b and "nothing to close" in b, b
    old = tmp_path / "rt2"
    d2 = run_dir(tmp_path, "r16x4-fort-site2")
    _refuse(d2, "bp.place", {"tpl": "seal", "site": "S1"}, "refused: seal: nothing to close", ago=8 * 3600, cid="c4")
    assert "abgelehnt" not in leiter.compute(d2, s)["tracks"]["wehr"]["blocked"], "older than blocked_hours (6)"
    del old


def test_refuge_drink_no_site_is_blocked(tmp_path, cfg_dir):  # noqa: F811
    d = run_dir(tmp_path)
    s = state(ready={"lvl": 0, "open": 0, "fail": ["refuge_dry"]})
    assert leiter.compute(d, s)["tracks"]["wehr"]["cmd"].endswith("tpl=refuge_drink site=S1")
    _refuse(d, "bp.place", {"tpl": "refuge_drink", "site": "S1"}, "refused: refuge_drink: no site")
    assert "no site" in leiter.compute(d, s)["tracks"]["wehr"]["blocked"]


def test_ladder_orders_containers_not_a_still_when_df_says_so_and_rock_when_no_log(tmp_path, cfg_dir):  # noqa: F811
    d = run_dir(tmp_path)
    s = state(stock={"drink_d": 0, "dwhy": "DF cancels Brew 412x in 7 d: Needs empty food storage item", "wood": 0, "woodt": 25, "woodb": 336})
    cmd = leiter.compute(d, s)["tracks"]["versorgung"]["cmd"]            # no dcx flag: DF's words in dwhy are enough
    assert "MakeBarrel" in cmd and '"mat":"rock"' in cmd and "Still" not in cmd, cmd
    s2 = state(stock={"drink_d": 0, "dcx": 1, "dwhy": "DF cancels Brew 412x in 7 d: Needs empty food storage item", "wood": 80, "woodt": 80})
    assert '"mat":"wood"' in leiter.compute(d, s2)["tracks"]["versorgung"]["cmd"] or '"mat":"wood"' in leiter.compute(d, state(
        stock={"drink_d": 0, "dcx": 1, "dwhy": "x"}))["tracks"]["versorgung"]["cmd"]


# ---------------------------------------------------------------- BUG-859: the popup wake and trade.want add
def test_popup_pause_wakes_wait_after_popup_s(tmp_path, monkeypatch):
    alarm._POPUP_SEEN.clear()
    save = tmp_path / "rt" / "r16x5-fort-site3"
    save.mkdir(parents=True)
    monkeypatch.setattr(files, "read_heartbeat", lambda d, now: ({"paused": True}, 1.0))
    monkeypatch.setattr(files, "read_state", lambda d: {"owners": {"pause": "popup"}})
    monkeypatch.setattr(files, "follow_off", lambda d, now: "")
    cfg = {**session.config()["wait"], "popup_s": 20, "follow_check": False}
    assert [r for r in alarm.sys_reasons(save, cfg, 1000.0) if r["type"] == "POPUP_PAUSE"] == []
    assert [r for r in alarm.sys_reasons(save, cfg, 1010.0) if r["type"] == "POPUP_PAUSE"] == []
    got = [r for r in alarm.sys_reasons(save, cfg, 1021.0) if r["type"] == "POPUP_PAUSE"]
    assert got and "paused by a popup" in got[0]["msg"], got
    assert "cmd resume" in alarm.SYS_NEXT["POPUP_PAUSE"]
    assert "POPUP_PAUSE" in alarm.fmt_wake(dict(got[0], kind="sys"))
    monkeypatch.setattr(files, "read_state", lambda d: {"owners": {"pause": "gordon"}})      # the player's own pause: no wake, clock reset
    assert [r for r in alarm.sys_reasons(save, cfg, 1100.0) if r["type"] == "POPUP_PAUSE"] == []
    assert str(save) not in alarm._POPUP_SEEN
    cfg0 = {**cfg, "popup_s": 0}
    monkeypatch.setattr(files, "read_state", lambda d: {"owners": {"pause": "popup"}})
    assert [r for r in alarm.sys_reasons(save, cfg0, 1200.0) if r["type"] == "POPUP_PAUSE"], "popup_s 0 = at once"
    assert session.config()["wait"]["popup_s"] == 20


def test_live_trade_keeps_add_and_remove_and_the_draft_applies_them(tmp_path):
    save = tmp_path / "s"
    save.mkdir()
    applied = time.time() - 100
    (save / "plan.json").write_text("{}", encoding="utf-8")
    import os
    os.utime(save / "plan.json", (applied, applied))
    _cli(save, applied + 10, "verb:trade.want", {"add": ["wood", "block"]}, "sent a1")
    _cli(save, applied + 11, "verb:trade.want", {"remove": ["anvil"], "sell_add": ["gem"]}, "sent a2")
    live = plan.live_trade(save)
    assert live == {"want_ops": [{"add": ["wood", "block"], "remove": []}, {"add": [], "remove": ["anvil"]}],
                    "sell_ops": [{"add": ["gem"], "remove": []}]}, live
    assert plan.apply_trade_ops(["bar:iron", "anvil", "cloth"], live["want_ops"]) == ["wood", "block", "bar:iron", "cloth"]
    # a later replacement of the list ends the add / remove history of that list
    _cli(save, applied + 20, "verb:trade.want", {"want": ["food"]}, "sent a3")
    live = plan.live_trade(save)
    assert live["want"] == ["food"] and "want_ops" not in live and live["sell_ops"]
    _cli(save, applied + 30, "verb:trade.want", {"add": ["seeds"]}, "sent a4")
    live = plan.live_trade(save)
    assert plan.apply_trade_ops(live["want"], live["want_ops"]) == ["seeds", "food"]
    assert len(plan.apply_trade_ops([f"t{i}" for i in range(60)], [{"add": ["x"]}])) == 40
    # the draft: propose() puts the running changes into its trade lists
    doc_trade = {"want": ["bar:iron", "anvil", "cloth"], "sell": ["crafts"]}
    for k in ("want", "sell"):
        if live.get(k + "_ops"):
            doc_trade[k] = plan.apply_trade_ops(doc_trade.get(k) or [], live[k + "_ops"])
    assert doc_trade["want"][0] == "seeds"
