"""FEATURE-003 forbid-watch: forbidden own items by class and cause, game-log correlation, digest/wake, fix (dry run
by default). Fixtures are SYNTHETIC (fixtures/v3/forbid/), the Lua runs under fixtures/v3/hygiene/hygiene_mock.lua."""
import json
import shutil
import subprocess
from pathlib import Path

import pytest

from df_llm_helper.client import MockClient
from df_llm_helper.clock import FakeClock
from df_llm_helper.features import forbid_watch as fw
from df_llm_helper.features import hygiene as hy
from df_llm_helper.store import Store
from df_llm_helper.wake import wake_check

ROOT = Path(__file__).resolve().parent.parent
FIX = ROOT / "fixtures" / "v3" / "forbid"
MOCK = ROOT / "fixtures" / "v3" / "hygiene" / "hygiene_mock.lua"
LUA = shutil.which("lua5.4") or shutil.which("lua")


def fx(name):
    return (FIX / name).read_text(encoding="utf-8")


@pytest.fixture
def clock():
    return FakeClock(1_790_840_000.0)


def client(clock, status="forbid_all_barrels.json", fix=None):
    m = MockClient(clock=clock)
    if status:
        m.set(fw.STATUS_CMD, fx(status))
    m.prefix_handlers.append(("claude/pilot_forbid fix", fix or (lambda c: json.dumps(
        {"ok": True, "applied": "--apply" in c, "candidates": 300, "changed": 300 if "--apply" in c else 0,
         "ids": list(range(100, 300)), "by_class": {"container": 300},
         "skipped": {"hidden": 0, "dump_zone": 2, "class": 743, "cap": 0}, "log": "tools/out/forbid-fix.log"}))))
    return m


def watch(m, clock, store=None, gamelog=None, tools=None, cfg=None):
    return fw.ForbidWatch(m, store or Store(), clock, cfg, gamelog=gamelog, tools=tools)


# ------------------------------------------------------------------ acceptance 1: all barrels forbidden
def test_all_barrels_forbidden_prints_100_percent_and_warning(clock):
    r = watch(client(clock), clock).status()
    assert r.ok and r.source == "pilot_forbid" and r.state == "warn" and r.drink_pct == 100
    lines = fw.report_lines(r, fw.DEFAULTS)
    assert lines[0] == "! Forbidden own items: 1043 (drinks 475/475, food 0/220)"
    assert lines[1] == "!! FORBID: 1043 own items forbidden (drinks 475 = 100 %), 0 Forbidden-area cancels in 10 min " \
                       "-> drinking blocked"
    assert any(ln.startswith("causes: dense area (mass forbid designation or a script) 1043") for ln in lines)
    assert any(ln.startswith("where: z130 x86..101 y112..127: 900 (container 260, material 640, stockpile #495)")
               for ln in lines)
    assert any("forbid_other_dead_items" in ln for ln in lines)
    assert any(ln.startswith("fix: python -m df_llm_helper forbid-watch fix") for ln in lines)


@pytest.mark.skipif(not LUA, reason="lua5.4 not installed")
def test_all_barrels_forbidden_digest_shows_both_counts(tmp_path):
    """Acceptance 1 (digest half, BUG-125): claude/status under the mock -> digest status line and alert."""
    from df_llm_helper.config import DEFAULTS
    from df_llm_helper.digest import DigestState, build_digest
    from df_llm_helper.snapshot import parse_snapshot
    sys_mock = ROOT / "tests" / "lua_mock" / "claude_mock.lua"
    setup = tmp_path / "setup.lua"
    from test_lua_claude import _FORBID_SETUP
    setup.write_text("MOCK_FORBID = true\n" + _FORBID_SETUP, encoding="utf-8")
    home = tmp_path / "home"
    (home / "tools" / "out").mkdir(parents=True)
    r = subprocess.run([LUA, str(sys_mock), str(ROOT / "lua" / "claude" / "status.lua")], capture_output=True, text=True,
                       timeout=10, env={"PATH": "/usr/bin:/bin", "DF_LLM_HELPER_HOME": str(home), "MOCK_HOME": str(home),
                                        "MOCK_SETUP": str(setup)})
    assert r.returncode == 0, r.stderr
    snap = parse_snapshot({"claude/status": r.stdout})
    text, _ = build_digest(snap, DigestState(), th=DEFAULTS["thresholds"])
    assert "(+250 forbidden)" in text and "!! Drinks 0 available (+250 forbidden, 100%)" in text


