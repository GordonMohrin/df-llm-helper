"""Tests: yamlmini, expr, clock, client (mock/replay/record), fair play, snapshot parser."""
import json

import pytest

from conftest import FIX
from dfpilot import yamlmini
from dfpilot.client import (MAX_REPORT_ID_CMD, SERVICES_CMD, MockClient, RecordingClient, ReplayClient,
                            ReplayMismatch, Result, is_write, load_records, parse_json_tolerant)
from dfpilot.clock import FakeClock, GameDate, RealTime, TICKS_PER_DAY
from dfpilot.expr import ExprError, evaluate, names_used
from dfpilot.fairplay import LEGACY_CONSENT_KEY, ExceptionRegistry, FairPlayError, check_command
from dfpilot.snapshot import collect, fixture_snapshot, parse_snapshot


# ---------------------------------------------------------------- yamlmini
def test_yaml_basic_structures():
    src = """
# comment
a: 1
b: [x, 'y z', 3.5, true, null]
c:
  - id: r1
    when: "x > 3 # not a comment"
    do:
      - cmd: claude/status
  - plain
d: |
  zeile1
  zeile2
e: {k: v, n: 2}
f:
- 1
- 2
"""
    d = yamlmini.loads(src)
    assert d["a"] == 1 and d["b"] == ["x", "y z", 3.5, True, None]
    assert d["c"][0]["when"] == "x > 3 # not a comment"
    assert d["c"][0]["do"] == [{"cmd": "claude/status"}] and d["c"][1] == "plain"
    assert d["d"] == "zeile1\nzeile2\n" and d["e"] == {"k": "v", "n": 2} and d["f"] == [1, 2]


def test_yaml_folded_and_errors():
    assert yamlmini.loads("a: >-\n  eins\n  zwei\n") == {"a": "eins zwei"}
    assert yamlmini.loads("") is None
    with pytest.raises(yamlmini.YamlError, match="duplicate"):
        yamlmini.loads("a: 1\na: 2\n")
    with pytest.raises(yamlmini.YamlError, match="line"):
        yamlmini.loads("a: 1\n   b: 2\n")
    with pytest.raises(yamlmini.YamlError):
        yamlmini.loads('a: "open\n')


def test_yaml_roundtrip():
    obj = {"id": "x", "liste": [1, "zwei: drei", {"k": [True, None]}], "leer": [], "t": "a#b"}
    assert yamlmini.loads(yamlmini.dumps(obj)) == obj


# ---------------------------------------------------------------- expr
def test_expr_basics():
    ctx = {"a": 5, "d": {"x": {"y": 2}}, "l": [1, 2, 3], "none": None}
    assert evaluate("a > 3 and d.x.y == 2", ctx) is True
    assert evaluate("none > 3", ctx) is False
    assert evaluate("none is None", ctx) is True
    assert evaluate("sum(v for v in l if v > 1)", ctx) == 5
    assert evaluate("[v * 2 for v in l]", ctx) == [2, 4, 6]
    assert evaluate("missing.attr", ctx) is None
    assert evaluate("len(l) if a else 0", ctx) == 3
    assert evaluate("a // 2 + -1", ctx) == 1
    assert evaluate("1 / 0", ctx) is None
    assert evaluate("'x' in ['x']", ctx) is True and evaluate("'x' not in none", ctx) is True
    assert names_used("a and b.c or any(x for x in l)") == {"a", "b", "l"}


@pytest.mark.parametrize("bad", ["__import__('os')", "a.__class__", "(lambda: 1)()", "a.b()", "x := 1", "",
                                 "a if"])
def test_expr_rejects_unsafe(bad):
    with pytest.raises(ExprError):
        evaluate(bad, {"a": 1})