# ------------------------------------------------------------------ acceptance 2: game-log correlation
def test_gamelog_37_cancels_with_forbidden_drinks(clock, tmp_path):
    gl = tmp_path / "gamelog.txt"
    gl.write_text(fx("gamelog_forbidden_37.txt"), encoding="utf-8")
    st = Store()
    r = watch(client(clock), clock, st, gamelog=gl).status()
    assert r.cancels == 37 and r.cancel_jobs == {"Drink": 30, "Eat": 7}
    line = fw.forbid_line(r)
    assert line == "FORBID: 1043 own items forbidden (drinks 475 = 100 %), 37 Forbidden-area cancels in 10 min -> " \
                   "drinking blocked"
    assert any(ln.startswith("cancels: Drink 30, Eat 7") for ln in fw.report_lines(r, fw.DEFAULTS))
    # the same lines are not counted twice; they drop out of the window after log_minutes
    clock.sleep(120)
    assert watch(client(clock), clock, st, gamelog=gl).status().cancels == 37
    clock.sleep(600)
    assert watch(client(clock), clock, st, gamelog=gl).status().cancels == 0
    with gl.open("a", encoding="utf-8") as f:
        f.write("Urist McDwarf cancels Drink: Forbidden area.\n" * 3)
    assert watch(client(clock), clock, st, gamelog=gl).status().cancels == 3


def test_gamelog_cancels_without_forbidden_items_point_to_burrow(clock, tmp_path):
    gl = tmp_path / "gamelog.txt"
    gl.write_text(fx("gamelog_forbidden_37.txt"), encoding="utf-8")
    r = watch(client(clock, "forbid_none.json"), clock, gamelog=gl).status()
    assert r.state == "area"
    lines = fw.report_lines(r, fw.DEFAULTS)
    assert lines[1] == "! FORBID: 0 own items forbidden, 37 Forbidden-area cancels in 10 min: Forbidden-area cancels " \
                       "without forbidden items (burrow/zone?)"


def test_first_read_takes_only_the_log_tail(clock, tmp_path):
    gl = tmp_path / "gamelog.txt"
    gl.write_text("Urist cancels Drink: Forbidden area.\n" * 500 + "noise\n" * 280, encoding="utf-8")
    r = watch(client(clock), clock, gamelog=gl).status()
    assert r.cancels == 20 and "first read: last 300 log lines" in r.log_note


# ------------------------------------------------------------------ acceptance 3: nothing forbidden
def test_no_forbidden_exit_0_no_wake(clock, cfg, monkeypatch, capsys, tmp_path):
    import df_llm_helper.cli as cli
    from df_llm_helper.pilot import Pilot
    st = Store()
    m = client(clock, "forbid_none.json")
    monkeypatch.setattr(cli, "_pilot", lambda args: Pilot(cfg, m, store=st, clock=clock))
    assert cli.main(["forbid-watch"]) == 0
    out = capsys.readouterr().out
    assert out.startswith("Forbidden own items: 0") and "FORBID" not in out
    p = Pilot(cfg, m, store=st, clock=clock)
    assert fw.check_hook(p, None, False) == []
    tools = Path(cfg.get("paths.tools"))
    from df_llm_helper.toolsfs import ToolsDir
    assert wake_check(ToolsDir(tools, clock), st, clock, emit_existing=True) == []
    assert m.write_calls == []