# ---------------------------------------------------------------- clock
def test_clock_types_do_not_mix():
    rt = RealTime(1000.0)
    gd = GameDate(102, 114200)
    assert (rt + 60) - rt == 60
    with pytest.raises(TypeError):
        rt - gd
    with pytest.raises(TypeError):
        gd - 5
    with pytest.raises(TypeError):
        rt + rt
    assert GameDate(102, 0) - GameDate(101, 0) == 403200
    assert gd.text() == "Y102 Hematite 12"
    assert GameDate.parse_text("12. Hematite, Jahr 102") == GameDate(102, 3 * 28 * TICKS_PER_DAY + 11 * TICKS_PER_DAY)
    assert GameDate.parse_text("J102_Hematite_12") == GameDate.parse_text("12. Hematite, Jahr 102")
    assert GameDate.parse_text("Unsinn") is None and GameDate.parse_text("1. Foo, Jahr 3") is None
    fc = FakeClock(10)
    fc.sleep(5)
    assert fc.now().epoch == 15 and fc.advance(5).epoch == 20
    assert GameDate(1, 0) < GameDate(1, 5)


# ---------------------------------------------------------------- client
def test_parse_json_tolerant_decimal_comma_and_bom():
    raw = (FIX / "gefahr_status.txt").read_text(encoding="utf-8")
    with pytest.raises(json.JSONDecodeError):
        json.loads(raw)   # the real fixture is broken JSON ("fps": 250,0)
    j = parse_json_tolerant(raw)
    assert j["fps"] == 250.0 and j["alarm"] == 0
    assert parse_json_tolerant("﻿Warning\n{\"a\": 1}") == {"a": 1}
    assert parse_json_tolerant("no json") is None and parse_json_tolerant("") is None
    assert parse_json_tolerant('{"a": 1} trailing junk') == {"a": 1}
    assert parse_json_tolerant("{kaputt") is None


@pytest.mark.parametrize("cmd,write", [
    ("claude/status", False), ("claude/report", False), ("claude/mil tabelle", False), ("claude/handel status", False),
    ("claude/area 130 80 90 40 28", False), ("claude/mil guard status", False), (MAX_REPORT_ID_CMD, False),
    (SERVICES_CMD, False), ("claude/handel select --dry", False),
    ("claude/watchdog start", True), ("claude/mil workmode 32 on --apply", True), ("claude/arbeit status", True), ("claude/ueberwacher status", True), ("claude/handel scan Trade", False),
    ("claude/arbeit", True), ('lua "df.global.enabler.fps=30"', True), ("claude/tempo off", True),
    ("claude/handel status --live", True), ("quickfort run x.csv -c 1,2,3", True),
])
def test_is_write(cmd, write):
    assert is_write(cmd) is write


def test_mock_client_fixtures_failures_delays(clock):
    m = MockClient.from_fixture_dir(FIX, clock=clock, fail={"claude/status": 1}, delay={"claude/report": 2.5})
    r1 = m.run("claude/status")
    assert not r1.ok and "injected" in r1.stderr
    assert m.run("claude/status").ok
    t0 = clock.now().epoch
    r = m.run("claude/report")
    assert r.ok and r.json["buerger"] == 24 and clock.now().epoch - t0 == 2.5
    assert not m.run("claude/unknown status").ok
    assert m.run("claude/watchdog start").ok      # unknown write command: ok, logged
    assert m.write_calls == ["claude/watchdog start"]
    m.delay["claude/units"] = 100
    assert "Timeout" in m.run("claude/units", timeout=5).stderr
    strict = MockClient({}, strict=True)
    with pytest.raises(KeyError):
        strict.run("claude/status")
    m.set("x", lambda c: Result.make(c, True, '{"ok": 1}'))
    assert m.run("x").json == {"ok": 1}


def test_run_many_partial_failure(clock):
    m = MockClient({"a": "1"}, clock=clock)
    m.set("b", lambda c: (_ for _ in ()).throw(RuntimeError("kaputt")))
    res = m.run_many(["a", "b", "claude/status"])
    assert [r.ok for r in res] == [True, False, False]
    assert "kaputt" in res[1].stderr