# ------------------------------------------------------------------ check hook: digest line + wake once per change
def test_check_hook_warns_and_wakes_once_per_state_change(clock, cfg):
    from df_llm_helper.pilot import Pilot
    from df_llm_helper.toolsfs import ToolsDir
    st = Store()
    m = client(clock)
    p = Pilot(cfg, m, store=st, clock=clock)
    lines = fw.check_hook(p, None, False)
    assert lines[0] == "Forbid-watch: ! Forbidden own items: 1043 (drinks 475/475, food 0/220)"
    assert lines[1].startswith("Forbid-watch: !! FORBID: 1043 own items forbidden (drinks 475 = 100 %)")
    tools = ToolsDir(Path(cfg.get("paths.tools")), clock)
    wl = wake_check(tools, st, clock, emit_existing=True)
    assert len(wl) == 1 and "Forbidden own items: 1043" in wl[0]
    assert fw.check_hook(p, None, False) == []                       # interval
    clock.sleep(400)
    assert fw.check_hook(p, None, False) == []                       # same state and text: no repeat
    assert wake_check(tools, st, clock) == []
    m.set(fw.STATUS_CMD, fx("forbid_none.json"))
    clock.sleep(400)
    assert fw.check_hook(p, None, False) == ["Forbid-watch: resolved - Forbidden own items: 0 (drinks 0/475, food 0/220)"]
    m.set(fw.STATUS_CMD, fx("forbid_all_barrels.json"))
    clock.sleep(400)
    assert len(fw.check_hook(p, None, False)) == 2
    assert len(wake_check(tools, st, clock)) == 1                     # new transition -> one new wake line
    # digest: the crit warning appears once as a line
    text = p.digest(include_warnings=True)
    assert "[forbid-watch] Forbidden own items: 1043" in text


def test_hygiene_forbid_warning_defers_to_forbid_watch(clock, cfg):
    from df_llm_helper.pilot import Pilot
    from test_hygiene import client as hclient
    m = hclient(clock, ["status_j109_block0.json", "status_j109_block1.json"], "report_no_zone.json")
    forb = json.loads(fx("forbid_all_barrels.json"))
    m.set("claude/pilot_hygiene forbid", json.dumps(forb))
    m.set(fw.STATUS_CMD, json.dumps(forb))
    st = Store()
    p = Pilot(cfg, m, store=st, clock=clock)
    assert fw.check_hook(p, None, False)
    lines = hy.check_hook(p, None, False)
    assert not [ln for ln in lines if "forbidden own items" in ln]
    assert st.get("forbid_watch.active_ts") is not None


def test_fallback_to_pilot_hygiene_forbid(clock):
    m = MockClient(clock=clock)
    m.set("claude/pilot_hygiene forbid", json.dumps({"ok": True, "total": 10, "classes": {"container": 10},
                                                     "drink": {"total": 250, "blocked": 250}, "food": {"total": 7}}))
    r = watch(m, clock).status()
    assert r.ok and r.source == "pilot_hygiene" and r.state == "warn"
    assert any("causes: unknown (claude/pilot_forbid not installed" in ln for ln in fw.report_lines(r, fw.DEFAULTS))
    r = watch(MockClient(clock=clock), clock).status()
    assert not r.ok and "not readable" in fw.report_lines(r, fw.DEFAULTS)[0]


def test_siege_loot_only_is_info_not_warn(clock):
    j = json.loads(fx("forbid_none.json"))
    j.update(total=400, classes={"other": 400}, causes={"other_dead": 300, "foreign_made": 100})
    m = MockClient(clock=clock)
    m.set(fw.STATUS_CMD, json.dumps(j))
    r = watch(m, clock).status()
    assert r.state == "info"
    lines = fw.report_lines(r, fw.DEFAULTS)
    assert not lines[0].startswith("!") and not lines[1].startswith("!")


# ------------------------------------------------------------------ fix: dry run by default, --apply only
def test_fix_dry_by_default_and_apply_logged(clock, cfg, monkeypatch, capsys):
    import df_llm_helper.cli as cli
    from df_llm_helper.pilot import Pilot
    st = Store()
    m = client(clock)
    monkeypatch.setattr(cli, "_pilot", lambda args: Pilot(cfg, m, store=st, clock=clock))
    assert cli.main(["forbid-watch", "fix"]) == 0
    out = capsys.readouterr().out
    assert out.startswith("[dry] would unforbid 300 own items (container 300)") and m.write_calls == []
    assert m.calls[-1] == "claude/pilot_forbid fix drink,food,container --max 2000 --dry"
    assert cli.main(["forbid-watch", "--fix", "--classes", "drink,container", "--apply"]) == 0
    out = capsys.readouterr().out
    assert out.startswith("Unforbade 300 own items") and m.write_calls == ["claude/pilot_forbid fix drink,container --max "
                                                                           "2000 --apply"]
    assert st.actions()[-1]["action"] == "fix" and st.actions()[-1]["dry_run"] == 0
    assert cli.main(["forbid-watch", "fix", "--classes", "other", "--apply"]) == 2     # siege loot: refused
    assert "not allowed" in capsys.readouterr().err
    assert cli.main(["forbid-watch", "--apply"]) == 2                                  # status is read only