def test_record_replay_roundtrip(tmp_path, mock):
    path = tmp_path / "rec.jsonl"
    rec = RecordingClient(mock, path)
    cmds = ["claude/status", "claude/report", "claude/status", "claude/mil tabelle", "claude/notthere status"]
    orig = [rec.run(c) for c in cmds]
    replay = ReplayClient.from_file(path, strict=True)
    again = [replay.run(c) for c in cmds]
    assert [(r.ok, r.stdout, r.stderr) for r in orig] == [(r.ok, r.stdout, r.stderr) for r in again]
    with pytest.raises(ReplayMismatch):
        replay.run("claude/status")          # called more often than recorded
    with pytest.raises(ReplayMismatch):
        replay.run("claude/units")           # never recorded
    lenient = ReplayClient.from_file(path)
    assert lenient.run("claude/units").ok is False and lenient.run("claude/alert on").ok is True
    _, recs = load_records(path)
    assert len(recs) == 5 and all("ts" in r for r in recs)


def test_replay_timeline():
    recs = [{"t": 0, "cmd": "claude/status", "stdout": '{"drink_days": 80}'},
            {"t": 3, "cmd": "claude/status", "stdout": '{"drink_days": 20}'}]
    rc = ReplayClient(recs)
    rc.set_step(2)
    assert rc.run("claude/status").json["drink_days"] == 80
    rc.set_step(5)
    assert rc.run("claude/status").json["drink_days"] == 20
    with pytest.raises(ReplayMismatch):
        ReplayClient(recs, strict=True).run("claude/report")


def test_load_records_meta_and_error(tmp_path):
    p = tmp_path / "s.jsonl"
    p.write_text('{"meta": {"id": "x"}}\n\n{"cmd": "a", "stdout": "1"}\n', encoding="utf-8")
    meta, recs = load_records(p)
    assert meta == {"id": "x"} and recs == [{"cmd": "a", "stdout": "1"}]
    p.write_text("{kaputt\n", encoding="utf-8")
    with pytest.raises(ValueError, match="not JSON"):
        load_records(p)


# ---------------------------------------------------------------- fairplay
@pytest.mark.parametrize("cmd,rule", [
    ("createitem WEAPON:ITEM_WEAPON_PICK", "FP01"), ("dig-now", "FP02"), ("build-now", "FP03"),
    ("reveal", "FP04"), ("prospect all", "FP05"), ("gui/gm-editor", "FP06"), ("teleport", "FP07"),
    ('lua "df.item.find(187405).flags.foreign=false"', "FP08"), ('lua "u.flags1.left=true"', "FP09"),
    ('lua "u.pos.x=5"', "FP10"), ('lua "d.hidden=false"', "FP11"), ('lua "work_weapons:insert(1)"', "FP12"),
])
def test_fairplay_blocks(cmd, rule, mock):
    with pytest.raises(FairPlayError) as e:
        mock.run(cmd)
    assert e.value.rule == rule
    assert cmd not in mock.calls


@pytest.mark.parametrize("cmd", ["claude/status", "prospect", 'lua "print(u.pos.x == 5)"', "claude/dig 130 1 1 2 2 d",
                                 "quickfort run claude/x.csv -c 1,2,3", "revealed"])
def test_fairplay_allows(cmd):
    check_command(cmd)


def test_exception_registry(tmp_path):
    p = tmp_path / "ex.jsonl"
    p.write_text('{"example": true, "action": "FP08"}\n'
                 '{"action": "FP08", "reason": "E18"}\n'
                 'kaputt\n', encoding="utf-8")
    reg = ExceptionRegistry(p, now_iso="2026-10-01T10:00:00Z")
    assert len(reg.errors) == 2 and not reg.entries
    cmd = 'lua "df.item.find(187405).flags.foreign=false"'
    with pytest.raises(FairPlayError):
        check_command(cmd, reg)
    with pytest.raises(FairPlayError):
        reg.add("FP08", "E18", "")
    reg.add("FP08", "E18 embark picks", "yes, foreign=false for the embark picks", objects=[187405, 187429],
            max_uses=2, expires="2026-12-31T00:00:00Z")
    check_command(cmd, reg)           # allowed (object in the register)
    with pytest.raises(FairPlayError):
        check_command('lua "df.item.find(999999).flags.foreign=false"', reg)   # different object
    check_command(cmd, reg)
    with pytest.raises(FairPlayError):
        check_command(cmd, reg)       # max_uses exhausted
    reg2 = ExceptionRegistry(p, now_iso="2027-01-02T00:00:00Z")
    assert not reg2.allows("FP08", objects=[187405])   # expired
    assert ExceptionRegistry(None).allows("FP08") is False


def test_exception_register_accepts_legacy_consent_field(tmp_path):
    p = tmp_path / "ex.jsonl"
    p.write_text(json.dumps({"action": "FP09", "reason": "stuck traders", LEGACY_CONSENT_KEY: "yes"}) + "\n"
                 + json.dumps({"action": "FP08", "reason": "picks", "player_consent": "ok"}) + "\n", encoding="utf-8")
    reg = ExceptionRegistry(p)
    assert not reg.errors and reg.allows("FP09") and reg.allows("FP08")
    assert {e.player_consent for e in reg.entries} == {"yes", "ok"}
    reg.add("FP10", "x", "y")
    assert json.loads(p.read_text(encoding="utf-8").splitlines()[-1])["player_consent"] == "y"


# ---------------------------------------------------------------- snapshot
def test_fixture_snapshot_values():
    s = fixture_snapshot(FIX)
    assert s.errors == [] and s.fort == "Windrings"
    assert (s.pop_total, s.adults, s.idle, s.drink_days, s.food_days) == (24, 23, 7, 76, 189)
    assert s.date == GameDate(102, 114200) and s.idle_pct == 30.4
    assert s.stocks.meals == 52 and s.stocks.plants == 25 and s.jobs.dig == 63 and s.jobs.by_type["Dig"] == 63
    assert [c.id for c in s.hungry(40000)] == [414, 3473]
    assert s.citizen(3744).name == "Såkzul" and s.citizen(3744).skills["MINING"] == 13
    assert s.citizen(3744).thirst == 23555 and s.citizen(3746).has_pick
    assert {q.name: q.size for q in s.squads} == {"Bergleute": 3, "Wache": 3}
    assert s.pick_holders == 1 and s.diggers == 3
    assert s.caravan_active and not s.danger and s.alerts.refuge_ok is True
    assert s.workdetail("Miners").members == [3744, 3750, 3746, 3745, 414]
    assert s.embark == (100, 263900) and s.game_id == "Windrings|100|263900"
    assert s.fps == 250.0 and s.timestream is False
    assert s.facts()["squad_members"] == 6 and s.to_dict()["date"] == [102, 114200]


def test_parser_tolerant_garbage():
    s = parse_snapshot({"claude/status": "no json", "claude/report": '{"gefaehrdet": ["xx broken"], "jobs": "no"}',
                        "claude/units": '{"units": [{"id": "abc"}, 5, {"id": 7, "pos": [1]}]}',
                        "claude/mil tabelle": "Trupp | Id\nA | 1 | x\n", "claude/config": "[]",
                        "claude/handel status": '{"caravans": [{"name": null}]}'})
    assert s.pop_total is None and s.citizen(7).pos is None
    assert any("no JSON object" in e for e in s.errors) and any("not readable" in e for e in s.errors)
    assert s.squads == [] and s.alerts.caravans[0].name == "?"


def test_parser_failed_commands_and_probes(mock):
    mock.fail["claude/status"] = 1
    s = collect(mock, ["claude/status", "claude/report", MAX_REPORT_ID_CMD, SERVICES_CMD])
    assert s.failed and s.failed[0].startswith("claude/status")
    assert s.max_report_id == 5000 and s.services["watchdog"]["running"] is True
    assert s.pop_total == 24          # fallback from report