def test_fix_loop_protection(clock):
    st = Store()
    w = watch(client(clock), clock, st)
    for _ in range(3):
        assert w.fix(apply=True)[0].startswith("Unforbade")
    assert w.fix(apply=True)[0].startswith("Loop protection")


def test_json_output(clock, cfg, monkeypatch, capsys):
    import df_llm_helper.cli as cli
    from df_llm_helper.pilot import Pilot
    m = client(clock)
    monkeypatch.setattr(cli, "_pilot", lambda args: Pilot(cfg, m, store=Store(), clock=clock))
    assert cli.main(["forbid-watch", "--json"]) == 0
    j = json.loads(capsys.readouterr().out)
    assert j["state"] == "warn" and j["drink_pct"] == 100 and j["causes"]["area"] == 1043
    assert j["forbid_line"].startswith("FORBID: 1043 own items forbidden")


def test_script_log_hint(clock, tmp_path):
    tools = tmp_path / "tools"
    (tools / "out").mkdir(parents=True)
    (tools / "out" / "sperre.log").write_text("x\nsperre: forbid items in box 3\n", encoding="utf-8")
    (tools / "out" / "forbid-fix.log").write_text("unforbid 1. Granite n=3 ids=1,2,3\n", encoding="utf-8")
    (tools / "events.log").write_text("info nothing\n", encoding="utf-8")
    r = watch(client(clock), clock, tools=tools).status()
    assert any(s.startswith("sperre.log: 1 lines mention forbid") for s in r.scripts)
    assert any(s.startswith("forbid-fix.log: 1 earlier unforbid runs") for s in r.scripts)


# ------------------------------------------------------------------ the Lua script (pilot_forbid) under the mock
def run_lua(tmp_path, items, *args, buildings=None, env=None):
    ip = tmp_path / "items.json"
    ip.write_text(json.dumps(items), encoding="utf-8")
    e = {"MOCK_ITEMS": str(ip), "PATH": "/usr/bin:/bin", "MOCK_LOG": str(tmp_path / "fix.log")}
    if buildings is not None:
        bp = tmp_path / "b.json"
        bp.write_text(json.dumps(buildings), encoding="utf-8")
        e["MOCK_BUILDINGS"] = str(bp)
    e.update(env or {})
    r = subprocess.run([LUA, str(MOCK), str(ROOT / "lua" / "pilot_forbid.lua"), *args], capture_output=True, text=True,
                       timeout=30, env=e)
    assert r.returncode == 0, r.stderr
    lines = r.stdout.strip().splitlines()
    tail = {ln.split(" ", 1)[0]: json.loads(ln.split(" ", 1)[1]) for ln in lines[1:]}
    return json.loads(lines[0]), tail


def run5_items():
    items = []
    for b in range(10):                      # 10 forbidden barrels with 25 drinks each, all in one map block
        items.append({"id": 100 + b, "type": "BARREL", "x": 86 + b, "y": 112, "z": 130, "forbid": True})
        items.append({"id": 200 + b, "type": "DRINK", "x": 86 + b, "y": 112, "z": 130, "n": 25, "container": 100 + b})
    for i in range(15):                      # 15 forbidden blocks in the same block -> 25 forbidden there: 'area'
        items.append({"id": 300 + i, "type": "BLOCKS", "x": 86 + i % 10, "y": 114 + i // 10, "z": 130,
                      "forbid": True})
    items += [{"id": 400, "type": "CORPSE", "x": 10, "y": 10, "z": 131, "forbid": True, "race": 100},
              {"id": 401, "type": "WEAPON", "x": 11, "y": 40, "z": 131, "forbid": True, "maker": 300},
              {"id": 402, "type": "BARREL", "x": 51, "y": 51, "z": 131, "forbid": True},        # on the dump zone
              {"id": 403, "type": "BIN", "x": 60, "y": 60, "z": 120, "forbid": True, "hidden": True},
              {"id": 404, "type": "BARREL", "x": 70, "y": 70, "z": 131, "forbid": True, "foreign": True},
              {"id": 405, "type": "FOOD", "x": 71, "y": 70, "z": 131, "n": 7},
              {"id": 406, "type": "AMMO", "x": 72, "y": 90, "z": 131, "forbid": True},
              {"id": 407, "type": "BIN", "x": 73, "y": 90, "z": 131, "in_job": True}]
    return items


ZONE = [{"id": 538, "x1": 50, "y1": 50, "x2": 52, "y2": 52, "z": 131}]


@pytest.mark.skipif(not LUA, reason="lua5.4 not installed")
def test_lua_status_classes_causes_clusters(tmp_path):
    st = tmp_path / "st.json"
    st.write_text(json.dumps({"forbid_other_dead_items": 1, "forbid_used_ammo": 1}), encoding="utf-8")
    out, tail = run_lua(tmp_path, run5_items(), "status", buildings=ZONE, env={"MOCK_STANDING": str(st)})
    assert out["classes"] == {"container": 11, "drink": 0, "food": 0, "material": 15, "other": 3}
    assert out["total"] == 29 and out["hidden"] == 1                # foreign barrel never counted
    assert out["drink"] == {"total": 250, "blocked": 250, "in_forbidden_container": 250}
    assert out["food"]["blocked"] == 0 and out["food"]["total"] == 7
    assert out["causes"] == {"area": 25, "dump_zone": 1, "other_dead": 1, "foreign_made": 1, "used_ammo": 1,
                             "own_dead": 0, "unknown": 0}
    c0 = out["clusters"][0]
    assert (c0["z"], c0["n"], c0["x1"], c0["x2"], c0["y2"]) == (130, 25, 86, 95, 115)
    assert out["standing"]["forbid_other_dead_items"] is True and out["flags"]["in_job"] == 1
    assert len(tail["FORBIDDEN"]) == 31                               # read only
    r = fw.parse_status(out, "pilot_forbid")
    r.state = fw.assess(r, fw.DEFAULTS)
    assert r.state == "warn" and fw.forbid_line(r).startswith("FORBID: 29 own items forbidden (drinks 250 = 100 %)")


@pytest.mark.skipif(not LUA, reason="lua5.4 not installed")
def test_lua_fix_dry_then_apply_only_own_fixable_items(tmp_path):
    items = run5_items()
    out, tail = run_lua(tmp_path, items, "fix", "drink,food,container,other", "--dry", buildings=ZONE)
    assert out["candidates"] == 10 and out["changed"] == 0 and out["refused_classes"] == ["other"]
    assert len(tail["FORBIDDEN"]) == 31 and not (tmp_path / "fix.log").exists()
    assert out["skipped"]["dump_zone"] == 1 and out["skipped"]["hidden"] == 1
    out, tail = run_lua(tmp_path, items, "fix", "drink,food,container", "--apply", buildings=ZONE)
    assert out["changed"] == 10 and sorted(out["ids"]) == list(range(100, 110))
    left = set(tail["FORBIDDEN"])
    assert not left & set(range(100, 110))
    assert {402, 403, 404, 400, 401, 406} <= left and set(range(300, 315)) <= left     # dump zone/hidden/foreign/loot/blocks
    log = (tmp_path / "fix.log").read_text(encoding="utf-8")
    assert log.startswith("unforbid 1. Granite, Jahr 122 n=10 ids=100,")
    out, _ = run_lua(tmp_path, items, "fix", "material", "--max", "4", "--apply", buildings=ZONE)
    assert out["changed"] == 4 and out["skipped"]["cap"] == 11
    out, _ = run_lua(tmp_path, items, "fix", "other", buildings=ZONE)
    assert out["ok"] is False and "no fixable class" in out["reason"]
